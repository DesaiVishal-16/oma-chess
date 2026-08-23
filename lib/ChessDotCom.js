/*
 ChessDotCom.js — pure parsing/URL helpers for the public chess.com API.

 NO I/O happens here: every function takes already-fetched JSON (or plain
 values) and returns plain JS objects. This keeps the network logic in
 ChessService.qml testable and the parsers swappable.

 API docs: https://www.chess.com/news/view/published-data-api
 Gotchas contributors should know:
   * chess.com requires a descriptive User-Agent or it serves 403s.
   * Usernames in URLs are case-insensitive but the API 404s some
     mixed-case spellings — ChessService lowercases before calling.
   * Monthly archive bodies are {"games":[ ... ]}, not bare arrays.
   * Result codes: "win" means we won; a fixed set of draw codes exists
     (see DRAW_RESULTS); everything else counts as a loss.
*/

/*
 Pure parsing/URL helpers for the public chess.com API. No I/O here.
 Docs: https://www.chess.com/news/view/published-data-api
*/

function statsUrl(user) {
  return "https://api.chess.com/pub/player/" + encodeURIComponent(user) + "/stats"
}

function profileUrl(user) {
  return "https://api.chess.com/pub/player/" + encodeURIComponent(user)
}

/*
 Player profile: display name, avatar, country, last online. FIDE lives in
 the stats response too, but keep it here as a fallback.
*/
function parseProfile(raw) {
  if (!raw || typeof raw !== "object") return null
  return {
    name: String(raw.name || raw.username || ""),
    username: String(raw.username || ""),
    avatar: raw.avatar ? String(raw.avatar) : "",
    url: raw.url ? String(raw.url) : "",
    countryCode: raw.country ? String(raw.country).split("/").pop() : "",
    lastOnline: Number(raw.last_online) * 1000 || 0,
    fide: Number(raw.fide) || null
  }
}

function archiveUrl(user, year, month) {
  var m = month < 10 ? "0" + month : "" + month
  return "https://api.chess.com/pub/player/" + encodeURIComponent(user) + "/games/" + year + "/" + m
}

/*
 Newest-first list of the current and previous monthly archives. Monthly
 files can be large, so we never walk further back than two months.
*/
function recentArchives(now) {
  var months = []
  var d = new Date(now)
  months.push({ year: d.getFullYear(), month: d.getMonth() + 1 })
  var prev = new Date(d.getFullYear(), d.getMonth() - 1, 1)
  months.push({ year: prev.getFullYear(), month: prev.getMonth() + 1 })
  return months
}

var DRAW_RESULTS = [
  "agreed", "repetition", "stalemate", "insufficient",
  "50move", "timevsinsufficient"
]

function resultFor(myColor, whiteResult, blackResult) {
  var mine = myColor === "white" ? whiteResult : blackResult
  var r = String(mine || "")
  if (r === "win") return "W"
  if (DRAW_RESULTS.indexOf(r) !== -1) return "D"
  return "L"
}

/* time_control is "600", "600+5", "-1" (unlimited) or "1/259200" (daily). */
function formatTimeControl(tc) {
  var s = String(tc || "")
  if (s === "" || s === "-1") return "unlimited"
  if (s.indexOf("1/") === 0) return Math.round(parseInt(s.slice(2), 10) / 86400) + "d"
  var parts = s.split("+")
  var secs = parseInt(parts[0], 10)
  if (isNaN(secs)) return s
  var mins = secs / 60
  var label = mins >= 60 ? (mins / 60 % 1 === 0 ? mins / 60 + "h" : mins + "m") : mins + " min"
  if (parts.length > 1 && parseInt(parts[1], 10) > 0) label += "+" + parts[1]
  return label
}

function parseStats(raw) {
  var out = { bullet: null, blitz: null, rapid: null, daily: null, tactics: null, fide: null }
  if (!raw || typeof raw !== "object") return out

  var speeds = ["bullet", "blitz", "rapid", "daily"]
  for (var i = 0; i < speeds.length; i++) {
    var speed = speeds[i]
    var block = raw["chess_" + speed]
    if (!block || !block.last) continue
    var rec = block.record || {}
    out[speed] = {
      rating: Number(block.last.rating) || 0,
      wins: Number(rec.win) || 0,
      losses: Number(rec.loss) || 0,
      draws: Number(rec.draw) || 0
    }
  }

  if (raw.tactics && raw.tactics.highest)
    out.tactics = Number(raw.tactics.highest.rating) || null
  if (raw.fide)
    out.fide = Number(raw.fide) || null

  return out
}

/*
 rawArray is the JSON body of a monthly archive endpoint; userLower must be
 the lowercase chess.com username. Returns newest-first, capped to max.
*/
function parseGames(rawArray, userLower, max) {
  var games = []
  if (!rawArray || !rawArray.length) return games

  for (var i = rawArray.length - 1; i >= 0 && games.length < max; i--) {
    try {
      var g = rawArray[i]
      if (!g || !g.white || !g.black) continue

      var myColor = String(g.white.username || "").toLowerCase() === userLower ? "white" : "black"
      var me = myColor === "white" ? g.white : g.black
      var opp = myColor === "white" ? g.black : g.white
      /* Skip games where the opponent row has no username (e.g. deleted bots). */
      if (!opp.username) continue

      games.push({
        result: resultFor(myColor, g.white.result, g.black.result),
        opponent: String(opp.username),
        opponentRating: Number(opp.rating) || 0,
        myRating: Number(me.rating) || 0,
        timeControl: formatTimeControl(g.time_control),
        endedAt: Number(g.end_time) * 1000,
        rules: String(g.rules || "chess"),
        url: String(g.url || "")
      })
    } catch (e) {
      /* Corrupt row: skip it, keep the rest. */
    }
  }
  return games
}
