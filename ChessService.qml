/*
 ChessService.qml — all networking, caching and polling for the panel.

 Mental model for contributors:
   Panel.qml owns the settings (usernames); this Item owns the DATA.
   It exposes parsed payloads (chessComData / lichessData) that the UI
   binds to directly. There are no signals consumers must listen to.

 Request strategy:
   * HTTP runs through curl subprocesses (house pattern — gives us
     --max-time timeouts and a proper User-Agent; lichess 404s requests
     without one, chess.com rate-limits aggressively).
   * Each site is a STRICTLY SERIAL chain of stages. Lichess: profile →
     games → current-game → tournaments. Chess.com: stats → monthly game
     archives → profile. Parallel calls trip 429s on both platforms.
     Each stage advances via liAdvance()/startNextCcArchive(); the
     StdioCollector's onStreamFinished normally drives progression and
     Process.onExited is only a fallback (collector vs exit ordering is
     not guaranteed — see the _ccGamesHandled/_liProcHandled guards).
   * A failed round sets a 2-minute backoff per site so we never hammer
     a rate-limited or offline API from the refresh timer.

 Caching:
   Every finished round is written to ~/.cache/omarchy-chess/<site>.json.
   The cache is loaded at startup so the panel renders instantly, offline
   included. cachedPayload() rejects caches belonging to another username,
   and finish*() never lets a failed round wipe previously-good games.

 All timestamps inside payloads are epoch milliseconds.
*/

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/ChessDotCom.js" as ChessComLib
import "lib/LichessApi.js" as LichessApi

/*
 Network + cache layer for the chess panel. All I/O is non-blocking:
 curl subprocesses for HTTP (house pattern, gives us --max-time and a
 proper User-Agent), FileView for the on-disk last-good payload.

 Consumers bind to chessComData / lichessData and get change notification
 via the *Updated signals. Data always renders from cache first; fetches
 only happen when panelVisible is true.
*/
Item {
  id: root


  property string chessComUser: ""
  property string lichessUser: ""
  property int refreshSecs: 60
  property bool panelVisible: false

  /*
   Parsed payloads: null until first load. Shape:
     chessComData: { fetchedAt, user, ratings:{bullet,blitz,rapid,tactics,fide}, games:[...] }
     lichessData:  { fetchedAt, user, profile:{...}, games:[...] }
  */
  property var chessComData: null
  property var lichessData: null
  property bool busyChessCom: false
  property bool busyLichess: false
  property string chessComError: ""
  property string lichessError: ""

  readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/omarchy-chess"
  readonly property string userAgent: "oma-chess-plugin/0.1 (omarchy quickshell plugin)"

  Timer {
    id: livePollTimer
    interval: 30000
    repeat: true
    running: root.livePollEnabled && root.lichessUser.trim() !== ""
    onTriggered: root.pollCurrentGame()
  }

  function pollCurrentGame() {
    var user = root.lichessUser.trim()
    if (user === "") return
    liLiveProc.command = [
      "curl", "-fsS", "--max-time", "8",
      "-A", root.userAgent,
      "-H", "Accept: application/x-ndjson",
      LichessApi.currentGameUrl(user)
    ]
    liLiveProc.running = true
  }

  Process {
    id: liLiveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lichessCurrentGame = LichessApi.parseCurrentGame(String(text || ""))
    }
    onExited: function(code) { if (code !== 0) root.lichessCurrentGame = null }
  }

  Component.onCompleted: {
    ensureDirsProc.running = true
    ccCacheFile.reload()
    liCacheFile.reload()
  }

  onChessComUserChanged: {
    root.chessComData = null
    root.chessComError = ""
    ccCacheFile.reload()
    Qt.callLater(function() { if (root.panelVisible) refreshChessCom() })
  }

  onLichessUserChanged: {
    root.lichessData = null
    root.lichessError = ""
    liCacheFile.reload()
    Qt.callLater(function() { if (root.panelVisible) refreshLichess() })
  }

  /*
   Background refresh only while the user can see the panel — hidden
   panels must not generate traffic (marketplace rule: be gentle).
  */
  Timer {
    id: refreshTimer
    interval: Math.max(15, root.refreshSecs) * 1000
    repeat: true
    running: root.panelVisible && (root.chessComUser !== "" || root.lichessUser !== "")
    onTriggered: root.refreshIfStale()
  }

  /*
   A payload older than refreshSecs needs refetching. Failed rounds carry
   their predecessor's fetchedAt forward, so "stale" keeps meaning
   "the user has not seen fresh data yet" rather than "we tried recently".
  */
  function isStale(data) {
    return !data || !data.fetchedAt || (Date.now() - data.fetchedAt) > Math.max(15, root.refreshSecs) * 1000
  }

  function refreshIfStale() {
    if (root.chessComUser !== "" && root.isStale(root.chessComData)) refreshChessCom()
    if (root.lichessUser !== "" && root.isStale(root.lichessData)) refreshLichess()
  }

  /* ---- chess.com ------------------------------------------------------ */

  property var _ccPartial: null
  property var _ccArchiveQueue: []
  property bool _ccGamesHandled: false
  property bool _ccStatsDone: false
  property bool _ccProcHandled: false

  /*
   Backoff: after a failed fetch, skip auto-refresh for this long so a
   rate-limited or offline API isn't hammered every refresh tick.
  */
  property date ccBackoffUntil: new Date(0)
  property date liBackoffUntil: new Date(0)
  readonly property int backoffMs: 120000

  /*
   Opt-in background poll of the current-game endpoint so the bar icon can
   glow while a game is live, even with the panel closed.
  */
  property bool livePollEnabled: false
  property var lichessCurrentGame: null
  property var lichessTournaments: null
  property date liTournamentsFetchedAt: new Date(0)
  readonly property int tournamentsRefreshMs: 600000

  function refreshChessCom() {
    if (Date.now() < root.ccBackoffUntil.getTime()) return
    var user = root.chessComUser.trim().toLowerCase()
    if (user === "") return

    root.busyChessCom = true
    root.chessComError = ""
    root._ccPartial = { user: user, ratings: null, games: [], profile: null }
    root._ccArchiveQueue = ChessComLib.recentArchives(Date.now())
    root._ccStatsDone = false

    chessComStatsProc.command = [
      "curl", "-fsS", "--max-time", "8", "-A", root.userAgent,
      ChessComLib.statsUrl(user)
    ]
    chessComStatsProc.running = true
    /*
     Archives chain after stats completes; chess.com also asks for
     serialized requests.
    */
  }

  function beginCcStage() {
    root._ccProcHandled = false
  }

  function startNextCcArchive() {
    if (!root._ccPartial) return
    /* Monthly archive bodies look like {"games":[...]} — NOT bare arrays. */
    if (root._ccArchiveQueue.length === 0) {
      startCcProfile()
      return
    }
    var next = root._ccArchiveQueue.shift()
    root._ccGamesHandled = false
    chessComGamesProc.command = [
      "curl", "-fsS", "--max-time", "12", "-A", root.userAgent,
      ChessComLib.archiveUrl(root._ccPartial.user, next.year, next.month)
    ]
    chessComGamesProc.running = true
  }

  function startCcProfile() {
    if (!root._ccPartial) return
    beginCcStage("profile")
    ccProfileProc.command = [
      "curl", "-fsS", "--max-time", "8", "-A", root.userAgent,
      ChessComLib.profileUrl(root._ccPartial.user)
    ]
    ccProfileProc.running = true
  }

  function finishChessCom() {
    if (!root._ccPartial) return
    /*
     The username may have changed while this round was in flight — its
     results belong to whoever is configured now, not who started it.
    */
    if (root._ccPartial.user !== root.chessComUser.trim().toLowerCase()) return
    var payload = {
      fetchedAt: Date.now(),
      user: root._ccPartial.user,
      ratings: root._ccPartial.ratings || ChessComLib.parseStats(null),
      games: root._ccPartial.games || [],
      profile: root._ccPartial.profile
    }

    /* A round where the archives failed must not wipe previously good games. */
    var prev = root.chessComData
    if (payload.games.length === 0 && prev && prev.games && prev.games.length > 0)
      payload.games = prev.games

    var hasRatings = payload.ratings && (payload.ratings.blitz || payload.ratings.bullet || payload.ratings.rapid)
    var meaningful = hasRatings || payload.games.length > 0
    if (!meaningful && prev && prev.fetchedAt) {
      /*
       Nothing new arrived: carry the old timestamp forward so isStale()
       keeps returning true and the next open retries.
      */
      payload.fetchedAt = prev.fetchedAt
    }

    root.chessComData = payload
    root.busyChessCom = false
    if (meaningful) {
      root.ccBackoffUntil = new Date(0)
    } else {
      /* Everything failed this round — back off before trying again. */
      root.ccBackoffUntil = new Date(Date.now() + root.backoffMs)
    }
    writeCache(ccCacheFile, payload)
  }

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", root.cacheDir]
  }

  Process {
    id: chessComStatsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!root._ccPartial || root._ccStatsDone) return
        root._ccStatsDone = true
        if (raw) {
          try {
            root._ccPartial.ratings = ChessComLib.parseStats(JSON.parse(raw))
          } catch (e) {
          }
        }
        root.startNextCcArchive()
      }
    }
    onExited: function(code) {
      if (code !== 0) root.chessComError = "stats unavailable"
      /* Advance the chain even when the collector never fired. */
      if (root._ccPartial && !root._ccStatsDone) {
        root._ccStatsDone = true
        root.startNextCcArchive()
      }
    }
  }

  Process {
    id: chessComGamesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root._ccPartial || root._ccGamesHandled) return
        root._ccGamesHandled = true
        var raw = String(text || "").trim()
        if (raw) {
          try {
            /* Archive body shape: {"games":[ ... ]} */
            var body = JSON.parse(raw)
            var monthGames = ChessComLib.parseGames(body.games || [], root._ccPartial.user, 25)
            var merged = monthGames.concat(root._ccPartial.games)
            var seen = {}
            var deduped = []
            for (var i = 0; i < merged.length; i++) {
              var key = merged[i].url || (merged[i].opponent + merged[i].endedAt)
              if (seen[key]) continue
              seen[key] = true
              deduped.push(merged[i])
            }
            root._ccPartial.games = deduped.slice(0, 10)
          } catch (e) {
          }
        }
        /* Enough games already — skip the older month(s). */
        if (root._ccPartial.games.length >= 10) root._ccArchiveQueue = []
        /* A missing/failed month must not stall the queue. */
        startNextCcArchive()
      }
    }
  }

  Process {
    id: ccProfileProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root._ccPartial || root._ccProcHandled) return
        root._ccProcHandled = true
        var raw = String(text || "").trim()
        if (raw) {
          try {
            root._ccPartial.profile = ChessComLib.parseProfile(JSON.parse(raw))
          } catch (e) {
            /* Profile is optional decoration; stats and games carry the tab. */
          }
        }
        finishChessCom()
      }
    }
    onExited: function(code) {
      if (!root._ccProcHandled && code !== 0) {
        root._ccProcHandled = true
        finishChessCom()
      }
    }
  }

  /* ---- lichess -------------------------------------------------------- */

  property var _liPartial: null
  property bool _liProfileDone: false
  property bool _liGamesDone: false

  function refreshLichess() {
    if (Date.now() < root.liBackoffUntil.getTime()) return
    var user = root.lichessUser.trim()
    if (user === "") return

    root.busyLichess = true
    root.lichessError = ""
    root._liPartial = { user: user.toLowerCase(), profile: null, games: [] }

    /*
     Strictly serialized chain — lichess trips 429 on parallel calls:
     profile -> games -> current-game -> tournaments (only when stale).
    */
    beginLiStage("profile")
    lichessProfileProc.command = [
      "curl", "-fsS", "--max-time", "8",
      "-A", root.userAgent,
      "-H", "Accept: application/json",
      LichessApi.userUrl(user)
    ]
    lichessProfileProc.running = true
  }

  property string _liStage: ""
  property bool _liProcHandled: false

  function beginLiStage(stage) {
    root._liStage = stage
    root._liProcHandled = false
  }

  function liAdvance() {
    if (!root._liPartial) return
    if (root._liStage === "profile") { startLichessGames(); return }
    if (root._liStage === "games") { startLichessCurrent(); return }
    if (root._liStage === "current") {
      if (isStaleTournaments()) startLichessTournaments()
      else finishLichess()
      return
    }
    finishLichess()
  }

  function isStaleTournaments() {
    return (Date.now() - root.liTournamentsFetchedAt.getTime()) > root.tournamentsRefreshMs
  }

  function startLichessGames() {
    if (!root._liPartial) return
    beginLiStage("games")
    lichessGamesProc.command = [
      "curl", "-fsS", "--max-time", "8",
      "-A", root.userAgent,
      "-H", "Accept: application/x-ndjson",
      LichessApi.gamesUrl(root._liPartial.user, 10)
    ]
    lichessGamesProc.running = true
  }

  function startLichessCurrent() {
    if (!root._liPartial) return
    beginLiStage("current")
    lichessCurrentProc.command = [
      "curl", "-fsS", "--max-time", "8",
      "-A", root.userAgent,
      "-H", "Accept: application/x-ndjson",
      LichessApi.currentGameUrl(root._liPartial.user)
    ]
    lichessCurrentProc.running = true
  }

  function startLichessTournaments() {
    beginLiStage("tournaments")
    lichessTourneysProc.command = [
      "curl", "-fsS", "--max-time", "10",
      "-A", root.userAgent,
      LichessApi.tournamentsUrl()
    ]
    lichessTourneysProc.running = true
  }

  function finishLichess() {
    if (!root._liPartial) return
    if (root._liPartial.user !== root.lichessUser.trim().toLowerCase()) return
    var payload = {
      fetchedAt: Date.now(),
      user: root._liPartial.user,
      profile: root._liPartial.profile,
      games: root._liPartial.games || [],
      currentGame: root.lichessCurrentGame,
      tournaments: root.lichessTournaments
    }

    /*
     The games export endpoint rate-limits hardest — never let a failed
     games fetch wipe previously good games.
    */
    var prev = root.lichessData
    if (payload.games.length === 0 && prev && prev.games && prev.games.length > 0)
      payload.games = prev.games

    var meaningful = payload.profile !== null || payload.games.length > 0
    if (!meaningful && prev && prev.fetchedAt) {
      payload.fetchedAt = prev.fetchedAt
    }

    root.lichessData = payload
    root.busyLichess = false
    if (payload.profile) {
      root.liBackoffUntil = new Date(0)
    } else {
      /* Rate-limited or offline — back off before trying again. */
      root.liBackoffUntil = new Date(Date.now() + root.backoffMs)
    }
    writeCache(liCacheFile, payload)
  }

  Process {
    id: lichessProfileProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root._liPartial || root._liProcHandled) return
        root._liProcHandled = true
        var raw = String(text || "").trim()
        if (raw) {
          try {
            root._liPartial.profile = LichessApi.parseProfile(JSON.parse(raw))
          } catch (e) {
          }
        } else {
          root.lichessError = "profile unavailable"
        }
        root.liAdvance()
      }
    }
    onExited: function(code) {
      /* Fallback for the rare case the collector never fires. */
      if (!root._liProcHandled && code !== 0) {
        root._liProcHandled = true
        root.lichessError = "profile unavailable"
        root.liAdvance()
      }
    }
  }

  Process {
    id: lichessGamesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root._liPartial || root._liProcHandled) return
        root._liProcHandled = true
        var raw = String(text || "").trim()
        /* curl -f gives us an empty body on HTTP errors (404/429). */
        if (!raw) root.lichessError = "games unavailable"
        root._liPartial.games = LichessApi.parseGamesNdjson(raw, root._liPartial.user, 10)
        root.liAdvance()
      }
    }
    onExited: function(code) {
      if (!root._liProcHandled && code !== 0) {
        root._liProcHandled = true
        root.lichessError = "games unavailable"
        root.liAdvance()
      }
    }
  }

  Process {
    id: lichessCurrentProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root._liPartial || root._liProcHandled) return
        root._liProcHandled = true
        root.lichessCurrentGame = LichessApi.parseCurrentGame(String(text || ""))
        root.liAdvance()
      }
    }
    onExited: function(code) {
      if (!root._liProcHandled && code !== 0) {
        root._liProcHandled = true
        root.lichessCurrentGame = null
        root.liAdvance()
      }
    }
  }

  Process {
    id: lichessTourneysProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root._liPartial || root._liProcHandled) return
        root._liProcHandled = true
        var raw = String(text || "").trim()
        if (raw) {
          try {
            root.lichessTournaments = LichessApi.parseUpcomingTournaments(JSON.parse(raw), Date.now(), 48 * 3600 * 1000)
            root.liTournamentsFetchedAt = new Date()
          } catch (e) {
            /* Tournaments are optional; keep whatever we had. */
          }
        }
        root.liAdvance()
      }
    }
    onExited: function(code) {
      if (!root._liProcHandled && code !== 0) {
        root._liProcHandled = true
        root.liAdvance()
      }
    }
  }

  /* ---- disk cache ----------------------------------------------------- */

  function writeCache(file, payload) {
    try {
      file.setText(JSON.stringify(payload))
    } catch (e) {
      /* Cache write failure is never fatal. */
    }
  }

  function cachedPayload(text, expectedUser) {
    var raw = String(text || "").trim()
    if (!raw) return null
    try {
      var parsed = JSON.parse(raw)
      /* No user configured -> nothing to show. */
      if (expectedUser === "") return null
      /* Cache from a different username than the configured one is stale. */
      if (parsed && parsed.user && String(parsed.user).toLowerCase() !== expectedUser.toLowerCase())
        return null
      return parsed && parsed.fetchedAt ? parsed : null
    } catch (e) {
      return null
    }
  }

  /*
   Disk cache. setText() writes atomically; reload() + onLoaded seeds
   in-memory data before the first fetch completes.
  */
  FileView {
    id: ccCacheFile
    path: root.cacheDir + "/chesscom.json"
    atomicWrites: true
    printErrors: false
    watchChanges: false
    onLoaded: {
      var cached = root.cachedPayload(text(), root.chessComUser)
      if (cached && !root.chessComData) root.chessComData = cached
    }
    onLoadFailed: { /* no cache yet */ }
  }

  FileView {
    id: liCacheFile
    path: root.cacheDir + "/lichess.json"
    atomicWrites: true
    printErrors: false
    watchChanges: false
    onLoaded: {
      var cached = root.cachedPayload(text(), root.lichessUser)
      if (cached && !root.lichessData) root.lichessData = cached
    }
    onLoadFailed: { /* no cache yet */ }
  }
}
