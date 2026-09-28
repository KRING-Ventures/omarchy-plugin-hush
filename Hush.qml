import QtQuick
import qs.Commons
import qs.Ui

// Presentation only. Everything stateful lives in Service.qml, which the shell
// mounts exactly once regardless of how many monitors show this widget.
BarWidget {
  id: root
  moduleName: "io.github.kring-ventures.hush"

  readonly property var service: bar?.shell?.serviceFor(moduleName)
  readonly property bool ready: service !== null && service !== undefined
  readonly property int count: ready ? service.count : 0
  readonly property int awake: ready ? service.awakeCount : 0
  readonly property bool alwaysShow: setting("alwaysShow", false) === true

  // Nerd Font / FontAwesome eye-slash (hushed) and bell (a hushed window woke),
  // written as escapes rather than literal glyphs so they survive editors that
  // do not handle the PUA.
  readonly property string glyph: awake > 0 ? "" : ""

  readonly property string tooltip: {
    if (!ready) return "Hush: starting up"
    if (count === 0)
      return "Hush: no windows hushed\nBind a key: omarchy-shell " + moduleName + " toggle"
    var lines = [awake > 0 ? "Hush: " + awake + " woke up" : "Hushed windows:"]
    var h = service.hushed
    for (var k in h) {
      var e = h[k]
      // Titles were cleaned by the service; this only shortens them.
      var name = String(e["class"] || "?")
      var title = String(e.title || "")
      if (title.length > 44) title = title.substring(0, 44) + "…"
      var head = e.awake ? "   ●  " : "  " + (Math.round(service.levelOpacity(e.level) * 100) + "%").padStart(4) + "  "
      lines.push(head + name + (title !== "" ? " — " + title : "") + (e.awake ? "  (" + e.why + ")" : ""))
    }
    lines.push(awake > 0 ? "Click: go to it · Right-click: restore all" : "Click: restore all")
    return lines.join("\n")
  }

  visible: alwaysShow || count > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.awake > 0 ? root.glyph + "  " + root.awake
        : root.count > 0 ? root.glyph + "  " + root.count : root.glyph
    fontSize: Style.font.bodySmall
    dimmed: root.count === 0
    // Theme's attention colour while a hushed window is awake.
    active: root.awake > 0
    tooltipText: root.tooltip

    onPressed: function (b) {
      if (!root.ready || root.count === 0) return
      if (b !== Qt.RightButton && root.awake > 0 && root.service.goToAwake()) return
      root.service.clearAll()
    }
  }
}
