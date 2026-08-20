import QtQuick
import qs.Commons

// One row of the panel: an organization, a server or a site.
//
// Pure presentational — no service reference, no Model import, no reach back
// into the panel. Everything it draws arrives as a declared property, and
// everything it wants done leaves as a signal. `Model.rowView` is what turns a
// row into these strings; the metrics and the palette are this component's,
// because those are QML types the model may not touch.
Rectangle {
  id: root

  // "org" | "server" | "site". Drives weight, size and the chevron, which are
  // the only things that differ structurally between the three.
  property string kind: "server"

  property string label: ""
  property string detail: ""
  property string status: ""
  property string timeText: ""

  // "bad" | "busy" | "ok" | "idle"
  property string tone: "idle"

  // How far under its parent this row sits, in steps rather than pixels.
  property int depth: 0
  property int indentStep: Style.space(16)

  property bool expanded: false
  property bool showChevron: true
  property bool hasCursor: false
  // Deploying takes two presses, and the row is where both are reported.
  property bool armed: false
  property bool deploying: false

  property color foreground: Color.foreground
  property color dimColor: Qt.darker(foreground, 1.55)
  property color badColor: Color.urgent
  property color busyColor: Color.accent
  property color okColor: Color.foreground
  property color urgentColor: Color.urgent
  property color cursorFill: "transparent"
  property string fontFamily: Style.font.family

  signal activated()
  signal contextRequested()
  signal entered()

  readonly property bool isSite: kind === "site"

  readonly property color toneColor: {
    switch (root.tone) {
    case "bad": return root.badColor
    case "busy": return root.busyColor
    case "ok": return root.okColor
    }
    return root.dimColor
  }

  // The two states that outrank whatever the row would otherwise report.
  readonly property string statusText: root.deploying ? "sending…"
    : root.armed ? "press again to deploy"
    : root.status

  implicitHeight: rowContent.implicitHeight + Style.space(10)
  height: implicitHeight
  radius: Style.cornerRadius
  color: root.hasCursor ? root.cursorFill : "transparent"

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onEntered: root.entered()
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.contextRequested()
      else root.activated()
    }
  }

  Row {
    id: rowContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(8) + root.depth * root.indentStep
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(8)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(6)
      height: width
      radius: width / 2
      color: root.toneColor
      opacity: root.tone === "idle" ? 0.4 : 1.0

      SequentialAnimation on opacity {
        running: root.tone === "busy"
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { from: 1.0; to: 0.3; duration: 700 }
        NumberAnimation { from: 0.3; to: 1.0; duration: 700 }
      }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, parent.width - Style.space(6) - trailing.implicitWidth
        - parent.spacing * 2 - chevron.width)
      spacing: Style.space(2)

      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.isSite ? Style.font.bodySmall : Style.font.body
        font.bold: root.kind === "org"
        text: root.label
      }

      Text {
        width: parent.width
        elide: Text.ElideRight
        visible: text !== ""
        textFormat: Text.PlainText
        color: root.foreground
        opacity: 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        text: root.detail
      }
    }

    // Right-aligned inside a Column has to come from the text's own alignment:
    // anchoring children to a Column whose width is derived from those same
    // children loops.
    Column {
      id: trailing
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      width: Math.max(statusLabel.implicitWidth, timeLabel.implicitWidth)

      Text {
        id: statusLabel
        width: parent.width
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        color: root.armed ? root.urgentColor : root.foreground
        opacity: root.armed ? 1.0 : 0.75
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        text: root.statusText
      }

      Text {
        id: timeLabel
        width: parent.width
        horizontalAlignment: Text.AlignRight
        visible: text !== ""
        textFormat: Text.PlainText
        color: root.foreground
        opacity: 0.45
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        text: root.timeText
      }
    }

    Text {
      id: chevron
      anchors.verticalCenter: parent.verticalCenter
      width: root.showChevron ? implicitWidth : 0
      visible: root.showChevron
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      text: root.expanded ? "󰅀" : "󰅂"
    }
  }
}
