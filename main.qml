import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import Qt.labs.folderlistmodel
import org.qfield
import org.qgis
import Theme

Item {
  id: plugin

  property var mainWindow: iface.mainWindow()
  property var uploadQueue: []
  property bool isProcessingQueue: false
  property string currentUploadPath: ""
  property bool manualUploadTriggered: false
  property string lastActiveWebdavProject: ""
  property date nextScheduledCheck: new Date(0)

  Settings {
    id: settings
    category: "qfield-webdav-autoupload"

    property bool enabled: false
    property int intervalHours: 2
    property string projectStatuses: "{}"
    property string pendingUploads: "[]"
    property string knownProjects: "[]"
    property string timerAnchor: ""
  }

  Component.onCompleted: {
    iface.addItemToDashboardActionsToolbar(uploadButton)
    updateActiveProject()

    if (settings.enabled) {
      if (!settings.timerAnchor) {
        settings.timerAnchor = new Date().toISOString()
      }
      updateNextCheck()
      Qt.callLater(function() { runAutoUploadCycle(false) })
      uploadTimer.restart()
    }
  }

  Component.onDestruction: {
    iface.removeItemFromDashboardActionsToolbar(uploadButton)
  }

  function configure() {
    settingsDialog.open()
  }

  Connections {
    target: qgisProject ? qgisProject : null

    function onFileNameChanged() {
      var previousProject = lastActiveWebdavProject
      updateActiveProject()

      if (!settings.enabled) {
        return
      }

      // If we left a WebDAV project that was marked as "due" (missed a scheduled upload),
      // upload it now since we're no longer actively using it
      if (previousProject && previousProject !== lastActiveWebdavProject) {
        if (isPending(previousProject) && !isProcessingQueue && !webdav.isUploadingPath) {
          uploadQueue = [previousProject]
          isProcessingQueue = true
          manualUploadTriggered = false
          processNextInQueue()
        }
      }
    }
  }

  Timer {
    id: uploadTimer
    repeat: true
    running: false
    interval: Math.max(1, settings.intervalHours) * 3600000

    onTriggered: {
      settings.timerAnchor = new Date().toISOString()
      updateNextCheck()
      runAutoUploadCycle(true)
    }
  }

  WebdavConnection {
    id: webdav

    onIsUploadingPathChanged: {
      if (isUploadingPath && manualUploadTriggered) {
        uploadOverlay.open()
      } else if (!isUploadingPath) {
        uploadOverlay.close()
      }
    }

    onUploadFinished: function(success, message) {
      if (currentUploadPath) {
        saveProjectStatus(currentUploadPath, success ? "success" : "failed", message)

        if (success) {
          removePending(currentUploadPath)
        } else {
          addPending(currentUploadPath)
        }
      }

      if (manualUploadTriggered) {
        uploadOverlay.close()
        mainWindow.displayToast(success ? qsTr("Upload complete") : qsTr("Upload failed: %1").arg(message))
        manualUploadTriggered = false
      }

      if (isProcessingQueue) {
        Qt.callLater(processNextInQueue)
      } else {
        currentUploadPath = ""
      }
    }

    onUploadSkipped: function(reason) {
      if (currentUploadPath) {
        saveProjectStatus(currentUploadPath, "skipped", reason)

        if (isNoChangesReason(reason)) {
          removePending(currentUploadPath)
        } else {
          addPending(currentUploadPath)
        }
      }

      if (manualUploadTriggered) {
        uploadOverlay.close()
        mainWindow.displayToast(qsTr("Skipped: %1").arg(reason))
        manualUploadTriggered = false
      }

      if (isProcessingQueue) {
        Qt.callLater(processNextInQueue)
      } else {
        currentUploadPath = ""
      }
    }
  }

  QfToolButton {
    id: uploadButton
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    height: parent ? parent.height * 0.9 : 48
    width: height
    iconSource: Qt.resolvedUrl("webdav-upload-button.svg")
    iconColor: Theme.mainTextColor
    bgcolor: "transparent"
    enabled: !webdav.isUploadingPath
    opacity: enabled ? 1.0 : 0.4
    onClicked: triggerManualUpload()
  }

  QfDialog {
    id: uploadOverlay
    parent: mainWindow.contentItem
    modal: true
    closePolicy: Popup.NoAutoClose
    standardButtons: Dialog.NoButton
    title: qsTr("Uploading to WebDAV")

    width: Math.min(parent.width - 40, 320)
    x: (parent.width - width) / 2
    y: (parent.height - height) / 2

    ColumnLayout {
      width: parent.width
      spacing: 16

      Label {
        Layout.fillWidth: true
        text: qsTr("Please wait…")
        font: Theme.tipFont
        color: Theme.secondaryTextColor
        wrapMode: Text.WordWrap
      }

      ProgressBar {
        Layout.fillWidth: true
        from: 0
        to: 1
        value: webdav.progress
        indeterminate: webdav.progress < 0.01
      }

      Label {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignRight
        text: Math.round(webdav.progress * 100) + "%"
        font: Theme.tipFont
        color: Theme.secondaryTextColor
        visible: webdav.progress >= 0.01
      }
    }
  }

  QfDialog {
    id: settingsDialog
    parent: mainWindow.contentItem
    modal: true
    title: qsTr("WebDAV Scheduler")
    standardButtons: Dialog.Ok | Dialog.Cancel

    width: Math.min(parent.width - 40, 400)
    x: (parent.width - width) / 2
    y: (parent.height - height) / 2

    onOpened: {
      enableSwitch.checked = settings.enabled
      intervalTumbler.currentIndex = Math.max(0, settings.intervalHours - 1)
      updateNextCheck()
      refreshStatus()
    }

    onAccepted: {
      settings.enabled = enableSwitch.checked
      settings.intervalHours = intervalTumbler.currentIndex + 1

      if (settings.enabled) {
        settings.timerAnchor = new Date().toISOString()
        updateNextCheck()
        updateActiveProject()
        Qt.callLater(function() { runAutoUploadCycle(false) })
        uploadTimer.restart()
      } else {
        uploadTimer.stop()
        settings.timerAnchor = ""
        updateNextCheck()
        savePending([])
      }

      mainWindow.displayToast(qsTr("Settings saved"))
    }

    function refreshStatus() {
      var path = getProjectPath()
      if (path) {
        var root = findProjectRoot(path)
        if (isValidRoot(root)) {
          statusSection.projectRoot = root
          statusSection.statusData = getProjectStatus(root)
          statusSection.visible = true
          return
        }
      }
      statusSection.visible = false
    }

    ColumnLayout {
      width: parent.width
      spacing: 20

      RowLayout {
        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
          Layout.fillWidth: true
          spacing: 4

          Label {
            text: qsTr("Enable auto-upload")
            font: Theme.defaultFont
            color: Theme.mainTextColor
          }

          Label {
            text: qsTr("Sync projects automatically in background")
            font: Theme.tipFont
            color: Theme.secondaryTextColor
          }
        }

        Switch { id: enableSwitch }
      }

      Rectangle {
        Layout.fillWidth: true
        height: 1
        color: Theme.controlBorderColor
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 12
        opacity: enableSwitch.checked ? 1.0 : 0.4

        Label {
          text: qsTr("Upload interval")
          font: Theme.defaultFont
          color: Theme.mainTextColor
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: 16

          Item {
            Layout.preferredWidth: 60
            Layout.preferredHeight: 90

            Tumbler {
              id: intervalTumbler
              anchors.fill: parent
              model: 24
              wrap: true
              visibleItemCount: 3
              enabled: enableSwitch.checked

              background: Rectangle { color: "transparent" }

              delegate: Label {
                text: modelData + 1
                font: Theme.defaultFont
                color: Theme.mainTextColor
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                opacity: 1.0 - Math.abs(Tumbler.displacement) / (intervalTumbler.visibleItemCount / 2)
              }
            }

            Rectangle {
              anchors.centerIn: parent
              width: parent.width + 8
              height: 30
              color: "transparent"
              border.color: enableSwitch.checked ? Theme.mainColor : Theme.controlBorderColor
              border.width: 1
              radius: 4
            }
          }

          Label {
            text: (intervalTumbler.currentIndex + 1) === 1 ? qsTr("hour") : qsTr("hours")
            font: Theme.defaultFont
            color: Theme.mainTextColor
          }

          Item { Layout.fillWidth: true }
        }
      }

      Rectangle {
        Layout.fillWidth: true
        height: 1
        color: Theme.controlBorderColor
        visible: statusSection.visible
      }

      ColumnLayout {
        id: statusSection
        Layout.fillWidth: true
        spacing: 12
        visible: false

        property string projectRoot: ""
        property var statusData: ({})

        Label {
          text: qsTr("Status")
          font.family: Theme.defaultFont.family
          font.pointSize: Theme.defaultFont.pointSize
          font.bold: true
          color: Theme.mainTextColor
        }

        GridLayout {
          Layout.fillWidth: true
          columns: 2
          columnSpacing: 20
          rowSpacing: 8

          Label {
            text: qsTr("Last result:")
            font: Theme.tipFont
            color: Theme.secondaryTextColor
          }

          Label {
            text: {
              var s = statusSection.statusData.status
              if (s === "success") return qsTr("Success")
              if (s === "failed") return qsTr("Failed")
              if (s === "skipped") return qsTr("Skipped")
              return qsTr("Never")
            }
            font: Theme.tipFont
            color: {
              var s = statusSection.statusData.status
              if (s === "success") return Theme.mainColor
              if (s === "failed") return Theme.errorColor
              return Theme.mainTextColor
            }
          }

          Label { text: qsTr("Last upload:")
            font: Theme.tipFont
            color: Theme.secondaryTextColor
          }

          Label {
            text: {
              var ts = statusSection.statusData.timestamp
              if (ts) return Qt.formatDateTime(new Date(ts), "MMM d, hh:mm")
              return qsTr("Never")
            }
            font: Theme.tipFont
            color: Theme.mainTextColor
          }

          Label {
            text: qsTr("Next check:")
            font: Theme.tipFont
            color: Theme.secondaryTextColor
            visible: settings.enabled
          }

          Label {
            text: nextScheduledCheck.getTime() > 0 ? Qt.formatDateTime(nextScheduledCheck, "MMM d, hh:mm") : qsTr("Pending")
            font: Theme.tipFont
            color: Theme.mainTextColor
            visible: settings.enabled
          }
        }

        // show message for failed OR skipped
        Label {
          Layout.fillWidth: true
          visible: (statusSection.statusData.status === "failed" || statusSection.statusData.status === "skipped") && statusSection.statusData.message
          text: statusSection.statusData.message || ""
          font: Theme.tipFont
          color: statusSection.statusData.status === "failed" ? Theme.errorColor : Theme.secondaryTextColor
          wrapMode: Text.WordWrap
        }
      }

      Rectangle {
        Layout.fillWidth: true
        height: 1
        color: Theme.controlBorderColor
      }

      Label {
        Layout.fillWidth: true
        text: qsTr("Use the toolbar button in the dashboard for manual uploads.")
        font: Theme.tipFont
        color: Theme.secondaryTextColor
        wrapMode: Text.WordWrap
      }
    }
  }

  QtObject {
    id: folderScanner

    property var callback: null
    property var foundProjects: []
    property var pendingFolders: []
    property bool scanning: false

    function startScan(rootPath, cb) {
      if (scanning) {
        return
      }
      callback = cb
      foundProjects = []
      pendingFolders = [rootPath]
      scanning = true
      scanNext()
    }

    function scanNext() {
      if (pendingFolders.length === 0) {
        scanning = false
        if (callback) {
          callback(foundProjects)
        }
        return
      }
      var folder = pendingFolders.shift()
      scanModel.folder = Qt.resolvedUrl("file://" + folder)
    }

    function handleResults() {
      for (var i = 0; i < scanModel.count; i++) {
        var fileName = scanModel.get(i, "fileName")
        var filePath = scanModel.get(i, "filePath")
        var isDir = scanModel.get(i, "fileIsDir")

        var cleanPath = filePath.toString()
        if (cleanPath.startsWith("file://")) {
          cleanPath = cleanPath.substring(7)
        }
        cleanPath = decodeURIComponent(cleanPath)

        if (fileName === "qfield_webdav_configuration.json") {
          var projectRoot = cleanPath.replace("/qfield_webdav_configuration.json", "")
          if (foundProjects.indexOf(projectRoot) === -1) {
            foundProjects.push(projectRoot)
          }
        } else if (isDir && fileName.charAt(0) !== ".") {
          pendingFolders.push(cleanPath)
        }
      }
      scanNext()
    }
  }

  FolderListModel {
    id: scanModel
    showDirs: true
    showFiles: true
    showHidden: false
    sortField: FolderListModel.Name

    onStatusChanged: {
      if (status === FolderListModel.Ready) {
        folderScanner.handleResults()
      } else if (status === FolderListModel.Error || status === FolderListModel.Null) {
        folderScanner.scanNext()
      }
    }
  }

  function getProjectPath() {
    if (qgisProject && qgisProject.fileName) {
      var path = qgisProject.fileName.toString()
      if (path.startsWith("file://")) {
        path = path.substring(7)
      }
      return decodeURIComponent(path)
    }
    return ""
  }

  function findProjectRoot(path) {
    path = path.replace(/\\/g, "/").replace(/\/+$/, "")
    var parts = path.split("/")
    for (var i = parts.length; i >= 1; i--) {
      var testPath = parts.slice(0, i).join("/")
      if (testPath && webdav.hasWebdavConfiguration(testPath)) {
        return testPath
      }
    }
    return ""
  }

  function isValidRoot(root) {
    return root && webdav.hasWebdavConfiguration(root)
  }

  function isCurrentProject(projectRoot) {
    var current = getProjectPath()
    if (!current || !projectRoot) {
      return false
    }
    current = current.replace(/\\/g, "/").replace(/\/+$/, "")
    projectRoot = projectRoot.replace(/\\/g, "/").replace(/\/+$/, "")
    return current.startsWith(projectRoot + "/") || current === projectRoot
  }

  function isNoChangesReason(reason) {
    if (!reason) {
      return false
    }
    var r = reason.toLowerCase()
    return r.indexOf("no changes") !== -1 ||
           r.indexOf("no local changes") !== -1 ||
           r.indexOf("nothing to upload") !== -1 ||
           r.indexOf("up to date") !== -1
  }

  function getProjectStatuses() {
    try {
      return JSON.parse(settings.projectStatuses)
    } catch (e) {
      return {}
    }
  }

  function getProjectStatus(projectRoot) {
    var statuses = getProjectStatuses()
    var key = Qt.md5(projectRoot)
    return statuses[key] || {}
  }

  function saveProjectStatus(projectRoot, status, message) {
    var statuses = getProjectStatuses()
    var key = Qt.md5(projectRoot)
    statuses[key] = { status: status, message: message || "", timestamp: new Date().toISOString() }
    settings.projectStatuses = JSON.stringify(statuses)
  }

  function getPending() {
    try {
      return JSON.parse(settings.pendingUploads)
    } catch (e) {
      return []
    }
  }

  function savePending(list) {
    settings.pendingUploads = JSON.stringify(list)
  }

  function addPending(projectRoot) {
    var list = getPending()
    if (list.indexOf(projectRoot) === -1) {
      list.push(projectRoot)
      savePending(list)
    }
  }

  function removePending(projectRoot) {
    var list = getPending()
    var index = list.indexOf(projectRoot)
    if (index !== -1) {
      list.splice(index, 1)
      savePending(list)
    }
  }

  function isPending(projectRoot) {
    return getPending().indexOf(projectRoot) !== -1
  }

  function getKnownProjects() {
    try {
      return JSON.parse(settings.knownProjects)
    } catch (e) {
      return []
    }
  }

  function saveKnownProjects(list) {
    settings.knownProjects = JSON.stringify(list)
  }

  function rememberProject(root) {
    if (!root) {
      return
    }
    var list = getKnownProjects()
    if (list.indexOf(root) === -1) {
      list.push(root)
      saveKnownProjects(list)
    }
  }

  function updateNextCheck() {
    if (!settings.enabled) {
      nextScheduledCheck = new Date(0)
      return
    }

    var anchor = settings.timerAnchor ? new Date(settings.timerAnchor) : new Date()
    if (isNaN(anchor.getTime())) {
      anchor = new Date()
    }

    var now = new Date()
    var ms = Math.max(1, settings.intervalHours) * 3600000
    var elapsed = now.getTime() - anchor.getTime()
    var steps = Math.max(1, Math.floor(elapsed / ms) + 1)
    nextScheduledCheck = new Date(anchor.getTime() + steps * ms)
  }

  function updateActiveProject() {
    var path = getProjectPath()
    if (path) {
      var root = findProjectRoot(path)
      if (isValidRoot(root)) {
        lastActiveWebdavProject = root
        rememberProject(root)
        return
      }
    }
    lastActiveWebdavProject = ""
  }

  function findWebdavProjects(callback) {
    var appDir = PlatformUtilities.applicationDirectory
    if (!appDir) {
      callback([]);
      return
    }
    if (appDir.endsWith("/")) {
      appDir = appDir.slice(0, -1)
    }
    var importedDir = appDir + "/Imported Projects"
    folderScanner.startScan(importedDir, callback)
  }

  function getAllProjects(callback) {
    var known = getKnownProjects()
    findWebdavProjects(function(scanned) {
      var all = known.slice()
      for (var i = 0; i < scanned.length; i++) {
        if (all.indexOf(scanned[i]) === -1) {
          all.push(scanned[i])
        }
      }
      var valid = []
      for (var j = 0; j < all.length; j++) {
        if (isValidRoot(all[j]))
        {
          valid.push(all[j])
        }
      }
      saveKnownProjects(valid)
      callback(valid)
    })
  }

  function runAutoUploadCycle(isTimerTick) {
    if (!settings.enabled || isProcessingQueue || webdav.isUploadingPath) {
      return
    }

    var pending = getPending()

    getAllProjects(function(projects) {
      if (!projects || projects.length === 0) {
        return
      }

      var toUpload = []

      for (var i = 0; i < projects.length; i++) {
        var root = projects[i]
        var active = isCurrentProject(root)
        var due = pending.indexOf(root) !== -1

        if (active) {
          // Only mark "due" on real schedule tick
          if (isTimerTick && !due) {
            addPending(root)
          }
        } else {
          // Upload only if due already, or schedule tick says its time
          if (due || isTimerTick) {
            toUpload.push(root)
          }
        }
      }

      if (toUpload.length > 0) {
        uploadQueue = toUpload
        isProcessingQueue = true
        manualUploadTriggered = false
        processNextInQueue()
      }
    })
  }

  function processNextInQueue() {
    if (uploadQueue.length === 0) {
      isProcessingQueue = false
      currentUploadPath = ""
      return
    }
    currentUploadPath = uploadQueue.shift()
    webdav.requestUpload(currentUploadPath, false)
  }

  function triggerManualUpload() {
    if (webdav.isUploadingPath) {
      return
    }
    var path = getProjectPath()
    if (!path) {
      mainWindow.displayToast(qsTr("No project open"))
      return
    }
    var root = findProjectRoot(path)
    if (!isValidRoot(root)) {
      mainWindow.displayToast(qsTr("Not a WebDAV project"))
      return
    }
    manualUploadTriggered = true
    currentUploadPath = root
    webdav.requestUpload(root, true)
  }
}
