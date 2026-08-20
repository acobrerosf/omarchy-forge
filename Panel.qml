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
  // servers and sites without caring which is which.
  readonly property var rows: {
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

  function siteFor(row) {
    if (!row || row.kind !== "site") return null
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

  function currentRow() { return rowAt(cursorIndex) }
  function currentServer() {
    var row = currentRow()
    return row && row.kind !== "org" ? serverById(row.org, row.serverId) : null
  }
  function currentSite() { return siteFor(currentRow()) }

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

  function activate() {
    var row = currentRow()
    if (!row) return
    if (row.kind === "org") {
      setOrgExpanded(row.org, !isOrgExpanded(row.org))
      return
    }
    if (row.kind === "server") {
      setExpanded(row.org, row.serverId, !isExpanded(row.org, row.serverId))
      return
    }
    deployCurrent()
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
    else { disarm(); cursorActive = false }
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
    function status(): string { return summary }
  }

  // ------------------------------------------------------------- bar button

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Forge — " + summary

    iconComponent: Component {
      Item {
        ForgeIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: health === "setup" ? Qt.darker(button.bar ? button.bar.barForeground : root.foreground, 1.6)
                                          : (button.bar ? button.bar.barForeground : root.foreground)
          badgeColor: health === "busy" ? Color.accent : root.urgent
          badge: {
            switch (health) {
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx) }
      // Enter raises returnRequested AND activateRequested; space raises only
      // activateRequested. Handling both would run the action twice — which
      // would arm a deploy and immediately send it, skipping the confirm.
      onActivateRequested: root.activate()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
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

          PanelHero {
            width: parent.width
            title: root.organizations.length === 1 ? root.orgLabel(root.organizations[0]) : "Forge"
            meta: summary
            detail: root.refreshing ? "refreshing…"
                                    : Model.relativeMs(root.lastRefreshMs, root.nowMs)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              ForgeIcon {
                iconSize: Style.font.display
                color: root.foreground
                badgeColor: health === "busy" ? root.busyColor : root.urgent
                badge: health === "bad" ? "bad"
                     : health === "busy" ? "busy"
                     : (health === "setup" || health === "error") ? "warn" : "none"
              }
            }
          }

          // ------------------------------------------------------- setup

          Column {
            width: parent.width
            spacing: Style.space(10)
            // What is missing is only known once the helper's state file has
            // been read, so say nothing until then rather than guess.
            visible: tokenKnown && (needsSetup || root.organizations.length === 0)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: needsSetup
                ? "No Forge API token on this machine yet. Setup stores one in your keyring."
                : "No organizations are being watched yet."
            }

            Button {
              width: parent.width
              text: needsSetup ? "Set up Forge" : "Add an organization"
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
              text: root.showOrgHeaders ? "ORGANIZATIONS" : "SERVERS"
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

          // -------------------------------------------------------- empty

          Text {
            width: parent.width
            visible: root.rows.length === 0 && root.organizations.length > 0 && !needsSetup
            wrapMode: Text.WordWrap
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
            visible: root.rows.length > 0
            wrapMode: Text.WordWrap
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: "[enter] expand · [d] deploy · [o] open · [f] forge · [s] copy ssh · [r] refresh · [a] add org"
          }
        }
      }
    }
  }
}
