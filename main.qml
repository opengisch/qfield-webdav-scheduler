import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import org.qfield
import org.qgis
import Theme

Item {
  id: plugin

  property var mainWindow: iface.mainWindow()
  property var busyOverlay: iface.findItemByObjectName('busyOverlay')
  property var uploadQueue: []
  property bool isUploading: false
  property string currentUploadPath: ""
  property bool isActiveProjectUpload: false

  Settings {
    id: settings
    category: "qfield-webdav-autoupload"

    property bool enabled: false
    property int intervalHours: 2
    property string lastCheckTime: ""
    property string lastUploadStatus: ""
    property string lastUploadMessage: ""
    property string knownProjects: "[]"
  }

  Component.onCompleted: {
    iface.addItemToDashboardActionsToolbar(uploadButton)
    rememberCurrentProject()
    if (settings.enabled) {
      checkAndStartTimer()
    }

    if (busyOverlay) {
      busyOverlay.actionClicked.connect(cancelUpload)
    }
  }

  Component.onDestruction: {
    if (busyOverlay) {
      busyOverlay.actionClicked.disconnect(cancelUpload)
    }
  }

  function configure() {
    settingsDialog.open()
  }

  // Handle interval persistence across app restarts
  function checkAndStartTimer() {
    var now = new Date()
    var lastCheck = settings.lastCheckTime ? new Date(settings.lastCheckTime) : null
    var interval = intervalMs()

    if (lastCheck) {
      var elapsed = now.getTime() - lastCheck.getTime()
      if (elapsed >= interval) {
        settings.lastCheckTime = now.toISOString()
        Qt.callLater(runAutoUploadCycle)
        uploadTimer.restart()
      } else {
        initialDelayTimer.interval = Math.max(1000, interval - elapsed)
        initialDelayTimer.start()
      }
    } else {
      settings.lastCheckTime = now.toISOString()
      Qt.callLater(runAutoUploadCycle)
      uploadTimer.restart()
    }
  }

  function intervalMs() {
    return Math.max(1, settings.intervalHours) * 3600000
  }

  function getNextCheckTime() {
    if (!settings.enabled) {
      return null
    }
    var lastCheck = settings.lastCheckTime ? new Date(settings.lastCheckTime) : new Date()
    return new Date(lastCheck.getTime() + intervalMs())
  }

  // Remember current project when it changes
  Connections {
    target: qgisProject ? qgisProject : null
    function onFileNameChanged() {
      rememberCurrentProject()
    }
  }

  Timer {
    id: initialDelayTimer
    repeat: false
    running: false
    onTriggered: {
      settings.lastCheckTime = new Date().toISOString()
      runAutoUploadCycle()
      uploadTimer.restart()
    }
  }

  Timer {
    id: uploadTimer
    repeat: true
    running: false
    interval: intervalMs()
    onTriggered: {
      settings.lastCheckTime = new Date().toISOString()
      runAutoUploadCycle()
    }
  }

  WebdavConnection {
    id: webdav

    onIsUploadingPathChanged: {
      if (isUploadingPath && isActiveProjectUpload && busyOverlay) {
        busyOverlay.text = qsTr("Uploading to WebDAV")
        busyOverlay.showProgress = true
        busyOverlay.actionText = qsTr("Cancel")
        busyOverlay.progress = 0
        busyOverlay.state = "visible"
      } else if (!isUploadingPath && busyOverlay) {
        busyOverlay.state = "hidden"
        busyOverlay.actionText = ""
      }
    }

    onProgressChanged: {
      if (isActiveProjectUpload && busyOverlay) {
        busyOverlay.progress = progress
      }
    }

    onUploadFinished: function(success, message) {
      settings.lastUploadStatus = success ? "success" : "failed"
      settings.lastUploadMessage = message || ""

      if (isActiveProjectUpload && busyOverlay) {
        busyOverlay.state = "hidden"
        busyOverlay.actionText = ""
        mainWindow.displayToast(success ? qsTr("Upload complete") : qsTr("Upload failed: %1").arg(message))
      }

      finishCurrentUpload()
      processNextProject()
    }

    onUploadSkipped: function(reason) {
      settings.lastUploadStatus = "skipped"
      settings.lastUploadMessage = reason || ""

      if (isActiveProjectUpload && busyOverlay) {
        busyOverlay.state = "hidden"
        busyOverlay.actionText = ""
        mainWindow.displayToast(qsTr("Skipped: %1").arg(reason))
      }

      finishCurrentUpload()
      processNextProject()
    }
  }

  function finishCurrentUpload() {
    currentUploadPath = ""
    isActiveProjectUpload = false
    isUploading = uploadQueue.length > 0
  }

  function processNextProject() {
    if (uploadQueue.length === 0) {
      isUploading = false
      return
    }

    var projectRoot = uploadQueue.shift()
    currentUploadPath = projectRoot
    isActiveProjectUpload = isCurrentProject(projectRoot)

    // Active project: force=true shows overlay, background: force=false skips if unchanged
    webdav.requestUpload(projectRoot, isActiveProjectUpload)
  }

  function runAutoUploadCycle() {
    if (!settings.enabled || isUploading || webdav.isUploadingPath) {
      return
    }

    getAllProjects(function(projects) {
      if (!projects || projects.length === 0) {
        return
      }

      //active project first so it shows overlay
      var ordered = []
      for (var i = 0; i < projects.length; i++) {
        if (isCurrentProject(projects[i])) {
          ordered.unshift(projects[i])
        } else {
          ordered.push(projects[i])
        }
      }

      uploadQueue = ordered
      isUploading = true
      processNextProject()
    })
  }

  function triggerManualUpload() {
    if (webdav.isUploadingPath || isUploading) {
      return
    }

    var projectRoot = getCurrentProjectRoot()
    if (!projectRoot) {
      mainWindow.displayToast(qsTr("No WebDAV project open"))
      return
    }

    rememberProject(projectRoot)
    uploadQueue = [projectRoot]
    isUploading = true
    processNextProject()  // This will shift from queue and start upload
  }

  function cancelUpload() {
    if (isActiveProjectUpload && webdav.isUploadingPath) {
      webdav.cancelRequest()
      if (busyOverlay) {
        busyOverlay.state = "hidden"
        busyOverlay.actionText = ""
      }
      mainWindow.displayToast(qsTr("Upload cancelled"))
    }
    uploadQueue = []
    isUploading = false
    currentUploadPath = ""
    isActiveProjectUpload = false
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

  function getCurrentProjectRoot() {
    var path = getProjectPath()
    return path ? webdav.findWebdavRootForPath(path) : ""
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

  function rememberCurrentProject() {
    var root = getCurrentProjectRoot()
    if (root) {
      rememberProject(root)
    }
  }

  // Project cache - ensures projects are found even if scanner has issues
  function getKnownProjects() {
    try {
      return JSON.parse(settings.knownProjects)
    }
    catch (e) {
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

  function getAllProjects(callback) {
    var known = getKnownProjects()

    var appDir = PlatformUtilities.applicationDirectory
    if (!appDir) {
      // PlatformUtilities not available, just use known projects
      callback(known)
      return
    }

    if (appDir.endsWith("/")) {
      appDir = appDir.slice(0, -1)
    }
    var scanned = webdav.findWebdavProjectFolders(appDir + "/Imported Projects")

    // Merge known and scanned
    var all = known.slice()
    for (var i = 0; i < scanned.length; i++) {
      if (all.indexOf(scanned[i]) === -1) {
        all.push(scanned[i])
      }
    }

    // Validate and update cache
    var valid = []
    for (var j = 0; j < all.length; j++) {
      if (webdav.hasWebdavConfiguration(all[j])) {
        valid.push(all[j])
      }
    }
    saveKnownProjects(valid)
    callback(valid)
  }

  QfToolButton {
    id: uploadButton
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    height: parent ? parent.height * 0.9 : 48
    width: height
    iconSource: Qt.resolvedUrl("webdav-upload-button.svg")
    iconColor: Theme.mainTextColor
    bgcolor: "transparent"
    enabled: !webdav.isUploadingPath && !isUploading
    opacity: enabled ? 1.0 : 0.4
    onClicked: {
      iface.findItemByObjectName("dashBoard").close()
      triggerManualUpload()
    }
  }

  QfDialog {
    id: settingsDialog
    parent: mainWindow.contentItem
    modal: true
    title: qsTr("WebDAV Auto-Upload")
    standardButtons: Dialog.Ok | Dialog.Cancel

    width: Math.min(parent.width - 40, 400)
    x: (parent.width - width) / 2
    y: (parent.height - height) / 2

    onOpened: {
      enableSwitch.checked = settings.enabled
      intervalTumbler.currentIndex = Math.max(0, settings.intervalHours - 1)
    }

    onAccepted: {
      settings.enabled = enableSwitch.checked
      settings.intervalHours = intervalTumbler.currentIndex + 1

      if (settings.enabled) {
        settings.lastCheckTime = new Date().toISOString()
        initialDelayTimer.stop()
        uploadTimer.restart()
      } else {
        uploadTimer.stop()
        initialDelayTimer.stop()
      }
      mainWindow.displayToast(qsTr("Settings saved"))
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
            text: qsTr("Automatically sync WebDAV projects at regular intervals")
            font: Theme.tipFont
            color: Theme.secondaryTextColor
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
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

      RowLayout {
        Layout.fillWidth: true
        spacing: 16
        opacity: enableSwitch.checked ? 1.0 : 0.4

        Label {
          text: qsTr("Upload interval")
          font: Theme.defaultFont
          color: Theme.mainTextColor
        }

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

        Item {
          Layout.fillWidth: true
        }
      }

      Rectangle {
        Layout.fillWidth: true
        height: 1
        color: Theme.controlBorderColor
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        Label {
          text: qsTr("Status")
          font: Theme.defaultFont
          color: Theme.mainTextColor
        }

        GridLayout {
          Layout.fillWidth: true
          columns: 2
          columnSpacing: 20
          rowSpacing: 4

          Label {
            text: qsTr("Last result:")
            font: Theme.tipFont
            color: Theme.secondaryTextColor
            visible: settings.lastUploadStatus !== ""
          }

          Label {
            visible: settings.lastUploadStatus !== ""
            text: {
              var s = settings.lastUploadStatus
              if (s === "success") {
                return qsTr("Success")
              }
              if (s === "failed") {
                return qsTr("Failed")
              }
              if (s === "skipped") {
                return qsTr("Skipped")
              }
              return qsTr("Unknown")
            }
            font: Theme.tipFont
            color: {
              var s = settings.lastUploadStatus
              if (s === "success") {
                return Theme.mainColor
              }
              if (s === "failed") {
                return Theme.errorColor
              }
              return Theme.mainTextColor
            }
          }

          Label {
            text: qsTr("Last check:")
            font: Theme.tipFont
            color: Theme.secondaryTextColor
            visible: settings.lastCheckTime !== ""
          }

          Label {
            visible: settings.lastCheckTime !== ""
            text: settings.lastCheckTime ? Qt.formatDateTime(new Date(settings.lastCheckTime), "MMM d, hh:mm") : qsTr("Never")
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
            visible: settings.enabled
            text: {
              var next = getNextCheckTime()
              return next ? Qt.formatDateTime(next, "MMM d, hh:mm") : qsTr("Pending")
            }
            font: Theme.tipFont
            color: Theme.mainTextColor
          }
        }

        Label {
          Layout.fillWidth: true
          visible: settings.lastUploadStatus === "failed" && settings.lastUploadMessage
          text: settings.lastUploadMessage
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
        text: qsTr("Use the toolbar button for manual uploads. Auto-upload will sync all WebDAV projects found in Imported Projects.")
        font: Theme.tipFont
        color: Theme.secondaryTextColor
        wrapMode: Text.WordWrap
      }
    }
  }
}
