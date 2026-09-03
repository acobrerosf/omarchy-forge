// Delegates and Components bind their outer scope lexically here rather than
// resolving it by walking the scope chain at every evaluation. The scope-chain
// form works right up until a delegate gains a property named like one of
// root's, at which point it quietly starts reading the wrong one.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "acobrerosf.forge"
  ipcTarget: "acobrerosf.forge"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // Folding is per screen, and a server id is only unique within its
  // organization's account, so both keys carry the organization.
  property var expandedServers: ({})
  property var autoExpanded: ({})
  property var collapsedOrgs: ({})
  property int cursorIndex: 0
  property bool cursorActive: false

  // Where in the panel we are. Empty is the tree; each entry is a view pushed
  // over it, and `route` is the one on screen. Reassigned rather than mutated,
  // like every other `var` here — `rows` binds to it.
  //
  // A stack rather than a pair of booleans because the views nest: a site is
  // reached from the tree and a log from that site, and backing out has to
  // land where it came from. Sites stopped being leaves when they grew
  // actions; this is what they grew into.
  property var navStack: []
  readonly property var route: navStack.length > 0 ? navStack[navStack.length - 1] : null
  readonly property string routeKind: route ? String(route.kind) : ""

  // The site the current view is about, re-resolved from the service on every
  // refresh rather than captured when the view was pushed — a deploy finishing
  // while its log is open should update the header behind it. Same for the
  // server: a reboot that lands should be visible in the view that asked for it.
  readonly property var routeSite: route ? siteFor(route) : null
  readonly property var routeServer: route ? serverById(route.org, route.serverId) : null

  // The routes that are a pane rather than a list. They share everything that
  // follows from that — no cursor to move, j/k scrolls instead, a wider card,
  // and the reading keys `g G c w` — so the distinction is drawn once here
  // rather than at each of the places that has to know.
  readonly property bool paneRoute: routeKind === "log" || routeKind === "commandOutput"
    || routeKind === "eventOutput" || routeKind === "siteLog"

  // The log this panel asked for, and what came back. Keyed the same way the
  // service keys its answer, so two screens with two logs open don't cross.
  property string logRequestKey: ""
  // The file this screen asked for. `textSaved` is session-wide like every
  // other service signal, and two monitors both showing a log should not both
  // announce one of them saving it.
  property string saveRequestedPath: ""
  property var logLines: []
  property string logError: ""
  property bool logLoading: false

  // A server's event feed and, above it, one event's output. The feed is the
  // first thing here that stays alive *under* another route — backing out of
  // an event's output must land on the list it came from, not on an empty one
  // — which is why `popView` clears it by the kind it popped rather than
  // unconditionally the way it clears the log. `eventsCursor` is the page
  // after the one on screen: empty once the feed has been read to its end.
  property string eventsRequestKey: ""
  property var events: []
  property string eventsCursor: ""
  property string eventsError: ""
  property bool eventsLoading: false
  property string eventOutputRequestKey: ""
  property var eventOutputLines: []
  property string eventOutputError: ""
  property bool eventOutputLoading: false
  // The event the output pane is about, looked up in the feed under it.
  readonly property var routeEvent: {
    if (routeKind !== "eventOutput" || !route) return null
    for (var i = 0; i < events.length; i++)
      if (events[i].id === String(route.eventId)) return events[i]
    return null
  }

  // The command prompt and the run it turns into. `commandText` is deliberately
  // not remembered between opens: a command that can be recalled is a command
  // that can be repeated by accident, which for this endpoint is the whole
  // thing worth preventing.
  property string commandText: ""
  // Drives `PanelKeyCatcher.blocked`. While it is true the catcher forwards
  // every key to the field instead of reading it as movement, so it has to go
  // false again — and focus has to be handed back by hand — before `h j k l`
  // mean anything again. See `stopCommandEditing`.
  property bool commandEditing: false
  property string commandRequestKey: ""
  property var commandLines: []
  property string commandHeader: ""
  property string commandError: ""
  property bool commandRunning: false
  // The run's own id, which arrives only once it has been recognised. It names
  // the file `w` writes; nothing else here needs it.
  property string commandId: ""
  // Nothing here that changes a real server goes on one press: the first arms
  // the row, the second sends it. `armedConfirm` is what the second press has
  // to be — "again" for a deploy or a service restart, "Y" for a reboot, which
  // is a different order of destructive and gets a key of its own.
  property string armedKey: ""
  property string armedConfirm: ""
  // What this widget asked the service to send. The service's result is
  // session-wide, so without this every screen would flash the same message.
  property string actionRequestedKey: ""
  property string flash: ""

  readonly property color badColor: urgent
  readonly property color okColor: foreground
  readonly property color busyColor: Color.accent

  // ------------------------------------------------------------- the service

  // One service instance per session, shared by every screen's copy of this
  // widget, so polling and notifications happen once rather than once per
  // monitor. It is null for the frame or two before the shell has it loaded.
  readonly property var forge: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

  readonly property var setup: forge ? forge.setup : Model.emptySetup()

  // Which organizations this widget shows. The setting is a filter over what
  // the helper is watching: empty means all of them, a slug means that one, a
  // comma-separated list means those. One widget covering everything is the
  // point — adding a third organization should not mean a third bar icon.
  readonly property var organizations: Model.organizationsInView(setup, setting("organization", ""))
  readonly property bool showOrgHeaders: organizations.length > 1

  readonly property string dashboardUrlTemplate:
    String(setting("dashboardUrlTemplate", "https://forge.laravel.com/{org}/{server}/{site}"))

  readonly property string health: forge ? forge.healthForList(organizations) : "setup"
  readonly property string summary: forge ? forge.summaryForList(organizations) : "Loading…"
  readonly property bool needsSetup: forge ? forge.needsSetup === true : false
  readonly property bool tokenKnown: forge ? forge.tokenKnown === true : false
  readonly property string busyKey: forge ? String(forge.busyActionKey) : ""

  // Every organization's state, so the auto-unfold below re-runs whenever any
  // of them lands rather than only the first.
  readonly property var orgStates: forge ? forge.orgs : ({})

  function stateFor(org) {
    return forge ? forge.stateFor(org) : Model.emptyState()
  }

  function sitesFor(org, serverId) {
    return forge ? forge.sitesFor(org, serverId) : []
  }

  function serverById(org, id) {
    return forge ? forge.serverById(org, id) : null
  }

  function orgLabel(org) {
    return Model.orgLabel(setup, org)
  }

  function refresh() {
    if (forge) forge.refreshList(organizations)
  }

  // Anything the widget cannot fix by asking again: a missing or rejected
  // token belongs to an account, so it is named once however many
  // organizations sit behind it.
  readonly property var problems: {
    var out = []
    var seen = ({})
    for (var i = 0; i < organizations.length; i++) {
      var org = organizations[i]
      var state = stateFor(org)
      var isAccount = state.accountError !== ""
      var text = isAccount ? state.accountError : state.lastError
      if (text === "") continue
      // A broken account is one problem however many organizations sit behind
      // it, so it collapses to a single line. Anything else is that
      // organization's own failure and has to be reported per organization —
      // folding two orgs that both say "Not found" into one line would hide
      // the second entirely.
      var key = isAccount ? "account/" + state.account : "org/" + org
      if (seen[key] === true) continue
      seen[key] = true
      out.push(showOrgHeaders && !isAccount ? orgLabel(org) + ": " + text : text)
    }
    return out
  }

  readonly property bool refreshing: {
    for (var i = 0; i < organizations.length; i++)
      if (stateFor(organizations[i]).refreshing) return true
    return false
  }

  readonly property double lastRefreshMs: {
    var newest = 0
    for (var i = 0; i < organizations.length; i++)
      newest = Math.max(newest, stateFor(organizations[i]).lastRefreshMs)
    return newest
  }

  // ----------------------------------------------------------- subscription

  // The service polls the union of what its watchers ask for, so this widget
  // registers what it wants and re-registers whenever that changes. One
  // watcher covers every organization on show; two screens asking for the same
  // one collapse into a single poll.
  property string watcherId: ""
  readonly property var watchConfig: ({
    organizations: organizations,
    refreshIntervalSec: setting("refreshIntervalSec", 60),
    watchDeployments: setting("watchDeployments", true),
    notifyDeployments: setting("notifyDeployments", true)
  })

  function syncSubscription() {
    if (!forge) { watcherId = ""; return }
    if (watcherId === "") watcherId = forge.subscribe(watchConfig)
    else forge.update(watcherId, watchConfig)
  }

  // A service reload hands back a different instance, and the token issued by
  // the old one means nothing to it.
  onForgeChanged: { watcherId = ""; syncSubscription() }
  onWatchConfigChanged: syncSubscription()
  Component.onCompleted: syncSubscription()
  Component.onDestruction: if (forge && watcherId !== "") forge.unsubscribe(watcherId)

  // ----------------------------------------------------------------- rows

  // One flat list, so the cursor is a single index and j/k walks organizations,
  // servers and sites without caring which is which. A view is nothing more
  // than a different list: the same cursor, the same delegate, the same key
  // handler, so nothing about moving around has to be learned twice.
  readonly property var rows: {
    if (paneRoute) return []
    // One row, and it is the send. Built from what has been typed rather than
    // from the site alone, so that arming it, rendering "press Y to run" and
    // reporting the result all go through the machinery the other writes
    // already use — see `Model.siteCommandAction`.
    if (routeKind === "command") {
      if (!routeSite) return []
      var send = Model.siteCommandAction(route.org, routeSite, commandText)
      return [{ kind: "action", org: route.org, serverId: route.serverId,
                siteId: route.siteId, action: send,
                // The typed command rides the arm key the way the maintenance
                // toggle's direction does, and for the sharper version of the
                // same reason: this row is nothing *but* its text. A keystroke
                // that lands after enter has armed it — the field keeps focus
                // for one turn of the event loop, see `stopCommandEditing` —
                // then lapses the arm instead of retargeting it at a command
                // the row never named.
                armKey: route.org + "/" + route.siteId + "/command-run/"
                  + send.armIntent,
                // Not the arm key: the cursor is restored by row key, and a row
                // that changed its identity on every keystroke would lose it.
                key: route.org + "/" + route.siteId + "/command-run" }]
    }
    if (routeKind === "site" || routeKind === "server") return actionRows
    if (routeKind === "events") return eventRows

    var out = []
    for (var o = 0; o < organizations.length; o++) {
      var org = organizations[o]
      if (showOrgHeaders) {
        out.push({ kind: "org", org: org, key: "org/" + org })
        if (!isOrgExpanded(org)) continue
      }
      var servers = stateFor(org).servers
      for (var i = 0; i < servers.length; i++) {
        var server = servers[i]
        out.push({ kind: "server", org: org, serverId: server.id,
                   key: org + "/" + server.id })
        if (!isExpanded(org, server.id)) continue
        var sites = sitesFor(org, server.id)
        for (var j = 0; j < sites.length; j++)
          out.push({ kind: "site", org: org, serverId: server.id,
                     siteId: sites[j].id, key: org + "/" + sites[j].key })
      }
    }
    return out
  }

  // A view's rows: what can be done to the site or the server it is about.
  // Split out of `rows` so the tree's loop stays legible, and so the list is
  // derived once per route rather than once per keypress. A subject that has
  // gone from the API is not an empty view — `Model` answers for a missing one
  // with every row unavailable, which says what happened where a blank pane
  // would read as a bug.
  readonly property var actionRows: {
    var out = []
    var forSite = routeKind === "site"
    if (!forSite && routeKind !== "server") return out
    var actions = forSite ? Model.siteActions(route.org, routeSite)
                          : Model.serverActions(route.org, routeServer)
    var prefix = route.org + "/" + (forSite ? route.siteId : route.serverId) + "/"
    var subjectKey = forSite && routeSite ? String(routeSite.key) : ""
    for (var i = 0; i < actions.length; i++)
      out.push({ kind: "action", org: route.org, serverId: route.serverId,
                 siteId: forSite ? route.siteId : "", action: actions[i],
                 // What the arm and the send are reported on, and the action
                 // says which it wants. Deploy asks for the subject's key,
                 // because the tree's row for that site reports the same deploy
                 // and has to light up with it; everything else takes its own
                 // row's, because rows can send to the same endpoint and only
                 // the one that was pressed should say so.
                 //
                 // `armIntent` is folded in where an action has one. This list
                 // is rebuilt on every refresh, and the maintenance row's label
                 // and method are derived from live state — so without it a
                 // sweep landing inside the arm window would leave the arm
                 // matching a row that now means the opposite thing.
                 armKey: actions[i].armsSubject ? subjectKey
                   : prefix + actions[i].id
                     + (actions[i].armIntent ? "/" + actions[i].armIntent : ""),
                 key: prefix + actions[i].id })
    return out
  }

  // The event feed's rows: one per event, newest first, and — while Forge has
  // a page after this one — a last row that fetches it. A row rather than a
  // key, so enter and a click both reach it and it says "loading…" itself
  // while the page is on its way; it stays available meanwhile because the
  // service already refuses a second copy of a page it is fetching. The event
  // object rides the row the way an action does, so the delegate has no
  // lookup to make; the row carries no `siteId` on purpose — see
  // `Model.eventsFrom`.
  readonly property var eventRows: {
    var out = []
    if (routeKind !== "events") return out
    var prefix = route.org + "/" + route.serverId + "/"
    for (var i = 0; i < events.length; i++)
      out.push({ kind: "event", org: route.org, serverId: route.serverId,
                 eventId: events[i].id, event: events[i],
                 key: prefix + "event/" + events[i].id })
    if (eventsCursor !== "")
      out.push({ kind: "action", org: route.org, serverId: route.serverId, siteId: "",
                 action: { id: "events-more", hint: "",
                           label: eventsLoading ? "Loading older events…" : "Older events…",
                           available: true, reason: "" },
                 armKey: "", key: prefix + "more" })
    return out
  }

  // The row the view was opened from rides the view, so backing out lands on
  // it rather than on the top of whatever list is underneath — which for a
  // feed of thirty events read one at a time is the difference between
  // reading and scrolling.
  function pushView(view) {
    var from = currentRow()
    view.returnKey = from ? String(from.key) : ""
    view.returnActive = cursorActive
    navStack = navStack.concat([view])
    cursorIndex = 0
    cursorActive = false
    disarm()
  }

  function popView() {
    if (navStack.length === 0) return false
    var popped = route
    navStack = navStack.slice(0, navStack.length - 1)
    // `rows` has already followed `navStack`, so the origin can be looked up
    // in it now. A row that has gone — a site the sweep dropped — falls back
    // to the top, which is where every pop used to land.
    var origin = String(popped.returnKey || "")
    cursorIndex = 0
    if (origin !== "") cursorIndex = indexOfRow(origin)
    cursorActive = popped.returnActive === true && rows.length > 0
    disarm()
    // The log and the command are only ever the top of the stack, so nothing
    // is lost by clearing them on every pop. The feed is not: an event's
    // output sits over it, and clearing the list on the way back out of the
    // output is what this branch exists to avoid.
    clearLog()
    clearCommand()
    clearEventOutput()
    if (popped.kind === "events") clearEvents()
    return true
  }

  // Swapping the top of the stack rather than growing it. The prompt is spent
  // once it has sent — backing out of the output onto a filled-in command that
  // has already run is an invitation to run it twice — so the pane takes its
  // place and `h` lands on the site view behind them both.
  function replaceView(view) {
    if (navStack.length === 0) { pushView(view); return }
    // The replaced view's origin is this one's too: what is underneath has
    // not changed, so where backing out lands must not either.
    view.returnKey = route ? String(route.returnKey || "") : ""
    view.returnActive = route ? route.returnActive === true : false
    navStack = navStack.slice(0, navStack.length - 1).concat([view])
    cursorIndex = 0
    cursorActive = false
    disarm()
  }

  function serverKey(org, serverId) {
    return String(org) + "/" + String(serverId)
  }

  function isOrgExpanded(org) {
    return collapsedOrgs[String(org)] !== true
  }

  function setOrgExpanded(org, value) {
    var next = ({})
    for (var key in collapsedOrgs) next[key] = collapsedOrgs[key]
    next[String(org)] = !value
    collapsedOrgs = next
  }

  function isExpanded(org, serverId) {
    return expandedServers[serverKey(org, serverId)] === true
  }

  function setExpanded(org, serverId, value) {
    var next = ({})
    for (var key in expandedServers) next[key] = expandedServers[key]
    next[serverKey(org, serverId)] = value
    expandedServers = next
  }

  function rowAt(index) {
    if (index < 0 || index >= rows.length) return null
    return rows[index]
  }

  // Anything carrying a site id — a tree row, or the route of a view opened
  // from one — resolves through here, and always against the service's current
  // list rather than a copy taken when the view was pushed.
  function siteFor(row) {
    if (!row || !row.siteId) return null
    var sites = sitesFor(row.org, row.serverId)
    for (var i = 0; i < sites.length; i++)
      if (sites[i].id === row.siteId) return sites[i]
    return null
  }

  // Everything a row needs drawing, gathered here so the delegate itself holds
  // no service reference. The volatile per-screen bits — cursor, armed,
  // deploying, relative time — are bound separately on the delegate, so moving
  // the cursor or the clock ticking doesn't re-derive every row's text.
  function rowView(row) {
    if (!row) return Model.rowView(null, {})
    if (row.kind === "action")
      return Model.rowView(row, { action: row.action, armKey: row.armKey })
    if (row.kind === "event") return Model.rowView(row, { event: row.event })
    var isOrg = row.kind === "org"
    return Model.rowView(row, {
      server: isOrg ? null : serverById(row.org, row.serverId),
      site: siteFor(row),
      orgLabel: orgLabel(row.org),
      orgHealth: isOrg && forge ? forge.healthFor(row.org) : "",
      orgSummary: isOrg && forge ? forge.summaryFor(row.org) : "",
      siteCount: row.kind === "server" ? sitesFor(row.org, row.serverId).length : 0,
      showOrgHeaders: showOrgHeaders
    })
  }

  // The log view has no rows at all, so "the row under the cursor" is not what
  // these can be about there. Falling back to the route keeps `d`, `o`, `f`
  // and `s` meaning the same thing in every view rather than silently doing
  // nothing in one of them.
  function currentRow() { return rowAt(cursorIndex) }
  // The log view has no rows, so which organization is being looked at has to
  // come from the route there — the same fallback, for the same reason.
  function currentOrg() {
    var row = currentRow()
    return row ? String(row.org) : route ? String(route.org) : ""
  }
  function currentServer() {
    var row = currentRow()
    if (row) return row.kind !== "org" ? serverById(row.org, row.serverId) : null
    return route ? serverById(route.org, route.serverId) : null
  }
  function currentSite() { return siteFor(currentRow()) || routeSite }

  // ------------------------------------------------------------- behaviour

  function moveCursor(delta) {
    if (rows.length === 0) return
    if (!cursorActive) { cursorActive = true; return }
    var next = cursorIndex + delta
    if (next < 0) next = rows.length - 1
    if (next >= rows.length) next = 0
    cursorIndex = next
    disarm()
  }

  // Enter and Space. Every kind of row answers it the same way — go to what
  // this row is about — which is why a site opens its actions here rather than
  // arming a deploy: on an organization and a server the key already meant
  // "show me what is inside this", and a site having been the exception was an
  // accident of sites having had nothing inside them. `d` still deploys from
  // anywhere, two presses, unchanged.
  function activate() {
    var row = currentRow()
    if (!row) return
    if (row.kind === "org") {
      setOrgExpanded(row.org, !isOrgExpanded(row.org))
      return
    }
    if (row.kind === "server") {
      var opening = !isExpanded(row.org, row.serverId)
      setExpanded(row.org, row.serverId, opening)
      // An opened row is worth a fresh look — the rotation will get to this
      // server eventually, the unfold wants it now. The service debounces, so
      // the auto-unfold path and a held key cost nothing extra.
      if (opening && forge) forge.fetchServerSites(row.org, row.serverId)
      return
    }
    if (row.kind === "action") { runAction(row); return }
    if (row.kind === "event") { openEventOutput(row); return }
    if (!siteFor(row)) { say("That site is no longer listed"); return }
    pushView({ kind: "site", org: row.org, serverId: row.serverId, siteId: row.siteId })
  }

  // Right, and `l`. Distinct from `activate` because a tree key that toggles
  // is wrong in one direction: on an already-open server, "go deeper" must not
  // mean "close this".
  function drillIn() {
    var row = currentRow()
    if (!row) return
    if (row.kind === "org" && isOrgExpanded(row.org)) return
    // An unfolded server has nothing left to unfold, so right goes where the
    // tree cannot: into what can be done to it. A folded one still unfolds —
    // deeper means its sites first, and its actions once those are showing.
    if (row.kind === "server" && isExpanded(row.org, row.serverId)) {
      openServerActions(row)
      return
    }
    activate()
  }

  // Both ways into a server's actions. `l` only means this on a server that is
  // already unfolded, because on a folded one it still has unfolding to do; the
  // icon has no such double duty, so it means the same thing on every server
  // row and the pointer never has to know which state the row is in.
  function openServerActions(row) {
    if (!row || row.kind !== "server") return
    pushView({ kind: "server", org: row.org, serverId: row.serverId })
  }

  // Left, `h`, and Escape. Leaves a view before it leaves the panel, and in
  // the tree walks back out the way the cursor walked in.
  function back() {
    if (popView()) return true
    var row = currentRow()
    if (!row) return false
    if (row.kind === "site") {
      // Collapsing the server the cursor is inside would strand it on whatever
      // row slid into the index, so it moves to the parent first.
      setExpanded(row.org, row.serverId, false)
      cursorIndex = indexOfRow(serverKey(row.org, row.serverId))
      return true
    }
    if (row.kind === "server" && isExpanded(row.org, row.serverId)) {
      setExpanded(row.org, row.serverId, false)
      return true
    }
    if (row.kind === "server" && showOrgHeaders) {
      cursorIndex = indexOfRow("org/" + row.org)
      return true
    }
    if (row.kind === "org" && isOrgExpanded(row.org)) {
      setOrgExpanded(row.org, false)
      return true
    }
    return false
  }

  // What the hero says about a server: the two facts its row showed, since the
  // row it came from is no longer on screen to show them.
  function serverDetailLine(server) {
    if (!server) return "not listed"
    var label = Model.serverStateLabel(server.state)
    var count = route ? sitesFor(route.org, server.id).length : 0
    return count > 0 ? label + " · " + Model.pluralize(count, "site") : label
  }

  // What the hero says about a site: the same two facts its row shows, since
  // the row it came from is no longer on screen to show them.
  function siteMeta(site) {
    var parts = []
    if (site.branch) parts.push(site.branch)
    if (site.commitHash) parts.push(site.commitHash)
    return parts.join(" · ")
  }

  // The same rule the row under it draws by, so the hero's words and its badge
  // cannot say different things about one site.
  //
  // The timestamp is the *deployment's*, so it is only appended to a label that
  // is also the deployment's — `timed` says which. Joining it to "maintenance"
  // would date the wrong fact: a site parked a moment ago would read
  // "maintenance · 2h ago". The tree row is left alone, where the two sit on
  // separate lines rather than in one phrase.
  function siteDetailLine(site) {
    var reported = Model.siteStatus(site)
    var when = reported.timed && site.deployedAt
      ? Model.relativeTime(site.deployedAt, nowMs) : ""
    return when === "" ? reported.label : reported.label + " · " + when
  }

  // What the hero says under an event's description: who it ran as and which
  // site it was about, the same two facts its row showed.
  function eventMeta(event) {
    if (!event) return ""
    var parts = []
    if (event.ranAs) parts.push("as " + event.ranAs)
    if (event.siteName) parts.push(event.siteName)
    return parts.join(" · ")
  }

  // The badge follows whatever the hero is about, so in a site view it reports
  // that site rather than the health of everything being watched.
  readonly property string heroTone: {
    if (routeSite) {
      var tone = Model.siteTone(routeSite)
      return tone === "bad" ? "bad" : tone === "busy" ? "busy"
        : tone === "warn" ? "maintenance" : "none"
    }
    if (routeKind === "server" || routeKind === "events") {
      var serverTone = routeServer ? Model.serverTone(routeServer.state) : "idle"
      return serverTone === "bad" ? "bad" : serverTone === "busy" ? "busy" : "none"
    }
    // An event has no status for a badge to report — see `Model.eventsFrom`.
    if (routeKind === "eventOutput") return "none"
    return health === "bad" ? "bad"
      : health === "busy" ? "busy"
      : health === "maintenance" ? "maintenance"
      : (health === "setup" || health === "error") ? "warn" : "none"
  }

  readonly property var routeDetails: routeKind === "site" ? Model.siteDetails(routeSite) : []

  // What the footer says. Per *row* in the tree, not per view: `l` on a server
  // means something different depending on whether it is already unfolded, and
  // a footer that lists every key in the plugin is a list nobody reads — which
  // is how the one key with nowhere else to announce itself, the server view,
  // stayed invisible. Every line is short enough to stay a single line, so
  // moving the cursor changes the words without moving the panel underneath
  // them. Until the cursor is active nothing is highlighted, so nothing is
  // claimed about a particular row.
  readonly property string hintText: {
    if (routeKind === "log")
      return "[j/k] scroll · [g/G] top/bottom · [c] copy · [w] save · [h] back"
    if (routeKind === "commandOutput" || routeKind === "eventOutput"
        || routeKind === "siteLog")
      return "[j/k] scroll · [g/G] top/bottom · [c] copy · [w] save · [r] look again · [h] back"
    if (routeKind === "events")
      return "[enter] output · [r] refresh · [h] back"
    // Two lines because it is two states, and the one it is in is the whole
    // question: a field that is typing into and a row that is waiting for `Y`
    // look similar and take completely different keys.
    if (routeKind === "command")
      return commandEditing ? "type a command · [enter] arm · [esc] cancel"
        : armedKey !== "" ? "[Y] run · [enter] edit again · [h] back"
        : "[enter] arm · [h] back"
    var row = cursorActive ? currentRow() : null
    if (routeKind === "site" || routeKind === "server") {
      // The confirm key is worth naming on the one row that wants it, and
      // nowhere else — on `Restart nginx` it would only be a puzzle.
      if (row && row.action && String(row.action.confirm) === "Y")
        return "[enter] arm · [Y] confirm · [h] back"
      return "[enter] run · [h] back · [r] refresh"
    }
    if (!row) return "[j/k] move · [enter] open · [r] refresh · [a] add org"
    if (row.kind === "org")
      return (isOrgExpanded(row.org) ? "[enter] fold" : "[enter] unfold")
        + " · [f] forge · [r] refresh · [a] add org"
    if (row.kind === "server")
      return isExpanded(row.org, row.serverId)
        ? "[l] actions · [h] fold · [e] events · [f] forge · [s] ssh"
        : "[enter] unfold · [e] events · [f] forge · [s] ssh · [r] refresh"
    return "[enter] actions · [d] deploy · [o] open · [f] forge"
  }

  function indexOfRow(key) {
    for (var i = 0; i < rows.length; i++)
      if (rows[i].key === key) return i
    return cursorIndex
  }

  // One row from a view. An unavailable action says why rather than doing
  // nothing — a key that appears to have missed is worse than a refusal. The
  // row rather than the action, because a server action needs to know which
  // server, and which row of the four is arming.
  function runAction(row) {
    if (!row || !row.action) return
    var action = row.action
    if (action.available === false) {
      say(String(action.label) + " — " + String(action.reason))
      return
    }
    // The three site logs share one handler and differ only by the kind their
    // id carries, so they are matched by prefix rather than spelled out — the
    // one place in this switch where the id is not the whole answer.
    if (String(action.id).indexOf("site-log:") === 0) {
      openSiteLog(action.log)
      return
    }
    switch (String(action.id)) {
    case "deploy": deployCurrent(); break
    case "command": openCommandPrompt(); break
    // The prompt's own row. It reaches the same two presses as a reboot, so it
    // reaches them through the same function — except for the second enter,
    // which everywhere else means "never mind" and here means "let me fix it".
    case "command-run":
      if (armedKey === row.armKey && armedConfirm === "Y") reopenCommandPrompt()
      else runWriteAction(row)
      break
    case "log": openLog(); break
    case "events": openServerEvents(); break
    case "events-more": fetchEvents(eventsCursor); break
    case "open": openCurrent(); break
    case "forge": openCurrentInForge(); break
    case "ssh": copyCurrentSsh(); break
    case "maintenance":
    case "nginx-restart":
    case "php-reload":
    case "php-restart":
    case "reboot": runWriteAction(row); break
    }
  }

  function deployCurrent() {
    var site = currentSite()
    if (!site) return
    if (!Model.canDeploy(site)) {
      say(site.name + " has no repository to deploy")
      return
    }
    if (armedKey !== site.key) { arm(site.key, "again"); return }
    disarm()
    if (!forge) return
    actionRequestedKey = site.key
    forge.deploy(currentOrg(), site)
  }

  // The two confirms. A service restart and a maintenance toggle take the
  // deploy's two presses. A reboot takes a key of its own: enter is one row
  // away from enter on something harmless, and no key a mistyped movement could
  // land on should ever be the last press before a server goes down.
  function runWriteAction(row) {
    // `""` is also the disarmed state, so a row with no arm key would match on
    // its *first* press and send without a confirm. Nothing produces one today
    // — `runAction`'s availability check is what answers the user for a subject
    // that has gone from the API, and it blocks the one row that could — but
    // the two-press guarantee should not rest on that staying true.
    if (String(row.armKey) === "") return
    if (armedKey !== row.armKey) {
      arm(row.armKey, String(row.action.confirm || "again"))
      return
    }
    // A second enter on a Y-confirm disarms rather than sends: pressing the
    // same key twice is exactly the mistake the extra key is there to catch.
    if (armedConfirm === "Y") { disarm(); return }
    sendWriteAction(row)
  }

  // `Y`, and only for the row that asked for it. The cursor cannot have moved
  // since the arm — every move disarms — so the armed row is the one under it.
  function confirmArmed() {
    var row = currentRow()
    if (!row || armedConfirm !== "Y" || armedKey === "") return
    // The arm lapsed rather than missed: an arm key carries what the row meant
    // when it was armed — the command that was typed, the direction a toggle
    // was pointing — so a row that no longer matches is one that changed under
    // the arm. The press is spent saying so rather than sending something the
    // row never named.
    if (row.armKey !== armedKey) {
      disarm()
      say("That changed while it was armed — arm it again")
      return
    }
    // Re-checked here, not only in `runAction`: the subject can go from the API
    // inside the confirm window, and this path never went past that check.
    if (row.action && row.action.available === false) {
      disarm()
      say(String(row.action.label) + " — " + String(row.action.reason))
      return
    }
    sendWriteAction(row)
  }

  // The action carries everything that differs between one write and another —
  // where it goes, how, what to re-read — so this hands the whole entry over
  // rather than sorting it by subject first.
  function sendWriteAction(row) {
    disarm()
    if (!forge) return
    actionRequestedKey = row.armKey
    // A command is the one write with an answer worth waiting for, so it goes
    // out through its own door and the pane that follows it is opened here —
    // see `onActionFinished`, which is where the 202 lands.
    if (String(row.action.id) === "command-run") {
      var key = forge.runSiteCommand(row.org, row.serverId, row.siteId,
                                     row.action, row.armKey)
      // Nothing was sent — the last write is still in flight, the minute is
      // spent, the site has gone. The refusal has already been said through
      // `onActionFinished`, and there is no run to watch, so the prompt is left
      // exactly as it was rather than dressed up as one that is running.
      if (key === "") return
      // Set before the answer can arrive: the service says "queued" the moment
      // the 202 lands, and an update this screen cannot recognise is one it
      // would throw away.
      commandRequestKey = key
      commandLines = []
      commandError = ""
      commandHeader = ""
      commandRunning = true
      return
    }
    forge.sendAction(row.org, row.serverId, row.action, row.armKey)
  }

  function arm(key, confirm) {
    armedKey = key
    armedConfirm = confirm
    // The stronger confirm gets longer: it asks for a key that is not already
    // under the hand, and timing out mid-reach is its own kind of annoying.
    disarmTimer.interval = confirm === "Y" ? 8000 : 4000
    disarmTimer.restart()
  }

  // ------------------------------------------------------------- deploy log

  function clearLog() {
    logRequestKey = ""
    saveRequestedPath = ""
    logLines = []
    logError = ""
    logLoading = false
  }

  function openLog() {
    var row = currentRow()
    var site = currentSite()
    if (!site) { say("That site is no longer listed"); return }
    if (!site.deploymentId) { say(site.name + " has never deployed"); return }
    if (!forge) return

    clearLog()
    logRequestKey = forge.logRequestKey(row.org, row.serverId, site.id, site.deploymentId)
    logLoading = true
    pushView({ kind: "log", org: row.org, serverId: row.serverId,
               siteId: site.id, deploymentId: site.deploymentId })
    forge.fetchDeploymentLog(row.org, row.serverId, site.id, site.deploymentId)
  }

  // ---------------------------------------------------------------- site logs

  // On the deploy log's state rather than a second set of properties: only one
  // pane is ever open — `popView` clears the log on every pop, and `paneLines`
  // falls through to it — so a `siteLog` route reading and writing the same
  // `log*` trio is the shape that already holds. What tells the two apart is
  // the route kind, the request key, and the words on the pane.
  function openSiteLog(kind) {
    var row = currentRow()
    var site = currentSite()
    if (!site) { say("That site is no longer listed"); return }
    if (!forge) return

    clearLog()
    logRequestKey = forge.siteLogRequestKey(row.org, row.serverId, site.id, kind)
    logLoading = true
    pushView({ kind: "siteLog", org: row.org, serverId: row.serverId,
               siteId: site.id, log: String(kind) })
    forge.fetchSiteLog(row.org, row.serverId, site.id, kind)
  }

  // A log is a tail as of the moment it was asked for, so looking again is the
  // point of the pane rather than a recovery from an error. The key stays the
  // same one the command's output and an event's use.
  function refreshSiteLog() {
    if (!forge || routeKind !== "siteLog") return
    logLines = []
    logError = ""
    logLoading = true
    forge.fetchSiteLog(route.org, route.serverId, route.siteId, route.log)
  }

  // ---------------------------------------------------------- server events

  function clearEvents() {
    eventsRequestKey = ""
    events = []
    eventsCursor = ""
    eventsError = ""
    eventsLoading = false
  }

  function clearEventOutput() {
    eventOutputRequestKey = ""
    saveRequestedPath = ""
    eventOutputLines = []
    eventOutputError = ""
    eventOutputLoading = false
  }

  // `e`, and the row in the server view. Resolves the server the way `f` and
  // `s` do — the row under the cursor, else the view's — so it means the same
  // thing from a site as from its server. Three refusals: from inside a pane
  // or the command prompt, because a view pushed over either would let
  // `popView` clear it — the pane's text, the prompt's command — on the way
  // back; and from the feed itself, where it would only stack a second copy
  // over the first.
  function openServerEvents() {
    if (paneRoute || routeKind === "events" || routeKind === "command") return
    var server = currentServer()
    if (!server || !forge) return
    var org = currentOrg()
    clearEvents()
    pushView({ kind: "events", org: org, serverId: server.id })
    fetchEvents("")
  }

  // The first page replaces the list; a later one, asked for by the trailing
  // row, extends it. Both are one request and both go through the log's
  // refusals. The key is the feed's, not the page's, so the answer to either
  // finds the same pane.
  function fetchEvents(cursor) {
    if (!forge || routeKind !== "events") return
    eventsRequestKey = forge.eventsRequestKey(route.org, route.serverId)
    eventsLoading = true
    if (cursor === "") { eventsError = ""; eventsCursor = "" }
    forge.fetchServerEvents(route.org, route.serverId, cursor)
  }

  function openEventOutput(row) {
    if (!row || !forge) return
    clearEventOutput()
    eventOutputRequestKey = forge.eventOutputRequestKey(row.org, row.serverId, row.eventId)
    eventOutputLoading = true
    pushView({ kind: "eventOutput", org: row.org, serverId: row.serverId, eventId: row.eventId })
    forge.fetchEventOutput(row.org, row.serverId, row.eventId)
  }

  function refreshEventOutput() {
    if (!forge || routeKind !== "eventOutput") return
    eventOutputLines = []
    eventOutputError = ""
    eventOutputLoading = true
    forge.fetchEventOutput(route.org, route.serverId, route.eventId)
  }

  // ------------------------------------------------------------------ panes

  // Which pane's document is on screen, decided once. Three panes share one
  // `ForgeLogView`, and a three-way ternary in each of its bindings is the
  // wrong shape for a decision that has to come out the same every time.
  readonly property var paneLines: routeKind === "commandOutput" ? commandLines
    : routeKind === "eventOutput" ? eventOutputLines : logLines
  readonly property bool paneLoading: routeKind === "commandOutput" ? commandRunning
    : routeKind === "eventOutput" ? eventOutputLoading : logLoading
  readonly property string paneError: routeKind === "commandOutput" ? commandError
    : routeKind === "eventOutput" ? eventOutputError : logError
  readonly property string paneLoadingText: routeKind === "commandOutput"
    ? (commandHeader === "" ? "queued…" : commandHeader + "…")
    : routeKind === "eventOutput" ? "Fetching the event's output…" : "Fetching the log…"
  readonly property string paneEmptyText: routeKind === "commandOutput"
    ? "This command printed nothing."
    : routeKind === "eventOutput" ? "This event printed nothing."
    : routeKind === "siteLog" ? "This log is empty."
    : "This deployment printed nothing."

  // The two ways what is on screen leaves a pane. Both take the text already
  // there, so neither costs a request — and both go out on stdin rather than
  // in an argv, because a verbose deploy can outgrow what an argument may hold.
  function copyPane() {
    if (paneLines.length === 0 || !forge) return
    forge.copyToClipboard(paneLines.join("\n") + "\n")
    say("Copied " + Model.pluralize(paneLines.length, "line"))
  }

  function savePane() {
    if (paneLines.length === 0 || !forge || !route) return
    var site = routeSite
    var name = site ? site.name : ""
    // The file is named after the site — or, for an event, the server — which
    // is API data reaching a path. These three are what stop a name being a
    // separator.
    saveRequestedPath = forge.downloadDir() + "/"
      + (routeKind === "commandOutput"
         ? Model.commandFileName(name, commandId)
         : routeKind === "eventOutput"
           ? Model.eventFileName(routeServer ? routeServer.name : "", route.eventId)
           : routeKind === "siteLog"
             ? Model.siteLogFileName(name, route.log)
             : Model.logFileName(name, route.deploymentId))
    forge.saveText(paneLines.join("\n") + "\n", saveRequestedPath)
  }

  // ---------------------------------------------------------- run a command

  function clearCommand() {
    if (forge && commandRequestKey !== "") forge.stopCommandWatch(commandRequestKey)
    commandRequestKey = ""
    // The field holds its own text, so clearing the property it feeds is not
    // enough — and leaving a spent command in it is the one-key repeat this
    // whole route is shaped to avoid.
    commandField.text = ""
    commandText = ""
    commandId = ""
    commandLines = []
    commandHeader = ""
    commandError = ""
    commandRunning = false
    stopCommandEditing()
  }

  function openCommandPrompt() {
    var row = currentRow()
    var site = currentSite()
    if (!site) { say("That site is no longer listed"); return }

    clearCommand()
    pushView({ kind: "command", org: row.org, serverId: row.serverId,
               siteId: site.id })
    startCommandEditing()
  }

  // Focus is handed over by hand in both directions, which is the contract
  // `PanelKeyCatcher.blocked` documents: while the field has it the catcher is
  // deaf, and nothing gives it back on its own. `Qt.callLater` because the
  // field may not exist yet on the frame the route changed.
  function startCommandEditing() {
    commandEditing = true
    cursorActive = false
    Qt.callLater(function () { if (commandField.visible) commandField.forceActiveFocus() })
  }

  // Deferred, both halves of it, and that is the whole point. The enter that
  // arms is delivered to the field *while the catcher is still blocked*;
  // clearing the flag here and now would unblock the catcher mid-delivery, and
  // the same keypress would go on to reach `onActivateRequested` — which, on a
  // row that was just armed, reads as "enter again" and hands the arm straight
  // back. The arm never survived the press that made it, so `Y` went into the
  // field instead of confirming. One turn of the event loop is enough to keep
  // the two apart.
  function stopCommandEditing() {
    if (!commandEditing) return
    Qt.callLater(function () {
      root.commandEditing = false
      keyCatcher.forceActiveFocus()
    })
  }

  // Enter in the field. It does not send — it arms, and the row below the field
  // says what is about to run and on which site. `Y` is the press that sends.
  function armCommand() {
    var row = currentRow()
    if (!row || !row.action) return
    if (row.action.available === false) {
      say(String(row.action.reason || "Nothing to run"))
      return
    }
    stopCommandEditing()
    cursorActive = true
    cursorIndex = 0
    arm(row.armKey, "Y")
  }

  // Both ways out of an armed command that was not confirmed: the text is kept
  // and the field takes focus back, because the likely next move is to fix a
  // typo rather than to start again.
  function reopenCommandPrompt() {
    disarm()
    startCommandEditing()
  }

  // The prompt has sent, so it becomes the pane that follows the run, and the
  // text goes with the prompt — see `commandText`.
  function openCommandOutput() {
    commandText = ""
    stopCommandEditing()
    replaceView({ kind: "commandOutput", org: route.org, serverId: route.serverId,
                  siteId: route.siteId })
  }

  // Only the panel that has a live watch can look again, and only it should say
  // so: once the output has landed the run is done being read, and a flash
  // saying otherwise is a look that never happened.
  function refreshCommandRun() {
    if (!forge || commandRequestKey === "") return
    say(forge.refreshCommand(commandRequestKey) ? "Looking again"
                                                : "Nothing left to look at")
  }

  function disarm() {
    armedKey = ""
    armedConfirm = ""
    disarmTimer.stop()
  }

  // A site knows its own address; anything else falls back to its page in
  // Forge, which is what `f` reaches directly.
  function openCurrent() {
    var site = currentSite()
    // Ask the model for the address rather than reading site.url directly: one
    // it refuses has to fall through to the Forge link, not silently do nothing.
    var url = site ? Model.externalUrl(site.url) : ""
    if (url && forge) { forge.openInBrowser(url); close(); return }
    openCurrentInForge()
  }

  function openCurrentInForge() {
    var row = currentRow()
    if (!row || !forge) return
    if (row.kind === "org") {
      forge.openInBrowser("https://forge.laravel.com/" + encodeURIComponent(row.org))
      close()
      return
    }
    var server = serverById(row.org, row.serverId)
    if (!server) return
    var url = Model.dashboardUrl(dashboardUrlTemplate, row.org, server,
                                 row.kind === "site" ? row.siteId : "")
    if (url === "") {
      // Stay open — closing would take the explanation with it.
      say("No Forge link for " + server.name + " — check the dashboard URL template")
      return
    }
    forge.openInBrowser(url)
    close()
  }

  function copyCurrentSsh() {
    var server = currentServer()
    if (!server) return
    var command = Model.sshCommand(server)
    if (command === "") { say("That server has no public IP"); return }
    if (forge) forge.copyToClipboard(command)
    say("Copied " + command)
  }

  function say(text) {
    flash = text
    flashTimer.restart()
  }

  // Token entry stays in a terminal: the helper reads it straight into the
  // keyring, so it never passes through this process or any argv.
  function launchSetup() {
    close()
    Quickshell.execDetached(["omarchy-launch-or-focus-tui",
                             "--app-id=org.omarchy.forge",
                             forge ? forge.cliPath : "", "setup"])
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(root, direction)
    return false
  }

  onRowsChanged: {
    if (cursorIndex >= rows.length) cursorIndex = Math.max(0, rows.length - 1)
  }

  // Deferred, because the row the cursor moved to may not have been laid out
  // yet — a view that has just been pushed has rows the Column has not sized.
  function followCursor() {
    if (!cursorActive) return
    Qt.callLater(function () { flick.revealRow(cursorIndex) })
  }
  onCursorIndexChanged: followCursor()
  onCursorActiveChanged: followCursor()

  onOpenedChanged: {
    if (opened) root.refresh()
    // Reopening lands on the tree. A view is where a train of thought was, and
    // resuming one from an hour ago mid-way is disorienting — the log behind
    // it is stale by then anyway.
    else {
      disarm(); cursorActive = false; navStack = []
      clearLog(); clearCommand(); clearEventOutput(); clearEvents()
    }
  }

  // A server that has just started failing is worth unfolding on its own — the
  // point of the widget is not having to go looking. Each server is only opened
  // once this way, so collapsing it again sticks.
  onOrgStatesChanged: {
    for (var o = 0; o < organizations.length; o++) {
      var org = organizations[o]
      var servers = stateFor(org).servers
      for (var i = 0; i < servers.length; i++) {
        var id = servers[i].id
        var key = serverKey(org, id)
        if (autoExpanded[key] === true) continue
        var sites = sitesFor(org, id)
        var failing = false
        for (var j = 0; j < sites.length; j++)
          if (Model.deploymentTone(sites[j].deploymentStatus) === "bad") failing = true
        if (!failing) continue
        var seen = ({})
        for (var k in autoExpanded) seen[k] = autoExpanded[k]
        seen[key] = true
        autoExpanded = seen
        setExpanded(org, id, true)
      }
    }
  }

  // A write's result is a session-wide signal, so only the widget that armed
  // it should speak up — otherwise every screen flashes the same message.
  Connections {
    target: root.forge
    enabled: root.forge !== null
    function onActionFinished(key, ok, message) {
      if (root.actionRequestedKey !== key) return
      root.actionRequestedKey = ""
      root.say(message)
      // The send was accepted, so the prompt has done its job and the pane that
      // follows the run takes its place. A refusal — no scope, rate limited —
      // leaves the prompt standing with the text still in it, which is what
      // makes trying again after fixing the token one keypress.
      if (!ok || root.routeKind !== "command") return
      root.openCommandOutput()
    }

    // The run, from `queued` through to what it printed. Filtered by key like
    // the log's: the service answers the session, and a second screen watching
    // a different run must not be updated by this one.
    function onCommandRunUpdated(requestKey, ok, running, commandId, header,
                                 text, message) {
      if (root.commandRequestKey !== requestKey) return
      root.commandRunning = running
      root.commandHeader = Model.plainText(header)
      // Kept for the file name `w` writes, which is the only thing that needs
      // it — and it only arrives once the run has been recognised.
      if (commandId !== "") root.commandId = commandId
      if (!ok) {
        root.commandError = String(message || "Could not read the command")
        return
      }
      root.commandError = ""
      // Same guard, same boundary as the log's: split only what the guard has
      // already been through, or an escape sequence survives the split. Only a
      // settled run assigns at all — and an empty one assigns empty, which is
      // what lets the pane finally say the command printed nothing.
      if (!running) root.commandLines = text === "" ? [] : Model.logLines(text)
    }

    // Filtered the same way and for the same reason: the service answers the
    // session, and only the screen that asked has a pane waiting for it.
    function onDeploymentLogFetched(requestKey, ok, text, message) {
      if (root.logRequestKey !== requestKey) return
      root.logLoading = false
      // The guard runs here, where the string is about to enter a Text — the
      // boundary it exists for. It also splits, because splitting a log the
      // guard has not seen is how an escape sequence gets to survive one.
      root.logLines = ok ? Model.logLines(text) : []
      root.logError = ok ? "" : String(message || "Could not read the log")
    }

    // A site log lands in the same three properties, guarded by the same key —
    // the two panes are never open at once, and the key's shape differs, so a
    // stale deploy log's answer cannot be mistaken for this one's.
    function onSiteLogFetched(requestKey, ok, text, message) {
      if (root.logRequestKey !== requestKey) return
      root.logLoading = false
      root.logLines = ok ? Model.logLines(text) : []
      root.logError = ok ? "" : String(message || "Could not read the log")
    }

    // The feed, filtered the same way. A first page replaces what is shown; a
    // later one extends it, and a later one that fails says so in the footer
    // rather than blanking a list that is already on screen. The array is
    // reassigned, never appended to in place — see CLAUDE.md.
    function onServerEventsFetched(requestKey, ok, events, cursor, nextCursor, message) {
      if (root.eventsRequestKey !== requestKey) return
      root.eventsLoading = false
      if (!ok) {
        var why = String(message || "Could not read the events")
        if (cursor === "" || root.events.length === 0) root.eventsError = why
        else root.say(why)
        return
      }
      root.eventsError = ""
      root.events = cursor === "" ? events : root.events.concat(events)
      root.eventsCursor = String(nextCursor || "")
    }

    function onEventOutputFetched(requestKey, ok, text, message) {
      if (root.eventOutputRequestKey !== requestKey) return
      root.eventOutputLoading = false
      root.eventOutputLines = ok ? Model.logLines(text) : []
      root.eventOutputError = ok ? "" : String(message || "Could not read the event")
    }

    // Saving is the one thing here that touches the filesystem, so where it
    // landed — or why it didn't — is worth saying rather than assuming.
    function onTextSaved(ok, path, message) {
      if (root.saveRequestedPath !== path) return
      root.saveRequestedPath = ""
      root.say(message)
    }
  }

  // The interval is set per arm — see `arm()` — so this is only the default.
  Timer {
    id: disarmTimer
    interval: 4000
    // Plain `disarm()`, deliberately: every *deliberate* way of dropping an arm
    // hands the command field its focus back, and this one must not — the key
    // most likely to follow a confirm line is `Y`, and it would land in the
    // command as a character. See ARCHITECTURE.md's Views.
    onTriggered: root.disarm()
  }

  Timer {
    id: flashTimer
    interval: 3500
    onTriggered: root.flash = ""
  }

  // Relative timestamps go stale while the panel sits open, so tick a clock
  // the labels can depend on rather than re-reading the wall clock per frame.
  property double nowMs: Date.now()
  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string { return root.summary }
  }

  // ------------------------------------------------------------- bar button

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // `summary` can be an API error message, and the shell's own components
    // render what they are handed in a `Text` with no `textFormat` — which we
    // cannot set from out here. So the string is neutralised on the way in
    // instead. Same for the two PanelHero bindings below. See Model.plainText.
    tooltipText: "Forge — " + Model.plainText(root.summary)

    iconComponent: Component {
      Item {
        ForgeIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.health === "setup" ? Qt.darker(button.bar ? button.bar.barForeground : root.foreground, 1.6)
                                          : (button.bar ? button.bar.barForeground : root.foreground)
          badgeColor: root.health === "busy" ? Color.accent : root.urgent
          badge: {
            switch (root.health) {
            case "bad": return "bad"
            case "error": return "warn"
            case "setup": return "warn"
            case "busy": return "busy"
            // Its own value rather than `warn`, which is spoken for by the two
            // above: the icon draws this one hollow, the way the rows do.
            case "maintenance": return "maintenance"
            }
            return "none"
          }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ----------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // A log is wide and long where a tree is neither, and both of these are
    // plain bindings, so the card follows the view onto the screen. Both
    // helpers clamp to what the screen actually has, so asking for more than
    // fits is safe.
    contentWidth: panel.fittedContentWidth(Style.space(root.paneRoute ? 620 : 420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + footer.implicitHeight
                                             + Style.space(12),
                                             Style.space(root.paneRoute ? 760 : 560))
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // The one place this panel hands its keys away. While the command field
      // has focus every key belongs to it — `h j k l` included, which are
      // movement everywhere else and letters in a shell command. Nothing gives
      // focus back on its own: `stopCommandEditing` does it by hand.
      blocked: root.commandEditing

      // `h j k l` never reach onTextKey — the catcher reads them as movement
      // before that — so the horizontal axis is where a tree key has to come
      // from. It cost nothing to take: until the site view existed, right and
      // `l` were a second way to press `j`.
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          if (root.paneRoute) logView.scrollBy(dy)
          // One row and a field above it: there is nowhere to move to, so j/k
          // means what every other stray key at the confirm means — back to
          // typing, with what was typed still there.
          else if (root.routeKind === "command") root.reopenCommandPrompt()
          else root.moveCursor(dy)
          return
        }
        if (dx > 0) root.drillIn()
        else if (dx < 0) root.back()
      }
      // Enter raises returnRequested AND activateRequested; space raises only
      // activateRequested. Handling both would run the action twice — which
      // would arm a deploy and immediately send it, skipping the confirm.
      onActivateRequested: if (!root.paneRoute) root.activate()
      // Out of the view first, out of the panel only from the tree.
      onCloseRequested: if (!root.back()) root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        // Before everything, and before the fold to lower case: a row waiting
        // for `Y` must not have one keypress mean two things, and `Y` is a
        // different key from `y` here — which is the whole point of it.
        if (root.armedConfirm === "Y") {
          if (text === "Y") { root.confirmArmed(); return }
          // Anything else was not the confirmation, lower-case `y` included.
          // The press is spent disarming and says so, rather than disarming
          // and then also doing whatever it usually does.
          var armedRow = root.currentRow()
          // A command that was not confirmed goes back to being editable
          // rather than being thrown away — the press that disarmed it was
          // most likely aimed at the typo it names.
          if (root.routeKind === "command") {
            root.reopenCommandPrompt()
            root.say("Not confirmed — still editing")
            return
          }
          root.disarm()
          root.say(armedRow && armedRow.action
                   ? String(armedRow.action.label) + " — not confirmed"
                   : "Not confirmed")
          return
        }
        // Before the fold to lower case, because these two are a pair that
        // only means anything while their case is intact.
        if (root.paneRoute) {
          if (text === "g") { logView.toTop(); return }
          if (text === "G") { logView.toEnd(); return }
          if (text === "c" || text === "C") { root.copyPane(); return }
          if (text === "w" || text === "W") { root.savePane(); return }
        }
        switch (String(text).toLowerCase()) {
        // In the output pane `r` looks at the run again rather than refreshing
        // everything being watched: the one thing on screen is the one thing
        // worth re-reading, and the ladder that was following it has stopped.
        case "r":
          if (root.routeKind === "commandOutput") root.refreshCommandRun()
          else if (root.routeKind === "eventOutput") root.refreshEventOutput()
          else if (root.routeKind === "siteLog") root.refreshSiteLog()
          else if (root.routeKind === "events") root.fetchEvents("")
          else root.refresh()
          break
        case "e": root.openServerEvents(); break
        case "o": root.openCurrent(); break
        case "f": root.openCurrentInForge(); break
        case "s": root.copyCurrentSsh(); break
        case "d": root.deployCurrent(); break
        case "a": root.launchSetup(); break
        }
      }

      Flickable {
        id: flick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: footer.top
        // The gap the scrolling Column used to get from its own spacing.
        anchors.bottomMargin: footer.height > 0 ? Style.space(12) : 0
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // Keeps the row under the cursor on screen. The tree never needed this
        // — a handful of servers fits — but a feed of thirty events does not,
        // and a cursor that has walked below the fold is a cursor nobody can
        // see. Scrolls by the least that brings the row into view, so `j`
        // through a long list reads as a list moving up one row at a time.
        function revealRow(index) {
          var item = rowRepeater.itemAt(index)
          if (!item || contentHeight <= height) return
          var top = item.mapToItem(column, 0, 0).y
          var bottom = top + item.height
          var y = contentY
          if (top < y) y = top
          else if (bottom > y + height) y = bottom - height
          contentY = Math.max(0, Math.min(y, contentHeight - height))
        }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          // The way back, and where "back" goes. A view reached with a keypress
          // still needs to be leavable with the mouse, and the trail says which
          // server's site this is — which the site view otherwise never states.
          Text {
            id: crumb
            width: parent.width
            visible: root.routeKind !== ""
            elide: Text.ElideRight
            textFormat: Text.PlainText
            color: root.foreground
            opacity: crumbArea.containsMouse ? 0.9 : 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              if (root.routeKind === "") return ""
              var parts = []
              // The trail names what is above this view. For a server view that
              // is the organization whether or not the tree shows headers for
              // it — and not the server, which the hero right below already
              // names.
              var aboutServer = root.routeKind === "server" || root.routeKind === "events"
              if (root.route && (root.showOrgHeaders || aboutServer))
                parts.push(root.orgLabel(root.route.org))
              var server = aboutServer ? null
                : root.route ? root.serverById(root.route.org, root.route.serverId) : null
              if (server) parts.push(server.name)
              if ((root.routeKind === "log" || root.routeKind === "siteLog") && root.routeSite)
                parts.push(root.routeSite.name)
              // Which of the three, since the hero below names the site and
              // three panes would otherwise wear the same trail.
              if (root.routeKind === "siteLog" && root.route)
                parts.push(Model.siteLogLabel(root.route.log))
              return "‹ " + Model.plainText(parts.join(" / "))
            }

            MouseArea {
              id: crumbArea
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.back()
            }
          }

          PanelHero {
            width: parent.width
            // In a view the hero is about the thing the view is about. Same
            // three slots, so nothing below has to move.
            // The feed is about the server, so it wears the server's hero;
            // an event's output is about that event, and gets its three
            // facts — what, for whom, when — in the same three slots.
            title: root.routeSite
              ? Model.plainText(root.routeSite.name)
              : root.routeKind === "eventOutput"
                ? Model.plainText(root.routeEvent ? root.routeEvent.description : "Event")
              : root.routeKind === "server" || root.routeKind === "events"
                ? Model.plainText(root.routeServer ? root.routeServer.name : "Server")
                : root.organizations.length === 1
                  ? Model.plainText(root.orgLabel(root.organizations[0])) : "Forge"
            meta: root.routeSite
              ? Model.plainText(root.siteMeta(root.routeSite))
              : root.routeKind === "eventOutput"
                ? Model.plainText(root.eventMeta(root.routeEvent))
              : root.routeKind === "server" || root.routeKind === "events"
                ? Model.plainText(root.routeServer ? Model.serverMeta(root.routeServer) : "")
                : Model.plainText(root.summary)
            detail: root.routeSite
              ? root.siteDetailLine(root.routeSite)
              : root.routeKind === "eventOutput"
                ? (root.routeEvent && root.routeEvent.createdAt
                   ? Model.relativeTime(root.routeEvent.createdAt, root.nowMs) : "")
              : root.routeKind === "server" || root.routeKind === "events"
                ? root.serverDetailLine(root.routeServer)
                : root.refreshing ? "refreshing…"
                                  : Model.relativeMs(root.lastRefreshMs, root.nowMs)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              ForgeIcon {
                iconSize: Style.font.display
                color: root.foreground
                badgeColor: root.heroTone === "busy" ? root.busyColor : root.urgent
                badge: root.heroTone === "bad" ? "bad"
                     : root.heroTone === "busy" ? "busy"
                     : root.heroTone === "maintenance" ? "maintenance"
                     : root.heroTone === "warn" ? "warn" : "none"
              }
            }
          }

          // ------------------------------------------------------- setup

          Column {
            width: parent.width
            spacing: Style.space(10)
            // What is missing is only known once the helper's state file has
            // been read, so say nothing until then rather than guess.
            visible: root.routeKind === "" && root.tokenKnown
              && (root.needsSetup || root.organizations.length === 0)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: root.needsSetup
                ? "No Forge API token on this machine yet. Setup stores one in your keyring."
                : "No organizations are being watched yet."
            }

            Button {
              width: parent.width
              text: root.needsSetup ? "Set up Forge" : "Add an organization"
              iconText: "󰅂"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.launchSetup()
            }
          }

          // ------------------------------------------------------- command

          // The prompt. Not a row: a row is something the cursor lands on and
          // a keypress does, and this is the one place in the panel where a
          // keypress is a letter. The row below it — the only one this route
          // has — is what sends.
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.routeKind === "command"

            PanelSectionHeader {
              text: "RUN A COMMAND"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: commandField
              width: parent.width
              foreground: root.foreground
              accent: root.busyColor
              placeholderText: "php artisan migrate"
              // Bound one way only: `commandText` is what the row is built
              // from, and binding it back would fight the field's own editing.
              onTextChanged: root.commandText = text
              onAccepted: root.armCommand()
              Keys.onEscapePressed: root.back()
              // Focus arrives by hand from `startCommandEditing`; this is for
              // the frame the route changes on, where that call is too early.
              onVisibleChanged: if (visible && root.commandEditing) Qt.callLater(forceActiveFocus)
            }

            // Where it lands, stated rather than assumed. The site view above
            // names the site; this names the machine and the account, which is
            // the part a command can be wrong about.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: {
                var site = root.routeSite
                var server = root.routeServer
                if (!site) return ""
                return "runs as forge in " + Model.plainText(site.name)
                  + "'s directory, on "
                  + Model.plainText(server ? server.name : "this server")
                  + (server && server.ip ? " · " + Model.plainText(server.ip) : "")
              }
            }
          }

          // ------------------------------------------------------ servers

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.rows.length > 0

            PanelSectionHeader {
              // The command route's one row sits directly under the field it
              // is about, which the block above has already headed — a second
              // header between the two would only separate them.
              visible: root.routeKind !== "command"
              text: root.routeKind === "site" || root.routeKind === "server" ? "ACTIONS"
                : root.routeKind === "events" ? "EVENTS"
                : root.showOrgHeaders ? "ORGANIZATIONS" : "SERVERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              id: rowRepeater
              model: root.rows

              ForgeRow {
                id: rowItem
                required property var modelData
                required property int index

                readonly property var view: root.rowView(modelData)

                width: parent.width
                indentStep: Style.space(16)

                kind: rowItem.modelData.kind
                label: rowItem.view.label
                detail: rowItem.view.detail
                status: rowItem.view.status
                tone: rowItem.view.tone
                depth: rowItem.view.depth
                showChevron: rowItem.view.showChevron
                showDot: rowItem.modelData.kind !== "action" && rowItem.modelData.kind !== "event"
                showActions: rowItem.modelData.kind === "server"
                expanded: rowItem.modelData.kind === "org"
                  ? root.isOrgExpanded(rowItem.modelData.org)
                  : root.isExpanded(rowItem.modelData.org, rowItem.modelData.serverId)

                // Bound separately rather than folded into `view`: these change
                // on their own clock, and re-deriving every row's text on a
                // cursor move or a tick would be wasted work.
                hasCursor: root.cursorActive && root.cursorIndex === rowItem.index
                armed: rowItem.view.actionKey !== ""
                  && root.armedKey === rowItem.view.actionKey
                armedText: rowItem.view.armedText
                sending: rowItem.view.actionKey !== ""
                  && root.busyKey === rowItem.view.actionKey
                timeText: rowItem.view.timeAt
                  ? Model.relativeTime(rowItem.view.timeAt, root.nowMs) : ""

                foreground: root.foreground
                dimColor: root.dim
                badColor: root.badColor
                busyColor: root.busyColor
                okColor: root.okColor
                urgentColor: root.urgent
                cursorFill: root.hoverFill
                fontFamily: root.fontFamily

                onEntered: {
                  root.cursorActive = true
                  root.cursorIndex = rowItem.index
                }
                onActivated: {
                  root.cursorIndex = rowItem.index
                  root.cursorActive = true
                  root.activate()
                }
                onContextRequested: {
                  root.cursorIndex = rowItem.index
                  root.cursorActive = true
                  root.openCurrentInForge()
                }
                onActionsRequested: {
                  root.cursorIndex = rowItem.index
                  root.cursorActive = true
                  root.openServerActions(rowItem.modelData)
                }
              }
            }
          }

          // ------------------------------------------------------- details

          // Every one of these arrived in the sites response the panel already
          // pays for, so the block costs no request. Not rows: the cursor
          // should only ever land on something a keypress can do.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.routeDetails.length > 0

            PanelSectionHeader {
              text: "DETAILS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.routeDetails

              Row {
                id: detailRow
                required property var modelData

                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: Style.space(92)
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: root.foreground
                  opacity: 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  text: detailRow.modelData.label
                }

                Text {
                  width: Math.max(0, parent.width - Style.space(92) - parent.spacing)
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: root.foreground
                  opacity: 0.75
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  text: detailRow.modelData.value
                }
              }
            }
          }

          // ----------------------------------------------------------- log

          ForgeLogView {
            id: logView
            width: parent.width
            visible: root.paneRoute
            // An Item has no implicit height, and the card's height is this
            // column's. Asking for a screenful rather than measuring one:
            // `fittedContentHeight` clamps whatever it cannot fit, so this is
            // a request for as much as the screen will give.
            height: visible ? Style.space(460) : 0

            // Three panes, one Item: which one is a matter of which route is
            // up, decided once on the root — see `paneLines`. The header is
            // the command run's alone: it is the one pane with a state line.
            lines: root.paneLines
            loading: root.paneLoading
            error: root.paneError
            loadingText: root.paneLoadingText
            emptyText: root.paneEmptyText
            header: root.routeKind === "commandOutput" && !root.commandRunning
              ? root.commandHeader : ""
            headerBad: root.routeKind === "commandOutput"
              && Model.commandHeaderBad(root.commandHeader)
            foreground: root.foreground
            badColor: root.badColor
            fontFamily: root.fontFamily
          }

          // -------------------------------------------------------- empty

          Text {
            width: parent.width
            visible: root.routeKind === "" && root.rows.length === 0
              && root.organizations.length > 0 && !root.needsSetup
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: root.refreshing
              ? "Loading servers…"
              : "No servers in " + root.organizations.join(", ") + "."
          }

          // The feed's three empty states: on its way, refused, or genuinely
          // nothing — the last is a real answer for a server Forge has not
          // touched since it was provisioned, and reads as one.
          Text {
            width: parent.width
            visible: root.routeKind === "events" && root.rows.length === 0
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: root.eventsError !== "" ? root.badColor : root.foreground
            opacity: root.eventsError !== "" ? 0.9 : 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: root.eventsLoading ? "Fetching events…"
              : root.eventsError !== "" ? root.eventsError
              : "No events recorded for this server."
          }
        }
      }

      // Outside the Flickable, and pinned. It used to be the last thing in the
      // scrolling Column, which meant a server with a lot of sites pushed it
      // off the bottom — so the one line that says what the row under the
      // cursor can do was hidden exactly when the list was long enough to need
      // it. The scroll bar stops at its top now too.
      Column {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(12)

        PanelSeparator {
          foreground: root.foreground
          visible: statusLine.visible || hints.visible
        }

        Text {
          id: statusLine
          width: parent.width
          visible: text !== ""
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: root.problems.length > 0 && root.flash === "" ? root.urgent : root.foreground
          opacity: root.problems.length > 0 && root.flash === "" ? 0.9 : 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          text: {
            if (root.flash !== "") return root.flash
            if (root.problems.length > 0) return root.problems.join(" · ")
            for (var i = 0; i < root.organizations.length; i++) {
              var note = root.stateFor(root.organizations[i]).note
              if (note !== "") return note
            }
            return ""
          }
        }

        Text {
          id: hints
          width: parent.width
          // The feed keeps its footer while empty: `[h] back` is the one key
          // that matters on a list that is still loading or came back refused.
          visible: root.rows.length > 0 || root.paneRoute || root.routeKind === "events"
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          // Derived on the root, where the cursor is — see `hintText`.
          text: root.hintText
        }
      }
    }
  }
}
