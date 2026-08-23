/*
 LichessApi.js — pure parsing/URL helpers for the public lichess API.

 NO I/O here; ChessService.qml owns requests. Docs: https://lichess.org/api
 Gotchas contributors should know:
   * lichess BLOCKS unknown User-Agents on some endpoints (games export
     returns 404, tournaments 429) — requests must send a custom UA.
   * Only ONE request at a time; parallel calls trip 429. That is why the
     service serialises its whole chain through this module's endpoints.
   * /api/games/user returns NDJSON (one JSON object per line), not an
     array — parseGamesNdjson tolerates blank/corrupt lines.
   * /api/tournament field names differ from most of the API: the display
     name is `fullName`, ratings info lives under `perf.name`, and clock
     data is `clock.limit`/`clock.increment` (seconds).
   * `prog` in perfs is the rating change over the last ~12 hours (the
     ▲/▼ arrows); `prov: true` marks provisional (shown with "?").
*/

/*
 Pure parsing/URL helpers for the public lichess API. No I/O here.
 Docs: https://lichess.org/api
*/

/*
 Free-text API fields (names, titles, tournament labels) are rendered by
 QML Text items. Strip markup, entities and control characters and cap
 length so a hostile payload can never smuggle rich text into the UI.
*/
function cleanText(value, max) {
  var s = String(value == null ? "" : value)
  s = s.replace(/<[^>]*>/g, " ").replace(/[&<>]/g, " ")
       .replace(/[\u0000-\u001f\u007f]/g, "")
  return s.trim().slice(0, max || 64)
}

function userUrl(user) {
  return "https://lichess.org/api/user/" + encodeURIComponent(user)
}

function gamesUrl(user, max) {
  return "https://lichess.org/api/games/user/" + encodeURIComponent(user) +
    "?max=" + max + "&moves=false&tags=false&clocks=false&evals=false&opening=false"
}

function currentGameUrl(user) {
  return "https://lichess.org/api/user/" + encodeURIComponent(user) + "/current-game"
}

function tournamentsUrl() {
  return "https://lichess.org/api/tournament"
}

var SPEED_LABELS = {
  ultraBullet: "½+0", bullet: "1 min", blitz: "3 min", rapid: "10 min",
  classical: "30 min", correspondence: "daily"
}

function parseProfile(raw) {
  if (!raw || typeof raw !== "object") return null
  var perfs = raw.perfs || {}
  function perf(name) {
    var p = perfs[name]
    if (!p || typeof p.rating !== "number") return null
    return { rating: p.rating, prog: Number(p.prog) || 0, games: Number(p.games) || 0, prov: p.prov === true }
  }
  var counts = raw.count || {}
  return {
    id: cleanText(raw.id, 32),
    name: cleanText(raw.username || raw.id || "", 64),
    title: raw.title ? cleanText(raw.title, 8) : "",
    online: raw.online === true,
    disabled: raw.disabled === true,
    seenAt: Number(raw.seenAt) || 0,
    playing: raw.playing ? String(raw.playing) : "",
    url: "https://lichess.org/@/" + encodeURIComponent(raw.username || raw.id || ""),
    ratings: {
      bullet: perf("bullet"),
      blitz: perf("blitz"),
      rapid: perf("rapid"),
      classical: perf("classical"),
      puzzle: perf("puzzle")
    },
    counts: {
      wins: Number(counts.win) || 0,
      losses: Number(counts.loss) || 0,
      draws: Number(counts.draw) || 0
    }
  }
}

/* NDJSON body → newest-first array of normalized games. */
function parseGamesNdjson(text, usernameLower, max) {
  var games = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length && games.length < max; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      var g = JSON.parse(line)
      var players = g.players || {}
      var white = players.white || {}
      var black = players.black || {}
      var whiteName = (white.user && white.user.name ? String(white.user.name) : "Anonymous").toLowerCase()
      var myColor = whiteName === usernameLower ? "white" : "black"
      var opp = myColor === "white" ? black : white
      var winner = g.winner // "white" | "black" | undefined (draw)

      var result = "D"
      if (winner) result = winner === myColor ? "W" : "L"

      var speed = String(g.speed || "")
      var clock = g.clock || {}
      var tcLabel = SPEED_LABELS[speed] || speed
      if (clock.initial) {
        tcLabel = Math.round(clock.initial / 60) + "+" + (clock.increment || 0)
      }

      games.push({
        result: result,
        opponent: opp.user && opp.user.name ? cleanText(opp.user.name, 64) : "Anonymous",
        opponentRating: Number(opp.rating) || 0,
        myRating: Number((myColor === "white" ? white : black).rating) || 0,
        timeControl: tcLabel,
        endedAt: Number(g.lastMoveAt || g.createdAt) || 0,
        rules: String(g.variant && g.variant.key === "standard" ? "chess" : (g.variant && g.variant.key) || "chess"),
        url: "https://lichess.org/" + String(g.id || "")
      })
    } catch (e) {
      /* Corrupt line: skip it. */
    }
  }
  return games
}

/* Single-object NDJSON (current-game) or "" when not playing. */
function parseCurrentGame(text) {
  var line = String(text || "").trim().split("\n")[0]
  if (!line) return null
  try {
    var g = JSON.parse(line)
    if (!g || !g.id) return null
    var clock = g.clock || {}
    return {
      id: String(g.id),
      url: "https://lichess.org/" + String(g.id),
      speed: String(g.speed || ""),
      timeControl: clock.initial ? Math.round(clock.initial / 60) + "+" + (clock.increment || 0) : "",
      fen: String(g.fen || "")
    }
  } catch (e) {
    return null
  }
}

/* /api/tournament → upcoming arenas within horizonMs, soonest first. */
function parseUpcomingTournaments(raw, now, horizonMs) {
  var out = []
  if (!raw || typeof raw !== "object") return out
  var groups = ["created", "started"]
  for (var gi = 0; gi < groups.length; gi++) {
    var list = raw[groups[gi]]
    if (!list || !list.length) continue
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (!t || !t.startsAt || !t.id) continue
      var startsAt = Number(t.startsAt) || 0
      if (startsAt - now > horizonMs) continue
      var clock = t.clock || {}
      var perfName = t.perf && t.perf.name ? cleanText(t.perf.name, 32) : ""
      out.push({
        id: String(t.id),
        name: cleanText(t.fullName || t.name || t.id, 80),
        perf: perfName,
        status: String(t.status || groups[gi]),
        startsAt: startsAt,
        minutes: Number(t.minutes) || 0,
        timeControl: clock.limit > 0 ? Math.round(clock.limit / 60) + "+" + (Number(clock.increment) || 0) : "",
        nbPlayers: Number(t.nbPlayers) || 0,
        url: "https://lichess.org/tournament/" + String(t.id),
        live: groups[gi] === "started"
      })
    }
  }
  out.sort(function(a, b) { return a.startsAt - b.startsAt })
  return out.slice(0, 15)
}
