/* Panel.qml — the popup UI for oma-chess.

 Everything the user sees lives here: account management, per-site stats,
 ratings rows, recent games, tournaments and the FIND OPPONENT action.

 How it works:
   * DATA comes from the ChessService instance below (`service`); this file
     only reads its parsed payloads and never touches the network itself.
   * SETTINGS live inline in ~/.config/omarchy/shell.json under this
     widget's bar-layout entry. Read via setting(key, fallback); written
     ONLY through persistSettings(), which keeps hostWidget/bar in sync —
     writing shell.json directly will be overwritten by the shell.
   * ACCOUNT MODEL: a site is "active" when toggled on AND has a username.
     Only active accounts get tabs, fetch traffic and data on screen.
   * SUB-VIEWS: `subView` switches between "" (main), "tournaments".
     `tourneySite` remembers which platform's tournament page to show.
   * LAYOUT GOTCHA: Repeater is NOT a visual item — `visible:` on it does
     nothing, gate its MODEL instead (see the games list). And never put
     anchors.fill children first inside a Row; use anchored Item layouts
   like the game-row delegate does.

*/
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "oma.chess"
  ipcTarget: "oma.chess"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  /*
   ---- Account model ----------------------------------------------------
   Each site can be enabled, disabled, added or removed independently at any
   time. An account is "active" when its toggle is on AND a username is set;
   only active accounts get tabs and fetch traffic.
  */

  readonly property string chessComUserName: String(setting("chessComUser", "") || "").trim()
  readonly property string lichessUserName: String(setting("lichessUser", "") || "").trim()
  readonly property bool chessComOn: setting("chessComOn", root.chessComUserName !== "") === true
  readonly property bool lichessOn: setting("lichessOn", root.lichessUserName !== "") === true

  readonly property bool chessComActive: root.chessComOn && root.chessComUserName !== ""
  readonly property bool lichessActive: root.lichessOn && root.lichessUserName !== ""

  readonly property var allSites: [
    { site: "chesscom", label: "CHESS.COM", on: root.chessComOn, user: root.chessComUserName },
    { site: "lichess", label: "LICHESS", on: root.lichessOn, user: root.lichessUserName }
  ]
  readonly property var activeAccounts: root.allSites.filter(function(a) { return a.on && a.user !== "" })

  property int activeTabIndex: 0
  readonly property string currentSite: {
    if (root.activeAccounts.length === 0) return ""
    var i = Math.min(Math.max(root.activeTabIndex, 0), root.activeAccounts.length - 1)
    return root.activeAccounts[i].site
  }
  readonly property string currentUser: root.currentSite === "chesscom" ? root.chessComUserName : root.lichessUserName

  property bool editingUsers: false
  property string subView: ""
  property string tourneySite: ""

  function openTournaments(site) {
    root.tourneySite = site
    root.subView = "tournaments"
  }
  property bool editingCcOn: false
  property bool editingLiOn: false
  /*
   Live references to the account editor's TextFields, registered by each
   row's Component.onCompleted. Needed because commitUsers() runs on root
   and cannot see ids declared inside Repeater delegates. Keyed by site.
  */
  property var rowFields: ({})

  readonly property bool liveIndicatorEnabled: setting("liveIndicator", false) === true
  readonly property bool lichessPlaying: service.lichessCurrentGame !== null

  onLichessPlayingChanged: {
    if (root.hostWidget && "setLiveGame" in root.hostWidget)
      root.hostWidget.setLiveGame(root.lichessPlaying && root.liveIndicatorEnabled)
  }

  ChessService {
    id: service
    chessComUser: root.chessComActive ? root.chessComUserName : ""
    lichessUser: root.lichessActive ? root.lichessUserName : ""
    panelVisible: root.opened
    livePollEnabled: root.liveIndicatorEnabled
  }

  function siteData(site) { return site === "chesscom" ? service.chessComData : service.lichessData }
  function siteBusy(site) { return site === "chesscom" ? service.busyChessCom : service.busyLichess }
  function siteError(site) { return site === "chesscom" ? service.chessComError : service.lichessError }

  function hiddenCats() {
    var h = setting("hiddenCats", [])
    return Array.isArray(h) ? h : []
  }

  function catKey(site, label) { return site + ":" + String(label).toLowerCase() }

  function isCatHidden(site, label) {
    return root.hiddenCats().indexOf(root.catKey(site, label)) !== -1
  }

  function toggleCat(site, label) {
    var k = root.catKey(site, label)
    var h = root.hiddenCats().slice()
    var i = h.indexOf(k)
    if (i === -1) h.push(k)
    else h.splice(i, 1)
    root.persistSettings({ hiddenCats: h })
  }

  function hiddenLabelsFor(site) {
    return root.hiddenCats()
      .filter(function(k) { return k.indexOf(site + ":") === 0 })
      .map(function(k) {
        var label = k.slice(site.length + 1)
        return label.charAt(0).toUpperCase() + label.slice(1)
      })
  }

  function ccProfile() {
    var d = service.chessComData
    return d ? (d.profile || null) : null
  }

  function chessComRatings() {
    var d = service.chessComData
    if (!d || !d.ratings) return []
    var r = d.ratings
    var out = []
    var speeds = [["bullet", "Bullet"], ["blitz", "Blitz"], ["rapid", "Rapid"], ["daily", "Daily"]]
    for (var i = 0; i < speeds.length; i++) {
      var p = r[speeds[i][0]]
      if (p && p.rating) {
        out.push({
          label: speeds[i][1],
          rating: p.rating,
          record: p.wins + p.losses + p.draws > 0
            ? "W " + p.wins + " · L " + p.losses + " · D " + p.draws
            : ""
        })
      }
    }
    if (r.tactics) out.push({ label: "Puzzles", rating: r.tactics, record: "" })
    if (r.fide) out.push({ label: "FIDE", rating: r.fide, record: "" })
    if (d.profile && !r.fide && d.profile.fide) out.push({ label: "FIDE", rating: d.profile.fide, record: "" })
    return out.filter(function(c) { return !root.isCatHidden("chesscom", c.label) })
  }

  function gamesForCurrent() {
    var data = siteData(root.currentSite)
    return data ? (data.games || []) : []
  }

  function timeAgo(ms) {
    if (!ms) return ""
    var mins = Math.floor((Date.now() - ms) / 60000)
    if (mins < 1) return "just now"
    if (mins < 60) return mins + "m ago"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + "h ago"
    return Math.floor(hours / 24) + "d ago"
  }

  readonly property string statusText: {
    if (root.currentSite === "") return ""
    if (siteBusy(root.currentSite)) return "Updating…"
    var err = siteError(root.currentSite)
    if (err !== "" && siteData(root.currentSite)) return "Offline — showing last update"
    return err
  }

  function lichessProfile() {
    var d = service.lichessData
    return d ? d.profile : null
  }

  function tournaments() {
    var d = service.lichessData
    return d && d.tournaments ? d.tournaments : []
  }

  function lichessRatings() {
    var prof = lichessProfile()
    if (!prof || !prof.ratings) return []
    var defs = [["bullet", "Bullet"], ["blitz", "Blitz"], ["rapid", "Rapid"], ["classical", "Classical"], ["puzzle", "Puzzles"]]
    var out = []
    for (var i = 0; i < defs.length; i++) {
      var p = prof.ratings[defs[i][0]]
      if (p) out.push({ label: defs[i][1], rating: p.rating, prog: p.prog, prov: p.prov })
    }
    return out.filter(function(c) { return !root.isCatHidden("lichess", c.label) })
  }

  function timeUntil(ms) {
    var diff = ms - Date.now()
    if (diff <= 0) return "live now"
    var mins = Math.floor(diff / 60000)
    if (mins < 60) return "in " + mins + "m"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return "in " + hours + "h " + (mins % 60) + "m"
    return "in " + Math.floor(hours / 24) + "d"
  }


  /*
   ---- Desktop app detection ----------------------------------------------
   Per-site: find .desktop entries whose Exec launches that site (e.g.
   Omarchy web apps "Chess" -> chess.com, "Lichess" -> lichess.org), plus
   native chess GUIs as a generic fallback. Values are desktop ids, "" if none.
  */

  Component.onCompleted: detectChessApps()

  function detectChessApps() {
    appDetectProc.running = true
  }

  Process {
    id: appDetectProc
    command: ["bash", "-c",
      'for f in /usr/share/applications/*.desktop "$HOME"/.local/share/applications/*.desktop /var/lib/flatpak/exports/share/applications/*.desktop "$HOME"/.local/share/flatpak/exports/share/applications/*.desktop; do ' +
      '  [ -f "$f" ] || continue; ' +
      '  id=$(basename "$f" .desktop); ' +
      '  ex=$(grep -m1 "^Exec=" "$f"); ' +
      '  case "$ex" in *chess.com*) case "$ex" in *omarchy-launch-webapp*) echo "ccwa:$id";; *) echo "cc:$id";; esac;; esac; ' +
      '  case "$ex" in *lichess.org*) case "$ex" in *omarchy-launch-webapp*) echo "liwa:$id";; *) echo "li:$id";; esac;; esac; ' +
      'done; ' +
      'for f in /usr/share/applications/*.desktop "$HOME/.local/share/applications/*.desktop"; do ' +
      '  [ -f "$f" ] || continue; ' +
      '  id=$(basename "$f" .desktop); ' +
      '  case "$id" in en-croissant|chessx|banksia|scid|scidvspc|cutechess) echo "gui:$id";; esac; ' +
      'done']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n").filter(function(l) { return l !== "" })
        function safeId(v) {
          v = String(v || "").trim()
          return /^[A-Za-z0-9._-]+$/.test(v) ? v : ""
        }
        var cc = "", li = "", gui = ""
        var ccWebapp = false, liWebapp = false
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split(":")
          if (parts[0] === "cc" && !cc) { cc = safeId(parts.slice(1).join(":")); ccWebapp = false }
          else if (parts[0] === "ccwa" && (!cc || !ccWebapp)) { cc = safeId(parts.slice(1).join(":")); ccWebapp = true }
          else if (parts[0] === "li" && !li) { li = safeId(parts.slice(1).join(":")); liWebapp = false }
          else if (parts[0] === "liwa" && (!li || !liWebapp)) { li = safeId(parts.slice(1).join(":")); liWebapp = true }
          else if (parts[0] === "gui" && !gui) gui = safeId(parts[1])
        }
        root.ccDesktopId = cc
        root.ccAppTakesUrl = ccWebapp
        root.liDesktopId = li
        root.liAppTakesUrl = liWebapp
        root.guiDesktopId = gui
      }
    }
  }

  property string ccDesktopId: ""
  property bool ccAppTakesUrl: false
  property string liDesktopId: ""
  property bool liAppTakesUrl: false
  property string guiDesktopId: ""

  function appIdForCurrentSite() {
    if (root.currentSite === "chesscom") return root.ccDesktopId
    if (root.currentSite === "lichess") return root.liDesktopId
    return root.guiDesktopId
  }



  /*
   SECURITY: Remote APIs supply the game/tournament URLs we open, so treat them as
   untrusted: only https links on a known allow-list of hosts ever launch.
  */
  function isTrustedUrl(url) {
    if (typeof url !== "string") return false
    try {
      var u = new URL(url)
      if (u.protocol !== "https:") return false
      var host = u.hostname.toLowerCase()
      return host === "chess.com" || host.endsWith(".chess.com") ||
             host === "lichess.org" || host.endsWith(".lichess.org")
    } catch (e) {
      return false
    }
  }

  property date lastLaunch: new Date(0)

  function launch(url) {
    if (!root.isTrustedUrl(url)) return
    if (Date.now() - root.lastLaunch.getTime() < 1500) return
    root.lastLaunch = new Date()
    Quickshell.execDetached(["xdg-open", url])
    root.close()
  }

  function launch2(argv) {
    for (var i = 0; i < argv.length; i++) {
      if (typeof argv[i] === "string" && argv[i].indexOf("http") === 0 && !root.isTrustedUrl(argv[i]))
        return
    }
    if (Date.now() - root.lastLaunch.getTime() < 1500) return
    root.lastLaunch = new Date()
    Quickshell.execDetached(argv)
    root.close()
  }

  function openGameUrl(site, url) {
    if (site === "lichess") return root.openLichessUrl(url)
    if (root.ccDesktopId !== "" && root.ccAppTakesUrl)
      return root.launch2(["omarchy-launch-webapp", url])
    root.launch(url)
  }

  function openLichessUrl(url) {
    if (root.liDesktopId !== "" && root.liAppTakesUrl)
      return root.launch2(["omarchy-launch-webapp", url])
    root.launch(url)
  }

  /*
   One-click matchmaking: open whichever site is active in its installed
   app (or its site page as fallback). Neither platform exposes a public
   deep-link that pre-selects a time control.
  */
  function findOpponent() {
    var appId = root.appIdForCurrentSite()
    if (appId !== "") return root.launch2(["gtk-launch", appId])
    if (root.currentSite === "chesscom") return root.launch("https://www.chess.com/play/online")
    if (root.currentSite === "lichess") return root.launch("https://lichess.org")
    root.launch("https://www.chess.com")
  }

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  /* Theme darkness derived from the background's perceived luminance */
  readonly property bool darkTheme: {
    var c = Color.background
    return (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) < 0.5
  }
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  /* ---- Lifecycle -------------------------------------------------------- */

  function open() {
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) {
        setCenterHoverRevealSuppressed(true)
        service.refreshIfStale()
      }
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingUsers) root.cancelEditingUsers()
    root.subView = ""
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  /*
   The ONLY way settings are written. Updates this widget's inline entry in
   shell.json through the shell so all monitors and the config file agree.
   `values` is merged on top of current settings; pass only changed keys.
  */
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  /* ---- Account editing -------------------------------------------------- */

  /*
   Usernames must survive encodeURIComponent and both platforms' rules;
   empty string means "not configured" and always validates.
  */
  function validUsername(name) {
    return name === "" || /^[A-Za-z0-9_-]{2,25}$/.test(name)
  }

  /*
   Opens the editor. focusSite ("chesscom"/"lichess") pre-focuses that
   field — used by the welcome cards so clicking a card starts typing there.
  */
  function startEditingUsers(focusSite) {
    root.editingUsers = true
    root.editingCcOn = root.chessComOn
    root.editingLiOn = root.lichessOn
    Qt.callLater(function() {
      var ccField = root.rowFields["chesscom"]
      var liField = root.rowFields["lichess"]
      if (ccField) ccField.text = root.chessComUserName
      if (liField) liField.text = root.lichessUserName
      var focusField = focusSite === "lichess" ? liField : ccField
      if (focusField) {
        focusField.forceActiveFocus()
        focusField.selectAll()
      }
    })
  }

  /* Onboarding entry point: pick a site from the welcome cards. */
  function addAccount(site) {
    root.startEditingUsers(site)
    if (site === "chesscom") root.editingCcOn = true
    else root.editingLiOn = true
  }

  /*
   Toggling applies instantly — no save click needed. Enabling without a
   username persists the flag but the site stays inactive until one exists.
  */
  function setSiteEnabled(site, on) {
    if (site === "chesscom") {
      root.editingCcOn = on
      root.persistSettings({ chessComOn: on })
    } else {
      root.editingLiOn = on
      root.persistSettings({ lichessOn: on })
    }
  }

  function cancelEditingUsers() {
    root.editingUsers = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitUsers() {
    var ccField = root.rowFields["chesscom"]
    var liField = root.rowFields["lichess"]
    var chessCom = ccField ? ccField.text.trim() : ""
    var lichess = liField ? liField.text.trim() : ""
    if (!root.validUsername(chessCom) || !root.validUsername(lichess)) return
    root.persistSettings({
      chessComUser: chessCom,
      lichessUser: lichess,
      chessComOn: root.editingCcOn && chessCom !== "",
      lichessOn: root.editingLiOn && lichess !== ""
    })
    root.activeTabIndex = 0
    root.cancelEditingUsers()
  }

  function handleUserKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingUsers()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitUsers()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    /*
     fittedContent* clamps our preferred size to the screen — never set
     raw widths/heights on KeyboardPanel or popouts can overflow displays.
    */
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingUsers
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.activeAccounts.length > 1)
          root.activeTabIndex = (root.activeTabIndex + dx + root.activeAccounts.length) % root.activeAccounts.length
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(12)

        /* ---- Main view -------------------------------------------------- */
        Column {
          id: mainView
          visible: root.subView === ""
          width: parent.width
          spacing: Style.space(12)

        /* ---- Header row ------------------------------------------------- */
        Item {
          width: parent.width
          height: Math.max(headerText.implicitHeight, settingsButton.height)

          Item {
            id: headerButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: headerText.width + Style.space(12)
            height: Math.max(headerText.height, Style.space(24))

            Text {
              id: headerText
              anchors.centerIn: parent
              text: root.editingUsers ? "‹ BACK" : "OMA-CHESS"
              color: root.editingUsers || headerMouse.containsMouse
                ? Color.accent
                : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            MouseArea {
              id: headerMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: root.editingUsers ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: if (root.editingUsers) root.cancelEditingUsers()
            }
          }

          Rectangle {
            id: settingsButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: setLabel.width + Style.space(16)
            height: Style.space(24)
            radius: Style.cornerRadius
            color: settingsMouse.containsMouse || root.editingUsers
              ? Style.hoverFillFor(root.contentForeground, Color.accent)
              : "transparent"

            Text {
              id: setLabel
              anchors.centerIn: parent
              text: "⚙ ACCOUNTS"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            MouseArea {
              id: settingsMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.editingUsers) root.cancelEditingUsers()
                else root.startEditingUsers()
              }
            }

            PanelToolTip {
              visible: settingsMouse.containsMouse && !root.editingUsers
              text: "Add or remove accounts"
              fontFamily: root.contentFontFamily
            }
          }
        }

        /* ---- Tabs (only when 2+ active accounts) ------------------------ */
        Row {
          visible: root.activeAccounts.length > 1 && !root.editingUsers
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.activeAccounts

            Rectangle {
              required property var modelData
              required property int index

              width: (parent.width - Style.space(6)) / 2
              height: Style.space(28)
              radius: Style.cornerRadius
              color: root.currentSite === modelData.site
                ? Style.selectedStateColor(root.contentForeground, Color.accent)
                : tabMouse.containsMouse
                  ? Style.hoverFillFor(root.contentForeground, Color.accent)
                  : "transparent"

              Text {
                anchors.centerIn: parent
                text: modelData.label
                color: root.currentSite === modelData.site
                  ? Color.background
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: true
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.activeTabIndex = index
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.contentForeground
          opacity: 0.1
        }

        /* ---- Account manager -------------------------------------------- */
        Item {
          visible: root.editingUsers
          width: parent.width
          height: visible ? editColumn.implicitHeight : 0

          Column {
            id: editColumn
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: root.activeAccounts.length === 0 ? "Choose where you play" : "Your accounts"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Repeater {
              model: [
                { site: "chesscom", label: "CHESS.COM", on: root.editingCcOn },
                { site: "lichess", label: "LICHESS", on: root.editingLiOn }
              ]

              Item {
                required property var modelData
                width: parent.width
                height: Math.max(usernameField.height, Style.space(30))

                /* Toggle */
                Rectangle {
                  id: siteToggle
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(30)
                  height: Style.space(18)
                  radius: height / 2
                  color: modelData.on ? Color.accent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15)

                  Rectangle {
                    x: modelData.on ? parent.width - width - 2 : 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(14)
                    height: width
                    radius: width / 2
                    color: Color.background

                    Behavior on x { NumberAnimation { duration: 120 } }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setSiteEnabled(
                      modelData.site,
                      modelData.site === "chesscom" ? !root.editingCcOn : !root.editingLiOn)
                  }
                }

                /* Site label + status */
                Column {
                  anchors.left: siteToggle.right
                  anchors.leftMargin: Style.space(8)
                  width: Style.space(64)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    text: modelData.label
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }

                  Text {
                    text: {
                      var u = modelData.site === "chesscom" ? root.chessComUserName : root.lichessUserName
                      if (u === "") return "not added"
                      return modelData.on ? "enabled" : "disabled"
                    }
                    elide: Text.ElideRight
                    width: parent.width
                    color: Qt.darker(root.contentForeground, 1.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                TextField {
                  id: usernameField
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(106)
                  anchors.right: removeButton.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  property string site: modelData.site
                  placeholderText: "your username"
                  foreground: root.validUsername(text.trim()) ? root.contentForeground : "#f85149"
                  font.family: root.contentFontFamily

                  Keys.onPressed: function(event) {
                    var other = root.rowFields[modelData.site === "chesscom" ? "lichess" : "chesscom"]
                    root.handleUserKey(event, other)
                  }
                }

                /* X — clear/remove */
                Rectangle {
                  id: removeButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(26)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: removeHover.containsMouse ? "#f85149" : "transparent"

                  Text {
                    anchors.centerIn: parent
text: "✕"
                    color: removeHover.containsMouse ? Color.background : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  MouseArea {
                    id: removeHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: usernameField.text = ""
                  }

                  PanelToolTip {
                    visible: removeHover.containsMouse
                    text: "Remove"
                    fontFamily: root.contentFontFamily
                  }
                }

                /* OK — save */
                Rectangle {
                  id: okButton
                  anchors.right: removeButton.left
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(40)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: okHover.containsMouse ? "#3fb950" : "transparent"

                  Text {
                    anchors.centerIn: parent
text: "✓"
                    color: okHover.containsMouse ? Color.background : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  MouseArea {
                    id: okHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.commitUsers()
                  }

                  PanelToolTip {
                    visible: okHover.containsMouse
                    text: "Save"
                    fontFamily: root.contentFontFamily
                  }
                }

                Component.onCompleted: {
                  root.rowFields[modelData.site] = usernameField
                  usernameField.text = modelData.site === "chesscom" ? root.chessComUserName : root.lichessUserName
                }
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Toggle on/off · X removes · OK saves · Esc cancels"
              color: Qt.darker(root.contentForeground, 1.9)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        /* ---- Welcome chooser (no accounts yet, not editing) --------------- */
        Column {
          visible: !root.editingUsers && root.activeAccounts.length === 0
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Where do you play?"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: [
                { site: "chesscom", label: "CHESS.COM" },
                { site: "lichess", label: "LICHESS" }
              ]

              Rectangle {
                required property var modelData
                width: (parent.width - Style.space(8)) / 2
                height: Style.space(52)
                radius: Style.cornerRadius
                color: welcomeMouse.containsMouse
                  ? Style.hoverFillFor(root.contentForeground, Color.accent)
                  : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

                Column {
                  anchors.centerIn: parent
                  spacing: 2

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "♞"
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: 20
                  }

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: modelData.label
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }
                }

                MouseArea {
                  id: welcomeMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addAccount(modelData.site)
                }
              }
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Add the other anytime via ⚙ ACCOUNTS"
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        /* ---- Single-account label (one account: show which) -------------- */
        Text {
          visible: root.activeAccounts.length === 1 && !root.editingUsers
          text: root.activeAccounts.length === 1 ? root.activeAccounts[0].label + " · @" + root.currentUser : ""
          textFormat: Text.PlainText
          color: Qt.darker(root.contentForeground, 1.5)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
        }

        /* ---- Chess.com header card --------------------------------------- */
        Item {
          visible: root.currentSite === "chesscom" && !root.editingUsers && root.ccProfile() !== null
          width: parent.width
          height: visible ? ccHeader.implicitHeight : 0

          Row {
            id: ccHeader
            width: parent.width
            spacing: Style.space(10)

            Rectangle {
              width: Style.space(38)
              height: width
              radius: width / 2
              clip: true
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                anchors.centerIn: parent
                text: "♞"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 20
                visible: !ccAvatar.status || ccAvatar.status === Image.Null || ccAvatar.status === Image.Error
              }

              Image {
                id: ccAvatar
                anchors.fill: parent
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                visible: root.currentSite === "chesscom" && root.ccProfile() !== null && root.ccProfile().avatar !== ""
                source: visible ? root.ccProfile().avatar : ""
              }
            }

            Column {
              width: parent.width - Style.space(96)
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.ccProfile() ? (root.ccProfile().name !== "" ? root.ccProfile().name : "@" + root.currentUser) : ""
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Row {
                width: parent.width
                spacing: Style.space(5)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: "@" + root.currentUser
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: root.ccProfile() && root.ccProfile().lastOnline > 0 ? "· seen " + root.timeAgo(root.ccProfile().lastOnline) : ""
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.9)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        /* ---- Chess.com ratings (table rows) -------------------------------- */
        Column {
          visible: root.currentSite === "chesscom" && !root.editingUsers && root.chessComRatings().length > 0
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.chessComRatings()

            Rectangle {
              required property var modelData
              width: parent.width
              height: Style.space(36)
              radius: Style.cornerRadius
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)

              Column {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                  text: modelData.label.toUpperCase()
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                Text {
                  visible: modelData.record !== ""
                  text: modelData.record
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.7)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              HoverHandler { id: ccRowHover }

              Rectangle {
                visible: ccRowHover.hovered
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(20)
                height: Style.space(18)
                radius: Style.cornerRadius
                color: ccHideMouse.containsMouse ? "#f85149" : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.1)

                Text {
                  anchors.centerIn: parent
                  text: "✕"
                  color: ccHideMouse.containsMouse ? Color.background : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: ccHideMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleCat("chesscom", modelData.label)
                }
              }

              Text {
                id: ccRatingValue
                anchors.right: parent.right
                anchors.rightMargin: ccRowHover.hovered ? Style.space(38) : Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.rating)
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
          }
        }

        /* ---- Lichess header card ------------------------------------------ */
        Item {
          visible: root.currentSite === "lichess" && !root.editingUsers && root.lichessProfile() !== null
          width: parent.width
          height: visible ? lichessHeader.implicitHeight : 0

          Row {
            id: lichessHeader
            width: parent.width
            spacing: Style.space(10)

            Rectangle {
              width: Style.space(38)
              height: width
              radius: width / 2
              clip: true
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                anchors.centerIn: parent
                text: "♞"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 20
                visible: !avatar.status || avatar.status === Image.Null || avatar.status === Image.Error
              }

              Image {
                id: avatar
                anchors.fill: parent
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                visible: root.currentSite === "lichess" && root.currentUser !== ""
                source: visible ? "https://lichess.org/avatar/" + encodeURIComponent(root.currentUser) : ""
              }
            }

            Column {
              width: parent.width - Style.space(96)
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: (root.lichessProfile() && root.lichessProfile().title ? root.lichessProfile().title + " " : "") + (root.lichessProfile() ? root.lichessProfile().name : "")
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Row {
                spacing: Style.space(5)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  color: root.lichessProfile() && root.lichessProfile().online ? "#3fb950" : Qt.darker(root.contentForeground, 1.8)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.lichessProfile()
                    ? (root.lichessProfile().online
                        ? "Online"
                        : "Seen " + root.timeAgo(root.lichessProfile().seenAt))
                    : ""
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        /* ---- Lichess ratings (table rows) ----------------------------------- */
        Column {
          visible: root.currentSite === "lichess" && !root.editingUsers && root.lichessRatings().length > 0
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.lichessRatings()

            Rectangle {
              required property var modelData
              width: parent.width
              height: Style.space(36)
              radius: Style.cornerRadius
              color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label.toUpperCase() + (modelData.prov ? " ?" : "")
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              HoverHandler { id: liRowHover }

              Rectangle {
                visible: liRowHover.hovered
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(20)
                height: Style.space(18)
                radius: Style.cornerRadius
                color: liHideMouse.containsMouse ? "#f85149" : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.1)

                Text {
                  anchors.centerIn: parent
                  text: "✕"
                  color: liHideMouse.containsMouse ? Color.background : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: liHideMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleCat("lichess", modelData.label)
                }
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: visible ? Style.space(38) : Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(5)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: modelData.prog !== 0
                  text: modelData.prog > 0 ? "▲" : "▼"
                  color: modelData.prog > 0 ? "#3fb950" : "#f85149"
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(modelData.rating)
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
              }
            }
          }
        }

        /* ---- Hidden categories: click to show again ------------------------- */
        Flow {
          visible: !root.editingUsers && root.currentSite !== "" && root.hiddenLabelsFor(root.currentSite).length > 0
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.currentSite !== "" ? root.hiddenLabelsFor(root.currentSite) : []

            Rectangle {
              required property var modelData
              width: showLabel.implicitWidth + Style.space(18)
              height: Style.space(22)
              radius: height / 2
              color: showChipMouse.containsMouse
                ? Style.selectedStateColor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                id: showLabel
                anchors.centerIn: parent
                text: modelData + " +"
                color: showChipMouse.containsMouse ? Color.background : Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: showChipMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleCat(root.currentSite, modelData)
              }
            }
          }
        }

        /* ---- Status line ---------------------------------------------------- */
        Text {
          visible: !root.editingUsers && root.currentSite !== "" && root.statusText !== ""
          width: parent.width
          text: root.statusText
          textFormat: Text.PlainText
          color: root.statusText.indexOf("Offline") === 0 || root.statusText.indexOf("unavailable") !== -1
            ? "#f85149"
            : Qt.darker(root.contentForeground, 1.5)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        /* ---- Recent games ----------------------------------------------------- */
        Text {
          visible: root.currentSite !== "" && !root.editingUsers && root.gamesForCurrent().length > 0
          text: "RECENT GAMES"
          color: Qt.darker(root.contentForeground, 1.5)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
        }

        Repeater {
          model: !root.editingUsers && root.activeAccounts.length > 0 ? root.gamesForCurrent().slice(0, 2) : []

          Item {
            required property var modelData
            width: parent.width
            height: Style.space(44)

            Rectangle {
              id: gameResult
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: width
              radius: Style.cornerRadius
              /* Solid badge — black plate on dark themes, white on light */
              color: root.darkTheme ? "#101010" : "#ffffff"
              border.width: Style.spacing.hairline
              border.color: root.darkTheme ? "#555555" : "#aaaaaa"

              Text {
                anchors.centerIn: parent
                text: modelData.result
                color: modelData.result === "W"
                  ? "#3fb950"
                  : modelData.result === "L"
                    ? "#f85149"
                    : "#d29922"
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Item {
              anchors.left: gameResult.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(34)
              anchors.top: parent.top
              anchors.bottom: parent.bottom

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                spacing: 0

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  text: modelData.opponent + (modelData.opponentRating ? " (" + modelData.opponentRating + ")" : "")
                  textFormat: Text.PlainText
                  color: gameRowMouse.containsMouse ? Color.accent : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  text: modelData.timeControl + (modelData.endedAt ? " · " + root.timeAgo(modelData.endedAt) : "")
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }



              MouseArea {
                id: gameRowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openGameUrl(root.currentSite, modelData.url || "")
              }

              PanelToolTip {
                visible: gameRowMouse.containsMouse && !viewMouse.containsMouse
                text: "View game"
                fontFamily: root.contentFontFamily
              }
            }

          Rectangle {
            id: viewButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(26)
            height: Style.space(22)
            radius: Style.cornerRadius
            color: viewMouse.containsMouse ? Color.accent : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

            Text {
              anchors.centerIn: parent
              text: "👁"
              color: viewMouse.containsMouse ? Color.background : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: viewMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openGameUrl(root.currentSite, modelData.url || "")
            }
          }
          }
        }

        /* ---- Tournaments entry rows (lists live in their own tab) ------------ */
        Column {
          visible: root.activeAccounts.length > 0 && !root.editingUsers && root.subView === ""
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "TOURNAMENTS"
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          Repeater {
            model: root.activeAccounts.filter(function(a) { return a.site === root.currentSite })

            Rectangle {
              required property var modelData
              width: parent.width
              height: Style.space(34)
              radius: Style.cornerRadius
              color: tEntryMouse.containsMouse
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)

              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label + " TOURNAMENTS"
                  color: tEntryMouse.containsMouse ? Color.accent : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: "→"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: tEntryMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openTournaments(modelData.site)
              }
            }
          }
        }

        /* ---- Footer: play chips + open -------------------------------------- */
        Rectangle {
          visible: !root.editingUsers && root.activeAccounts.length > 0
          width: parent.width
          height: visible ? Style.space(32) : 0
          radius: Style.cornerRadius
          color: playMouse.containsMouse
            ? Style.selectedStateColor(root.contentForeground, Color.accent)
            : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

          Text {
            anchors.centerIn: parent
            text: "▶ FIND OPPONENT"
            color: playMouse.containsMouse ? Color.background : root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            font.letterSpacing: 1
          }

          MouseArea {
            id: playMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.findOpponent()
          }

          PanelToolTip {
            visible: playMouse.containsMouse
            text: "Opens " + (root.currentSite === "chesscom" ? "Chess.com" : "Lichess") + " · pick the time control there"
            fontFamily: root.contentFontFamily
          }
        }
        }

        /* ---- Tournaments sub-view ----------------------------------------- */
        Column {
          id: tourneyView
          visible: root.subView === "tournaments"
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            height: Math.max(tourneyTitle.height, tourneyBack.height)

            Text {
              id: tourneyTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.tourneySite === "chesscom" ? "Chess.com Tournaments" : "Lichess Tournaments"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Rectangle {
              id: tourneyBack
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: backLabel.width + Style.space(14)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: backMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"

              Text {
                id: backLabel
                anchors.centerIn: parent
                text: "‹ BACK"
                color: backMouse.containsMouse ? Color.accent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }

              MouseArea {
                id: backMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.subView = ""
              }
            }
          }

          Text {
            width: parent.width
            visible: root.tourneySite === "lichess"
            text: {
              var t = root.tournaments()
              var live = t.filter(function(x) { return x.live }).length
              return live > 0 ? live + " live now · next 48 hours" : "Starting within 48 hours"
            }
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.subView === "tournaments" && root.tourneySite === "lichess" ? root.tournaments().slice(0, 10) : []

            Item {
              required property var modelData
              width: parent.width
              height: Style.space(44)

              Rectangle {
                id: tDot
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(8)
                height: width
                radius: width / 2
                color: modelData.live ? "#f85149" : "#d29922"
              }

              Item {
                anchors.left: tDot.right
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  spacing: 0

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: modelData.name
                    textFormat: Text.PlainText
                    color: tRowMouse.containsMouse ? Color.accent : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: modelData.live
                  }

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: {
                      var parts = []
                      if (modelData.live)
                        parts.push("LIVE · ends " + root.timeUntil(modelData.startsAt + modelData.minutes * 60000))
                      else
                        parts.push(root.timeUntil(modelData.startsAt))
                      if (modelData.perf !== "") parts.push(modelData.perf)
                      if (modelData.timeControl !== "") parts.push(modelData.timeControl)
                      if (modelData.minutes > 0) parts.push(modelData.minutes + " min")
                      parts.push(modelData.nbPlayers + " players")
                      return parts.join(" · ")
                    }
                    textFormat: Text.PlainText
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  id: tRowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openLichessUrl(modelData.url)
                }
              }
            }
          }

          Column {
            visible: root.tourneySite === "chesscom"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
              text: "Chess.com does not share upcoming tournaments publicly.\nOpen them on the site:"
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              width: parent.width
              height: Style.space(30)
              radius: Style.cornerRadius
              color: ccTOpenMouse.containsMouse
                ? Style.selectedStateColor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Text {
                anchors.centerIn: parent
                text: "OPEN ON CHESS.COM →"
                color: ccTOpenMouse.containsMouse ? Color.background : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.letterSpacing: 1
              }

              MouseArea {
                id: ccTOpenMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openGameUrl("chesscom", "https://www.chess.com/tournaments")
              }
            }
          }

          Rectangle {
            visible: root.tourneySite === "lichess"
            width: parent.width
            height: visible ? Style.space(28) : 0
            radius: Style.cornerRadius
            color: allLichMouse.containsMouse
              ? Style.hoverFillFor(root.contentForeground, Color.accent)
              : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

            Text {
              anchors.centerIn: parent
              text: "VIEW ALL TOURNAMENTS →"
              color: allLichMouse.containsMouse ? Color.accent : root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            MouseArea {
              id: allLichMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openGameUrl("lichess", "https://lichess.org/tournament")
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Showing arenas starting within 48 hours"
            color: Qt.darker(root.contentForeground, 1.9)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
