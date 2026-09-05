import QtQuick
import qs.Commons

// One row of the panel: an organization, a server, a site, or one of the
// actions the site view offers.
//
// Pure presentational — no service reference, no Model import, no reach back
// into the panel. Everything it draws arrives as a declared property, and
// everything it wants done leaves as a signal. `Model.rowView` is what turns a
// row into these strings; the metrics and the palette are this component's,
// because those are QML types the model may not touch.
Rectangle {
  id: root

  // "org" | "server" | "site" | "action" | "event" | "recipe". Drives weight,
  // size and the chevron, which are the only things that differ structurally
  // between them.
  property string kind: "server"

  // An action row has no dot: the dot reports remote state, and an action has
  // none to report until it is run.
  property bool showDot: true

  property string label: ""
  property string detail: ""
  property string status: ""
  property string timeText: ""

  // "bad" | "busy" | "warn" | "ok" | "idle". `warn` is drawn as a ring rather
  // than a fill — see the dot below.
  property string tone: "idle"

  // How far under its parent this row sits, in steps rather than pixels.
  property int depth: 0
  property int indentStep: Style.space(16)

  property bool expanded: false
  property bool showChevron: true
  property bool hasCursor: false
  // A server has somewhere to go that the tree cannot show — what can be done
  // to it — so the row carries the way there rather than leaving it to a key
  // nothing on screen mentions. Dim at rest so a list of servers still reads
  // as a list, and lit when the pointer is on it, which is what says it can be
  // clicked at all.
  property bool showActions: false
  // Nothing that changes a real server goes on one press, and the row is where
  // both are reported: the arm as `armedText`, the request on its way as
  // `sending`. The wording belongs to the action — "press again to deploy",
  // "press Y to reboot" — so it arrives with the rest of the row's text rather
  // than being decided here.
  property bool armed: false
  property string armedText: "press again to deploy"
  property bool sending: false

  property color foreground: Color.foreground
  property color dimColor: Qt.darker(foreground, 1.55)
  property color badColor: Color.urgent
  property color busyColor: Color.accent
  property color okColor: Color.foreground
  property color urgentColor: Color.urgent
  property color cursorFill: "transparent"
  property string fontFamily: Style.font.family

  signal activated()
  // Distinct from `activated`: clicking the row unfolds it, clicking this one
  // glyph inside the row goes to the actions instead.
  signal actionsRequested()
  signal contextRequested()
  signal entered()

  readonly property bool isSite: kind === "site"
  // Sites, actions, events and recipes all sit one level in from a heading and
  // read better a size down from it.
  readonly property bool isCompact: isSite || kind === "action"
    || kind === "event" || kind === "recipe"

  readonly property color toneColor: {
    switch (root.tone) {
    case "bad": return root.badColor
    case "busy": return root.busyColor
    case "ok": return root.okColor
    // Drawn as a ring rather than a fill, but the colour still comes out of
    // this switch — so the vocabulary is complete and the dot below has one
    // place to ask, whichever shape it is about to draw.
    case "warn": return root.foreground
    }
    return root.dimColor
  }

  // The two states that outrank whatever the row would otherwise report.
  readonly property string statusText: root.sending ? "sending…"
    : root.armed ? root.armedText
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

    // A fourth tone had nowhere to go in the palette: `Color` offers exactly
    // five values, `busyColor` and `okColor` are already the same one in a
    // theme that sets no accent, and `muted` falls back to the foreground the
    // dim colour is derived from. So `warn` is distinguished by shape — a ring
    // where every other tone is a disc — which is the same move the busy pulse
    // makes, and is legible in every theme rather than most of them.
    Rectangle {
      id: dot
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showDot
      width: root.showDot ? Style.space(6) : 0
      height: Style.space(6)
      radius: width / 2
      antialiasing: true
      color: root.tone === "warn" ? "transparent" : root.toneColor
      // Proportional, not a hairline: `Style.space` tracks the configured font
      // size, so a fixed 1px ring reads as a smudge on a large bar.
      border.width: root.tone === "warn" ? Math.max(1, Math.round(width / 3)) : 0
      border.color: root.toneColor
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
      // A Row puts a gap only between children it actually lays out, so both
      // the widths and the count of gaps follow what is visible.
      width: Math.max(0, parent.width - dot.width - trailing.implicitWidth
        - actionsIcon.width - chevron.width
        - parent.spacing * ((root.showDot ? 1 : 0) + 1
                            + (root.showActions ? 1 : 0) + (root.showChevron ? 1 : 0)))
      spacing: Style.space(2)

      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.isCompact ? Style.font.bodySmall : Style.font.body
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
      id: actionsIcon
      anchors.verticalCenter: parent.verticalCenter
      width: root.showActions ? implicitWidth : 0
      visible: root.showActions
      textFormat: Text.PlainText
      color: root.foreground
      opacity: actionsArea.containsMouse ? 0.95 : 0.4
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      text: "󰒓"

      MouseArea {
        id: actionsArea
        anchors.fill: parent
        // A caption-sized glyph is a target the pointer has to be aimed at, so
        // the area it answers to is bigger than the mark it draws. It sits over
        // the row's own MouseArea — a later sibling, so it wins the click — and
        // still reports the hover, or the cursor would jump off this row while
        // the pointer was on it.
        anchors.margins: -Style.space(4)
        hoverEnabled: true
        onEntered: root.entered()
        onClicked: root.actionsRequested()
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
