import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Settings surface for the fuzzy file search. Rendered inside the Omarchy menu
// card (Menu.qml) so `Super+Space` keeps working as the single entry point:
// Search Settings → folders to index, index behaviour, rebuild.
Item {
  id: root

  signal closeRequested()

  property var shell: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property string fontFamily: Style.font.menuFamily
  readonly property int contentSpacing: Style.spacing.md

  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/fuzzy-search.json"
  readonly property string configScript: Qt.resolvedUrl("bin/omarchy-search-config").toString().replace(/^file:\/\//, "")

  property var config: ({})
  property var stats: ({ files: 0, bytes: 0, ageSeconds: -1, missingRoots: [] })
  property var rows: []
  property int selectedIndex: 0
  property bool busy: false
  property bool rebuildPending: false
  property int statsPolls: 0
  property bool inputOpen: false
  property string message: ""
  property var queue: []

  readonly property color foreground: Color.menu.text
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color urgent: Color.urgent
  readonly property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  readonly property int sectionHeight: Math.max(Style.space(28), Style.font.caption + Style.spacing.md)
  readonly property var ttlOptions: [60, 300, 900, 1800, 3600]

  function focusView() {
    root.forceActiveFocus()
  }

  function shortPath(path) {
    var home = Quickshell.env("HOME")
    if (home && path === home) return "~"
    if (home && path.indexOf(home + "/") === 0) return "~/" + path.substring(home.length + 1)
    return path
  }

  function isMissingRoot(path) {
    var missing = root.stats.missingRoots || []
    return missing.indexOf(path) >= 0
  }

  function formatCount(value) {
    return String(Math.max(0, Number(value || 0))).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }

  function formatBytes(value) {
    var bytes = Number(value || 0)
    if (bytes >= 1024 * 1024 * 1024) return (bytes / (1024 * 1024 * 1024)).toFixed(1) + " GB"
    if (bytes >= 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB"
    if (bytes >= 1024) return Math.round(bytes / 1024) + " KB"
    return bytes + " B"
  }

  function formatAge(seconds) {
    var value = Number(seconds)
    if (value < 0) return "not built yet"
    if (value < 90) return "just now"
    if (value < 3600) return Math.round(value / 60) + " min ago"
    if (value < 86400) return Math.round(value / 3600) + " h ago"
    return Math.round(value / 86400) + " d ago"
  }

  function ttlLabel(seconds) {
    var value = Number(seconds || 300)
    if (value >= 3600) return "Every " + Math.round(value / 3600) + " h"
    return "Every " + Math.round(value / 60) + " min"
  }

  function statsLabel() {
    if (root.busy) return "Indexing…"
    if (!root.stats || Number(root.stats.files || 0) <= 0) return "No index yet"
    return formatCount(root.stats.files) + " files · " + formatBytes(root.stats.bytes)
      + " · " + formatAge(root.stats.ageSeconds)
  }

  function loadConfig(raw) {
    var parsed = ({})
    try { parsed = JSON.parse(raw || "{}") } catch (e) { parsed = ({}) }
    root.config = (parsed && typeof parsed === "object") ? parsed : ({})
    root.rebuildRows()
    root.refreshStats()
  }

  function rebuildRows() {
    var out = []
    var roots = Array.isArray(root.config.roots) ? root.config.roots : []
    var hidden = root.config.hidden === true
    var oneFileSystem = root.config.oneFileSystem !== false

    out.push({ kind: "section", label: "FOLDERS" })
    for (var i = 0; i < roots.length; i++) {
      var path = String(roots[i] || "")
      if (!path) continue
      out.push({
        kind: "root",
        path: path,
        label: root.shortPath(path),
        detail: root.isMissingRoot(path) ? "Missing — skipped" : "Indexed"
      })
    }
    out.push({ kind: "add", label: "Add folder…", detail: "Type a path, then press Enter" })

    out.push({ kind: "section", label: "OPTIONS" })
    out.push({
      kind: "toggle",
      key: "hidden",
      label: "Include hidden files",
      detail: hidden ? "Dotfiles and hidden directories are indexed" : "Dotfiles and hidden directories are skipped",
      value: hidden
    })
    out.push({
      kind: "toggle",
      key: "oneFileSystem",
      label: "Stay on local filesystem",
      detail: oneFileSystem ? "Skips network and FUSE mounts" : "Follows every mount, including network drives",
      value: oneFileSystem
    })
    out.push({
      kind: "ttl",
      label: "Refresh index",
      detail: ttlLabel(root.config.ttlSeconds),
      value: Number(root.config.ttlSeconds || 300)
    })

    out.push({ kind: "section", label: "INDEX" })
    out.push({
      kind: "rebuild",
      label: root.busy ? "Stop indexing" : "Rebuild index now",
      detail: root.busy ? "Scanning the configured folders…" : statsLabel()
    })
    out.push({ kind: "path", label: "Settings file", detail: root.shortPath(root.configPath) })

    root.rows = out
    root.clampSelection()
    pointerGate.reset()
  }

  function selectable(index) {
    if (index < 0 || index >= root.rows.length) return false
    return root.rows[index].kind !== "section"
  }

  function clampSelection() {
    if (!selectable(root.selectedIndex)) {
      for (var i = 0; i < root.rows.length; i++) {
        if (selectable(i)) { root.selectedIndex = i; return }
      }
      root.selectedIndex = 0
    }
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function move(delta) {
    if (root.rows.length === 0) return
    root.disarmPointer()
    var index = root.selectedIndex
    for (var step = 0; step < root.rows.length; step++) {
      index = (index + delta + root.rows.length) % root.rows.length
      if (selectable(index)) {
        root.selectedIndex = index
        return
      }
    }
  }

  function selectedRow() {
    return root.rows[root.selectedIndex] || null
  }

  function activateSelected() {
    var row = root.selectedRow()
    if (!row) return
    root.activate(row)
  }

  function activate(row) {
    if (!row) return
    if (row.kind === "root") {
      Util.execDetached("uwsm-app -- nautilus " + Util.shellQuote(row.path))
    } else if (row.kind === "add") {
      root.openInput()
    } else if (row.kind === "toggle") {
      root.runConfig(["set", row.key, row.value ? "false" : "true"])
    } else if (row.kind === "ttl") {
      var current = Number(row.value || 300)
      var next = current
      for (var i = 0; i < root.ttlOptions.length; i++) {
        if (root.ttlOptions[i] > current) { next = root.ttlOptions[i]; break }
        next = root.ttlOptions[0]
      }
      root.runConfig(["set", "ttlSeconds", String(next)])
    } else if (row.kind === "rebuild") {
      if (root.busy) root.stopRebuild()
      else root.rebuildIndex()
    } else if (row.kind === "path") {
      Util.execDetached(root.omarchyPath + "/bin/omarchy-launch-editor " + Util.shellQuote(root.configPath))
    }
  }

  function openInput() {
    root.inputOpen = true
    addField.text = ""
    root.message = ""
    Qt.callLater(function() { addField.forceActiveFocus() })
  }

  function cancelInput() {
    root.inputOpen = false
    addField.text = ""
    root.message = ""
    root.forceActiveFocus()
  }

  function commitInput() {
    var value = addField.text.trim()
    if (!value) { root.cancelInput(); return }
    root.runConfig(["add-root", value])
  }

  function removeRoot(path) {
    if (!path) return
    root.runConfig(["remove-root", path])
  }

  function deleteSelected() {
    var row = root.selectedRow()
    if (row && row.kind === "root") root.removeRoot(row.path)
  }

  function runConfig(args) {
    root.message = ""
    if (configProc.running) {
      root.queue = root.queue.concat([args])
      return
    }
    root.startConfig(args)
  }

  function startConfig(args) {
    configProc.errorText = ""
    configProc.command = [root.configScript].concat(args)
    configProc.running = true
  }

  function pumpQueue() {
    if (root.queue.length === 0) {
      configFile.reload()
      return
    }
    var next = root.queue[0]
    root.queue = root.queue.slice(1)
    root.startConfig(next)
  }

  function refreshStats() {
    if (statsProc.running) return
    statsProc.running = true
  }

  function rebuildIndex() {
    if (rebuildProc.running) {
      // A config change makes the run in flight obsolete. Stop it and start
      // over instead of letting a slow mount hold the old settings hostage.
      root.rebuildPending = true
      rebuildProc.running = false
      return
    }
    root.busy = true
    root.rebuildRows()
    rebuildProc.running = true
  }

  function stopRebuild() {
    root.rebuildPending = false
    root.busy = false
    if (rebuildProc.running) rebuildProc.running = false
    root.rebuildRows()
  }

  Timer {
    id: statsPoll
    interval: 700
    repeat: true
    onTriggered: {
      root.refreshStats()
      root.statsPolls += 1
      if (root.statsPolls >= 6) statsPoll.stop()
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfig(text())
    onLoadFailed: initProc.running = true
    onFileChanged: reload()
  }

  Process {
    id: initProc
    command: [root.configScript, "get"]
    onExited: configFile.reload()
  }

  Process {
    id: configProc
    property string errorText: ""
    stderr: SplitParser {
      onRead: function(data) { configProc.errorText += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.message = configProc.errorText.trim() || "Could not save settings"
      else if (root.inputOpen) root.cancelInput()
      root.pumpQueue()
      if (exitCode === 0 && root.queue.length === 0) {
        root.statsPolls = 0
        statsPoll.restart()
      }
    }
  }

  Process {
    id: statsProc
    property string collected: ""
    command: [root.configScript, "stats"]
    stdout: SplitParser {
      onRead: function(data) { statsProc.collected += data + "\n" }
    }
    onStarted: statsProc.collected = ""
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) return
      try {
        root.stats = JSON.parse(statsProc.collected || "{}")
      } catch (e) {
        root.stats = ({ files: 0, bytes: 0, ageSeconds: -1, missingRoots: [] })
      }
      root.rebuildRows()
    }
  }

  Process {
    id: rebuildProc
    onExited: function(exitCode, exitStatus) {
      root.busy = false
      if (root.rebuildPending) {
        root.rebuildPending = false
        root.rebuildIndex()
        return
      }
      root.message = (exitCode === 0 && exitStatus === 0) ? "" : "Index rebuild stopped"
      root.refreshStats()
      root.rebuildRows()
    }
  }

  onConfigChanged: root.rebuildRows()
  Component.onCompleted: root.refreshStats()
  onStatsChanged: root.rebuildRows()

  focus: !root.inputOpen
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (root.inputOpen) {
      if (event.key === Qt.Key_Escape) {
        root.cancelInput()
        event.accepted = true
      }
      return
    }

    if (event.key === Qt.Key_Escape) {
      root.closeRequested()
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      root.move(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      root.move(1)
      event.accepted = true
    } else if (event.key === Qt.Key_PageUp) {
      root.move(-6)
      event.accepted = true
    } else if (event.key === Qt.Key_PageDown) {
      root.move(6)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right) {
      root.activateSelected()
      event.accepted = true
    } else if (event.key === Qt.Key_Space) {
      var row = root.selectedRow()
      if (row && row.kind === "toggle") root.activate(row)
      event.accepted = true
    } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
      root.deleteSelected()
      event.accepted = true
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: root
  }

  Column {
    anchors.fill: parent
    spacing: root.contentSpacing

    Item {
      id: settingsHeader
      width: parent.width
      height: Math.max(Style.space(46), Style.font.heading + Style.font.caption + Style.spacing.md)

      Text {
        id: titleText
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        text: root.inputOpen ? "Add folder to index" : "Fuzzy Search"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: !root.inputOpen
        text: root.message.length > 0 ? root.message : "Folders searched by Super+Space"
        color: root.message.length > 0 ? root.urgent : root.foreground
        opacity: root.message.length > 0 ? 1 : 0.58
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      TextField {
        id: addField
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.inputOpen
        focus: root.inputOpen
        placeholderText: "~/Projects"
        foreground: root.foreground
        onAccepted: root.commitInput()
        Keys.onEscapePressed: function(event) {
          root.cancelInput()
          event.accepted = true
        }
      }
    }

    ListView {
      id: rowList
      width: parent.width
      height: parent.height - settingsHeader.height - settingsFooter.height - root.contentSpacing * 2
      model: root.rows
      clip: true
      spacing: Style.spacing.xs
      boundsBehavior: Flickable.StopAtBounds
      currentIndex: root.selectedIndex

      delegate: Item {
        id: rowItem
        required property int index
        required property var modelData

        readonly property bool isSection: modelData.kind === "section"
        readonly property bool hasCursor: !root.inputOpen && index === root.selectedIndex && !isSection

        width: ListView.view.width
        height: isSection ? root.sectionHeight : root.rowHeight

        Text {
          textFormat: Text.PlainText
          visible: rowItem.isSection
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: rowItem.isSection ? modelData.label : ""
          color: root.foreground
          opacity: 0.35
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          visible: !rowItem.isSection
          anchors.fill: parent
          radius: Style.cornerRadius
          color: rowItem.hasCursor ? root.selectedBackground : "transparent"

          Column {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.md
            anchors.right: trail.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: rowItem.isSection ? "" : String(modelData.label || "")
              color: rowItem.hasCursor ? root.selectedText : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.weight: Font.Medium
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: !rowItem.isSection
              text: rowItem.isSection ? "" : String(modelData.detail || "")
              color: rowItem.hasCursor ? root.selectedText : root.foreground
              opacity: 0.52
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideMiddle
            }
          }

          Row {
            id: trail
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            ToggleSwitch {
              visible: !rowItem.isSection && modelData.kind === "toggle"
              checked: !rowItem.isSection && modelData.value === true
              interactive: false
              hasCursor: rowItem.hasCursor
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              visible: !rowItem.isSection && modelData.kind === "root"
              text: "›"
              color: rowItem.hasCursor ? root.selectedText : root.foreground
              opacity: 0.36
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: {
              if (rowItem.isSection || root.inputOpen) return
              if (pointerGate.moved(rowItem, { x: rowMouse.mouseX, y: rowMouse.mouseY }))
                root.selectedIndex = rowItem.index
            }
            onPositionChanged: function(mouse) {
              if (rowItem.isSection || root.inputOpen) return
              if (pointerGate.moved(rowItem, mouse)) root.selectedIndex = rowItem.index
            }
            onClicked: {
              if (rowItem.isSection || root.inputOpen) return
              pointerGate.allowInitialSample()
              root.selectedIndex = rowItem.index
              root.activate(modelData)
            }
          }
        }
      }
    }

    Text {
      id: settingsFooter
      textFormat: Text.PlainText
      width: parent.width
      text: root.inputOpen
        ? "Enter add · Esc cancel"
        : "Enter open/toggle · Delete remove · Esc close"
      color: root.foreground
      opacity: 0.38
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
