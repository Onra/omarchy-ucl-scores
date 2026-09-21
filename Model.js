.pragma library

// Pure helpers for the Champions League panel: ESPN scoreboard parsing, round
// grouping and formatting. No QML types in here so it stays easy to test with
// plain JS.

var BASE = "https://site.api.espn.com/apis/site/v2/sports/soccer/uefa.champions/scoreboard"
var STANDINGS_URL = "https://site.api.espn.com/apis/v2/sports/soccer/uefa.champions/standings"

var DAY_MS = 24 * 60 * 60 * 1000
var GAP_MS = 3 * DAY_MS          // a longer silence between kickoffs starts a new round
var LENGTH_MS = 3 * 60 * 60 * 1000  // kickoff to final whistle, with extra time to spare
var RECENT_MS = 3 * DAY_MS       // a finished round stays "current" for this long

var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// ESPN's season.slug per phase. ESPN has no matchday numbers, so rounds are
// rebuilt from the kickoff dates (see buildRounds).
var PHASES = {
  "league-phase": { name: "Matchday", section: "League Phase", abbr: "MD", numbered: true },
  "knockout-round-playoffs": { name: "Knockout Playoffs", section: "Knockout Phase", abbr: "PO", legs: true },
  "round-of-16": { name: "Round of 16", section: "Knockout Phase", abbr: "R16", legs: true },
  "quarterfinals": { name: "Quarter-finals", section: "Knockout Phase", abbr: "QF", legs: true },
  "semifinals": { name: "Semi-finals", section: "Knockout Phase", abbr: "SF", legs: true },
  "final": { name: "Final", section: "Final", abbr: "FIN" }
}

function pad2(n) { return (n < 10 ? "0" : "") + n }

// The competition year of a season starts in July: on 21 Sep 2026 that is the
// 2026-27 season, which ESPN files under year 2026.
function seasonYearFor(ms) {
  var d = new Date(ms)
  return d.getMonth() >= 6 ? d.getFullYear() : d.getFullYear() - 1
}

function seasonLabel(year) { return year + "/" + pad2((year + 1) % 100) }

// One request returns a whole calendar year (up to ~190 games), which is how
// every round of a season that spans New Year is found.
function yearUrl(year) { return BASE + "?dates=" + year + "&limit=500" }

// ESPN days are UTC-based, and Champions League games never straddle midnight
// UTC, so the UTC date of "now" is the day to ask for.
function dayUrl(ms) {
  var d = new Date(ms)
  return BASE + "?dates=" + d.getUTCFullYear() + pad2(d.getUTCMonth() + 1) + pad2(d.getUTCDate()) + "&limit=100"
}

function standingsUrl() { return STANDINGS_URL }

// Season of a year request url (yearUrl), so a fetch answer can be filed.
function yearOfUrl(url) {
  var m = /[?&]dates=(\d{4})(?:&|$)/.exec(url || "")
  return m ? parseInt(m[1]) : 0
}

function scoreOf(v) {
  var n = parseInt(v)
  return isNaN(n) ? -1 : n
}

function numText(v) {
  if (v === undefined || v === null || v === "") return ""
  var n = parseInt(v)
  return isNaN(n) ? "" : String(n)
}

function parseTeam(c) {
  var t = c.team || {}
  return {
    id: t.id || "",
    abbr: t.abbreviation || "TBD",
    name: t.shortDisplayName || t.displayName || "TBD",
    fullName: t.displayName || "",
    aliases: [t.shortDisplayName, t.displayName, t.name, t.location],
    logo: t.logo || "",
    score: c.score === undefined || c.score === "" ? "" : String(c.score),
    pens: numText(c.shootoutScore),
    agg: numText(c.aggregateScore),
    advance: c.advance === true,
    won: false
  }
}

function parseGame(e) {
  var comp = (e.competitions && e.competitions[0]) || {}
  var st = e.status || comp.status || {}
  var type = st.type || {}
  var away = null, home = null
  var cs = comp.competitors || []
  for (var i = 0; i < cs.length; i++) {
    if (cs[i].homeAway === "home") home = parseTeam(cs[i])
    else away = parseTeam(cs[i])
  }
  var blank = { id: "", abbr: "TBD", name: "TBD", fullName: "", aliases: [], logo: "", score: "", pens: "", agg: "", advance: false, won: false }
  home = home || blank
  away = away || blank
  var state = type.state || "pre"    // pre | in | post

  // The result of the match itself. ESPN's own "winner" flag follows the tie
  // (who advances), which for a second leg is not who won the match.
  if (state === "post") {
    var hs = scoreOf(home.score), as = scoreOf(away.score)
    if (hs >= 0 && as >= 0) {
      if (hs !== as) { home.won = hs > as; away.won = as > hs }
      else {
        var hp = scoreOf(home.pens), ap = scoreOf(away.pens)
        if (hp >= 0 && ap >= 0 && hp !== ap) { home.won = hp > ap; away.won = ap > hp }
      }
    }
  }

  // Second legs: the aggregate score of the tie so far.
  var note = ""
  if (state !== "pre" && home.agg !== "" && away.agg !== "") note = "Agg " + home.agg + "-" + away.agg

  var venue = comp.venue || {}
  var city = venue.address && venue.address.city ? venue.address.city : ""
  return {
    id: e.id,
    date: Date.parse(e.date) || 0,
    timeValid: comp.timeValid !== false,
    slug: (e.season && e.season.slug) || "",
    seasonYear: e.season && e.season.year ? e.season.year : 0,
    state: state,
    statusName: type.name || "",
    detail: type.shortDetail || "",
    away: away,
    home: home,
    decided: home.won || away.won,
    note: note,
    city: city,
    venue: venue.fullName || ""
  }
}

// Games of one scoreboard response that belong to the given season. A calendar
// year mixes two seasons (Jan-May of the old one, Aug-Dec of the new one).
function parseEvents(json, seasonYear) {
  var events = (json && json.events) || []
  var out = []
  for (var i = 0; i < events.length; i++) {
    var g = parseGame(events[i])
    if (g.seasonYear === seasonYear) out.push(g)
  }
  return out
}

// ---- rounds ------------------------------------------------------------------------
//
// ESPN lists games by phase but has no matchday or leg number. Games of one
// phase are grouped by their kickoff dates: matchdays and legs are a few days
// wide, and days apart from each other. Returns, oldest first:
//   { key, slug, index, count, label, section, abbr, start, end, games }
function buildRounds(gamesById) {
  var all = []
  for (var id in gamesById) all.push(gamesById[id])
  all.sort(function(a, b) { return a.date - b.date })

  var order = []
  var bySlug = {}
  for (var i = 0; i < all.length; i++) {
    var g = all[i]
    var clusters = bySlug[g.slug]
    if (!clusters) { clusters = bySlug[g.slug] = []; order.push(g.slug) }
    var last = clusters.length ? clusters[clusters.length - 1] : null
    if (last && g.date - last[last.length - 1].date <= GAP_MS) last.push(g)
    else clusters.push([g])
  }

  var rounds = []
  for (var s = 0; s < order.length; s++) {
    var slug = order[s]
    var list = bySlug[slug]
    var p = PHASES[slug] || {
      name: slug ? slug.replace(/-/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase() }) : "Round",
      section: "Champions League",
      abbr: (slug || "UCL").replace(/-/g, "").substring(0, 3).toUpperCase()
    }
    for (var k = 0; k < list.length; k++) {
      var games = list[k]
      var n = k + 1
      var label = p.name, abbr = p.abbr
      if (p.numbered) { label = p.name + " " + n; abbr = p.abbr + n }
      else if (p.legs && list.length === 2) {
        label = p.name + " · " + (n === 1 ? "1st Leg" : "2nd Leg")
        abbr = p.abbr + "·" + n
      }
      rounds.push({
        key: slug + "-" + n,
        slug: slug,
        index: n,
        count: list.length,
        label: label,
        section: p.section,
        abbr: abbr,
        start: games[0].date,
        end: games[games.length - 1].date + LENGTH_MS,
        games: games
      })
    }
  }
  rounds.sort(function(a, b) { return a.start - b.start })
  return rounds
}

// The round the panel opens on: the first one that is not long over, moved on
// to a later round once that one is about to start. Between two matchdays weeks
// apart this means the results stay up for a few days, then the next fixtures.
function currentIndex(rounds, now) {
  if (!rounds || rounds.length === 0) return -1
  var i = 0
  while (i < rounds.length && rounds[i].end + RECENT_MS <= now) i++
  if (i >= rounds.length) return rounds.length - 1
  while (i + 1 < rounds.length && rounds[i + 1].start - 6 * 60 * 60 * 1000 <= now) i++
  return i
}

function indexOfKey(rounds, key) {
  for (var i = 0; i < (rounds || []).length; i++)
    if (rounds[i].key === key) return i
  return -1
}

function liveCount(gamesById) {
  var n = 0
  for (var id in gamesById) if (gamesById[id].state === "in") n++
  return n
}

// ---- formatting --------------------------------------------------------------------

function clock(ms) {
  var d = new Date(ms)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function dayLabel(ms) {
  var d = new Date(ms)
  return DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]
}

function dayKey(ms) {
  var d = new Date(ms)
  return d.getFullYear() * 10000 + d.getMonth() * 100 + d.getDate()
}

// Status column text: local kickoff time, live minute, or the final line (FT, AET).
function statusText(g) {
  if (g.state === "pre") {
    if (g.statusName !== "STATUS_SCHEDULED") return g.detail
    return g.timeValid ? clock(g.date) : "TBD"
  }
  return g.detail
}

// Games grouped by local calendar day, in kickoff order:
// [{ label, games: [...] }, ...]
function groupByDay(games) {
  var groups = []
  var last = null
  for (var i = 0; i < (games || []).length; i++) {
    var g = games[i]
    var k = g.timeValid ? dayKey(g.date) : -1
    if (!last || last.k !== k) {
      last = { k: k, label: g.timeValid ? dayLabel(g.date) : "Date TBD", games: [] }
      groups.push(last)
    }
    last.games.push(g)
  }
  return groups
}

// Flatten groups into one list of delegates: day headers interleaved with
// games, which is what a ListView wants.
function rows(games) {
  var out = []
  var groups = groupByDay(games)
  for (var i = 0; i < groups.length; i++) {
    out.push({ kind: "day", label: groups[i].label })
    for (var j = 0; j < groups[i].games.length; j++)
      out.push({ kind: "game", game: groups[i].games[j] })
  }
  return out
}

// "13 Oct – 14 Oct" span of the games shown, for the header subtitle.
function rangeLabel(games) {
  if (!games || games.length === 0) return ""
  var first = games[0], last = games[games.length - 1]
  if (!first.timeValid) return ""
  var a = new Date(first.date), b = new Date(last.date)
  var fa = a.getDate() + " " + MONTHS[a.getMonth()]
  var fb = b.getDate() + " " + MONTHS[b.getMonth()]
  return fa === fb ? fa : fa + " – " + fb
}

// ---- recaps ------------------------------------------------------------------------

function recapTeam(t) {
  return { name: t.fullName || t.name, aliases: t.aliases }
}

// Entries for recap.py: finished games with both teams known.
function recapEntries(games, seasonYear) {
  var out = []
  for (var i = 0; i < (games || []).length; i++) {
    var g = games[i]
    if (g.state !== "post" || !g.home.fullName || !g.away.fullName) continue
    out.push({
      id: g.id, date: g.date, season: seasonLabel(seasonYear),
      home: recapTeam(g.home), away: recapTeam(g.away),
      homeScore: scoreOf(g.home.score), awayScore: scoreOf(g.away.score)
    })
  }
  return out
}

// Fallback for games without an official video: YouTube's own results page.
function searchUrl(g, seasonYear) {
  var q = g.home.name + " " + g.away.name + " highlights Champions League " + seasonLabel(seasonYear)
  return "https://www.youtube.com/results?search_query=" + encodeURIComponent(q)
}

// ---- standings ---------------------------------------------------------------------

function statValue(stats, name) {
  for (var i = 0; i < (stats || []).length; i++)
    if (stats[i].name === name) return stats[i].displayValue !== undefined ? String(stats[i].displayValue) : ""
  return ""
}

// Flat delegate list for the league phase table: a header row for each
// qualification zone (round of 16, seeded playoffs, unseeded playoffs,
// eliminated) followed by its teams in rank order.
//   { kind: "zone", label: "Qualifies for round of 16" }
//   { kind: "team", team: { rank, name, logo, color, p, w, d, l, gd, pts } }
function parseStandings(json) {
  var out = []
  var groups = (json && json.children) || []
  var entries = groups.length && groups[0].standings ? (groups[0].standings.entries || []) : []
  var teams = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var st = e.stats || []
    var logos = (e.team && e.team.logos) || []
    var rank = parseInt(statValue(st, "rank"))
    teams.push({
      zone: e.note && e.note.description ? e.note.description : "",
      team: {
        rank: isNaN(rank) ? i + 1 : rank,
        name: (e.team && (e.team.shortDisplayName || e.team.displayName)) || "TBD",
        logo: logos.length ? logos[0].href : "",
        color: e.note && e.note.color ? e.note.color : "",
        p: statValue(st, "gamesPlayed"),
        w: statValue(st, "wins"),
        d: statValue(st, "ties"),
        l: statValue(st, "losses"),
        gd: statValue(st, "pointDifferential"),
        pts: statValue(st, "points")
      }
    })
  }
  teams.sort(function(a, b) { return a.team.rank - b.team.rank })
  var zone = null
  for (var j = 0; j < teams.length; j++) {
    if (teams[j].zone !== zone) {
      zone = teams[j].zone
      out.push({ kind: "zone", label: zone || "League phase" })
    }
    out.push({ kind: "team", team: teams[j].team })
  }
  var season = json && json.season ? json.season : null
  return {
    label: season && season.displayName ? season.displayName.replace(/\s*UEFA Champions League/, "") : "",
    rows: out
  }
}


// ---- knockout bracket ----------------------------------------------------------------
//
// The bracket is the classic mirrored tree: the knockout playoffs, the round of
// 16, the quarter-finals and the semi-finals on each side, and the final in the
// middle. Everything below is in layout units; the panel multiplies by
// Style.space(1).

var KNOCKOUT = ["knockout-round-playoffs", "round-of-16", "quarterfinals", "semifinals", "final"]
var FIRST_BRACKET_SEASON = 2024   // the league phase format, and so this bracket, starts in 2024-25

var CARD_W = 84
var CARD_H = 62
var COL_GAP = 34
var ROW = 100                       // vertical pitch of the four rows on each side
var LINE = 2

function firstBracketSeason() { return FIRST_BRACKET_SEASON }

function sortByKickoff(a, b) {
  return (a.legs[0].date - b.legs[0].date) || (a.legs[0].id < b.legs[0].id ? -1 : 1)
}

// One tie per pair of teams and phase: its legs, the aggregate score, and who
// went through. Teams are in the order of the first leg (home team first),
// which is how the classic bracket lists them.
//   { key, slug, a, b, winnerId, state, live, gameIds }
//   a / b: { id, abbr, name, logo, score, pens }   state: pre | part | in | post
function buildTies(gamesById) {
  var byKey = {}
  var list = []
  for (var id in gamesById) {
    var g = gamesById[id]
    if (KNOCKOUT.indexOf(g.slug) < 0 || !g.home.id || !g.away.id) continue
    var key = g.slug + ":" + (g.home.id < g.away.id ? g.home.id + "-" + g.away.id : g.away.id + "-" + g.home.id)
    var t = byKey[key]
    if (!t) { t = byKey[key] = { key: key, slug: g.slug, legs: [] }; list.push(t) }
    t.legs.push(g)
  }
  for (var i = 0; i < list.length; i++) finishTie(list[i])
  return list
}

// ESPN's abbreviations are American-style for some clubs (Bayern is "MUN",
// Man City "MNC"). The bracket uses the codes that UEFA and the fans use.
var BADGE = {
  "132": "FCB", "2980": "BOD", "10414": "QRB", "174": "ASM", "382": "MCI", "360": "MUN", "437": "POR",
  "1929": "BEN", "521": "SLO", "175": "LEN", "166": "LIL", "176": "OM", "104": "ROM", "2572": "COM",
  "125": "SGE", "909": "FCK", "494": "SLA", "124": "BVB", "134": "STU", "570": "CLB", "1068": "ATM"
}

function tieTeam(t) {
  return { id: t.id, abbr: BADGE[t.id] || t.abbr, name: t.name, logo: t.logo, score: 0, pens: "" }
}

function finishTie(t) {
  t.legs.sort(function(x, y) { return x.date - y.date })
  var first = t.legs[0]
  t.a = tieTeam(first.home)
  t.b = tieTeam(first.away)
  var played = 0, post = 0, live = false
  t.gameIds = []
  for (var i = 0; i < t.legs.length; i++) {
    var g = t.legs[i]
    t.gameIds.push(g.id)
    if (g.state === "pre") continue
    played++
    if (g.state === "post") post++
    if (g.state === "in") live = true
    var hs = Math.max(0, scoreOf(g.home.score)), as = Math.max(0, scoreOf(g.away.score))
    if (g.home.id === t.a.id) { t.a.score += hs; t.b.score += as }
    else { t.a.score += as; t.b.score += hs }
  }
  var last = t.legs[t.legs.length - 1]
  if (last.state === "post") {
    var ap = scoreOf(last.home.id === t.a.id ? last.home.pens : last.away.pens)
    var bp = scoreOf(last.home.id === t.a.id ? last.away.pens : last.home.pens)
    if (ap >= 0 && bp >= 0) { t.a.pens = String(ap); t.b.pens = String(bp) }
  }
  var complete = post === t.legs.length && (t.legs.length >= 2 || t.slug === "final")
  t.live = live
  t.state = complete ? "post" : live ? "in" : played > 0 ? "part" : "pre"
  t.winnerId = ""
  if (complete) {
    // ESPN flags who advances on the last leg; the score decides the rest.
    var winner = ""
    var ac = [last.home, last.away]
    for (var k = 0; k < ac.length; k++) if (ac[k].advance) winner = ac[k].id
    if (!winner) {
      if (t.a.score !== t.b.score) winner = t.a.score > t.b.score ? t.a.id : t.b.id
      else if (t.a.pens !== "" && t.a.pens !== t.b.pens) winner = parseInt(t.a.pens) > parseInt(t.b.pens) ? t.a.id : t.b.id
    }
    t.winnerId = winner
  }
}

function feeds(child, parent) {
  return !!child && !!parent && child.winnerId !== "" && (parent.a.id === child.winnerId || parent.b.id === child.winnerId)
}

// Put the ties of one round into the slots below their parent ties, so that
// every tie sits next to the tie it came from. Ties that cannot be linked yet
// (their opponent is not decided) take the slots that are left.
function fillSlots(slots, pool, parents, per) {
  pool = pool.slice()
  for (var p = 0; p < parents.length; p++) {
    if (!parents[p]) continue
    // The tie that feeds the first-listed team of the parent goes on top.
    var wanted = [parents[p].a.id, parents[p].b.id]
    var n = 0
    for (var w = 0; w < wanted.length && n < per; w++) {
      for (var i = 0; i < pool.length; i++) {
        if (pool[i].winnerId === wanted[w]) {
          slots[p * per + n] = pool[i]
          pool.splice(i, 1)
          n++
          break
        }
      }
    }
  }
  for (var s = 0; s < slots.length && pool.length > 0; s++)
    if (!slots[s]) slots[s] = pool.shift()
}

function emptySlots(n) {
  var a = []
  for (var i = 0; i < n; i++) a.push(null)
  return a
}

// Cards and connector lines of the bracket of one season.
//   cards: { key, x, y, w, h, tie|null, final }     lines: { x, y, w, h, hot }
//   champion: the team that won the final, or null
function layoutBracket(gamesById) {
  var ties = buildTies(gamesById)
  var by = { "knockout-round-playoffs": [], "round-of-16": [], "quarterfinals": [], "semifinals": [], "final": [] }
  for (var i = 0; i < ties.length; i++) by[ties[i].slug].push(ties[i])
  for (var k in by) by[k].sort(sortByKickoff)

  var fin = by["final"][0] || null
  var sf = emptySlots(2), qf = emptySlots(4), r16 = emptySlots(8), po = emptySlots(8)

  // Semi-finals: the finalist listed first comes from the left half.
  var sfPool = by["semifinals"].slice()
  if (fin) {
    var left = -1
    for (var j = 0; j < sfPool.length; j++) if (feeds(sfPool[j], fin) && sfPool[j].winnerId === fin.a.id) left = j
    if (left >= 0) sf[0] = sfPool.splice(left, 1)[0]
  }
  for (var s = 0; s < 2 && sfPool.length > 0; s++) if (!sf[s]) sf[s] = sfPool.shift()

  fillSlots(qf, by["quarterfinals"], sf, 2)
  fillSlots(r16, by["round-of-16"], qf, 2)
  fillSlots(po, by["knockout-round-playoffs"], r16, 1)

  var pitch = CARD_W + COL_GAP
  var cards = []
  var lines = []
  var champion = null
  if (fin && fin.winnerId) champion = fin.winnerId === fin.a.id ? fin.a : fin.b

  function card(tie, level, slot, half, cy, x) {
    var c = { key: level + "-" + slot, x: x, y: cy - CARD_H / 2, w: CARD_W, h: CARD_H, tie: tie, final: level === "final" }
    cards.push(c)
    return c
  }
  // Column of a level on the left (half 0) or the right (half 1) of the final.
  function colX(level, half) { return (half === 0 ? level : 8 - level) * pitch }

  var cPO = [], cR = [], cQ = [], cS = []
  for (var r = 0; r < 8; r++) {
    var half = r < 4 ? 0 : 1
    var cy = ((r % 4) + 0.5) * ROW
    cPO.push(card(po[r], "po", r, half, cy, colX(0, half)))
    cR.push(card(r16[r], "r16", r, half, cy, colX(1, half)))
  }
  for (var q = 0; q < 4; q++) {
    var qh = q < 2 ? 0 : 1
    cQ.push(card(qf[q], "qf", q, qh, (2 * (q % 2) + 1) * ROW, colX(2, qh)))
  }
  for (var f = 0; f < 2; f++) cS.push(card(sf[f], "sf", f, f, 2 * ROW, colX(3, f)))
  var cF = card(fin, "final", 0, 0, 2 * ROW, 4 * pitch)

  function link(child, parent) {
    if (!child.tie || !parent.tie || !feeds(child.tie, parent.tie)) return
    var hot = champion !== null && child.tie.winnerId === champion.id
    var childLeft = child.x < parent.x
    var x1 = childLeft ? child.x + CARD_W : child.x
    var x2 = childLeft ? parent.x : parent.x + CARD_W
    var y1 = child.y + CARD_H / 2, y2 = parent.y + CARD_H / 2
    var mid = (x1 + x2) / 2
    lines.push({ x: Math.min(x1, mid), y: y1 - LINE / 2, w: Math.abs(mid - x1), h: LINE, hot: hot })
    if (y1 !== y2)
      lines.push({ x: mid - LINE / 2, y: Math.min(y1, y2) - LINE / 2, w: LINE, h: Math.abs(y2 - y1) + LINE, hot: hot })
    lines.push({ x: Math.min(mid, x2), y: y2 - LINE / 2, w: Math.abs(x2 - mid), h: LINE, hot: hot })
  }
  for (var a = 0; a < 8; a++) { link(cPO[a], cR[a]); link(cR[a], cQ[a >> 1]) }
  for (var b = 0; b < 4; b++) link(cQ[b], cS[b >> 1])
  link(cS[0], cF)
  link(cS[1], cF)

  return {
    cards: cards,
    lines: lines,
    champion: champion,
    final: fin,
    width: 8 * pitch + CARD_W,
    height: 4 * ROW,
    centerX: 4 * pitch + CARD_W / 2,
    finalBottom: 2 * ROW + CARD_H / 2,
    hasTies: ties.length > 0
  }
}

// The round of the scores view that holds a game, "" when there is none.
function roundKeyOfGame(rounds, gameId) {
  for (var i = 0; i < (rounds || []).length; i++)
    for (var j = 0; j < rounds[i].games.length; j++)
      if (rounds[i].games[j].id === gameId) return rounds[i].key
  return ""
}
