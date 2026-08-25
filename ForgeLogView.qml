// Delegates bind their outer scope lexically here, the same as Panel.qml: the
// line delegate reaches `root` and `list` by id, which without this reads as
// unqualified access and does not build.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons

// The deployment log, as a pane rather than a row.
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

  property color foreground: Color.foreground
  property color badColor: Color.urgent
  property string fontFamily: Style.font.family

  readonly property bool hasContent: !loading && error === "" && lines.length > 0

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
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    visible: root.loading || root.error !== "" || root.lines.length === 0
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: root.error !== "" ? root.badColor : root.foreground
    opacity: root.error !== "" ? 0.9 : 0.55
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: root.loading ? "Fetching the log…"
      : root.error !== "" ? root.error
      : "This deployment printed nothing."
  }

  ListView {
    id: list
    anchors.fill: parent
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

    // Rebuilding the model resets the view to the top, and this pane is only
    // ever filled once per open, so the correction belongs here rather than in
    // the caller. Deferred because contentHeight is not final until the
    // delegates for the last screenful have been built.
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
