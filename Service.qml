import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Hush for Omarchy.
//
// Fades a window in place by setting its per-window opacity prop: the window
// keeps its tile, the layout does not reflow, and the same key brings it back.
// Each press steps the focused window down one level and then back to normal:
//
//   normal -> 50% (visible but out of your face) -> 10% (blanked) -> normal
//
// State is tracked here and persisted, because Hyprland has no way to read a
// window prop back.
//
// Bind it to a key:
//   o.bind("SUPER + H", "Hush window", "omarchy-shell io.github.kring-ventures.hush toggle")
Item {
  id: service

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.kring-ventures.hush"
  readonly property string statePath: home + "/.local/state/omarchy/hush.json"

  // Settings, inline on this plugin's entry in ~/.config/omarchy/shell.json:
  //   { "id": "io.github.kring-ventures.hush", "levels": [0.5, 0.1], "peek": true }
  // levels: the opacity steps the key cycles through before returning to
  //         normal (each 0..1; one entry makes it a plain toggle).
  // peek:   focusing a hushed window reveals it until focus leaves again.
  property var levels: [0.5, 0.1]
  property bool peek: true

  // Hushed windows: "0x..." address -> { class, title, level }. level indexes
  // into `levels`. The peeked window is still hushed; it is just temporarily
  // shown while it holds focus.
  property var hushed: ({})
  property string peeking: ""
  readonly property int count: Object.keys(hushed).length

  function applySettings(raw) {
    try {
      var cfg = JSON.parse(raw || "{}")
      var list = Array.isArray(cfg.plugins) ? cfg.plugins : []
      for (var i = 0; i < list.length; i++) {
        var e = list[i]
        if (!e || e.id !== service.pluginId) continue
        if (Array.isArray(e.levels) && e.levels.length > 0) {
          var next = []
          for (var j = 0; j < e.levels.length; j++) {
            var o = parseFloat(e.levels[j])
            if (!isNaN(o)) next.push(Math.min(1, Math.max(0, o)))
          }
          if (next.length > 0) levels = next
        }
        if (e.peek !== undefined) peek = e.peek !== false
        break
      }
    } catch (err) {}
    reapply()
  }

  function norm(addr) {
    addr = String(addr || "").trim()
    if (addr === "") return ""
    return addr.indexOf("0x") === 0 ? addr : "0x" + addr
  }

  // Addresses come from hyprctl JSON or from our own state file, never from
  // free text, but keep the dispatch argument strictly hex anyway.
  function safeAddr(addr) { return /^0x[0-9a-fA-F]+$/.test(addr) }

  function levelOpacity(level) {
    var i = Math.min(Math.max(0, level | 0), levels.length - 1)
    return levels[i]
  }

  function setOpacity(addr, value) {
    if (!safeAddr(addr)) return
    Quickshell.execDetached(["hyprctl", "dispatch",
      "hl.dsp.window.set_prop({ window = 'address:" + addr + "', prop = 'opacity', value = " + value + " })"])
  }

  function save() { stateFile.setText(JSON.stringify(hushed, null, 2) + "\n") }

  function forget(addr) {
    var next = {}
    for (var k in hushed) if (k !== addr) next[k] = hushed[k]
    hushed = next
    if (peeking === addr) peeking = ""
  }

  function setLevel(addr, level, cls, title) {
    var next = {}
    for (var k in hushed) next[k] = hushed[k]
    var prev = next[addr]
    next[addr] = {
      "class": String(cls || (prev && prev["class"]) || ""),
      "title": String(title || (prev && prev.title) || ""),
      "level": level
    }
    hushed = next
    if (peeking !== addr) setOpacity(addr, levelOpacity(level))
    save()
  }

  function unhushWindow(addr) {
    if (!(addr in hushed)) return
    forget(addr)
    setOpacity(addr, 1)
    save()
  }

  // One key, one cycle: normal -> levels[0] -> levels[1] -> ... -> normal.
  function cycleWindow(addr, cls, title) {
    addr = norm(addr)
    if (!safeAddr(addr)) return
    var entry = hushed[addr]
    if (!entry) { setLevel(addr, 0, cls, title); return }
    var nextLevel = (entry.level | 0) + 1
    if (nextLevel >= levels.length) unhushWindow(addr)
    else setLevel(addr, nextLevel, cls, title)
  }

  function cycleActive() { activeProc.running = true }

  function clearAll() {
    for (var k in hushed) setOpacity(k, 1)
    hushed = {}
    peeking = ""
    save()
  }

  // Re-assert every hushed window's opacity (settings change, config reload).
  // The peeked window is deliberately left visible.
  function reapply() {
    for (var k in hushed) if (k !== peeking) setOpacity(k, levelOpacity(hushed[k].level))
  }

  // Startup reconcile: window addresses do not survive a compositor restart,
  // so drop entries whose window no longer exists and re-hush the survivors
  // (a shell restart keeps the windows; the props were never lost, but
  // re-applying is harmless and covers a compositor that forgot them).
  function reconcile(raw) {
    try {
      var clients = JSON.parse(raw || "[]")
      var alive = {}
      for (var i = 0; i < clients.length; i++) alive[String(clients[i].address)] = true
      var next = {}
      var dropped = false
      for (var k in hushed) {
        if (alive[k]) {
          next[k] = hushed[k]
          setOpacity(k, levelOpacity(hushed[k].level))
        } else {
          dropped = true
        }
      }
      hushed = next
      if (dropped) save()
    } catch (err) {}
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name)
      if (name === "configreloaded") { service.reapply(); return }
      if (service.count === 0) return
      var data = String(event.data)
      if (name === "closewindow") {
        var closed = service.norm(data.split(",")[0])
        if (closed in service.hushed) {
          service.forget(closed)
          service.save()
        }
        return
      }
      if (!service.peek) return
      if (name === "activewindowv2") {
        var addr = service.norm(data.split(",")[0])
        if (service.peeking !== "" && service.peeking !== addr && (service.peeking in service.hushed))
          service.setOpacity(service.peeking, service.levelOpacity(service.hushed[service.peeking].level))
        if (service.peeking !== addr) service.peeking = ""
        if (addr !== "" && (addr in service.hushed)) {
          service.peeking = addr
          service.setOpacity(addr, 1)
        }
      }
    }
  }

  Process {
    id: activeProc
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var w = JSON.parse(text || "{}")
          if (w && w.address) service.cycleWindow(w.address, w["class"], w.title)
        } catch (err) {}
      }
    }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector { onStreamFinished: service.reconcile(text) }
  }

  FileView {
    id: shellConfig
    path: service.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: service.applySettings(text())
    onFileChanged: reload()
  }

  FileView {
    id: stateFile
    path: service.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try { service.hushed = JSON.parse(text() || "{}") || {} } catch (err) { service.hushed = {} }
      clientsProc.running = true
    }
  }

  IpcHandler {
    target: "io.github.kring-ventures.hush"
    function ping(): string { return "ok" }
    function toggle(): string { service.cycleActive(); return "ok" }
    function window(addr: string): string { service.cycleWindow(addr, "", ""); return "ok" }
    function clear(): string { service.clearAll(); return "ok" }
    function list(): string { return JSON.stringify(service.hushed) }
  }
}
