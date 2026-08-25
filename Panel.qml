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
  // while its log is open should update the header behind it.
  readonly property var routeSite: route ? siteFor(route) : null

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
  // Deploying is the one action here that changes something on a real server,
  // so it takes two presses: the first arms the row, the second sends it.
  property string armedSiteKey: ""
  // The site this widget asked the service to deploy. The service's result is
  // session-wide, so without this every screen would flash the same message.
  property string deployRequestedKey: ""
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
  readonly property string deployingKey: forge ? String(forge.deployingSiteKey) : ""

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
    if (routeKind === "log") return []
    if (routeKind === "site") return actionRows

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

  // The site view's rows. Split out of `rows` so the tree's loop stays legible,
  // and so the actions are derived once per site rather than once per keypress.
  readonly property var actionRows: {
    var out = []
    if (routeKind !== "site") return out
    var actions = Model.siteActions(routeSite)
    for (var i = 0; i < actions.length; i++)
      out.push({ kind: "action", org: route.org, serverId: route.serverId,
                 siteId: route.siteId, action: actions[i],
                 siteKey: routeSite ? routeSite.key : "",
                 key: route.org + "/" + route.siteId + "/" + actions[i].id })
    return out
  }

  function pushView(view) {
    navStack = navStack.concat([view])
    cursorIndex = 0
    cursorActive = false
    disarm()
  }

  function popView() {
    if (navStack.length === 0) return false
    navStack = navStack.slice(0, navStack.length - 1)
    cursorIndex = 0
    cursorActive = false
    disarm()
    clearLog()
    return true
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
      return Model.rowView(row, { action: row.action, siteKey: row.siteKey })
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
    if (row.kind === "action") { runAction(row.action); return }
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
    if (row.kind === "server" && isExpanded(row.org, row.serverId)) return
    activate()
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

  // What the hero says about a site: the same two facts its row shows, since
  // the row it came from is no longer on screen to show them.
  function siteMeta(site) {
    var parts = []
    if (site.branch) parts.push(site.branch)
    if (site.commitHash) parts.push(site.commitHash)
    return parts.join(" · ")
  }

  function siteDetailLine(site) {
    var label = Model.deploymentLabel(site.deploymentStatus)
    var when = site.deployedAt ? Model.relativeTime(site.deployedAt, nowMs) : ""
    return when === "" ? label : label + " · " + when
  }

  // The badge follows whatever the hero is about, so in a site view it reports
  // that site rather than the health of everything being watched.
  readonly property string heroTone: {
    if (routeSite) {
      var tone = Model.deploymentTone(routeSite.deploymentStatus)
      return tone === "bad" ? "bad" : tone === "busy" ? "busy" : "none"
    }
    return health === "bad" ? "bad"
      : health === "busy" ? "busy"
      : (health === "setup" || health === "error") ? "warn" : "none"
  }

  readonly property var routeDetails: routeKind === "site" ? Model.siteDetails(routeSite) : []

  function indexOfRow(key) {
    for (var i = 0; i < rows.length; i++)
      if (rows[i].key === key) return i
    return cursorIndex
  }

  // One action from the site view. An unavailable one says why rather than
  // doing nothing — a key that appears to have missed is worse than a refusal.
  function runAction(action) {
    if (!action) return
    if (action.available === false) {
      say(String(action.label) + " — " + String(action.reason))
      return
    }
    switch (String(action.id)) {
    case "deploy": deployCurrent(); break
    case "log": openLog(); break
    case "open": openCurrent(); break
    case "forge": openCurrentInForge(); break
    case "ssh": copyCurrentSsh(); break
    }
  }

  function deployCurrent() {
    var row = currentRow()
    var site = currentSite()
    if (!site) return
    if (!Model.canDeploy(site)) {
      say(site.name + " has no repository to deploy")
      return
    }
    if (armedSiteKey !== site.key) {
      armedSiteKey = site.key
      disarmTimer.restart()
      return
    }
    disarm()
    if (!forge) return
    deployRequestedKey = site.key
    forge.deploy(row.org, site)
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

  // The two ways a log leaves this pane. Both take the text already on screen,
  // so neither costs a request — and both go out on stdin rather than in an
  // argv, because a verbose deploy can outgrow what an argument may hold.
  function copyLog() {
    if (logLines.length === 0 || !forge) return
    forge.copyToClipboard(logLines.join("\n") + "\n")
    say("Copied " + Model.pluralize(logLines.length, "line"))
  }

  function saveLog() {
    if (logLines.length === 0 || !forge || !route) return
    var site = routeSite
    // The file is named after the site, which is API data reaching a path.
    // `Model.logFileName` is what stops a site name being a separator.
    var name = Model.logFileName(site ? site.name : "", route.deploymentId)
    saveRequestedPath = forge.downloadDir() + "/" + name
    forge.saveText(logLines.join("\n") + "\n", saveRequestedPath)
  }

  function disarm() {
    armedSiteKey = ""
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

  onOpenedChanged: {
    if (opened) root.refresh()
    // Reopening lands on the tree. A view is where a train of thought was, and
    // resuming one from an hour ago mid-way is disorienting — the log behind
    // it is stale by then anyway.
    else { disarm(); cursorActive = false; navStack = []; clearLog() }
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

  // The deploy result is a session-wide signal, so only the widget that armed
  // it should speak up — otherwise every screen flashes the same message.
  Connections {
    target: root.forge
    enabled: root.forge !== null
    function onDeployFinished(siteKey, ok, message) {
      if (root.deployRequestedKey !== siteKey) return
      root.deployRequestedKey = ""
      root.say(message)
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

    // Saving is the one thing here that touches the filesystem, so where it
    // landed — or why it didn't — is worth saying rather than assuming.
    function onTextSaved(ok, path, message) {
      if (root.saveRequestedPath !== path) return
      root.saveRequestedPath = ""
      root.say(message)
    }
  }

  Timer {
    id: disarmTimer
    interval: 4000
    onTriggered: root.armedSiteKey = ""
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
    contentWidth: panel.fittedContentWidth(Style.space(root.routeKind === "log" ? 620 : 420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight,
                                             Style.space(root.routeKind === "log" ? 760 : 560))
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // `h j k l` never reach onTextKey — the catcher reads them as movement
      // before that — so the horizontal axis is where a tree key has to come
      // from. It cost nothing to take: until the site view existed, right and
      // `l` were a second way to press `j`.
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          if (root.routeKind === "log") logView.scrollBy(dy)
          else root.moveCursor(dy)
          return
        }
        if (dx > 0) root.drillIn()
        else if (dx < 0) root.back()
      }
      // Enter raises returnRequested AND activateRequested; space raises only
      // activateRequested. Handling both would run the action twice — which
      // would arm a deploy and immediately send it, skipping the confirm.
      onActivateRequested: if (root.routeKind !== "log") root.activate()
      // Out of the view first, out of the panel only from the tree.
      onCloseRequested: if (!root.back()) root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        // Before the fold to lower case, because these two are a pair that
        // only means anything while their case is intact.
        if (root.routeKind === "log") {
          if (text === "g") { logView.toTop(); return }
          if (text === "G") { logView.toEnd(); return }
          if (text === "c" || text === "C") { root.copyLog(); return }
          if (text === "w" || text === "W") { root.saveLog(); return }
        }
        switch (String(text).toLowerCase()) {
        case "r": root.refresh(); break
        case "o": root.openCurrent(); break
        case "f": root.openCurrentInForge(); break
        case "s": root.copyCurrentSsh(); break
        case "d": root.deployCurrent(); break
        case "a": root.launchSetup(); break
        }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

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
              if (root.showOrgHeaders && root.route) parts.push(root.orgLabel(root.route.org))
              var server = root.route ? root.serverById(root.route.org, root.route.serverId) : null
              if (server) parts.push(server.name)
              if (root.routeKind === "log" && root.routeSite) parts.push(root.routeSite.name)
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
            title: root.routeSite
              ? Model.plainText(root.routeSite.name)
              : root.organizations.length === 1
                ? Model.plainText(root.orgLabel(root.organizations[0])) : "Forge"
            meta: root.routeSite
              ? Model.plainText(root.siteMeta(root.routeSite))
              : Model.plainText(root.summary)
            detail: root.routeSite
              ? root.siteDetailLine(root.routeSite)
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

          // ------------------------------------------------------ servers

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.rows.length > 0

            PanelSectionHeader {
              text: root.routeKind === "site" ? "ACTIONS"
                : root.showOrgHeaders ? "ORGANIZATIONS" : "SERVERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
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
                showDot: rowItem.modelData.kind !== "action"
                expanded: rowItem.modelData.kind === "org"
                  ? root.isOrgExpanded(rowItem.modelData.org)
                  : root.isExpanded(rowItem.modelData.org, rowItem.modelData.serverId)

                // Bound separately rather than folded into `view`: these change
                // on their own clock, and re-deriving every row's text on a
                // cursor move or a tick would be wasted work.
                hasCursor: root.cursorActive && root.cursorIndex === rowItem.index
                armed: rowItem.view.siteKey !== ""
                  && root.armedSiteKey === rowItem.view.siteKey
                deploying: rowItem.view.siteKey !== ""
                  && root.deployingKey === rowItem.view.siteKey
                timeText: rowItem.view.deployedAt
                  ? Model.relativeTime(rowItem.view.deployedAt, root.nowMs) : ""

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
            visible: root.routeKind === "log"
            // An Item has no implicit height, and the card's height is this
            // column's. Asking for a screenful rather than measuring one:
            // `fittedContentHeight` clamps whatever it cannot fit, so this is
            // a request for as much as the screen will give.
            height: visible ? Style.space(460) : 0

            lines: root.logLines
            loading: root.logLoading
            error: root.logError

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

          // ------------------------------------------------------- footer

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
            visible: root.rows.length > 0 || root.routeKind === "log"
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            // Per view, because a list of every key in the plugin is a list
            // nobody reads. Each one names only what works where you are.
            text: root.routeKind === "log"
              ? "[j/k] scroll · [g/G] top/bottom · [c] copy · [w] save · [h] back"
              : root.routeKind === "site"
                ? "[enter] run · [h] back · [r] refresh"
                : "[enter] open · [d] deploy · [o] open · [f] forge · [s] copy ssh · [r] refresh · [a] add org"
          }
        }
      }
    }
  }
}
