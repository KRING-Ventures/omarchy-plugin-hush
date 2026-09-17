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
  readonly property bool alwaysShow: setting("alwaysShow", false) === true

  // Nerd Font / FontAwesome eye-slash, written as an escape rather than a
  // literal glyph so it survives editors that do not handle the PUA.
  readonly property string glyph: ""

  readonly property string tooltip: {
    if (!ready) return "Hush: starting up"
    if (count === 0)
      return "Hush: no windows hushed\nBind a key: omarchy-shell " + moduleName + " toggle"
    var lines = ["Hushed windows:"]
    var h = service.hushed
    for (var k in h) {
      var e = h[k]
      var pct = Math.round(service.levelOpacity(e.level) * 100) + "%"
      var name = String(e["class"] || "?")
      var title = String(e.title || "")
      if (title.length > 44) title = title.substring(0, 44) + "…"
      lines.push("  " + pct.padStart(4) + "  " + name + (title !== "" ? " — " + title : ""))
    }
    lines.push("Click: restore all")
    return lines.join("\n")
  }

  visible: alwaysShow || count > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.count > 0 ? root.glyph + "  " + root.count : root.glyph
    fontSize: Style.font.bodySmall
    dimmed: root.count === 0
    tooltipText: root.tooltip

    onPressed: function (b) {
      if (root.ready && root.count > 0) root.service.clearAll()
    }
  }
}
