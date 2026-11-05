import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || homeDir + "/.config"
  readonly property string pluginPath: resolvedLocalPath(".")
  readonly property string binDir: pluginPath + "/bin"
  readonly property string soundsDir: Quickshell.env("SBOARD_SOUNDS_DIR")
    || configHome + "/omarchy/plugins/soundboard/sounds"
  readonly property string configPath: configHome + "/omarchy/plugins/soundboard/config.json"

  // ---- settings (persisted to config.json)
  property bool settingsLoaded: false
  property bool statusKnown: false
  property bool autoSetupDone: false
  property bool autoSetup: true
  property bool monitorLocal: true
  property int masterVolume: 80
  property real clipTargetLufs: -16.0

  // ---- runtime state
  property bool routerActive: false
  property bool routerEngaged: false
  property bool routerWatcher: false
  property bool routerBusy: false
  property bool importing: false
  property bool downloading: false
  property string lastMessage: ""
  property string lastError: ""
  property string busySound: ""
  property var sounds: []
  readonly property bool hasSounds: sounds.length > 0

  readonly property string statusLabel: !routerActive
    ? "Virtual mic off"
    : routerEngaged
      ? "Clips live — mic bridged"
      : (monitorLocal ? "Armed · mic untouched · local monitor on" : "Armed · mic untouched")

  function resolvedLocalPath(relativePath) {
    var value = String(Qt.resolvedUrl(relativePath))
    if (value.indexOf("file://") === 0) return decodeURIComponent(value.substring(7))
    return value
  }

  function script(name) {
    return binDir + "/" + name
  }

  Component.onCompleted: {
    refreshSounds()
    refreshStatus()
  }

  // ------------------------------------------------------------------ config

  FileView {
    id: settingsFile
    path: root.configPath
    atomicWrites: true
    printErrors: false
    onLoaded: root.applySettings(text())
    onLoadFailed: root.applySettings("{}")
  }

  function applySettings(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || "{}"))
    } catch (error) {
      parsed = {}
    }

    autoSetup = parsed.autoSetup === undefined ? true : !!parsed.autoSetup
    monitorLocal = parsed.monitorLocal === undefined ? true : !!parsed.monitorLocal
    masterVolume = clampVolume(parsed.masterVolume, 80)
    clipTargetLufs = clampLufs(parsed.clipTargetLufs, -16.0)
    settingsLoaded = true
    maybeAutoSetup()
  }

  // Auto-arm once per service lifetime, after the real router state is known.
  // Also heals an armed router whose watcher daemon died (never re-arms a
  // deliberate user teardown, which shows active=false).
  function maybeAutoSetup() {
    if (!autoSetup || !settingsLoaded || !statusKnown) return
    if (routerActive && !routerWatcher) { startRouter(); return } // heal dead watcher
    if (autoSetupDone) return
    autoSetupDone = true // first known state decides; a later user disconnect sticks
    if (routerActive) return
    startRouter()
  }

  function persistSettings() {
    if (!root.settingsLoaded) return
    settingsFile.setText(JSON.stringify({
      autoSetup: root.autoSetup,
      monitorLocal: root.monitorLocal,
      masterVolume: root.masterVolume,
      clipTargetLufs: root.clipTargetLufs
    }, null, 2) + "\n")
  }

  function clampVolume(value, fallback) {
    var numeric = Number(value)
    if (!isFinite(numeric)) numeric = fallback
    return Math.max(0, Math.min(100, Math.round(numeric)))
  }

  function clampLufs(value, fallback) {
    var numeric = Number(value)
    if (!isFinite(numeric)) numeric = fallback
    return Math.max(-24, Math.min(-10, numeric))
  }

  // ------------------------------------------------------------------ sounds

  Process {
    id: soundsProc
    running: false
    command: []

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySounds(text)
    }
  }

  function applySounds(raw) {
    var parsed = []
    try {
      parsed = JSON.parse(String(raw || "[]"))
    } catch (error) {
      root.lastError = "Could not list sounds"
      parsed = []
    }
    root.sounds = Array.isArray(parsed) ? parsed : []
  }

  function refreshSounds() {
    soundsProc.command = [script("list-sounds.sh")]
    soundsProc.running = true
  }

  // ------------------------------------------------------------------ router

  Process {
    id: statusProc
    running: false
    command: []

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  function applyStatus(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || "{}"))
    } catch (error) {
      parsed = {}
    }
    routerActive = !!parsed.active
    routerEngaged = !!parsed.engaged
    routerWatcher = !!parsed.watcher
    monitorLocal = !!parsed.monitor
    var statusVolume = clampVolume(parsed.volume, masterVolume)
    if (routerActive) masterVolume = statusVolume
    statusKnown = true
    maybeAutoSetup()
  }

  function refreshStatus() {
    statusProc.command = [script("audio_router.sh"), "status"]
    statusProc.running = true
  }

  Timer {
    interval: 4000
    running: true
    repeat: true
    onTriggered: if (!root.routerBusy) root.refreshStatus()
  }

  Process {
    id: routerProc
    running: false
    command: []

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message === "") return
        // router logs are prefixed "soundboard: ..."; anything else is an error
        if (message.indexOf("soundboard:") === 0) root.lastMessage = message
        else root.lastError = message
      }
    }

    onExited: function(exitCode) {
      root.routerBusy = false
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = "Router command failed"
      refreshStatus()
      refreshSounds()
      if (root.applyVolumeAfterSetup && exitCode === 0) {
        root.applyVolumeAfterSetup = false
        setVolume(masterVolume)
      }
    }
  }

  property bool applyVolumeAfterSetup: false

  function startRouter() {
    if (routerBusy) return
    routerBusy = true
    lastError = ""
    applyVolumeAfterSetup = true
    routerProc.command = [script("audio_router.sh"), "setup", monitorLocal ? "on" : "off"]
    routerProc.running = true
  }

  function stopRouter() {
    if (routerBusy) return
    routerBusy = true
    lastError = ""
    applyVolumeAfterSetup = false
    routerProc.command = [script("audio_router.sh"), "teardown"]
    routerProc.running = true
  }

  function toggleRouter() {
    if (routerActive) stopRouter()
    else startRouter()
  }

  // ------------------------------------------------------------ actions

  Process {
    id: auxProc
    running: false
    command: []

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "" && message.indexOf("Failure") === 0) root.lastError = message
      }
    }

    onExited: root.refreshStatus()
  }

  function setVolume(pct) {
    masterVolume = clampVolume(pct, masterVolume)
    persistSettings()
    auxProc.command = [script("audio_router.sh"), "volume", String(masterVolume)]
    auxProc.running = true
  }

  function setMonitor(on) {
    monitorLocal = !!on
    persistSettings()
    auxProc.command = [script("audio_router.sh"), "monitor", monitorLocal ? "on" : "off"]
    auxProc.running = true
  }

  Process {
    id: transferProc
    running: false
    command: []

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyTransferOutput(text)
    }

    onExited: function(exitCode) {
      root.downloading = false
      root.importing = false
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = transferKind === "download" ? "Download failed" : "Import failed"
      refreshSounds()
    }
  }

  property string transferKind: ""

  function applyTransferOutput(raw) {
    var lines = String(raw || "").split("\n")
    var ok = ""
    var error = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line.indexOf("ok ") === 0) ok = line.substring(3)
      else if (line.indexOf("error") === 0) error = line
    }
    root.lastMessage = ok !== "" ? "Added: " + ok : ""
    root.lastError = error
  }

  function download(url) {
    var trimmed = String(url || "").trim()
    if (trimmed === "" || downloading) return
    if (trimmed.indexOf("http") !== 0 && trimmed.indexOf("file://") !== 0) {
      lastError = "Paste a full http(s):// URL"
      return
    }
    lastError = ""
    lastMessage = "Downloading…"
    downloading = true
    transferKind = "download"
    transferProc.command = [script("download.sh"), trimmed]
    transferProc.running = true
  }

  function importPaths(paths) {
    var valid = []
    for (var i = 0; i < paths.length; i++) {
      var p = String(paths[i] || "").trim()
      if (p !== "") valid.push(p)
    }
    if (valid.length === 0 || importing) return
    lastError = ""
    lastMessage = "Importing " + valid.length + " file(s)…"
    importing = true
    transferKind = "import"
    transferProc.command = [script("import-file.sh")].concat(valid)
    transferProc.running = true
  }

  function removeSound(name) {
    deleteProc.command = [script("delete-sound.sh"), String(name || "")]
    deleteProc.running = true
  }

  Process {
    id: deleteProc
    running: false
    command: []
    onExited: root.refreshSounds()
  }

  // ------------------------------------------------------------------ play

  function play(sound) {
    var file = String(sound && sound.file ? sound.file : sound || "")
    if (file === "") return
    var path = file.indexOf("/") === 0 ? file : soundsDir + "/" + file
    Quickshell.execDetached([script("play.sh"), path, String(masterVolume)])
    flashBusy(path)
  }

  function flashBusy(file) {
    busySound = file
    busyTimer.restart()
  }

  Timer {
    id: busyTimer
    interval: 1400
    onTriggered: root.busySound = ""
  }

  function stopAll() {
    Quickshell.execDetached([script("stop-all.sh")])
    busySound = ""
    lastMessage = "Stopped all clips"
  }

  function openSoundsFolder() {
    Quickshell.execDetached(["xdg-open", soundsDir])
  }

  // Persistent floating window (survives focus loss, accepts file drops)
  function toggleWindow() {
    Quickshell.execDetached([script("toggle-soundboard.sh")])
  }
}
