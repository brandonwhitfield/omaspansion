import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "brandon.omaspansion"
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  readonly property string entriesPath: configHome + "/omaspansion/entries.json"
  readonly property string settingsPath: configHome + "/omaspansion/settings.json"
  readonly property string helperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/brandon.omaspansion/bin/omaspansion"

  property bool opened: false
  property bool managerMode: false
  property string targetWindow: ""
  property var entries: []
  property int paletteIndex: 0
  property int managerIndex: 0
  property string statusText: "Select an expansion. Enter never gets pressed."
  property bool statusError: false
  property bool typedEnabled: true
  property string typedPrefix: ";"
  property string excludedProgramsText: ""
  property string onePasswordBrokerIdleMinutes: "9"

  property string editorOriginalKey: ""
  property string editorOriginalType: ""
  property string editorOriginalValue: ""
  property string editorType: "paste"
  property bool editorLoading: false
  property string localSelectAfterReload: ""

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color scrim: Color.menu.scrim
  readonly property color accent: Color.accent
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int cardWidth: Math.min(managerMode ? Style.space(1040) : Style.space(760), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(managerMode ? Style.space(720) : Style.space(560), panel.height - Style.gapsOut * 2)
  readonly property int rowHeight: Style.space(66)

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(String(payloadJson || "{}")) || {} } catch (e) { payload = {} }
    targetWindow = String(payload.targetWindow || "")
    managerMode = false
    paletteIndex = 0
    statusText = "Select an expansion. Enter never gets pressed."
    statusError = false
    opened = true
    catalogFile.reload()
    rebuildPalette()
    Qt.callLater(function() { paletteSearch.forceActiveFocus() })
  }

  function close() {
    opened = false
  }

  function dismiss() {
    opened = false
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
  }

  function loadCatalog(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (!parsed || parsed.version !== 2 || !Array.isArray(parsed.entries)) throw new Error("Unsupported catalog")
      entries = parsed.entries
      statusError = false
      if (managerMode) {
        rebuildManager()
        if (localSelectAfterReload) {
          var localKey = localSelectAfterReload
          localSelectAfterReload = ""
          Qt.callLater(function() { root.selectManagerKey(localKey) })
        }
      } else rebuildPalette()
    } catch (e) {
      entries = []
      paletteModel.clear()
      managerModel.clear()
      statusText = "Could not load entries.json."
      statusError = true
    }
  }

  function actionLabel(type) {
    if (type === "paste") return "Paste"
    if (type === "copy") return "Copy"
    if (type === "open-url") return "URL"
    if (type === "open-file") return "File"
    if (type === "onepassword-paste") return "1Password"
    if (type === "bitwarden-paste") return "Bitwarden"
    if (type === "lastpass-paste") return "LastPass"
    if (type === "protonpass-paste") return "Proton Pass"
    if (type === "local-secret-paste") return "Local Secret"
    return type
  }

  function isSecureType(type) {
    return type === "onepassword-paste" || type === "bitwarden-paste" ||
      type === "lastpass-paste" || type === "protonpass-paste" ||
      type === "local-secret-paste"
  }

  function providerPlaceholder(type) {
    if (type === "onepassword-paste") return "op://vault/item/field"
    if (type === "bitwarden-paste") return "Bitwarden item UUID"
    if (type === "lastpass-paste") return "LastPass numeric item ID"
    if (type === "protonpass-paste") return "pass://vault/item/field"
    return "Command text; use $|$ for the final cursor position"
  }

  function providerHelp(type) {
    if (type === "onepassword-paste") return "First use asks the 1Password desktop app to authorize Omaspansion."
    if (type === "bitwarden-paste") return "Unlock with: omaspansion provider-login bitwarden"
    if (type === "lastpass-paste") return "Sign in first with: lpass login you@example.com"
    if (type === "protonpass-paste") return "Sign in first with: pass-cli login"
    if (type === "local-secret-paste") return "Stored in your desktop login keyring."
    return ""
  }

  function previewText(value, type) {
    if (type === "local-secret-paste") return "••••••••  Stored in login keyring"
    if (isSecureType(type)) return "••••••••  Resolved by " + actionLabel(type)
    return String(value || "").replace(/\n/g, " ↵ ").replace("$|$", "▏")
  }

  function searchScore(entry, query) {
    var terms = String(query || "").trim().toLowerCase().split(/\s+/).filter(function(term) { return term.length > 0 })
    if (terms.length === 0) return 4
    var key = String(entry.key || "").toLowerCase()
    var details = (String(entry.description || "") + " " + String(entry.category || "")).toLowerCase()
    var haystack = (key + " " + details + " " + String(entry.value || "") + " " + String(entry.type || "")).toLowerCase()
    for (var i = 0; i < terms.length; i++) if (haystack.indexOf(terms[i]) === -1) return -1
    if (terms.length === 1 && key === terms[0]) return 0
    if (terms.length === 1 && key.indexOf(terms[0]) === 0) return 1
    var allDetails = true
    for (var j = 0; j < terms.length; j++) if (details.indexOf(terms[j]) === -1) allDetails = false
    return allDetails ? 2 : 3
  }

  function filteredEntries(query) {
    var ranked = []
    for (var i = 0; i < entries.length; i++) {
      var score = searchScore(entries[i], query)
      if (score >= 0) ranked.push({ score: score, entry: entries[i] })
    }
    ranked.sort(function(a, b) {
      if (a.score !== b.score) return a.score - b.score
      var categoryCompare = String(a.entry.category || "").localeCompare(String(b.entry.category || ""))
      if (categoryCompare !== 0) return categoryCompare
      return String(a.entry.key || "").localeCompare(String(b.entry.key || ""))
    })
    return ranked
  }

  function appendModelEntry(model, entry) {
    model.append({
      commandKey: String(entry.key || ""),
      description: String(entry.description || ""),
      category: String(entry.category || "Custom"),
      actionType: String(entry.type || "paste"),
      commandValue: String(entry.value || "")
    })
  }

  function rebuildPalette() {
    paletteModel.clear()
    var ranked = filteredEntries(paletteSearch ? paletteSearch.text : "")
    for (var i = 0; i < ranked.length && i < 100; i++) appendModelEntry(paletteModel, ranked[i].entry)
    if (paletteModel.count === 0) paletteIndex = 0
    else paletteIndex = Math.max(0, Math.min(paletteIndex, paletteModel.count - 1))
    Qt.callLater(function() {
      if (paletteModel.count > 0) paletteList.positionViewAtIndex(paletteIndex, ListView.Contain)
    })
  }

  function movePalette(delta) {
    if (paletteModel.count === 0) return
    paletteIndex = (paletteIndex + delta + paletteModel.count) % paletteModel.count
    paletteList.positionViewAtIndex(paletteIndex, ListView.Contain)
  }

  function activatePalette(index) {
    if (index < 0 || index >= paletteModel.count) return
    var row = paletteModel.get(index)
    dismiss()
    Quickshell.execDetached([helperPath, "run", row.commandKey, targetWindow])
  }

  function openManager() {
    managerMode = true
    statusText = "Edit an existing expansion or create a new one. $|$ marks the final cursor position."
    statusError = false
    rebuildManager()
    settingsFile.reload()
    if (managerModel.count > 0) loadManagerEntry(0)
    else newEntry()
    Qt.callLater(function() { managerSearch.forceActiveFocus() })
  }

  function loadSettings(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (!parsed || parsed.version !== 1 || typeof parsed.enabled !== "boolean" ||
          typeof parsed.prefix !== "string" || !Array.isArray(parsed.excludedPrograms)) throw new Error("Unsupported settings")
      var idleMinutes = parsed.onePasswordBrokerIdleMinutes === undefined ? 9 : parsed.onePasswordBrokerIdleMinutes
      if (typeof idleMinutes !== "number" || Math.floor(idleMinutes) !== idleMinutes || idleMinutes < 1 || idleMinutes > 120)
        throw new Error("Unsupported 1Password broker timeout")
      typedEnabled = parsed.enabled
      typedPrefix = parsed.prefix
      excludedProgramsText = parsed.excludedPrograms.join("\n")
      onePasswordBrokerIdleMinutes = String(idleMinutes)
    } catch (e) {
      statusText = "Could not load settings."
      statusError = true
    }
  }

  function saveTypedSettings() {
    if (saveSettingsProc.running) return
    var prefix = typedPrefix
    if (prefix.length !== 1 || prefix.charCodeAt(0) < 33 || prefix.charCodeAt(0) > 126 || /^[A-Za-z0-9]$/.test(prefix)) {
      statusText = "The expansion prefix must be one ASCII punctuation character."
      statusError = true
      return
    }
    var excluded = excludedProgramsText.split(/\r?\n/).map(function(value) { return value.trim() }).filter(function(value) { return value.length > 0 })
    var uniqueExcluded = []
    for (var i = 0; i < excluded.length; i++) if (uniqueExcluded.indexOf(excluded[i]) === -1) uniqueExcluded.push(excluded[i])
    if (!/^[0-9]+$/.test(onePasswordBrokerIdleMinutes)) {
      statusText = "The 1Password idle timeout must be a whole number from 1 to 120 minutes."
      statusError = true
      return
    }
    var idleMinutes = Number(onePasswordBrokerIdleMinutes)
    if (idleMinutes < 1 || idleMinutes > 120) {
      statusText = "The 1Password idle timeout must be from 1 to 120 minutes."
      statusError = true
      return
    }
    saveSettingsProc.payload = JSON.stringify({ version: 1, enabled: typedEnabled, prefix: prefix, excludedPrograms: uniqueExcluded, onePasswordBrokerIdleMinutes: idleMinutes })
    saveSettingsProc.errorText = ""
    saveSettingsProc.command = [helperPath, "save-settings"]
    saveSettingsProc.running = true
    statusText = "Saving settings…"
    statusError = false
  }

  function closeManager() {
    managerMode = false
    statusText = "Select an expansion. Enter never gets pressed."
    statusError = false
    rebuildPalette()
    Qt.callLater(function() { paletteSearch.forceActiveFocus() })
  }

  function rebuildManager() {
    managerModel.clear()
    var ranked = filteredEntries(managerSearch ? managerSearch.text : "")
    for (var i = 0; i < ranked.length; i++) appendModelEntry(managerModel, ranked[i].entry)
    if (managerModel.count === 0) managerIndex = 0
    else managerIndex = Math.max(0, Math.min(managerIndex, managerModel.count - 1))
    Qt.callLater(function() {
      if (managerModel.count > 0) managerList.positionViewAtIndex(managerIndex, ListView.Contain)
    })
  }

  function moveManager(delta) {
    if (managerModel.count === 0) return
    managerIndex = Math.max(0, Math.min(managerModel.count - 1, managerIndex + delta))
    managerList.positionViewAtIndex(managerIndex, ListView.Contain)
    loadManagerEntry(managerIndex)
  }

  function loadManagerEntry(index) {
    if (index < 0 || index >= managerModel.count) return
    managerIndex = index
    var entry = managerModel.get(index)
    editorLoading = true
    editorOriginalKey = entry.commandKey
    editorOriginalType = entry.actionType
    editorOriginalValue = entry.commandValue
    keyField.text = entry.commandKey
    descriptionField.text = entry.description
    categoryField.text = entry.category
    editorType = entry.actionType
    typeDropdown.value = editorType
    commandArea.text = entry.actionType === "local-secret-paste" ? "" : entry.commandValue
    secretField.text = ""
    editorLoading = false
    statusText = entry.actionType === "local-secret-paste"
      ? "Editing '" + entry.commandKey + "'. Leave the secret blank to keep its current value."
      : "Editing '" + entry.commandKey + "'. $|$ marks the final cursor position."
    statusError = false
  }

  function newEntry() {
    editorLoading = true
    editorOriginalKey = ""
    editorOriginalType = ""
    editorOriginalValue = ""
    keyField.text = ""
    descriptionField.text = ""
    categoryField.text = "Custom"
    editorType = "paste"
    typeDropdown.value = "paste"
    commandArea.text = ""
    secretField.text = ""
    editorLoading = false
    statusText = "Enter a key and expansion, then save."
    statusError = false
    Qt.callLater(function() { keyField.forceActiveFocus() })
  }

  function entryObjectFromEditor() {
    return {
      key: keyField.text.trim(),
      description: descriptionField.text.trim(),
      category: categoryField.text.trim() || "Custom",
      type: editorType,
      value: editorType === "local-secret-paste"
        ? (editorOriginalType === "local-secret-paste" ? editorOriginalValue : "__pending_local_secret__")
        : commandArea.text
    }
  }

  function saveEditor() {
    var nextEntry = entryObjectFromEditor()
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(nextEntry.key)) {
      statusText = "Keys may contain letters, numbers, dots, underscores, and dashes."
      statusError = true
      return
    }
    var replacingLocalSecret = nextEntry.type === "local-secret-paste" && secretField.text.length > 0
    if (nextEntry.type === "local-secret-paste") {
      if (!replacingLocalSecret && editorOriginalType !== "local-secret-paste") {
        statusText = "Enter the local secret before saving."
        statusError = true
        return
      }
      if (replacingLocalSecret) nextEntry.value = "__pending_local_secret__"
    } else if (!nextEntry.value) {
      statusText = "The expansion value cannot be empty."
      statusError = true
      return
    }
    if (nextEntry.type === "onepassword-paste" && !/^op:\/\/.+\/.+\/.+/.test(nextEntry.value)) {
      statusText = "Enter one 1Password reference: op://vault/item/field"
      statusError = true
      return
    }
    if (nextEntry.type === "bitwarden-paste" && !/^[0-9a-fA-F-]{36}$/.test(nextEntry.value)) {
      statusText = "Enter the stable UUID for the Bitwarden item."
      statusError = true
      return
    }
    if (nextEntry.type === "lastpass-paste" && !/^[0-9]+$/.test(nextEntry.value)) {
      statusText = "Enter the numeric LastPass item ID, not its display name."
      statusError = true
      return
    }
    if (nextEntry.type === "protonpass-paste" && !/^pass:\/\/.+\/.+\/.+/.test(nextEntry.value)) {
      statusText = "Enter one Proton Pass reference: pass://vault/item/field"
      statusError = true
      return
    }
    if (nextEntry.type !== "local-secret-paste" && nextEntry.value.split("$|$").length > 2) {
      statusText = "An expansion can contain only one $|$ cursor marker."
      statusError = true
      return
    }

    var next = []
    var replaced = false
    for (var i = 0; i < entries.length; i++) {
      var existing = entries[i]
      if (String(existing.key) === editorOriginalKey) {
        next.push(nextEntry)
        replaced = true
      } else {
        if (String(existing.key) === nextEntry.key) {
          statusText = "The key '" + nextEntry.key + "' is already in use."
          statusError = true
          return
        }
        next.push(existing)
      }
    }
    if (!replaced) next.push(nextEntry)
    if (replacingLocalSecret) {
      persistLocalSecret(next, "Saved '" + nextEntry.key + "'.", nextEntry.key, secretField.text)
    } else {
      persistEntries(next, "Saved '" + nextEntry.key + "'.", nextEntry.key)
    }
  }

  function deleteEditor() {
    if (!editorOriginalKey) return
    var next = []
    for (var i = 0; i < entries.length; i++) if (String(entries[i].key) !== editorOriginalKey) next.push(entries[i])
    persistEntries(next, "Deleted '" + editorOriginalKey + "'.", "")
  }

  function persistEntries(next, message, selectKey) {
    if (saveProc.running || saveLocalSecretProc.running) return
    next.sort(function(a, b) { return String(a.key).localeCompare(String(b.key)) })
    saveProc.pendingEntries = next
    saveProc.successMessage = message
    saveProc.selectKey = selectKey
    saveProc.payload = JSON.stringify({ version: 2, entries: next })
    statusText = "Saving…"
    statusError = false
    saveProc.command = [helperPath, "save"]
    saveProc.running = true
  }

  function persistLocalSecret(next, message, selectKey, secret) {
    if (saveProc.running || saveLocalSecretProc.running) return
    next.sort(function(a, b) { return String(a.key).localeCompare(String(b.key)) })
    saveLocalSecretProc.successMessage = message
    saveLocalSecretProc.selectKey = selectKey
    saveLocalSecretProc.payload = JSON.stringify({
      version: 1,
      secret: secret,
      catalog: { version: 2, entries: next }
    })
    statusText = "Storing in the login keyring…"
    statusError = false
    saveLocalSecretProc.command = [helperPath, "save-local-secret"]
    saveLocalSecretProc.running = true
  }

  function selectManagerKey(key) {
    for (var i = 0; i < managerModel.count; i++) {
      if (managerModel.get(i).commandKey === key) {
        loadManagerEntry(i)
        managerList.positionViewAtIndex(i, ListView.Contain)
        return
      }
    }
    if (managerModel.count > 0) loadManagerEntry(0)
    else newEntry()
  }

  function insertCursorMarker() {
    var marker = "$|$"
    if (commandArea.text.indexOf(marker) !== -1) {
      statusText = "This command already has a $|$ cursor marker."
      statusError = true
      return
    }
    var position = commandArea.cursorPosition
    commandArea.text = commandArea.text.slice(0, position) + marker + commandArea.text.slice(position)
    commandArea.cursorPosition = position + marker.length
    commandArea.forceActiveFocus()
    statusText = "$|$ inserted. The cursor will land there after paste."
    statusError = false
  }

  ListModel { id: paletteModel }
  ListModel { id: managerModel }

  FileView {
    id: catalogFile
    path: root.entriesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadCatalog(text())
    onLoadFailed: root.loadCatalog("")
    onFileChanged: reload()
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onFileChanged: reload()
  }

  Process {
    id: saveProc
    property string payload: ""
    property var pendingEntries: []
    property string successMessage: ""
    property string selectKey: ""
    property string errorText: ""
    stdinEnabled: true
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: saveProc.errorText = String(text || "").trim()
    }
    onStarted: write(payload + "\n")
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.entries = pendingEntries
        root.rebuildManager()
        if (selectKey) root.selectManagerKey(selectKey)
        else if (managerModel.count > 0) root.loadManagerEntry(0)
        else root.newEntry()
        root.statusText = successMessage
        root.statusError = false
        catalogFile.reload()
      } else {
        root.statusText = errorText || "Could not save the command catalog."
        root.statusError = true
      }
      payload = ""
      pendingEntries = []
      successMessage = ""
      selectKey = ""
      errorText = ""
    }
  }

  Process {
    id: saveSettingsProc
    property string payload: ""
    property string errorText: ""
    stdinEnabled: true
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: saveSettingsProc.errorText = String(text || "").trim()
    }
    onStarted: write(payload + "\n")
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.statusText = "Settings saved. New triggers and broker sessions use them immediately."
        root.statusError = false
        settingsFile.reload()
      } else {
        root.statusText = errorText || "Could not save settings."
        root.statusError = true
      }
      payload = ""
      errorText = ""
    }
  }

  Process {
    id: saveLocalSecretProc
    property string payload: ""
    property string successMessage: ""
    property string selectKey: ""
    property string errorText: ""
    stdinEnabled: true
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: saveLocalSecretProc.errorText = String(text || "").trim()
    }
    onStarted: write(payload + "\n")
    onExited: function(exitCode) {
      if (exitCode === 0) {
        secretField.text = ""
        root.localSelectAfterReload = selectKey
        root.statusText = successMessage
        root.statusError = false
        catalogFile.reload()
      } else {
        root.statusText = errorText || "Could not store the local secret."
        root.statusError = true
      }
      payload = ""
      successMessage = ""
      selectKey = ""
      errorText = ""
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "brandon-omaspansion"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.centerIn: parent
      color: root.background
      radius: Style.cornerRadius
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true
        Keys.onEscapePressed: root.managerMode ? root.closeManager() : root.dismiss()

        Column {
          anchors.fill: parent
          spacing: Style.spacing.md

          Row {
            width: parent.width
            height: Style.spacing.controlHeight
            spacing: Style.spacing.md

            Text {
              width: parent.width - headerAction.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: root.managerMode ? "Manage expansions" : "Insert an expansion"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
              elide: Text.ElideRight
            }

            Button {
              id: headerAction
              text: root.managerMode ? "Back to Expansions" : "Manage Expansions"
              bordered: true
              onClicked: root.managerMode ? root.closeManager() : root.openManager()
            }
          }

          Item {
            width: parent.width
            height: parent.height - Style.spacing.controlHeight - statusLine.height - parent.spacing * 2

            Item {
              id: paletteView
              anchors.fill: parent
              visible: !root.managerMode

              TextField {
                id: paletteSearch
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                placeholderText: "Search key, description, content, or category"
                foreground: root.foreground
                accent: root.accent
                onTextChanged: if (!root.managerMode) { root.paletteIndex = 0; root.rebuildPalette() }
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Down) { root.movePalette(1); event.accepted = true }
                  else if (event.key === Qt.Key_Up) { root.movePalette(-1); event.accepted = true }
                  else if (event.key === Qt.Key_PageDown) { root.movePalette(6); event.accepted = true }
                  else if (event.key === Qt.Key_PageUp) { root.movePalette(-6); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.activatePalette(root.paletteIndex); event.accepted = true }
                  else if (event.key === Qt.Key_Escape) {
                    if (text) text = ""
                    else root.dismiss()
                    event.accepted = true
                  }
                }
              }

              ListView {
                id: paletteList
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: paletteSearch.bottom
                anchors.bottom: parent.bottom
                anchors.topMargin: Style.spacing.md
                model: paletteModel
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: paletteRow
                  required property int index
                  required property string commandKey
                  required property string description
                  required property string category
                  required property string actionType
                  required property string commandValue
                  readonly property bool selected: index === root.paletteIndex
                  width: ListView.view.width
                  height: root.rowHeight
                  radius: Style.cornerRadius
                  color: selected ? root.selectedBackground : "transparent"

                  Column {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    anchors.topMargin: Style.space(7)
                    anchors.bottomMargin: Style.space(7)
                    spacing: Style.space(3)

                    Row {
                      width: parent.width
                      height: Style.font.title + Style.space(4)
                      spacing: Style.spacing.md
                      Text {
                        width: Style.space(150)
                        text: paletteRow.commandKey
                        color: paletteRow.selected ? root.selectedText : root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.title
                        font.bold: true
                        elide: Text.ElideRight
                      }
                      Text {
                        width: parent.width - Style.space(150) - categoryText.width - typeText.width - parent.spacing * 3
                        text: paletteRow.description || "No description"
                        color: paletteRow.selected ? root.selectedText : root.foreground
                        opacity: paletteRow.description ? 1 : 0.58
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                      }
                      Text {
                        id: categoryText
                        text: paletteRow.category
                        color: paletteRow.selected ? root.selectedText : root.foreground
                        opacity: 0.68
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        id: typeText
                        text: root.actionLabel(paletteRow.actionType)
                        color: paletteRow.selected ? root.selectedText : root.accent
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }

                    Text {
                      width: parent.width
                      text: root.previewText(paletteRow.commandValue, paletteRow.actionType)
                      color: paletteRow.selected ? root.selectedText : root.foreground
                      opacity: 0.62
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.paletteIndex = paletteRow.index
                    onClicked: root.activatePalette(paletteRow.index)
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                visible: paletteModel.count === 0
                text: paletteSearch.text ? "No matching expansions" : "No expansions yet"
                color: root.foreground
                opacity: 0.62
                font.family: Style.font.family
                font.pixelSize: Style.font.title
              }
            }

            Item {
              id: managerView
              anchors.fill: parent
              visible: root.managerMode

              Row {
                anchors.fill: parent
                spacing: Style.spacing.lg

                Item {
                  width: Math.max(Style.space(300), parent.width * 0.34)
                  height: parent.height

                  TextField {
                    id: managerSearch
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    placeholderText: "Search all expansions"
                    foreground: root.foreground
                    accent: root.accent
                    onTextChanged: if (root.managerMode) { root.managerIndex = 0; root.rebuildManager() }
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Down) { root.moveManager(1); event.accepted = true }
                      else if (event.key === Qt.Key_Up) { root.moveManager(-1); event.accepted = true }
                      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.loadManagerEntry(root.managerIndex); event.accepted = true
                      } else if (event.key === Qt.Key_Escape) {
                        if (text) text = ""
                        else root.closeManager()
                        event.accepted = true
                      }
                    }
                  }

                  Button {
                    id: newButton
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: managerSearch.bottom
                    anchors.topMargin: Style.spacing.sm
                    text: "New Expansion"
                    bordered: true
                    onClicked: root.newEntry()
                  }

                  ListView {
                    id: managerList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: newButton.bottom
                    anchors.bottom: parent.bottom
                    anchors.topMargin: Style.spacing.sm
                    model: managerModel
                    clip: true
                    spacing: Style.space(3)
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                      id: managerRow
                      required property int index
                      required property string commandKey
                      required property string description
                      required property string category
                      required property string actionType
                      required property string commandValue
                      readonly property bool selected: index === root.managerIndex && root.editorOriginalKey === commandKey
                      width: ListView.view.width
                      height: Style.space(54)
                      radius: Style.cornerRadius
                      color: selected ? root.selectedBackground : "transparent"

                      Column {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(10)
                        anchors.topMargin: Style.space(6)
                        spacing: Style.space(2)
                        Text {
                          width: parent.width
                          text: managerRow.commandKey + (managerRow.description ? " — " + managerRow.description : "")
                          color: managerRow.selected ? root.selectedText : root.foreground
                          font.family: Style.font.family
                          font.pixelSize: Style.font.body
                          font.bold: true
                          elide: Text.ElideRight
                        }
                        Text {
                          width: parent.width
                          text: managerRow.category + " · " + root.actionLabel(managerRow.actionType)
                          color: managerRow.selected ? root.selectedText : root.foreground
                          opacity: 0.62
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                      }
                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: if (containsMouse) root.managerIndex = managerRow.index
                        onClicked: root.loadManagerEntry(managerRow.index)
                      }
                    }
                  }
                }

                Rectangle { width: Style.space(1); height: parent.height; color: root.foreground; opacity: 0.12 }

                QQC.ScrollView {
                  width: parent.width - Math.max(Style.space(300), parent.width * 0.34) - parent.spacing * 2 - Style.space(1)
                  height: parent.height
                  clip: true
                  contentWidth: availableWidth

                  Column {
                    width: parent.width
                    spacing: Style.spacing.sm

                    Text { text: "Key"; color: root.foreground; opacity: 0.72; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                    TextField { id: keyField; width: parent.width; placeholderText: "example"; foreground: root.foreground; accent: root.accent }

                    Text { text: "Description"; color: root.foreground; opacity: 0.72; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                    TextField { id: descriptionField; width: parent.width; placeholderText: "Optional description"; foreground: root.foreground; accent: root.accent }

                    Row {
                      width: parent.width
                      spacing: Style.spacing.md
                      Column {
                        width: parent.width - typeDropdown.width - parent.spacing
                        spacing: Style.spacing.labelGap
                        Text { text: "Category"; color: root.foreground; opacity: 0.72; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                        TextField { id: categoryField; width: parent.width; placeholderText: "Custom"; foreground: root.foreground; accent: root.accent }
                      }
                      Dropdown {
                        id: typeDropdown
                        width: Style.space(190)
                        label: "Action"
                        value: root.editorType
                        options: [
                          { value: "paste", label: "Paste into original window" },
                          { value: "copy", label: "Copy to clipboard" },
                          { value: "onepassword-paste", label: "Paste from 1Password" },
                          { value: "bitwarden-paste", label: "Paste from Bitwarden" },
                          { value: "lastpass-paste", label: "Paste from LastPass" },
                          { value: "protonpass-paste", label: "Paste from Proton Pass" },
                          { value: "local-secret-paste", label: "Paste local secret" },
                          { value: "open-url", label: "Open URL" },
                          { value: "open-file", label: "Open file" }
                        ]
                        onChanged: function(nextValue) { root.editorType = nextValue }
                      }
                    }

                    Row {
                      width: parent.width
                      height: cursorButton.height
                      Text {
                        width: parent.width - cursorButton.width - parent.spacing
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.editorType === "local-secret-paste" ? "Local secret" : (root.isSecureType(root.editorType) ? "Provider reference" : "Content")
                        color: root.foreground
                        opacity: 0.72
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      Button {
                        id: cursorButton
                        text: "Insert $|$ Cursor"
                        bordered: true
                        enabled: !root.isSecureType(root.editorType)
                        onClicked: root.insertCursorMarker()
                      }
                    }

                    QQC.ScrollView {
                      width: parent.width
                      height: Style.space(235)
                      visible: root.editorType !== "local-secret-paste"
                      clip: true
                      QQC.TextArea {
                        id: commandArea
                        wrapMode: TextEdit.Wrap
                        color: root.foreground
                        selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                        selectedTextColor: root.foreground
                        placeholderText: root.providerPlaceholder(root.editorType)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        padding: Style.spacing.controlPaddingX
                        background: BorderSurface {
                          color: Style.controlFill(commandArea.activeFocus, commandArea.hovered, root.foreground, root.accent)
                          borderSpec: Border.controlSpec(commandArea.activeFocus ? "focus" : (commandArea.hovered ? "hover-cursor" : "normal"), root.foreground, root.accent)
                          radius: Style.cornerRadius
                        }
                      }
                    }

                    TextField {
                      id: secretField
                      width: parent.width
                      visible: root.editorType === "local-secret-paste"
                      password: true
                      placeholderText: root.editorOriginalType === "local-secret-paste"
                        ? "Leave blank to keep the stored value"
                        : "Enter the secret to store in your login keyring"
                      foreground: root.foreground
                      accent: root.accent
                    }

                    Text {
                      width: parent.width
                      visible: root.isSecureType(root.editorType)
                      text: root.providerHelp(root.editorType)
                      color: root.foreground
                      opacity: 0.58
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.Wrap
                    }

                    Text { text: "Preview"; color: root.foreground; opacity: 0.72; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                    BorderSurface {
                      width: parent.width
                      height: Style.space(72)
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
                      borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10), 1)
                      radius: Style.cornerRadius
                      Text {
                        anchors.fill: parent
                        anchors.margins: Style.space(10)
                        text: root.editorType === "local-secret-paste"
                          ? (secretField.text.length > 0 ? "••••••••  New secret" : (root.editorOriginalType === "local-secret-paste" ? "••••••••  Stored in login keyring" : "Nothing stored yet"))
                          : (root.previewText(commandArea.text, root.editorType) || "Nothing to preview")
                        color: root.foreground
                        opacity: commandArea.text ? 0.78 : 0.48
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                      }
                    }

                    Row {
                      width: parent.width
                      spacing: Style.spacing.sm
                      Button { text: "Save Expansion"; selected: true; onClicked: root.saveEditor() }
                      Button { text: "Delete"; bordered: true; visible: root.editorOriginalKey !== ""; onClicked: root.deleteEditor() }
                    }

                    Rectangle { width: parent.width; height: Style.space(1); color: root.foreground; opacity: 0.12 }

                    Text {
                      text: "Typed expansion"
                      color: root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.title
                      font.bold: true
                    }
                    Text {
                      width: parent.width
                      text: "Type the prefix directly before an expansion key. Exact matches expand immediately; no Space or Enter is required."
                      color: root.foreground
                      opacity: 0.62
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.Wrap
                    }

                    Toggle {
                      width: parent.width
                      label: "Enable typed expansion"
                      description: "Alt+E remains available when this is off."
                      foreground: root.foreground
                      accent: root.accent
                      checked: root.typedEnabled
                      onClicked: root.typedEnabled = !root.typedEnabled
                    }

                    Text { text: "Prefix"; color: root.foreground; opacity: 0.72; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                    TextField {
                      id: typedPrefixField
                      width: parent.width
                      text: root.typedPrefix
                      placeholderText: ";"
                      foreground: root.foreground
                      accent: root.accent
                      maximumLength: 1
                      onTextChanged: root.typedPrefix = text
                    }

                    Text { text: "Excluded applications (one program or app ID per line)"; color: root.foreground; opacity: 0.72; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                    QQC.ScrollView {
                      width: parent.width
                      height: Style.space(130)
                      clip: true
                      QQC.TextArea {
                        id: excludedProgramsArea
                        text: root.excludedProgramsText
                        wrapMode: TextEdit.NoWrap
                        color: root.foreground
                        selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                        selectedTextColor: root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        padding: Style.spacing.controlPaddingX
                        onTextChanged: root.excludedProgramsText = text
                        background: BorderSurface {
                          color: Style.controlFill(excludedProgramsArea.activeFocus, excludedProgramsArea.hovered, root.foreground, root.accent)
                          borderSpec: Border.controlSpec(excludedProgramsArea.activeFocus ? "focus" : (excludedProgramsArea.hovered ? "hover-cursor" : "normal"), root.foreground, root.accent)
                          radius: Style.cornerRadius
                        }
                      }
                    }

                    Text {
                      text: "1Password"
                      color: root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.title
                      font.bold: true
                    }
                    Text {
                      width: parent.width
                      text: "Keep the authorized broker alive for this many minutes after its most recent request. Longer sessions reduce prompts but extend local access."
                      color: root.foreground
                      opacity: 0.62
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.Wrap
                    }
                    Text { text: "Idle timeout in minutes (1–120)"; color: root.foreground; opacity: 0.72; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                    TextField {
                      id: onePasswordIdleMinutesField
                      width: parent.width
                      text: root.onePasswordBrokerIdleMinutes
                      placeholderText: "9"
                      foreground: root.foreground
                      accent: root.accent
                      maximumLength: 3
                      onTextChanged: root.onePasswordBrokerIdleMinutes = text
                    }

                    Button {
                      text: saveSettingsProc.running ? "Saving…" : "Save Settings"
                      bordered: true
                      enabled: !saveSettingsProc.running
                      onClicked: root.saveTypedSettings()
                    }
                  }
                }
              }
            }
          }

          Text {
            id: statusLine
            width: parent.width
            height: Math.max(implicitHeight, Style.space(22))
            text: root.statusText
            color: root.statusError ? Color.urgent : root.foreground
            opacity: root.statusError ? 1 : 0.62
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
