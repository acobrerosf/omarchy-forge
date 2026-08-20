import QtQuick
import QtQuick.Shapes
import qs.Commons

// The Forge mark, plus one badge for the aggregate state.
//
// The path is authored on a 24-unit grid and is wider than it is tall, so the
// item keeps a square footprint — that is what the bar slot centres on — and
// the glyph is fitted inside it. CurveRenderer matters here: the mark is all
// diagonals, and the geometry renderer tessellates those into visible stairs
// at the ~11px the bar draws it at.
Item {
  id: root

  property real iconSize: Style.space(11)
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  // "none" | "busy" | "bad" | "warn"
  property string badge: "none"

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: implicitWidth
  height: implicitHeight

  Shape {
    anchors.fill: parent
    fillMode: Shape.PreserveAspectFit
    horizontalAlignment: Shape.AlignHCenter
    verticalAlignment: Shape.AlignVCenter
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true

    ShapePath {
      fillColor: root.color
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg {
        path: "M23.7123 2.64368H3.25309C3.00359 2.64368 2.75408 2.84328 2.70418 3.09278L2.20518 4.88919C2.15528 5.0888 2.25508 5.2385 2.40478 5.3383C3.20319 5.5878 7.49462 5.6876 6.84592 8.08282L6.69622 8.73153L4.9497 15.2685L4.8 15.9172C4.15129 18.3124 1.85588 18.4122 0.907768 18.6617C0.708167 18.7116 0.558465 18.9112 0.508565 19.1108L0.009561 20.9072C-0.0403394 21.1567 0.109362 21.3563 0.358864 21.3563H8.69223C8.94173 21.3563 9.19124 21.1567 9.24114 20.9072L10.7381 15.1188C10.788 14.8693 11.0376 14.6697 11.2871 14.6697H16.6264C16.8759 14.6697 17.1254 14.4701 17.1753 14.2206L17.9737 11.1267C18.0236 10.8772 17.8739 10.6776 17.6244 10.6776H12.2851C12.0356 10.6776 11.8859 10.478 11.9358 10.2285L12.6843 7.43412C12.7342 7.18461 12.9837 6.98501 13.2332 6.98501H21.2671C21.5166 6.98501 21.7661 6.78541 21.816 6.53591L23.9618 3.14268C24.0616 2.84328 23.9618 2.64368 23.7123 2.64368Z"
      }
    }
  }

  // The badge sits proud of the bottom-right corner, which is the emptiest
  // part of the mark, and carries a ring of background so it stays legible
  // where it overlaps the glyph.
  Rectangle {
    visible: root.badge !== "none"
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: -Math.round(root.iconSize * 0.08)
    anchors.bottomMargin: -Math.round(root.iconSize * 0.08)
    width: Math.max(3, Math.round(root.iconSize * 0.36))
    height: width
    radius: width / 2
    color: root.badgeColor
    opacity: root.badge === "busy" ? busyPulse.opacityValue : 1.0

    Rectangle {
      anchors.centerIn: parent
      width: parent.width + 2
      height: parent.height + 2
      radius: width / 2
      color: "transparent"
      border.width: 1
      border.color: Color.background
      z: -1
    }
  }

  QtObject {
    id: busyPulse
    property real opacityValue: 1.0
  }

  SequentialAnimation {
    running: root.badge === "busy"
    loops: Animation.Infinite
    alwaysRunToEnd: true
    NumberAnimation { target: busyPulse; property: "opacityValue"; from: 1.0; to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
    NumberAnimation { target: busyPulse; property: "opacityValue"; from: 0.35; to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
  }
}
