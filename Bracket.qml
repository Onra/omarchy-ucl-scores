import QtQuick
import qs.Commons

// The knockout bracket of one season: the classic mirrored tree, with the
// knockout playoffs on the outside and the final and the trophy in the middle.
// `layout` comes from Model.layoutBracket (positions are in layout units); the
// whole tree shrinks to fit when the screen is narrower than it is.
Item {
  id: view

  property var layout: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property string seasonText: ""
  property bool loading: false
  property bool clickable: false
  signal tieClicked(var tie)

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property real natW: layout ? Style.space(layout.width) : 0
  readonly property real natH: layout ? Style.space(layout.height) : 0
  readonly property real fit: natW > 0 ? Math.min(1, (width - Style.space(32)) / natW) : 1
  readonly property var champion: layout ? layout.champion : null

  Item {
    id: canvas
    width: view.natW
    height: view.natH
    scale: view.fit
    transformOrigin: Item.TopLeft
    x: Math.round((view.width - width * scale) / 2)
    y: Math.round(Math.max(Style.space(12), (view.height - height * scale) / 2))

    Repeater {
      model: view.layout ? view.layout.lines : []
      Rectangle {
        x: Style.space(modelData.x)
        y: Style.space(modelData.y)
        width: Style.space(modelData.w)
        height: Style.space(modelData.h)
        color: modelData.hot ? Color.accent : Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.3)
      }
    }

    Repeater {
      model: view.layout ? view.layout.cards : []
      BracketCard {
        x: Style.space(modelData.x)
        y: Style.space(modelData.y)
        width: Style.space(modelData.w)
        height: Style.space(modelData.h)
        tie: modelData.tie
        foreground: view.foreground
        fontFamily: view.fontFamily
        clickable: view.clickable
        onClicked: view.tieClicked(modelData.tie)
      }
    }

    // Trophy, and the champion once the final is played.
    Column {
      id: trophy
      x: Style.space(view.layout ? view.layout.centerX : 0) - width / 2
      y: Style.space(4)
      spacing: Style.space(6)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: "🏆"
        font.pixelSize: Style.space(44)
        opacity: view.champion ? 1 : 0.35
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: view.champion ? view.champion.name : "Champions League"
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: view.champion !== null
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: view.champion ? "CHAMPION" : "KNOCKOUT PHASE"
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 2
      }
    }

    // Under the final: the label, and the shootout when it was needed.
    Column {
      id: finalNote
      readonly property var fin: view.layout ? view.layout.final : null
      visible: fin !== null
      x: Style.space(view.layout ? view.layout.centerX : 0) - width / 2
      y: Style.space(view.layout ? view.layout.finalBottom + 6 : 0)
      spacing: Style.space(3)

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: finalText.implicitWidth + Style.space(14)
        height: Style.space(16)
        radius: Style.space(8)
        color: Color.accent
        Text {
          id: finalText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "FINAL"
          color: Color.background
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: finalNote.fin !== null && finalNote.fin.a.pens !== ""
        textFormat: Text.PlainText
        text: finalNote.fin && finalNote.fin.a.pens !== ""
          ? finalNote.fin.a.pens + " - " + finalNote.fin.b.pens + " pens" : ""
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // The tree is empty until ESPN publishes the knockout fixtures.
    Text {
      visible: view.layout !== null && !view.layout.hasTies
      x: Style.space(view.layout ? view.layout.centerX : 0) - width / 2
      y: Style.space(view.layout ? view.layout.finalBottom + 40 : 0)
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignHCenter
      text: view.loading ? "Loading…" : "The bracket fills in as the\nknockout fixtures are published"
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
