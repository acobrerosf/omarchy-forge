import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Everything that talks to Forge, for the whole session: polling, scheduling,
// the rate ledger, the request queue, deploys and notifications. One instance
// per session, whatever the monitor count. Panels subscribe and read state
// back out. Every request shells out to the bundled helper, so no token ever
// reaches this process. See ARCHITECTURE.md.
Item {
  id: root

  // Injected by the shell when it loads a service plugin.
  property var shell: null

  // --------------------------------------------------------------- setup

  // The accounts and the organizations they reach, as the helper recorded
  // them. Read-only here: `omarchy-forge add` is what writes this.
  property var setup: Model.emptySetup()
  readonly property string defaultOrganization: setup.defaultOrganization
  readonly property var watchedOrganizations: setup.organizationList

  // False until the state file has been read, so a panel doesn't announce
  // which half of setup is missing before anything is known.
  property bool tokenKnown: false

  // No credential on this machine at all. Known from the state file without a
  // request, and confirmed by any account whose token turns out to be gone.
  readonly property bool needsSetup: {
    var names = Object.keys(setup.accounts)
    if (names.length === 0) return true
    for (var i = 0; i < names.length; i++)
      if (accountState(names[i]).hasToken !== false) return false
    return true
  }

  property string deployingSiteKey: ""

  signal deployFinished(string siteKey, bool ok, string message)

  readonly property string pluginDir: String(Qt.resolvedUrl("."))
    .replace(/^file:\/\//, "")
    .replace(/\/$/, "")
  readonly property string cliPath: pluginDir + "/omarchy-forge"
  readonly property string statePath:
    (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/omarchy/forge.json"

  // ------------------------------------------------------- account state

  // Whether a token is there and whether Forge accepts it are facts about an
  // account, not about an organization, so three orgs behind one bad token
  // report one problem. See ARCHITECTURE.md.
  //
  // name → {hasToken: bool|undefined, rateRemaining: int, error: string}
  property var accountStates: ({})

  function accountState(name) {
    return accountStates[String(name)]
      || ({ hasToken: undefined, rateRemaining: -1, error: "" })
  }

  function accountLabel(name) {
    var entry = setup.accounts[String(name)]
    return entry && entry.label ? entry.label : String(name)
  }

  function _patchAccount(name, changes) {
    if (!name) return
    var key = String(name)
    var updated = _shallowCopy(accountState(key))
    var dirty = false
    for (var field in changes) {
      if (updated[field] === changes[field]) continue
      updated[field] = changes[field]
      dirty = true
    }
    if (!dirty) return
    var next = _shallowCopy(accountStates)
    next[key] = updated
    accountStates = next
  }

  function accountForOrg(org) {
    return Model.accountForOrg(setup, org, "default")
  }

  // ---------------------------------------------------------------- watchers

  // Watcher id → what that panel asked for. Panels come and go with monitors
  // and with config reloads, so subscriptions are keyed by an issued token
  // rather than by anything the panel might not keep stable.
  property var _watchers: ({})
  property int _nextWatcherId: 0

  // Organization → the merged demands of everyone watching it.
  property var _config: ({})
  // Organization → state, the shape panels read.
  property var orgs: ({})

  function subscribe(config) {
    _nextWatcherId += 1
    var id = "w" + _nextWatcherId
    var next = _shallowCopy(_watchers)
    next[id] = _normalizeConfig(config)
    _watchers = next
    _reconcile()
    return id
  }

  function update(id, config) {
    if (!id || !_watchers[id]) return
    var next = _shallowCopy(_watchers)
    next[id] = _normalizeConfig(config)
    _watchers = next
    _reconcile()
  }

  function unsubscribe(id) {
    if (!id || !_watchers[id]) return
    var next = ({})
    for (var key in _watchers) if (key !== id) next[key] = _watchers[key]
    _watchers = next
    _reconcile()
  }

  // Panels hand over whatever sits in their shell.json entry, which a user may
  // well have typed as a string, so coercion belongs here rather than in every
  // panel.
  function _normalizeConfig(config) {
    var c = config || {}
    var interval = parseInt(String(c.refreshIntervalSec), 10)
    if (!isFinite(interval)) interval = 60

    var wanted = []
    var raw = c.organizations
    if (raw !== undefined && raw !== null) {
      var list = Array.isArray(raw) ? raw : [raw]
      for (var i = 0; i < list.length; i++) {
        var org = String(list[i] || "")
        if (org !== "" && wanted.indexOf(org) === -1) wanted.push(org)
      }
    }

    return {
      organizations: wanted,
      refreshIntervalSec: Math.max(15, Math.min(3600, interval)),
      watchDeployments: _bool(c.watchDeployments, true),
      notifyDeployments: _bool(c.notifyDeployments, true)
    }
  }

  function _bool(value, fallback) {
    if (value === undefined || value === null) return fallback
    if (typeof value === "boolean") return value
    var text = String(value).toLowerCase()
    if (text === "true" || text === "on" || text === "1") return true
    if (text === "false" || text === "off" || text === "0") return false
    return fallback
  }

  // Rebuild the merged per-organization demands and the set of organizations
  // being polled. Every subscription change funnels through here, and so does
  // every change to the state file, since that is what decides which account
  // an organization is reached through.
  function _reconcile() {
    var merged = ({})
    for (var id in _watchers) {
      var w = _watchers[id]
      for (var i = 0; i < w.organizations.length; i++) {
        var org = w.organizations[i]
        var m = merged[org]
        if (!m) {
          merged[org] = {
            refreshIntervalSec: w.refreshIntervalSec,
            watchDeployments: w.watchDeployments,
            notifyDeployments: w.notifyDeployments
          }
        } else {
          // The most demanding watcher wins: nobody should be handed staler
          // data than they asked for because someone else asked for less.
          m.refreshIntervalSec = Math.min(m.refreshIntervalSec, w.refreshIntervalSec)
          m.watchDeployments = m.watchDeployments || w.watchDeployments
          m.notifyDeployments = m.notifyDeployments || w.notifyDeployments
        }
      }
    }
    _config = merged

    var nextOrgs = ({})
    for (var slug in merged) {
      var state = orgs[slug] || Model.emptyState()
      var account = accountForOrg(slug)
      if (state.account !== account) {
        state = _shallowCopy(state)
        state.account = account
        // The old account's verdict says nothing about the new one — and
        // neither does a site walk started under its credential.
        state.accountError = ""
        state.nextDueMs = 0
        state.siteCursor = ""
        state.sweepSites = []
      }
      nextOrgs[slug] = state
    }
    orgs = nextOrgs

    queue.keepOrgs(merged)

    _tick()
  }

  function _shallowCopy(source) {
    var out = ({})
    for (var key in source) out[key] = source[key]
    return out
  }

  // Panels bind to these, so state has to be replaced rather than mutated —
  // QML only notices a `var` property when it is assigned.
  function _patch(org, changes) {
    var current = orgs[org]
    if (!current) return
    var updated = _shallowCopy(current)
    for (var key in changes) updated[key] = changes[key]
    var next = _shallowCopy(orgs)
    next[org] = updated
    orgs = next
  }

  // ------------------------------------------------------------------ reads

  function stateFor(org) {
    return orgs[String(org)] || Model.emptyState()
  }

  function sitesFor(org, serverId) {
    var state = orgs[String(org)]
    var list = state ? state.sitesByServer[String(serverId)] : null
    return list ? list : []
  }

  function serverById(org, id) {
    var state = orgs[String(org)]
    if (!state) return null
    for (var i = 0; i < state.servers.length; i++)
      if (state.servers[i].id === String(id)) return state.servers[i]
    return null
  }

  function allSites(org) {
    var out = []
    var state = orgs[String(org)]
    if (!state) return out
    for (var i = 0; i < state.servers.length; i++) {
      var list = state.sitesByServer[state.servers[i].id]
      if (list) for (var j = 0; j < list.length; j++) out.push(list[j])
    }
    return out
  }

  function serverCount(org) {
    var state = orgs[String(org)]
    return state ? state.servers.length : 0
  }

  // Aggregate health, in the order the bar cares about it: a broken thing
  // outranks a busy thing, which outranks a quiet one.
  function healthFor(org) {
    var key = String(org)
    if (key === "") return "setup"
    var state = orgs[key]
    if (!state) return "setup"
    if (state.accountError !== "") return "setup"
    if (state.lastError !== "") return "error"
    for (var i = 0; i < state.servers.length; i++)
      if (Model.serverTone(state.servers[i].state) === "bad") return "bad"
    var busy = false
    var all = allSites(key)
    for (var j = 0; j < all.length; j++) {
      var tone = Model.deploymentTone(all[j].deploymentStatus)
      if (tone === "bad") return "bad"
      if (tone === "busy") busy = true
    }
    return busy ? "busy" : "ok"
  }

  function _healthRank(health) {
    switch (health) {
    case "bad": return 4
    case "error": return 3
    case "setup": return 2
    case "busy": return 1
    }
    return 0
  }

  // One bar icon stands for every organization the widget shows, so the worst
  // thing among them is what it has to report.
  function healthForList(list) {
    if (needsSetup) return "setup"
    if (!list || list.length === 0) return "setup"
    var worst = "ok"
    for (var i = 0; i < list.length; i++) {
      var health = healthFor(list[i])
      if (_healthRank(health) > _healthRank(worst)) worst = health
    }
    return worst
  }

  function summaryFor(org) {
    var key = String(org)
    if (key === "") return "Not set up"
    var state = orgs[key]
    if (!state) return "Loading…"
    if (state.accountError !== "") return state.accountError
    if (state.servers.length === 0) return state.refreshing ? "Loading…" : "No servers"
    var text = Model.pluralize(state.servers.length, "server")
    var config = _config[key]
    var count = allSites(key).length
    if (config && config.watchDeployments && count > 0)
      text += " · " + Model.pluralize(count, "site")
    return text
  }

  function summaryForList(list) {
    if (!list || list.length === 0)
      return needsSetup ? "No API token" : "Nothing watched"
    if (list.length === 1) return summaryFor(list[0])

    var servers = 0
    var sites = 0
    var loading = false
    var watchingSites = false
    for (var i = 0; i < list.length; i++) {
      var state = orgs[list[i]]
      if (!state) { loading = true; continue }
      if (state.refreshing && state.servers.length === 0) loading = true
      servers += state.servers.length
      sites += allSites(list[i]).length
      var config = _config[list[i]]
      if (config && config.watchDeployments) watchingSites = true
    }
    if (servers === 0 && loading) return "Loading…"

    var text = Model.pluralize(list.length, "org") + " · " + Model.pluralize(servers, "server")
    if (watchingSites && sites > 0) text += " · " + Model.pluralize(sites, "site")
    return text
  }

  // ------------------------------------------------------------ rate budget

  // Forge's 60-a-minute is per Forge user, so the ledger is keyed by the
  // identity behind an account rather than by the account. The ceiling is the
  // margin that decides when a sweep gets dropped. See ARCHITECTURE.md.
  QtObject {
    id: budget

    readonly property int ceiling: 40

    // bucket → [request timestamps]. Nothing outside this object reads it, so
    // unlike the state panels bind to it is mutated rather than reassigned.
    property var _spentAt: ({})

    function bucketFor(account) {
      return Model.budgetBucket(root.setup, account)
    }

    function spent(bucket) {
      var now = Date.now()
      var times = _spentAt[bucket] || []
      var kept = []
      for (var i = 0; i < times.length; i++)
        if (now - times[i] < 60000) kept.push(times[i])
      _spentAt[bucket] = kept
      return kept.length
    }

    // Whether `count` more requests for this account would breach the ceiling.
    function wouldExceed(account, count) {
      return spent(bucketFor(account)) + count > ceiling
    }

    function charge(bucket) {
      var times = _spentAt[bucket] || (_spentAt[bucket] = [])
      times.push(Date.now())
    }

    // A request that never left the machine — no token to send it with —
    // should not eat into the minute's allowance.
    function refund(bucket) {
      var times = _spentAt[bucket]
      if (times && times.length > 0) times.pop()
    }

    // bucket → the moment it may be used again. The ledger above only counts
    // what this process spent, so a 429 means something else on the same Forge
    // user burnt the minute — a browser tab, another script — and the hold has
    // to outrank the local count until Forge says otherwise.
    property var _blockedUntil: ({})

    function block(bucket, untilMs) {
      if (untilMs > (_blockedUntil[bucket] || 0)) _blockedUntil[bucket] = untilMs
    }

    // Milliseconds still to wait for this account's identity, 0 when clear.
    function blockedMs(account) {
      var left = (_blockedUntil[bucketFor(account)] || 0) - Date.now()
      return left > 0 ? left : 0
    }
  }

  // ------------------------------------------------------------------ queue

  // The pending list, and nothing else — dispatch policy lives in `_pump`,
  // which needs to see the whole service. See ARCHITECTURE.md.
  QtObject {
    id: queue

    // Mutated in place. Nothing may bind to this — a binding would not
    // re-evaluate on a push, which is exactly the trap `_patch` exists to
    // avoid for the state panels do bind to.
    property var _jobs: []

    function push(job) {
      _jobs.push(job)
      root._pump()
    }

    // A continuation page belongs to a fetch that is already under way, so it
    // goes in front of whatever is queued behind it — not least the
    // `sweepDone` marker, which would otherwise fire on a half-walked sweep
    // and publish it.
    function pushFront(job) {
      _jobs.unshift(job)
      root._pump()
    }

    function take() {
      return _jobs.length > 0 ? _jobs.shift() : null
    }

    // The one filter. What counts as work worth throwing away is the service's
    // judgement, so it arrives as a predicate rather than as knowledge here.
    function drop(shouldDrop) {
      var kept = []
      for (var i = 0; i < _jobs.length; i++)
        if (!shouldDrop(_jobs[i])) kept.push(_jobs[i])
      _jobs = kept
    }

    // Work queued for an organization nobody watches any more is spend with no
    // reader.
    function keepOrgs(wanted) {
      drop(function (job) { return wanted[job.org] === undefined })
    }

    // Whether anything queued matches — the on-demand fetch's dedupe reads it.
    function contains(matches) {
      for (var i = 0; i < _jobs.length; i++)
        if (matches(_jobs[i])) return true
      return false
    }
  }

  // The request in flight, which pairs with fetchProcess and its watchdog
  // rather than with the pending list.
  property var _current: null
  property double _currentStartedMs: 0
  property bool _timedOut: false
  // When each server's on-demand fetch last went out (org "/" serverId → ms):
  // the debounce behind `fetchServerSites`. Reassigned, never mutated, since
  // a guard reads it while a copy may be under way.
  property var _serverSitesAskedAt: ({})
  // The helper gives curl 15 seconds of its own, so anything still running
  // well past that is stuck rather than slow.
  readonly property int requestTimeoutMs: 25000

  // One request at a time for the whole session, so two organizations coming
  // due together interleave rather than racing.
  function _pump() {
    if (fetchProcess.running) return
    var job
    while ((job = queue.take()) !== null) {
      // A marker rather than a request: it runs the moment every site fetch
      // ahead of it has landed, whichever organizations interleaved. Its one
      // job is closing the refresh — including one whose sites request errored
      // and answered nothing.
      if (job.kind === "sweepDone") { _finishRefresh(job.org); continue }
      if (!orgs[job.org]) continue

      _current = job
      _currentStartedMs = Date.now()
      budget.charge(budget.bucketFor(job.account))
      fetchProcess.command = [cliPath, "api", "--account", job.account, "GET", _pathFor(job)]
      fetchProcess.running = true
      return
    }
  }

  function _pathFor(job) {
    if (job.kind === "servers") return Model.serversPath(job.org, job.cursor)
    if (job.kind === "serverSites")
      return Model.serverSitesPath(job.org, job.serverId, job.cursor)
    return Model.sitesPath(job.org, job.cursor)
  }

  // ------------------------------------------------------------- pagination

  // A cursor chain is stopped by a page cap or by the budget ceiling, and a
  // list cut short always leaves a note — a short list that doesn't say so is
  // indistinguishable from a complete one. The ceiling applies to
  // continuations only, so the first page always lands. See ARCHITECTURE.md.

  // 5 pages is 150 rows — per chain, per tick. For the server list that is
  // still the coverage limit: past it, an organization is being used in a way
  // a bar widget is the wrong shape for. For the org site list it only sizes
  // the window — the cursor persists in org state, so coverage is the whole
  // organization, one rotation window per tick.
  readonly property int maxPages: 5

  // "next" when another page was queued, "" when the list is complete, and
  // otherwise why it was cut short. The caller words the note, because a cap
  // is a hard stop for the server chain but merely "resumes next tick" for
  // the rotating site chain.
  function _continuePage(job, envelope, rows) {
    var cursor = Model.nextCursor(envelope.body)
    if (cursor === "") return ""
    if (job.page >= maxPages) return "cap"
    if (budget.wouldExceed(job.account, 1)) return "budget"

    var next = _shallowCopy(job)
    next.cursor = cursor
    next.page = job.page + 1
    next.rows = rows
    queue.pushFront(next)
    return "next"
  }

  // Notes are cleared at the start of every refresh, so they accumulate across
  // one cycle rather than overwriting each other: a sweep that was skipped and
  // a list that was cut short are two separate things the user has to be told.
  function _addNote(org, text) {
    var state = orgs[org]
    if (!state) return
    if (state.note === "") { _patch(org, { note: text }); return }
    if (state.note.indexOf(text) !== -1) return
    _patch(org, { note: state.note + " · " + text })
  }

  // -------------------------------------------------------------- refreshing

  function refresh(org) {
    var key = String(org)
    var state = orgs[key]
    if (!state || state.refreshing) return
    // The one gate every refresh passes through — the ticker, the CLI, a middle
    // click, and the short look-again after a deploy. `nextDueMs` alone could
    // not hold them: `_reconcile` zeroes it whenever the state file changes.
    // The 429 already left its word in `lastError`, so this says nothing new.
    if (budget.blockedMs(state.account || accountForOrg(key)) > 0) return
    _patch(key, { refreshing: true, note: "" })
    queue.push({ org: key, account: state.account || accountForOrg(key),
                 kind: "servers", page: 1, rows: [] })
  }

  function refreshList(list) {
    if (!list) return
    for (var i = 0; i < list.length; i++) refresh(list[i])
  }

  function _isMissingToken(envelope) {
    return envelope.status === 0
      && String(envelope.error || "").indexOf("No API token") !== -1
  }

  function _applyEnvelope(org, account, envelope) {
    tokenKnown = true

    var changes = ({})
    if (envelope.rateRemaining !== null && envelope.rateRemaining !== undefined)
      changes.rateRemaining = Number(envelope.rateRemaining)

    if (envelope.ok) {
      changes.hasToken = true
      changes.error = ""
      _patchAccount(account, changes)
      if (org) _patch(org, { lastError: "", accountError: "" })
      return true
    }

    if (_isMissingToken(envelope)) {
      changes.hasToken = false
      changes.error = ""
      _patchAccount(account, changes)
      budget.refund(budget.bucketFor(account))
      if (org)
        _patch(org, { lastError: "",
                      accountError: "No token for " + accountLabel(account) })
      return false
    }

    // Being refused for the minute is the whole Forge identity's problem, and
    // every organization behind it has to stop rather than take turns being
    // told no. This is the choke point every response passes through, so one
    // branch covers the server list, the sweep and a deploy alike.
    if (envelope.status === 429) {
      changes.hasToken = true
      _patchAccount(account, changes)
      _holdAccount(account, envelope)
      return false
    }

    // A rejected token is the account's problem too, and worth saying once
    // rather than once per organization behind it.
    if (envelope.status === 401 || envelope.status === 403) {
      changes.hasToken = true
      changes.error = Model.envelopeError(envelope)
    }
    _patchAccount(account, changes)
    // Getting an answer at all — even a bad one — settles the question of
    // whether there is a token. Leaving a stale "no token" in place would
    // outrank the real error and keep saying it long after the token was
    // restored, for as long as anything else kept going wrong.
    if (org) _patch(org, { lastError: Model.envelopeError(envelope), accountError: "" })
    return false
  }

  // Everything already queued for this identity would land inside the same
  // closed minute, so it is thrown away rather than sent — and with it go the
  // `sweepDone` markers that would have ended those refreshes, which is why
  // each one is ended here instead.
  function _holdAccount(account, envelope) {
    var bucket = budget.bucketFor(account)
    budget.block(bucket, Model.backoffUntilMs(envelope, Date.now()))
    queue.drop(function (job) { return budget.bucketFor(job.account) === bucket })

    var message = Model.envelopeError(envelope)
    for (var org in _config) {
      var state = orgs[org]
      if (!state) continue
      if (budget.bucketFor(state.account || accountForOrg(org)) !== bucket) continue
      // `lastError`, not `accountError`: an account-level verdict blanks the
      // server list further down, and the bar icon judges what it can see.
      // The site walk starts over after the hold — its dropped continuation
      // was the only thing that could have advanced the cursor.
      _patch(org, { lastError: message, accountError: "",
                    siteCursor: "", sweepSites: [] })
      if (state.refreshing) _finishRefresh(org)
    }
  }

  function _onServers(job, text) {
    var org = job.org
    var envelope = Model.parseEnvelope(text)
    if (!orgs[org]) return

    if (!_applyEnvelope(org, job.account, envelope)) {
      if (orgs[org].accountError !== "")
        // An account that can no longer see the servers can't vouch for a
        // half-walked rotation either, so that starts over with it.
        _patch(org, { servers: [], sitesByServer: ({}),
                      siteCursor: "", sweepSites: [] })
      _finishRefresh(org)
      return
    }

    var servers = job.rows.concat(Model.serversFrom(envelope.body))
    var more = _continuePage(job, envelope, servers)
    if (more === "next") return
    if (more === "cap")
      _addNote(org, "Showing the first " + Model.pluralize(servers.length, "server"))
    else if (more === "budget")
      _addNote(org, "Server list cut short to stay inside the rate limit")

    // Sites belonging to a server that has disappeared would linger forever.
    var kept = Model.mergeSitesByServer(orgs[org].sitesByServer, [], servers)

    _patch(org, { servers: servers, sitesByServer: kept, lastRefreshMs: Date.now() })
    _startSweep(org)
  }

  // One request chain for the organization's whole site list, not one per
  // server — and for a large organization, one *window* of that list per tick:
  // `siteCursor` carries the walk across ticks and wraps around, so every site
  // is reached without any single tick paying for more than a window. Sites
  // arrive flat and are grouped when the chain ends, so a server that is not
  // `ready` gets its sites too — a site on an unreachable server is exactly
  // what is worth seeing.
  function _startSweep(org) {
    var config = _config[org]
    if (!config || !config.watchDeployments) { _finishRefresh(org); return }

    // Nothing to group the answer under, so there is nothing to ask for.
    if (orgs[org].servers.length === 0) { _finishRefresh(org); return }

    var account = orgs[org].account || accountForOrg(org)
    if (budget.wouldExceed(account, 1)) {
      _addNote(org, "Deployment check skipped to stay inside the rate limit")
      _finishRefresh(org)
      return
    }

    // `fresh` marks a walk starting over — it is what empties the previous
    // rotation's accumulation, and it rides `_continuePage`'s copy onto every
    // continuation of this chain.
    queue.push({ org: org, account: account, kind: "sites", page: 1, rows: [],
                 cursor: orgs[org].siteCursor, fresh: orgs[org].siteCursor === "" })
    queue.push({ org: org, account: account, kind: "sweepDone" })
  }

  // The whole window lands in one patch — publishing pages as they arrive
  // would make a panel's row list shuffle under the cursor — and how it lands
  // depends on how the chain ended. A wrap (no next cursor) is the full
  // picture and replaces everything, which is what lets a server that
  // genuinely lost its last site go empty. A window cut short updates only
  // the sites it observed and leaves every other server exactly as it was:
  // the org list is not grouped by server, so anything more would delete
  // sites the window simply never reached. See ARCHITECTURE.md.
  function _onSites(job, text) {
    var envelope = Model.parseEnvelope(text)
    if (!orgs[job.org]) return
    if (!_applyEnvelope(job.org, job.account, envelope)) {
      // The cursor may be the very thing that failed, so the walk restarts
      // from page 1 next tick. What is on screen stays exactly as it was, and
      // the sweepDone marker closes the refresh.
      _patch(job.org, { siteCursor: "", sweepSites: [] })
      return
    }

    var pageRows = Model.sitesFrom(envelope.body)
    if (Model.sitesLinkageMissing(envelope.body, pageRows)) {
      // Publishing this as-is would show an empty organization under a
      // healthy icon — the exact silence the linkage check exists to break.
      _patch(job.org, { lastError: "Site list arrived without server links — check the token's scopes",
                        siteCursor: "", sweepSites: [] })
      return
    }

    var sites = job.rows.concat(pageRows)
    var more = _continuePage(job, envelope, sites)
    if (more === "next") return

    // `_applyEnvelope` patched, so the state in hand must be re-read.
    var state = orgs[job.org]
    var swept = Model.mergeSweepSites(job.fresh ? [] : state.sweepSites, sites)

    if (more === "") {
      var grouped = Model.groupSitesByServer(swept, state.servers)
      _patch(job.org, { sitesByServer: grouped, siteCursor: "", sweepSites: [],
                        lastStatus: _announce(job.org, sites, grouped, state, true),
                        seeded: true })
      return
    }

    // "cap" or "budget": the window ended mid-list, and the kept cursor
    // carries the walk into the next tick.
    var merged = Model.mergeSitesByServer(state.sitesByServer, sites, state.servers)
    _patch(job.org, { sitesByServer: merged,
                      siteCursor: Model.nextCursor(envelope.body),
                      sweepSites: swept,
                      lastStatus: _announce(job.org, sites, merged, state, false),
                      seeded: true })
    if (more === "budget")
      _addNote(job.org, "Site check paused to stay inside the rate limit — it resumes next refresh")
    else
      _addNote(job.org, "Deployments checked in rotation — "
               + Model.pluralize(Model.countSites(merged), "site") + " watched")
  }

  // The rotation keeps every row honest eventually; this makes an *opened* row
  // honest now, through the per-server list that is complete for exactly that
  // server. The guards are what keep a held key or the panel's auto-unfold
  // from turning one gesture into a request per sweep — and `force` (the
  // post-deploy look) bypasses only the debounce, never the budget or a hold.
  function fetchServerSites(org, serverId, force) {
    var key = String(org)
    var state = orgs[key]
    if (!state) return
    var config = _config[key]
    if (!config || !config.watchDeployments) return

    var account = state.account || accountForOrg(key)
    if (budget.blockedMs(account) > 0) return
    if (budget.wouldExceed(account, 1)) return

    var id = String(serverId)
    var stamp = key + "/" + id
    if (!force && Date.now() - (_serverSitesAskedAt[stamp] || 0) < 15000) return
    var pending = function (job) {
      return job.kind === "serverSites" && job.org === key && job.serverId === id
    }
    if (queue.contains(pending) || (_current !== null && pending(_current))) return

    var asked = _shallowCopy(_serverSitesAskedAt)
    asked[stamp] = Date.now()
    _serverSitesAskedAt = asked
    queue.push({ org: key, account: account, kind: "serverSites",
                 serverId: id, page: 1, rows: [] })
  }

  function _onServerSites(job, text) {
    var envelope = Model.parseEnvelope(text)
    if (!orgs[job.org]) return
    // Nothing to close on failure: this job carries no marker and set no
    // `refreshing` flag — it belongs to a keypress, not to a tick.
    if (!_applyEnvelope(job.org, job.account, envelope)) return

    var sites = job.rows.concat(Model.sitesFrom(envelope.body))
    var more = _continuePage(job, envelope, sites)
    if (more === "next") return
    if (more === "cap")
      _addNote(job.org, "Showing the first " + Model.pluralize(sites.length, "site"))
    else if (more === "budget")
      _addNote(job.org, "Site list cut short to stay inside the rate limit")

    var state = orgs[job.org]
    var merged = Model.replaceServerSites(state.sitesByServer, job.serverId, sites, state.servers)
    _patch(job.org, {
      sitesByServer: merged,
      // Feeding the accumulation is load-bearing, not tidiness: a site fetched
      // here at a list position the rotation has already passed would
      // otherwise vanish at the wrap and flap back a rotation later.
      sweepSites: Model.mergeSweepSites(state.sweepSites, sites),
      lastStatus: _announce(job.org, sites, merged, state, false),
      seeded: true
    })
  }

  function _finishRefresh(org) {
    var state = orgs[org]
    var config = _config[org]
    var seconds = config ? config.refreshIntervalSec : 60
    var now = Date.now()
    // A hold on the account outlives the configured interval: coming back
    // before the minute resets only spends another refusal. Every path that
    // ends a refresh goes through here, so none of them can undercut it.
    var held = state ? budget.blockedMs(state.account || accountForOrg(org)) : 0
    _patch(org, { refreshing: false, nextDueMs: now + Math.max(seconds * 1000, held) })
  }

  // ----------------------------------------------------------- notifications

  // Deployment status per site key as of that site's *last observation* — a
  // rotation sees one window per tick, so an unobserved site keeps its last
  // word rather than losing it, and a key leaves the map only when `complete`
  // says the whole organization was seen. That retention is what lets a site
  // that briefly fell out of a window announce its next change exactly once
  // instead of never. Seeding on the first sweep matters: without it, every
  // already-failed site would announce itself the moment the shell starts.
  function _announce(org, observed, published, state, complete) {
    var next
    if (complete) {
      // The one place keys are pruned: a site absent from the full picture is
      // genuinely gone. Earlier windows already recorded their observations,
      // so nothing here re-announces.
      next = ({})
      for (var id in published) {
        var list = published[id]
        for (var i = 0; i < list.length; i++)
          next[list[i].key] = list[i].deploymentStatus
      }
    } else {
      next = _shallowCopy(state.lastStatus)
      for (var j = 0; j < observed.length; j++)
        next[observed[j].key] = observed[j].deploymentStatus
    }

    var notify = _config[org] ? _config[org].notifyDeployments : false
    if (!state.seeded || !notify) return next
    for (var k = 0; k < observed.length; k++) {
      var site = observed[k]
      // Dropped at grouping — a site the panel does not draw should not speak.
      if (!Model.hasKey(published, site.serverId)) continue
      var before = state.lastStatus[site.key]
      if (before === undefined || before === site.deploymentStatus) continue
      _notifyDeployment(org, site)
    }
    return next
  }

  function _notifyDeployment(org, site) {
    // Two organizations can hold sites with the same name, and a notification
    // arrives with no other context, so name the organization once there is
    // more than one in play.
    var where = Object.keys(_config).length > 1
      ? " · " + Model.orgLabel(setup, org) : ""
    var tone = Model.deploymentTone(site.deploymentStatus)
    if (tone === "bad")
      _notify("critical", "󰅚", site.name,
              "Deployment " + Model.deploymentLabel(site.deploymentStatus) + where, site.url)
    else if (tone === "ok" && String(site.deploymentStatus).toLowerCase() === "finished")
      _notify("low", "󰄬", site.name,
              "Deployed" + (site.commitHash ? " · " + site.commitHash : "") + where, site.url)
  }

  function _notify(urgency, glyph, headline, description, url) {
    var command = ["omarchy-notification-send", "--app-name", "Forge",
                   "-u", urgency, "-g", glyph]
    // Unlike every other command here, `--exec` is a shell *string* by contract:
    // the shell's notification service runs it through `bash -lc` on click. The
    // address came from the API, so it is validated on the way in and quoted on
    // the way out — neither one alone is load-bearing. See ARCHITECTURE.md.
    var safe = Model.externalUrl(url)
    if (safe)
      command = command.concat(["--exec",
                                "omarchy-launch-browser " + Util.shellQuote(safe)])
    // The address is not the only untrusted string in this argv: the headline is
    // site.name, and both positionals sit where two parsers read a leading `-`
    // as a flag. See Model.notifyText and ARCHITECTURE.md.
    //
    // Both guards apply here, and in this order. The toast is drawn by the
    // shell's own NotificationCard, which is the one Text in the shell that asks
    // for `Text.StyledText` — and StyledText renders `<img>`, so a name carrying
    // one is fetched on a toast the user never opened and which outlives a
    // restart. plainText has to run first: it can turn `<--exec…` into
    // `--exec…`, which is exactly what notifyText is there to strip.
    var scrub = function (text) { return Model.notifyText(Model.plainText(text)) }
    Quickshell.execDetached(command.concat([scrub(headline) || "Forge", scrub(description)]))
  }

  // --------------------------------------------------------------- deploying

  property string _deployOrg: ""
  property string _deployAccount: ""
  property string _deployServerId: ""

  function deploy(org, site) {
    if (!site || actionProcess.running || String(org) === "") return
    if (!Model.canDeploy(site)) return
    _deployOrg = String(org)
    _deployAccount = (orgs[_deployOrg] && orgs[_deployOrg].account)
      || accountForOrg(_deployOrg)
    // Sending it anyway would only earn another refusal and push the hold out
    // further, so say when it can be pressed again rather than spending it.
    var held = budget.blockedMs(_deployAccount)
    if (held > 0) {
      _deployOrg = ""
      _deployAccount = ""
      deployFinished(site.key, false,
                     "Rate limited — try again in " + Math.ceil(held / 1000) + "s")
      return
    }
    _deployServerId = String(site.serverId)
    deployingSiteKey = site.key
    budget.charge(budget.bucketFor(_deployAccount))
    actionProcess.command = [cliPath, "api", "--account", _deployAccount, "POST",
                             Model.deployPath(_deployOrg, site.serverId, site.id)]
    actionProcess.running = true
  }

  function _onAction(text) {
    var envelope = Model.parseEnvelope(text)
    var org = _deployOrg
    var account = _deployAccount
    var serverId = _deployServerId
    var key = deployingSiteKey
    deployingSiteKey = ""
    _deployOrg = ""
    _deployAccount = ""
    _deployServerId = ""

    if (_applyEnvelope(org, account, envelope)) {
      deployFinished(key, true, "Deployment queued")
      // Forge queues the deploy asynchronously, so the status only moves a
      // moment later. Look again shortly rather than making the user wait out
      // a whole refresh interval — and look at the deployed server directly:
      // under rotation the re-poll only advances the window, which for a
      // large organization will usually be looking somewhere else entirely.
      if (orgs[org]) {
        _patch(org, { nextDueMs: Date.now() + 6000 })
        fetchServerSites(org, serverId, true)
      }
    } else {
      deployFinished(key, false, Model.envelopeError(envelope))
    }
  }

  // ---------------------------------------------------------------- actions

  // An argv element, so no shell is involved — but omarchy-launch-browser hands
  // its arguments straight to the browser binary, where an address beginning
  // with `-` would read as a flag and a foreign scheme as something to open.
  function openInBrowser(url) {
    var safe = Model.externalUrl(url)
    if (!safe) return
    Quickshell.execDetached(["omarchy-launch-browser", safe])
  }

  function copyToClipboard(text) {
    if (!text) return
    Quickshell.execDetached(["bash", "-c",
      "printf %s \"$1\" | wl-copy", "wl-copy-helper", String(text)])
  }

  // ------------------------------------------------------------------ wiring

  // Which accounts exist, and which organization each is reached through, live
  // in the helper's state file so that `omarchy-forge add` can introduce a new
  // one without the shell being restarted or any bar config being edited.
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root._applySetup(text())
    onLoadFailed: root._applySetup("")
    onFileChanged: reload()
  }

  function _applySetup(text) {
    setup = Model.parseSetup(text)
    tokenKnown = true
    // An organization may have changed hands, and a newly added one has to
    // start being polled without waiting for a panel to notice.
    _reconcile()
  }

  // One ticker for every organization rather than a timer each: intervals
  // differ per organization, and this keeps the scheduling in plain arithmetic
  // instead of dynamically created objects.
  Timer {
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root._tick()
  }

  function _tick() {
    var now = Date.now()
    for (var org in _config) {
      var state = orgs[org]
      if (!state || state.refreshing || now < state.nextDueMs) continue
      refresh(org)
    }
  }

  // A hung helper would otherwise pin the queue forever, since every start is
  // guarded on `running`. Only a request that has actually overrun is killed:
  // a fixed ticker that aborted whatever happened to be in flight when it fired
  // would cut healthy requests off at random, and an aborted request comes back
  // as an empty reply, which reads downstream as a malformed one.
  Timer {
    interval: 5000
    repeat: true
    running: fetchProcess.running
    onTriggered: {
      if (Date.now() - root._currentStartedMs < root.requestTimeoutMs) return
      root._timedOut = true
      fetchProcess.running = false
    }
  }

  Process {
    id: fetchProcess
    running: false
    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    onExited: {
      var job = root._current
      var text = String(fetchOut.text || "")
      if (root._timedOut) {
        root._timedOut = false
        text = JSON.stringify({ ok: false, status: 0, rateRemaining: null, rateReset: null,
                                body: null, error: "The Forge helper timed out" })
      }
      root._current = null
      if (job) {
        if (job.kind === "servers") root._onServers(job, text)
        else if (job.kind === "serverSites") root._onServerSites(job, text)
        else root._onSites(job, text)
      }
      root._pump()
    }
  }

  Process {
    id: actionProcess
    running: false
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    onExited: root._onAction(String(actionOut.text || ""))
  }
}
