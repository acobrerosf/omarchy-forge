// Delegates bind their outer scope lexically here, the same as Panel.qml: the
// line delegate reaches `root` and `list` by id, which without this reads as
// unqualified access and does not build.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons

// A pane of output rather than a row: a deployment log, or what a command
// printed. The two differ only in words and in the header, both of which are
// handed in — what the pane itself does with thousands of lines is the same.
//
// Presentational on the same terms as ForgeRow: declared properties in,
// nothing reached back out. It is handed lines rather than a document, because
// splitting the log is `Model.logLines`' job and this file may not import
// Model any more than ForgeRow may.
//
// A ListView rather than a Column of Text: a long deploy runs to thousands of
// lines, and only the delegates on screen should exist. It is also what makes
// `positionViewAtEnd` available, which is how the pane opens — the answer to
// "why did this fail" is at the bottom of the file, so the bottom of the file
// is where reading starts.
Item {
  id: root

  property var lines: []
  property bool loading: false
  // Set instead of `lines` when there is nothing to show: a refused request, a
  // token without the scope. Reported here rather than in the panel's status
  // line because it is the answer to what this pane was opened for.
  property string error: ""

  // What the pane says while it is empty. Defaulted to the log's words because
  // the log is what it was built for; a command run replaces both, and its
  // "waiting" is a live status rather than a fixed sentence.
  property string loadingText: "Fetching the log…"
  property string emptyText: "This deployment printed nothing."

  // One line above the output — a command's state, duration and exit code.
  // Empty for a log, which has nothing to say about itself that the site view
  // has not already said.
  property string header: ""
  property bool headerBad: false

  property color foreground: Color.foreground
  property color badColor: Color.urgent
  property string fontFamily: Style.font.family

  readonly property bool hasContent: !loading && error === "" && lines.length > 0

  readonly property real headerHeight: header === ""
    ? 0 : headerLine.implicitHeight + Style.space(6)

  // A step that moves by content rather than by pixels, so j/k walk the log at
  // the same rate whatever the font scale is. Three lines a press rather than
  // one: a deploy log is read by skimming for the place it went wrong, and a
  // pane this size would otherwise take forty presses to cross.
  readonly property real lineStep: Math.ceil(Style.font.bodySmall * 1.45) * 3

  function toEnd() { if (list.count > 0) list.positionViewAtEnd() }
  function toTop() { if (list.count > 0) list.positionViewAtBeginning() }

  function scrollBy(steps) {
    var maxY = Math.max(0, list.contentHeight - list.height)
    list.contentY = Math.max(0, Math.min(maxY, list.contentY + steps * root.lineStep))
  }

  Text {
    id: headerLine
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    visible: root.header !== ""
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: root.headerBad ? root.badColor : root.foreground
    opacity: root.headerBad ? 0.9 : 0.7
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: root.header
  }

  Text {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: root.headerHeight
    visible: root.loading || root.error !== "" || root.lines.length === 0
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: root.error !== "" ? root.badColor : root.foreground
    opacity: root.error !== "" ? 0.9 : 0.55
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: root.loading ? root.loadingText
      : root.error !== "" ? root.error
      : root.emptyText
  }

  ListView {
    id: list
    anchors.fill: parent
    anchors.topMargin: root.headerHeight
    visible: root.hasContent
    model: root.lines
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height
    // The panel's key catcher takes j/k before this ever sees them; the wheel
    // is what this handles on its own.
    keyNavigationEnabled: false
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    // Rebuilding the model resets the view to the top, so the correction
    // belongs here rather than in the caller. A log is filled once per open; a
    // command's output arrives once too, at the end of its run — what changes
    // while it runs is the header, which is not this model. Deferred because
    // contentHeight is not final until the delegates for the last screenful
    // have been built.
    onCountChanged: if (count > 0) Qt.callLater(root.toEnd)

    delegate: Text {
      required property var modelData

      width: list.width
      // WrapAnywhere, not WordWrap: a deploy log's long lines are paths,
      // stack frames and base64, which have no spaces to break at — a
      // word-wrapped one would run off the edge instead of wrapping.
      wrapMode: Text.WrapAnywhere
      textFormat: Text.PlainText
      color: root.foreground
      // Forge's own colour is stripped on the way in, so emphasis has to come
      // from somewhere else. The step markers a deploy script echoes are the
      // structure of the file; everything between them is output from whatever
      // it ran, and reads as such.
      opacity: String(modelData).indexOf("=> ") === 0 ? 0.95 : 0.65
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      text: modelData
    }
  }
}
