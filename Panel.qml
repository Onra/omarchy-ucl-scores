import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Scores and schedule panel. Owns the fetchers and the refresh timers so the
// bar label stays current while the panel is closed. Four fetches run:
//   - "season" (two calendar years): every game of the season, which is how the
//     rounds are found. ESPN has no matchday numbers, see Model.buildRounds.
//   - "today": today's games only, polled fast while something is live.
//   - "standings": the league phase table, when it is on screen.
Panel {
  id: root
  moduleName: "onra.ucl-scores"
  ipcTarget: "onra.ucl-scores"
  manageIpc: false

  property var anchorItem: null
  // The bar tracks the widget mounted in its slot, not this nested panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- data ----------------------------------------------------------------
  readonly property int seasonYear: Model.seasonYearFor(Date.now())
  property var games: ({})            // game id -> game, the whole season
  property int gamesVersion: 0
  property real now: Date.now()       // moves the "current round" along with the clock
  property real seasonAt: 0           // when the season was last fetched
  property string pickedKey: ""       // round chosen by the user; "" follows the calendar
  property string errorMessage: ""

  // "scores" (default: the current round), "standings" (league phase table) or
  // "bracket" (the knockout tree). Opening the panel always returns to scores.
  property string mode: "scores"
  readonly property bool standingsMode: root.mode === "standings"
  readonly property bool bracketMode: root.mode === "bracket"

  // The bracket of the current season is built from `games`; earlier seasons
  // are fetched once, when you step back to them, and kept here.
  property int bracketSeason: 0       // 0 follows the current season
  readonly property int shownSeason: root.bracketSeason > 0 ? root.bracketSeason : root.seasonYear
  property var archive: ({})          // season -> { game id -> game }
  property int archiveVersion: 0
  readonly property bool archiveLoading: root.shownSeason !== root.seasonYear && root.archive[root.shownSeason] === undefined
  readonly property var bracket: {
    root.gamesVersion
    root.archiveVersion
    var g = root.shownSeason === root.seasonYear ? root.games : (root.archive[root.shownSeason] || ({}))
    return Model.layoutBracket(g)
  }
  property var standingsRows: []
  property string standingsLabel: ""
  readonly property int activeRowCount: root.bracketMode ? (root.bracket.hasTies ? 1 : 0) : root.standingsMode ? root.standingsRows.length : root.viewRows.length
  readonly property var activeList: root.standingsMode ? standingsList : list

  // Standings table columns: which team field, header label, width in px.
  readonly property var statColumns: [
    { key: "p",   label: "P",   w: 26 },
    { key: "w",   label: "W",   w: 26 },
    { key: "d",   label: "D",   w: 26 },
    { key: "l",   label: "L",   w: 26 },
    { key: "gd",  label: "GD",  w: 36 },
    { key: "pts", label: "PTS", w: 36 }
  ]

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.5)

  readonly property var rounds: {
    root.gamesVersion  // dependency: re-evaluate when games change
    return Model.buildRounds(root.games)
  }
  readonly property int currentIndex: {
    root.now
    return Model.currentIndex(root.rounds, root.now)
  }
  readonly property var currentRound: root.currentIndex >= 0 ? root.rounds[root.currentIndex] : null
  readonly property string currentKey: root.currentRound ? root.currentRound.key : ""
  readonly property string viewKey: Model.indexOfKey(root.rounds, root.pickedKey) >= 0 ? root.pickedKey : root.currentKey
  readonly property int viewIndex: Model.indexOfKey(root.rounds, root.viewKey)
  readonly property var viewRound: root.viewIndex >= 0 ? root.rounds[root.viewIndex] : null
  readonly property var viewGames: root.viewRound ? root.viewRound.games : []
  readonly property var viewRows: Model.rows(root.viewGames)
  readonly property bool viewingCurrent: root.viewKey === root.currentKey

  readonly property bool hasData: root.rounds.length > 0
  readonly property int liveGames: {
    root.gamesVersion
    return Model.liveCount(root.games)
  }

  // The competition is part of the label, so it can never be mistaken for the
  // Europa League widget: "⚽ UCL MD2".
  readonly property string competition: "UCL"
  readonly property string barIcon: "⚽"
  readonly property string barText: {
    var r = root.currentRound
    if (!r) return root.barIcon + " " + root.competition
    var t = root.barIcon + " " + root.competition + " " + r.abbr
    if (root.liveGames > 0) t += " ● " + root.liveGames
    return t
  }

  function merge(json) {
    var list = Model.parseEvents(json, root.seasonYear)
    if (list.length === 0) return
    var next = ({})
    for (var k in root.games) next[k] = root.games[k]
    for (var i = 0; i < list.length; i++) next[list[i].id] = list[i]
    root.games = next
    root.gamesVersion++
  }

  // A season is fetched as two calendar years, because it runs from
  // September to May. Each is one request of a few hundred KB (compressed).
  function fetchSeason() {
    yearFetcher.fetch(Model.yearUrl(root.seasonYear))
    nextYearFetcher.fetch(Model.yearUrl(root.seasonYear + 1))
  }

  function fetchToday() { todayFetcher.fetch(Model.dayUrl(Date.now())) }

  function fetchStandings() { standingsFetcher.fetch(Model.standingsUrl()) }

  function refresh() {
    root.now = Date.now()
    root.fetchToday()
    // Fixtures rarely change, results arrive through the today fetch.
    if (Date.now() - root.seasonAt > 10 * 60 * 1000) root.fetchSeason()
    if (root.standingsMode) root.fetchStandings()
  }

  // A refresh the user asked for (r key, IPC) shows a spinner and a footer
  // note. It stays up for at least minRefreshMs so a fast fetch is still
  // visible, and until every fetcher is idle. Background polling stays silent.
  property bool manualRefresh: false
  readonly property int minRefreshMs: 800

  function refreshNow() {
    root.manualRefresh = true
    refreshFloor.restart()
    root.now = Date.now()
    root.fetchToday()
    root.fetchSeason()
    if (root.standingsMode) root.fetchStandings()
  }

  function settleRefresh() {
    if (!root.manualRefresh || refreshFloor.running) return
    if (yearFetcher.busy || nextYearFetcher.busy || todayFetcher.busy || standingsFetcher.busy) return
    root.manualRefresh = false
  }

  Timer {
    id: refreshFloor
    interval: root.minRefreshMs
    onTriggered: root.settleRefresh()
  }

  Fetcher {
    id: yearFetcher
    onLoaded: function(url, json) {
      root.merge(json)
      root.seasonAt = Date.now()
      root.errorMessage = ""
    }
    onFailed: root.errorMessage = "Couldn't reach ESPN"
    onBusyChanged: root.settleRefresh()
  }

  Fetcher {
    id: nextYearFetcher
    onLoaded: function(url, json) { root.merge(json) }
    // The second half of the season is not always published: not an error.
    onBusyChanged: root.settleRefresh()
  }

  Fetcher {
    id: todayFetcher
    onLoaded: function(url, json) {
      root.merge(json)
      root.errorMessage = ""
    }
    onFailed: root.errorMessage = "Couldn't reach ESPN"
    onBusyChanged: root.settleRefresh()
  }

  Fetcher {
    id: standingsFetcher
    onLoaded: function(url, json) {
      var r = Model.parseStandings(json)
      root.standingsRows = r.rows
      if (r.label) root.standingsLabel = r.label
      root.errorMessage = ""
    }
    onFailed: root.errorMessage = "Couldn't reach ESPN"
    onBusyChanged: root.settleRefresh()
  }

  // A past season, for the bracket: its knockouts all fall in the calendar year
  // after it starts, so that one request is enough.
  Fetcher {
    id: archiveFetcher
    onLoaded: function(url, json) {
      var season = Model.yearOfUrl(url) - 1
      var list = Model.parseEvents(json, season)
      var map = ({})
      for (var i = 0; i < list.length; i++) map[list[i].id] = list[i]
      var next = ({})
      for (var k in root.archive) next[k] = root.archive[k]
      next[season] = map
      root.archive = next
      root.archiveVersion++
      root.errorMessage = ""
    }
    onFailed: root.errorMessage = "Couldn't reach ESPN"
  }

  function fetchArchive(season) {
    if (season === root.seasonYear || root.archive[season] !== undefined) return
    archiveFetcher.fetch(Model.yearUrl(season + 1))
  }

  // ---- recaps ------------------------------------------------------------------
  // YouTube highlight videos for the finished games on screen, resolved by
  // recap.py (cached on disk, so this is cheap after the first look at a round).
  Recaps { id: recaps }

  function requestRecaps() {
    if (root.mode !== "scores") return
    recaps.want(Model.recapEntries(root.viewGames, root.seasonYear))
  }

  onViewGamesChanged: root.requestRecaps()

  function openUrl(url) {
    Quickshell.execDetached(["xdg-open", url])
    root.close()
  }

  function openRecap(videoId) { root.openUrl("https://www.youtube.com/watch?v=" + videoId) }

  function openSearch(game) { root.openUrl(Model.searchUrl(game, root.seasonYear)) }

  // Every 30s while a game is live, every 5 minutes otherwise; the whole season
  // is refreshed every half hour (kickoff times move now and then).
  Timer {
    interval: root.liveGames > 0 ? 30000 : 300000
    running: true
    repeat: true
    onTriggered: {
      root.now = Date.now()
      root.fetchToday()
      if (root.opened && root.standingsMode) root.fetchStandings()
    }
  }

  Timer {
    interval: 30 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.fetchSeason()
  }

  Component.onCompleted: {
    root.fetchSeason()
    root.fetchToday()
  }

  // ---- navigation ------------------------------------------------------------
  function stepRound(delta) {
    if (root.rounds.length === 0) return
    var i = root.viewIndex >= 0 ? root.viewIndex : 0
    var next = Math.max(0, Math.min(root.rounds.length - 1, i + delta))
    if (next === i) return
    var key = root.rounds[next].key
    root.pickedKey = key === root.currentKey ? "" : key
    root.errorMessage = ""
  }

  function goCurrent() {
    root.pickedKey = ""
    root.errorMessage = ""
  }

  function scrollBy(px) {
    var l = root.activeList
    var max = Math.max(0, l.contentHeight - l.height)
    l.contentY = Math.max(0, Math.min(max, l.contentY + px))
  }

  function showStandings() {
    root.mode = "standings"
    root.errorMessage = ""
    standingsList.keepY = 0
    standingsList.contentY = 0
    root.fetchStandings()
  }

  function showScores() {
    if (root.mode === "scores") return
    root.mode = "scores"
    root.errorMessage = ""
    root.requestRecaps()
  }

  function showBracket() {
    root.mode = "bracket"
    root.errorMessage = ""
    root.fetchArchive(root.shownSeason)
  }

  function toggleStandings() {
    if (root.standingsMode) root.showScores()
    else root.showStandings()
  }

  function toggleBracket() {
    if (root.bracketMode) root.showScores()
    else root.showBracket()
  }

  // Bracket of another season, back to the first one with this format.
  function stepSeason(delta) {
    var next = Math.max(Model.firstBracketSeason(), Math.min(root.seasonYear, root.shownSeason + delta))
    if (next === root.shownSeason) return
    root.bracketSeason = next === root.seasonYear ? 0 : next
    root.errorMessage = ""
    root.fetchArchive(next)
  }

  // A click on a tie of the current season opens the round it is being played in.
  function openTie(tie) {
    if (root.shownSeason !== root.seasonYear || !tie) return
    var id = tie.gameIds[0]
    for (var i = 0; i < tie.legs.length; i++) if (tie.legs[i].state !== "pre") id = tie.legs[i].id
    var key = Model.roundKeyOfGame(root.rounds, id)
    if (key === "") return
    root.pickedKey = key === root.currentKey ? "" : key
    root.showScores()
  }

  function setTab(name) {
    if (name === "standings") root.showStandings()
    else if (name === "bracket") root.showBracket()
    else root.showScores()
  }

  onViewKeyChanged: {
    if (typeof list === "undefined" || !list) return
    list.keepY = 0
    list.contentY = 0
  }

  function open() {
    root.mode = "scores"
    root.bracketSeason = 0
    root.goCurrent()
    root.controller.show()
    root.refresh()
    root.requestRecaps()
  }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // Declared here rather than left to the base Panel so every entry point
  // (bar click, summon, IPC) goes through this file's open(), which resets the
  // view to the current round.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function next(): void { root.bracketMode ? root.stepSeason(1) : root.stepRound(1) }
    function prev(): void { root.bracketMode ? root.stepSeason(-1) : root.stepRound(-1) }
    function today(): void { root.showScores(); root.goCurrent() }
    function standings(): void { root.showStandings() }
    function bracket(): void { root.showBracket() }
    function scores(): void { root.showScores() }
    function refresh(): void { root.refreshNow() }
  }

  // ---- UI ---------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.bracketMode ? 1080 : 520))
    contentHeight: panel.fittedContentHeight(root.bracketMode
      ? header.height + tabs.height + Style.space(root.bracket.height) + footer.height + Style.space(28)
      : Math.max(Style.space(320), header.height + tabs.height + root.activeList.contentHeight + footer.height + Style.space(24)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          if (root.bracketMode) root.stepSeason(dx)
          else if (!root.standingsMode) root.stepRound(dx)
        }
        else root.scrollBy(dy * Style.space(80))
      }
      onTextKey: function(t) {
        if (t === "t") { root.showScores(); root.goCurrent() }
        else if (t === "s") root.toggleStandings()
        else if (t === "b") root.toggleBracket()
        else if (t === "r") root.refreshNow()
      }

      // ---- header: ‹  Matchday 2  › --------------------------------------------
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(56)

        NavButton {
          id: prevButton
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          glyph: "‹"
          foreground: root.fg
          fontFamily: root.fontFamily
          visible: !root.standingsMode
          enabled: root.bracketMode ? root.shownSeason > Model.firstBracketSeason() : root.viewIndex > 0
          onClicked: root.bracketMode ? root.stepSeason(-1) : root.stepRound(-1)
        }

        Column {
          id: titleColumn
          anchors.centerIn: parent
          spacing: Style.space(3)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: root.standingsMode ? "Standings" : root.bracketMode ? "Knockout Bracket" : root.viewRound ? root.viewRound.label : "Champions League"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: {
              if (root.standingsMode)
                return (root.standingsLabel ? root.standingsLabel + " · " : "") + "league phase"
              if (root.bracketMode)
                return Model.seasonLabel(root.shownSeason).replace("/", "-") + " season"
              if (!root.viewRound) return ""
              var parts = [root.viewRound.section]
              var range = Model.rangeLabel(root.viewGames)
              if (range !== "") parts.push(range)
              return parts.join(" · ")
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // Spinner beside the title while a manual refresh is running: a round
        // 270-degree arc with rounded caps, drawn rather than a font glyph so
        // it stays smooth at any size and theme font.
        Shape {
          id: spinner
          readonly property real size: Style.space(16)
          readonly property real stroke: Math.max(2, Style.space(2))

          anchors.left: titleColumn.right
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          width: size
          height: size
          visible: root.manualRefresh
          layer.enabled: true
          layer.samples: 4

          ShapePath {
            strokeColor: root.fg
            strokeWidth: spinner.stroke
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap

            PathAngleArc {
              centerX: spinner.size / 2
              centerY: spinner.size / 2
              radiusX: (spinner.size - spinner.stroke) / 2
              radiusY: (spinner.size - spinner.stroke) / 2
              startAngle: 0
              sweepAngle: 270
            }
          }

          RotationAnimator on rotation {
            running: root.manualRefresh
            from: 0; to: 360
            duration: 800
            loops: Animation.Infinite
          }
        }

        // "This round" appears only once you have wandered off it.
        Rectangle {
          id: todayButton
          visible: !root.standingsMode && !root.bracketMode && !root.viewingCurrent && root.currentKey !== ""
          anchors.right: nextButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: todayText.implicitWidth + Style.space(16)
          height: Style.space(24)
          radius: Math.min(4, Style.cornerRadius)
          color: todayArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)

          Text {
            id: todayText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "This round"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: todayArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.goCurrent()
          }
        }

        NavButton {
          id: nextButton
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          glyph: "›"
          foreground: root.fg
          fontFamily: root.fontFamily
          visible: !root.standingsMode
          enabled: root.bracketMode ? root.shownSeason < root.seasonYear : root.viewIndex >= 0 && root.viewIndex < root.rounds.length - 1
          onClicked: root.bracketMode ? root.stepSeason(1) : root.stepRound(1)
        }
      }

      // Scores | Standings | Bracket
      Item {
        id: tabs
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(30)

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Repeater {
            model: [
              { id: "scores", label: "Scores" },
              { id: "standings", label: "Standings" },
              { id: "bracket", label: "Bracket" }
            ]

            Rectangle {
              readonly property bool active: root.mode === modelData.id
              width: tabText.implicitWidth + Style.space(22)
              height: Style.space(24)
              radius: Math.min(4, Style.cornerRadius)
              color: active ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
                : tabArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, active ? 0.4 : 0.2)

              Text {
                id: tabText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: modelData.label
                color: parent.active ? root.fg : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: parent.active
              }
              MouseArea {
                id: tabArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setTab(modelData.id)
              }
            }
          }
        }
      }

      PanelSeparator {
        id: headerRule
        anchors.top: tabs.bottom
        foreground: root.fg
      }

      // ---- games -----------------------------------------------------------------
      ListView {
        id: list
        visible: !root.standingsMode && !root.bracketMode
        anchors.top: headerRule.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.viewRows

        // A refresh swaps the model for a fresh array, which snaps a plain
        // ListView back to the top. Remember where we were and go back there
        // (a week change zeroes keepY first, so that still starts at the top).
        property real keepY: 0
        property bool restoring: false
        onContentYChanged: if (!restoring) keepY = contentY
        onModelChanged: {
          restoring = true
          Qt.callLater(function() {
            list.contentY = Math.min(list.keepY, Math.max(0, list.contentHeight - list.height))
            list.restoring = false
          })
        }

        delegate: Item {
          id: row
          readonly property bool isDay: modelData.kind === "day"
          readonly property var game: modelData.game
          readonly property bool live: !isDay && game.state === "in"

          width: list.width
          height: isDay ? Style.space(32) : Style.space(62)

          // Day header
          Text {
            visible: row.isDay
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(5)
            textFormat: Text.PlainText
            text: row.isDay ? modelData.label.toUpperCase() : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          // Game
          Item {
            visible: !row.isDay
            anchors.fill: parent

            Column {
              id: statusColumn
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(88)
              spacing: Style.space(2)

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: row.isDay ? "" : Model.statusText(row.game)
                color: row.live ? Color.urgent : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: row.live
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                // Second legs show the aggregate of the tie, otherwise the city.
                text: row.isDay ? "" : (row.game.note !== "" ? row.game.note : row.game.city)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            // Home team on top, as fixtures read in football.
            Column {
              anchors.left: statusColumn.right
              anchors.leftMargin: Style.space(12)
              anchors.right: recapPill.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter

              TeamLine {
                team: row.isDay ? ({}) : row.game.home
                foreground: root.fg
                fontFamily: root.fontFamily
                showScore: !row.isDay && row.game.state !== "pre"
                finished: !row.isDay && row.game.state === "post"
                decided: !row.isDay && row.game.decided
              }
              TeamLine {
                team: row.isDay ? ({}) : row.game.away
                foreground: root.fg
                fontFamily: root.fontFamily
                showScore: !row.isDay && row.game.state !== "pre"
                finished: !row.isDay && row.game.state === "post"
                decided: !row.isDay && row.game.decided
              }
            }

            // YouTube highlights of a finished game: the video itself once one
            // has been found on a club's official channel, until then (and for
            // clubs that post none) a YouTube search for the game.
            Rectangle {
              id: recapPill
              readonly property bool finished: !row.isDay && row.game.state === "post"
              readonly property string videoId: finished ? recaps.videoId(row.game.id) : ""
              readonly property bool searchOnly: finished && videoId === "" && recaps.answered(row.game.id)
              visible: videoId !== "" || searchOnly
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(76)
              height: Style.space(24)
              radius: Math.min(4, Style.cornerRadius)
              color: recapArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, recapArea.containsMouse ? 0.5 : 0.25)

              Text {
                id: recapText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: recapPill.videoId !== "" ? "▶ Recap" : "▶ Search"
                color: recapPill.videoId !== "" ? root.fg : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                id: recapArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (recapPill.videoId !== "") root.openRecap(recapPill.videoId)
                  else root.openSearch(row.game)
                }
              }
            }

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(16)
              anchors.rightMargin: Style.space(16)
              height: 1
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
            }
          }
        }

        // Empty / loading / error states.
        Text {
          anchors.centerIn: parent
          visible: list.count === 0
          textFormat: Text.PlainText
          text: root.errorMessage !== "" ? root.errorMessage
            : !root.hasData ? "Loading…"
            : "No games scheduled"
          color: root.errorMessage !== "" ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }

      // ---- standings ---------------------------------------------------------------
      ListView {
        id: standingsList
        visible: root.standingsMode
        anchors.top: headerRule.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.standingsRows

        // Same refresh-keeps-position handling as the scores list.
        property real keepY: 0
        property bool restoring: false
        onContentYChanged: if (!restoring) keepY = contentY
        onModelChanged: {
          restoring = true
          Qt.callLater(function() {
            standingsList.contentY = Math.min(standingsList.keepY, Math.max(0, standingsList.contentHeight - standingsList.height))
            standingsList.restoring = false
          })
        }

        delegate: Item {
          id: srow
          readonly property bool isDiv: modelData.kind === "zone"
          readonly property var t: modelData.team

          width: standingsList.width
          height: isDiv ? Style.space(36) : Style.space(30)

          // Qualification zone header, with the column labels on its right.
          Item {
            visible: srow.isDiv
            anchors.fill: parent

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(5)
              textFormat: Text.PlainText
              text: srow.isDiv ? modelData.label.toUpperCase() : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
            }
            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(5)
              spacing: Style.space(6)

              Repeater {
                model: root.statColumns
                Text {
                  width: Style.space(modelData.w)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }
            }
          }

          // Team
          Item {
            visible: !srow.isDiv
            anchors.fill: parent

            // Rank, with the colour of its qualification zone as a thin bar.
            Rectangle {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(3)
              height: parent.height - Style.space(10)
              radius: 1.5
              color: srow.isDiv || !srow.t.color ? "transparent" : srow.t.color
            }
            Text {
              id: rankText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: srow.isDiv ? "" : srow.t.rank
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Image {
              id: teamLogo
              anchors.left: parent.left
              anchors.leftMargin: Style.space(48)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: Style.space(22)
              source: srow.isDiv ? "" : (srow.t.logo || "")
              visible: status === Image.Ready
              asynchronous: true
              cache: true
              fillMode: Image.PreserveAspectFit
              sourceSize.width: Style.space(44)
              sourceSize.height: Style.space(44)
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(78)
              anchors.right: statRow.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: srow.isDiv ? "" : srow.t.name
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Row {
              id: statRow
              anchors.right: parent.right
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Repeater {
                model: root.statColumns
                Text {
                  width: Style.space(modelData.w)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: srow.isDiv ? "" : (srow.t[modelData.key] || "")
                  // Points are the headline figure; the rest recede.
                  color: modelData.key === "pts" ? root.fg : Qt.darker(root.fg, 1.25)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: modelData.key === "pts"
                }
              }
            }

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(16)
              anchors.rightMargin: Style.space(16)
              height: 1
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: standingsList.count === 0
          textFormat: Text.PlainText
          text: root.errorMessage !== "" ? root.errorMessage : "Loading…"
          color: root.errorMessage !== "" ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }
      }

      // ---- knockout bracket ----------------------------------------------------------
      Bracket {
        id: bracketView
        visible: root.bracketMode
        anchors.top: headerRule.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        layout: root.bracket
        foreground: root.fg
        fontFamily: root.fontFamily
        loading: root.archiveLoading && root.errorMessage === ""
        clickable: root.shownSeason === root.seasonYear
        onTieClicked: function(tie) { root.openTie(tie) }
      }

      // ---- footer: key hints --------------------------------------------------------
      Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(26)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.manualRefresh ? "Refreshing…"
            : root.errorMessage !== "" && root.activeRowCount > 0
            ? "Offline — showing last " + (root.standingsMode ? "standings" : root.bracketMode ? "bracket" : "scores")
            : root.standingsMode ? "s scores   b bracket   r refresh   esc close"
            : root.bracketMode ? "←/→ season   s standings   b scores   r refresh   esc close"
            : "←/→ round   s standings   b bracket   t this round   r refresh   esc close"
          color: root.manualRefresh ? root.fg
            : root.errorMessage !== "" && root.activeRowCount > 0 ? Color.urgent : Qt.darker(root.fg, 1.8)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Small square chevron button for the header.
  component NavButton: Rectangle {
    id: nav
    property string glyph: ""
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    signal clicked()

    width: Style.space(30)
    height: Style.space(30)
    radius: Math.min(4, Style.cornerRadius)
    opacity: enabled ? 1 : 0.3
    color: enabled && navArea.containsMouse ? Style.hoverFillFor(nav.foreground, Color.accent) : "transparent"

    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -Style.space(2)
      textFormat: Text.PlainText
      text: nav.glyph
      color: nav.foreground
      font.family: nav.fontFamily
      font.pixelSize: Style.font.display
    }
    MouseArea {
      id: navArea
      anchors.fill: parent
      enabled: nav.enabled
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: nav.clicked()
    }
  }
}
