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

  Settings {
    id: settings
    category: "qfield-webdav-autoupload"

    property bool enabled: false
    property int intervalHours: 2
    property string projectStatuses: "{}"
  }

  Component.onCompleted: {
    iface.addItemToDashboardActionsToolbar(uploadButton)
    if (settings.enabled) {
      Qt.callLater(runAutoUploadCycle)
      uploadTimer.restart()
    }
  }

  Component.onDestruction: {
    iface.removeItemFromDashboardActionsToolbar(uploadButton)
  }

  function configure() {
    settingsDialog.open()
  }

  Timer {
    id: uploadTimer
    repeat: true
    running: false
    interval: Math.max(1, settings.intervalHours) * 3600000

    onTriggered: {
      runAutoUploadCycle()
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
    objectName: "WebdavUploadButton"
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    height: parent.height * 0.9
    width: parent.height * 0.9
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
      refreshStatus()
    }

    onAccepted: {
      settings.enabled = enableSwitch.checked
      settings.intervalHours = intervalTumbler.currentIndex + 1
      uploadTimer.interval = settings.intervalHours * 3600000

      if (settings.enabled) {
        Qt.callLater(runAutoUploadCycle)
        uploadTimer.restart()
      } else {
        uploadTimer.stop()
      }

      mainWindow.displayToast(qsTr("Settings saved"))
    }

    function refreshStatus() {
      var path = getProjectPath()
      if (path && webdav.hasWebdavConfiguration(path)) {
        var root = findProjectRoot(path)
        statusSection.projectRoot = root
        statusSection.statusData = getProjectStatus(root)
        statusSection.visible = true
      } else {
        statusSection.visible = false
      }
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

        Switch {
          id: enableSwitch
        }
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

              background: Rectangle {
                color: "transparent"
              }

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

          Label {
            text: qsTr("Last upload:")
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
        }

        Label {
          Layout.fillWidth: true
          visible: statusSection.statusData.status === "failed" && statusSection.statusData.message
          text: statusSection.statusData.message || ""
          font: Theme.tipFont
          color: Theme.errorColor
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
    statuses[key] = {
      status: status,
      message: message || "",
      timestamp: new Date().toISOString()
    }
    settings.projectStatuses = JSON.stringify(statuses)
  }

  function findWebdavProjects(callback) {
    var appDir = PlatformUtilities.applicationDirectory
    var importedDir = appDir + "/Imported Projects"
    folderScanner.startScan(importedDir, callback)
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
        scanning = false;
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
      }
    }
  }

  function isCurrentProject(projectRoot) {
    var current = getProjectPath()
    if (!current || !projectRoot) {
      return false
    }
    var normalizedCurrent = current.replace(/\\/g, "/")
    var normalizedRoot = projectRoot.replace(/\\/g, "/")
    if (!normalizedRoot.endsWith("/")) normalizedRoot += "/"
    return normalizedCurrent.indexOf(normalizedRoot) === 0 || normalizedCurrent === projectRoot.replace(/\/$/, "")
  }

  function runAutoUploadCycle() {
    if (!settings.enabled || isProcessingQueue || webdav.isUploadingPath) {
      return
    }

    findWebdavProjects(function(projects) {
      var toUpload = []
      for (var i = 0; i < projects.length; i++) {
        if (!isCurrentProject(projects[i])) {
          toUpload.push(projects[i])
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

    if (!webdav.hasWebdavConfiguration(path)) {
      mainWindow.displayToast(qsTr("Not a WebDAV project"))
      return
    }

    manualUploadTriggered = true
    currentUploadPath = findProjectRoot(path)
    webdav.requestUpload(path, true)
  }

  function findProjectRoot(path) {
    var parts = path.split("/")
    for (var i = parts.length; i >= 1; i--) {
      var testPath = parts.slice(0, i).join("/")
      if (testPath && webdav.hasWebdavConfiguration(testPath)) {
        return testPath
      }
    }
    return path
  }
}
