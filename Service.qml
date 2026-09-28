import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Hush for Omarchy.
//
// Fades a window in place by setting its per-window opacity props: the window
// keeps its tile, the layout does not reflow, and the same key brings it back.
// Each press steps the focused window down one level and then back to normal:
//
//   normal -> 50% (visible but out of your face) -> 10% (blanked) -> normal
//
// A hushed window still gets a say: when its unread count goes up (chat apps
// put it in the window title) or it asks for attention, it wakes -- back to
// full opacity where it sits -- until you look at it.
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
  // Window addresses are only meaningful inside one Hyprland session; saved
  // state from another session is discarded rather than matched by address.
  readonly property string session: String(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")

  // Settings, inline on this plugin's entry in ~/.config/omarchy/shell.json:
  //   { "id": "io.github.kring-ventures.hush", "levels": [0.5, 0.1],
  //     "peek": true, "wake": true, "revealCommand": "" }
  // levels:        the opacity steps the key cycles through before returning
  //                to normal (each 0..1; one entry makes it a plain toggle).
  // peek:          focusing a hushed window reveals it until focus leaves.
  // wake:          new activity lifts a hushed window until you look at it.
  // revealCommand: run (bash, $HUSH_WORKSPACE set) before jumping to a woken
  //                window whose workspace is not on screen -- e.g. to switch a
  //                multi-monitor "global desktop" instead of one monitor.
  property var levels: [0.5, 0.1]
  property bool peek: true
  property bool wake: true
  property string revealCommand: ""

  // Hushed windows: "0x..." address -> { class, title, level, unread, awake,
  // why, wokeAt }. level indexes into `levels`; unread is the last { n, f }
  // parsed from the title (count, marker). The peeked window is still hushed;
  // it is just temporarily shown while it holds focus or the pointer.
  property var hushed: ({})
  property string peeking: ""
  property string activeAddr: ""
  // Focus alone can't end a peek: moving the pointer onto wallpaper, a bar, or
  // a dock strip leaves the window focused, so nothing would ever re-fade it.
  // While peeking, poll the cursor and end the peek when it leaves the window.
  // cursorSeen guards keyboard-driven peeks: only a cursor that actually
  // visited the window can end the peek by leaving it.
  property bool cursorSeen: false
  readonly property int count: Object.keys(hushed).length
  readonly property int awakeCount: {
    var n = 0
    for (var k in hushed) if (hushed[k].awake) n++
    return n
  }

  function applySettings(raw) {
    try {
      var cfg = JSON.parse(raw || "{}")
      // The entry sits in the bar layout once the widget is placed, otherwise
      // under plugins[]; read whichever holds it.
      var list = Array.isArray(cfg.plugins) ? cfg.plugins.slice() : []
      var layout = cfg.bar && cfg.bar.layout ? cfg.bar.layout : {}
      for (var s in layout) if (Array.isArray(layout[s])) list = list.concat(layout[s])
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
        if (e.wake !== undefined) wake = e.wake !== false
        revealCommand = typeof e.revealCommand === "string" ? e.revealCommand : ""
        break
      }
    } catch (err) {}
    if (!wake) {
      var next2 = {}
      for (var k in hushed) next2[k] = Object.assign({}, hushed[k], { "awake": false })
      hushed = next2
    }
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

  // Titles are whatever an app (or a web page) chose. Before one is kept or
  // shown: no control characters, no markup, bounded length.
  function cleanLabel(s, max) {
    var t = String(s || "").replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
      .replace(/</g, "‹").replace(/>/g, "›").trim()
    return t.length > max ? t.substring(0, max - 1) + "…" : t
  }

  // Unread state as chat apps encode it in the title:
  //   "(341) Discord | ..."  "(3) WhatsApp"      -> n = count
  //   "... - 3 new items - Slack"                -> n = count
  //   "! channel - ..." "* ..." "• ..."          -> f = marker (mention/unread)
  // Titles also change for reasons that are not activity (switching channels,
  // a sound indicator), so only a RISE counts: n goes up or f appears.
  function unreadOf(title) {
    var t = String(title || "")
    var n = 0
    var m = t.match(/^\s*\((\d+)\+?\)/)
    if (m) n = parseInt(m[1], 10)
    else {
      m = t.match(/(\d+)\s+new\s+items?\b/i)
      if (m) n = parseInt(m[1], 10)
    }
    return { "n": n, "f": /^\s*[!*•]/.test(t) }
  }

  function rise(prev, cur) {
    if (!prev) return ""
    if (cur.n > (prev.n | 0)) return cur.n + " unread"
    if (cur.f && !prev.f) return "new activity"
    return ""
  }

  function levelOpacity(level) {
    var i = Math.min(Math.max(0, level | 0), levels.length - 1)
    return levels[i]
  }

  // What a hushed window should look like right now (the peeked one aside).
  function targetOpacity(addr) {
    var e = hushed[addr]
    if (!e) return 1
    return e.awake ? 1 : levelOpacity(e.level)
  }

  // Set both opacity props: `opacity` only applies while the window is
  // active, so setting it alone fades the window while it is focused and
  // reverts the moment focus leaves — exactly backwards.
  function setOpacity(addr, value) {
    if (!safeAddr(addr)) return
    var w = "address:" + addr
    Quickshell.execDetached(["hyprctl", "--batch",
      "dispatch hl.dsp.window.set_prop({ window = '" + w + "', prop = 'opacity', value = " + value + " }) ; " +
      "dispatch hl.dsp.window.set_prop({ window = '" + w + "', prop = 'opacity_inactive', value = " + value + " })"])
  }

  function save() {
    stateFile.setText(JSON.stringify({ "session": session, "windows": hushed }, null, 2) + "\n")
  }

  // Replace one entry (bindings only see a new object, never a mutation).
  function putEntry(addr, fields) {
    var next = {}
    for (var k in hushed) next[k] = hushed[k]
    next[addr] = Object.assign({}, hushed[addr] || {}, fields)
    hushed = next
  }

  function forget(addr) {
    var next = {}
    for (var k in hushed) if (k !== addr) next[k] = hushed[k]
    hushed = next
    if (peeking === addr) peeking = ""
  }

  function setLevel(addr, level, cls, title) {
    var prev = hushed[addr]
    var fields = {
      "class": cleanLabel(cls || (prev && prev["class"]) || "", 64),
      "title": cleanLabel(title || (prev && prev.title) || "", 120),
      "level": level,
      "awake": false,
      "why": ""
    }
    // Baseline the unread state now, so a standing count ("(341)") never
    // wakes the window the moment it is hushed.
    if (title) fields.unread = unreadOf(title)
    putEntry(addr, fields)
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

  function wakeWindow(addr, why) {
    if (!wake || !(addr in hushed) || hushed[addr].awake) return
    // You are already looking at it; nothing to announce.
    if (addr === activeAddr) return
    putEntry(addr, { "awake": true, "why": why, "wokeAt": Date.now() })
    if (peeking !== addr) setOpacity(addr, 1)
    save()
  }

  // Seen it: the window goes back to sleep (re-faded when the peek ends, or
  // right away when peeking is off).
  function settle(addr) {
    if (!(addr in hushed) || !hushed[addr].awake) return
    putEntry(addr, { "awake": false, "why": "" })
    if (peeking !== addr) setOpacity(addr, targetOpacity(addr))
    save()
  }

  function onTitle(addr, title) {
    if (!(addr in hushed)) return
    var cur = unreadOf(title)
    var why = rise(hushed[addr].unread, cur)
    putEntry(addr, { "title": cleanLabel(title, 120), "unread": cur })
    if (why !== "") wakeWindow(addr, why)
  }

  // The most recently woken window, or "" if none.
  function latestAwake() {
    var best = ""
    var at = -1
    for (var k in hushed) {
      var e = hushed[k]
      if (e.awake && (e.wokeAt || 0) > at) { best = k; at = e.wokeAt || 0 }
    }
    return best
  }

  // Bar click: jump to the woken window. If its workspace is not on screen
  // and a revealCommand is set, let that bring it on screen first.
  function goToAwake() {
    var addr = latestAwake()
    if (!safeAddr(addr) || revealProc.running) return false
    revealProc.command = ["bash", "-c",
      "ws=$(hyprctl clients -j | jq -r --arg a \"$1\" '.[] | select(.address == $a) | .workspace.id');" +
      "[ -n \"$ws\" ] || exit 0;" +
      "if [ -n \"$2\" ] && [ \"$ws\" -gt 0 ] && ! hyprctl monitors -j | jq -e --argjson w \"$ws\" 'any(.[]; .activeWorkspace.id == $w)' >/dev/null; then" +
      "  HUSH_WORKSPACE=\"$ws\" HUSH_ADDRESS=\"$1\" bash -c \"$2\";" +
      "fi;" +
      "hyprctl dispatch \"hl.dsp.focus({ window = 'address:$1' })\" >/dev/null",
      "hush", addr, revealCommand]
    revealProc.running = true
    return true
  }

  function startPeek(addr) {
    peeking = addr
    cursorSeen = false
    setOpacity(addr, 1)
  }

  function endPeek() {
    if (peeking !== "" && (peeking in hushed))
      setOpacity(peeking, targetOpacity(peeking))
    peeking = ""
    cursorSeen = false
  }

  function peekTick(raw) {
    if (peeking === "") return
    var lines = String(raw || "").trim().split("\n")
    if (lines.length < 2) return
    var m = lines[0].match(/(-?\d+),\s*(-?\d+)/)
    if (!m) return
    var cx = parseInt(m[1], 10)
    var cy = parseInt(m[2], 10)
    var rect
    try { rect = JSON.parse(lines[lines.length - 1]) } catch (err) { return }
    // Window gone or not reported: leave cleanup to the closewindow event.
    if (!rect || !Array.isArray(rect.at) || !Array.isArray(rect.size)) return
    var inside = cx >= rect.at[0] && cx < rect.at[0] + rect.size[0]
              && cy >= rect.at[1] && cy < rect.at[1] + rect.size[1]
    if (inside) cursorSeen = true
    else if (cursorSeen) endPeek()
  }

  // Re-assert every hushed window's opacity (settings change, config reload).
  // The peeked window is deliberately left visible.
  function reapply() {
    for (var k in hushed) if (k !== peeking) setOpacity(k, targetOpacity(k))
  }

  function loadState(raw) {
    var data
    try { data = JSON.parse(raw || "{}") || {} } catch (err) { data = {} }
    if (data.windows && typeof data.windows === "object") {
      // Another Hyprland session: its addresses mean nothing here.
      hushed = data.session === session ? data.windows : {}
    } else {
      // v0.1 format: a bare address map, no session stamp. Keep it; the
      // reconcile below drops any address that is no longer alive.
      hushed = data
    }
  }

  // Startup reconcile: drop entries whose window no longer exists, refresh
  // class/title from the live window, wake any window whose unread count rose
  // while the shell was down, and re-apply every survivor's opacity (a shell
  // restart keeps the windows and their props; re-applying is harmless).
  function reconcile(raw) {
    try {
      var clients = JSON.parse(raw || "[]")
      var alive = {}
      for (var i = 0; i < clients.length; i++) alive[String(clients[i].address)] = clients[i]
      var next = {}
      for (var k in hushed) {
        var c = alive[k]
        if (!c || !safeAddr(k)) continue
        var e = hushed[k]
        var cur = unreadOf(c.title)
        var why = e.awake ? (e.why || "") : rise(e.unread, cur)
        next[k] = {
          "class": cleanLabel(c["class"] || e["class"] || "", 64),
          "title": cleanLabel(c.title || e.title || "", 120),
          "level": e.level | 0,
          "unread": cur,
          "awake": wake && why !== "",
          "why": why,
          "wokeAt": e.wokeAt || (why !== "" ? Date.now() : 0)
        }
      }
      hushed = next
      reapply()
      save()
    } catch (err) {}
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name)
      var data = String(event.data)
      if (name === "activewindowv2") {
        var addr = service.norm(data.split(",")[0])
        service.activeAddr = addr
        if (service.count === 0) return
        if (addr in service.hushed) service.settle(addr)
        if (!service.peek || addr === service.peeking) return
        service.endPeek()
        if (addr !== "" && (addr in service.hushed)) service.startPeek(addr)
        return
      }
      if (name === "configreloaded") { service.reapply(); return }
      if (service.count === 0) return
      if (name === "windowtitlev2") {
        // "address,title" -- the title itself may contain commas.
        var comma = data.indexOf(",")
        if (comma > 0) service.onTitle(service.norm(data.substring(0, comma)), data.substring(comma + 1))
        return
      }
      if (name === "urgent") {
        service.wakeWindow(service.norm(data), "wants attention")
        return
      }
      if (name === "closewindow") {
        var closed = service.norm(data.split(",")[0])
        if (closed in service.hushed) {
          service.forget(closed)
          service.save()
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

  Process { id: revealProc }

  // Only runs while a window is peeked; stops itself the moment the peek ends.
  Timer {
    id: peekTimer
    interval: 250
    repeat: true
    running: service.peeking !== ""
    onTriggered: {
      if (peekProbe.running) return
      peekProbe.command = ["bash", "-c",
        "hyprctl cursorpos; hyprctl clients -j | jq -c --arg a \"$1\" '[.[] | select(.address == $a)][0] | {at, size}'",
        "hush", service.peeking]
      peekProbe.running = true
    }
  }

  Process {
    id: peekProbe
    stdout: StdioCollector { onStreamFinished: service.peekTick(text) }
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
      service.loadState(text())
      clientsProc.running = true
    }
    onLoadFailed: clientsProc.running = true
  }

  IpcHandler {
    target: "io.github.kring-ventures.hush"
    function ping(): string { return "ok" }
    function toggle(): string { service.cycleActive(); return "ok" }
    function window(addr: string): string { service.cycleWindow(addr, "", ""); return "ok" }
    function clear(): string { service.clearAll(); return "ok" }
    function list(): string { return JSON.stringify(service.hushed) }
    function go(): string { return service.goToAwake() ? "ok" : "nothing awake" }
    // Read-only health report.
    function status(): string {
      return JSON.stringify({
        "session": service.session !== "" ? "ok" : "missing HYPRLAND_INSTANCE_SIGNATURE",
        "levels": service.levels, "peek": service.peek, "wake": service.wake,
        "revealCommand": service.revealCommand !== "",
        "hushed": service.count, "awake": service.awakeCount,
        "peeking": service.peeking, "active": service.activeAddr
      })
    }
  }
}
