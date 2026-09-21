import QtQuick
import qs.Commons

// One tie of the bracket: the two logos, their codes and the aggregate score.
// The team that went out has its code struck through. An empty card (tie is
// null) marks a place that ESPN has not filled yet.
Rectangle {
  id: card

  property var tie: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool clickable: false
  signal clicked()

  readonly property bool decided: tie !== null && tie.winnerId !== ""
  readonly property color dim: Qt.darker(foreground, 1.7)

  radius: Math.min(6, Style.cornerRadius)
  color: tie ? Qt.rgba(foreground.r, foreground.g, foreground.b, area.containsMouse ? 0.12 : 0.05) : "transparent"
  border.width: 1
  border.color: !tie ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)
    : tie.live ? Color.urgent
    : Qt.rgba(foreground.r, foreground.g, foreground.b, area.containsMouse ? 0.6 : 0.3)

  Row {
    visible: card.tie !== null
    anchors.top: parent.top
    anchors.topMargin: Style.space(6)
    anchors.horizontalCenter: parent.horizontalCenter

    Repeater {
      model: card.tie ? [card.tie.a, card.tie.b] : []

      Item {
        readonly property bool out: card.decided && modelData.id !== card.tie.winnerId

        width: card.width / 2
        height: Style.space(38)

        Image {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(22)
          height: Style.space(22)
          source: modelData.logo || ""
          visible: status === Image.Ready
          asynchronous: true
          cache: true
          fillMode: Image.PreserveAspectFit
          sourceSize.width: Style.space(44)
          sourceSize.height: Style.space(44)
          opacity: parent.out ? 0.7 : 1
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          textFormat: Text.PlainText
          text: modelData.abbr
          color: parent.out ? card.dim : card.foreground
          font.family: card.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: card.decided && !parent.out
          font.strikeout: parent.out
        }
      }
    }
  }

  Text {
    visible: card.tie !== null
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(5)
    textFormat: Text.PlainText
    text: !card.tie ? "" : card.tie.state === "pre" ? "vs" : card.tie.a.score + " - " + card.tie.b.score
    color: card.tie && card.tie.state === "pre" ? card.dim : card.foreground
    font.family: card.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  MouseArea {
    id: area
    anchors.fill: parent
    enabled: card.clickable && card.tie !== null
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: card.clicked()
  }
}
