import QtQuick
import qs.Commons

// One team's line in a game row: name on the left, score on the right, with the
// penalty shootout score in brackets. The loser of a finished game is dimmed;
// the winner is bold. A draw dims neither.
Item {
  id: line

  property var team: ({})
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool showScore: false
  property bool finished: false
  // True when the game has a winner (a draw has none).
  property bool decided: false

  readonly property bool loser: finished && decided && !team.won
  readonly property color dim: Qt.darker(foreground, 1.5)

  width: parent ? parent.width : Style.space(200)
  height: Style.space(25)

  Row {
    anchors.left: parent.left
    anchors.right: scoreRow.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    // Fixed box so names line up whether or not a logo exists (TBD teams).
    Item {
      width: Style.space(22)
      height: Style.space(22)
      anchors.verticalCenter: parent.verticalCenter

      Image {
        anchors.fill: parent
        source: line.team.logo || ""
        visible: status === Image.Ready
        asynchronous: true
        cache: true
        fillMode: Image.PreserveAspectFit
        sourceSize.width: Style.space(44)
        sourceSize.height: Style.space(44)
        opacity: line.loser ? 0.75 : 1
      }
    }

    Text {
      width: parent.width - Style.space(30)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: line.team.name || ""
      color: line.loser ? line.dim : line.foreground
      font.family: line.fontFamily
      font.pixelSize: Style.font.title
      font.bold: !line.finished || !line.decided || line.team.won === true
    }
  }

  Row {
    id: scoreRow
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(6)
    visible: line.showScore

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: (line.team.pens || "") !== ""
      textFormat: Text.PlainText
      text: "(" + (line.team.pens || "") + ")"
      color: line.dim
      font.family: line.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: line.team.score || ""
      color: line.loser ? line.dim : line.foreground
      font.family: line.fontFamily
      font.pixelSize: Style.font.title
      font.bold: !line.finished || !line.decided || line.team.won === true
    }
  }
}
