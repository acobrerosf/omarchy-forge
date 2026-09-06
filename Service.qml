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

  // Which write is in flight, under the key the row that asked for it knows
  // itself by. One key for the whole session rather than a map, because
  // `actionProcess` is single-flight: a deploy and a reboot cannot both be on
  // their way.
  //
  // Derived rather than assigned beside `_action`: the job is the one home of
  // "a write is in flight", and a copy of its key was a second writer to keep
  // in step by hand. `_action` is reassigned and never mutated, so this fires.
  readonly property string busyActionKey: _action ? String(_action.key) : ""

  signal actionFinished(string key, bool ok, string message)

  // One signal for the three document panes — a deploy log, a site log, an
  // event's output. Each is a one-shot read whose answer belongs to the one
  // panel that asked, the same reason `actionFinished` is a signal and not
  // state, and each is tens of kilobytes, which is no business of a property
  // every panel re-reads. `requestKey` is organization-qualified so two panels,
  // or two organizations holding the same numeric ids, cannot cross-answer.
  //
  // One rather than three: the panel never has to ask which pane it is
  // answering. Only one pane is ever open, the three keys differ in shape, and
  // the wording a 403 earns — the scopes differ, and two of the three are
  // surprising — is chosen here, in the handler that saw the status, rather
  // than by a reader downstream trying to work out what it was given.
  signal documentFetched(string requestKey, bool ok, string text, string message)

  function logRequestKey(org, serverId, siteId, deploymentId) {
    return String(org) + "/" + String(serverId) + ":" + String(siteId)
      + "/" + String(deploymentId)
  }

  // A server's event feed, on the log's terms: one panel asked, the answer is
  // rows, and a refusal is always reported. The feed answers with the `cursor`
  // it was asked for — "" for the first page — so the panel knows whether what
  // arrived replaces its list or extends it, and with the `nextCursor` a
  // further page would need. The list rides a `var` because it is rows rather
  // than text; the panel reassigns what it gets and never mutates it. One
  // event's *output* is a document and answers `documentFetched`.
  signal serverEventsFetched(string requestKey, bool ok, var events, string cursor,
                             string nextCursor, string message)

  function eventsRequestKey(org, serverId) {
    return String(org) + "/" + String(serverId) + "/events"
  }

  function eventOutputRequestKey(org, serverId, eventId) {
    return String(org) + "/" + String(serverId) + "/events/" + String(eventId)
  }

  // A site's own log, which is the deploy log's road a third time — and lands
  // on `documentFetched` with it. The key has a different shape (a kind where
  // that one has a deployment id), which is what keeps a stale answer from
  // being mistaken for this one's.
  function siteLogRequestKey(org, serverId, siteId, kind) {
    return String(org) + "/" + String(serverId) + ":" + String(siteId)
      + "/logs/" + String(kind)
  }

  // A command run, on the same terms as the log and for the same reasons — one
  // panel asked, and the output is a document rather than a property. Unlike
  // the log it arrives more than once: the run is watched from `waiting`
  // through to a terminal state, and every look answers here, so the pane can
  // say what is happening rather than sitting on "fetching" for a minute.
  //
  // `running` is what separates "not finished yet" from "finished and printed
  // nothing", which are the same empty string otherwise.
  signal commandRunUpdated(string requestKey, bool ok, bool running,
                           string commandId, string header, string text,
                           string message)

  // The send time rather than the command id, because the id is not known
  // until the run has been found — see `Model.commandFrom`. It is the same
  // moment the panel used to open the pane, so both sides can name the key
  // without either having to hear it from the other.
  function commandRequestKey(org, serverId, siteId, sentAtMs) {
    return String(org) + "/" + String(serverId) + ":" + String(siteId)
      + "@" + String(sentAtMs)
  }

  // The organization's recipes, on the event feed's terms: a keypress asked,
  // the answer is rows, and a refusal is always reported. Keyed by the
  // organization alone — recipes are the organization's, not the server's, and
  // the same list opened from two of its servers is the same list.
  signal recipesFetched(string requestKey, bool ok, var recipes, string cursor,
                        string nextCursor, string message)

  function recipesRequestKey(org) {
    return String(org) + "/recipes"
  }

  // A recipe run is followed on `commandRunUpdated` rather than a signal of its
  // own: there is one watch slot for the session, and every field of that
  // signal fits — `commandId` carries the run log's id, `header` its state
  // line. What keeps the two apart is this key's shape, which no command key
  // can collide with. The send time again, for `commandRequestKey`'s reason.
  function recipeRequestKey(org, serverId, recipeId, sentAtMs) {
    return String(org) + "/" + String(serverId) + "/recipe:" + String(recipeId)
      + "@" + String(sentAtMs)
  }

  readonly property string pluginDir: String(Qt.resolvedUrl("."))
    .replace(/^file:\/\//, "")
    .replace(/\/$/, "")
  readonly property string cliPath: pluginDir + "/omarchy-forge"
  readonly property string statePath:
    (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/omarchy/forge.json"

  // ------------------------------------------------------- account state

  // Whether there is a token is a fact about an account, not about an
  // organization, so three orgs behind one missing token report one problem.
  // It is the *only* credential fact kept here: what Forge said about a token
  // it rejected is reported per organization, because a 403 on one
  // organization says nothing about the next. See ARCHITECTURE.md.
  //
  // name → {hasToken: bool|undefined}
  property var accountStates: ({})

  function accountState(name) {
    return accountStates[String(name)] || ({ hasToken: undefined })
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
        // The verdict follows the account by construction now, but a site walk
        // started under the old credential does not.
        state.nextDueMs = 0
        state.siteCursor = ""
        state.sweepSites = []
      }
      nextOrgs[slug] = state
    }
    orgs = nextOrgs

    // Work queued for an organization nobody watches any more is spend with no
    // reader — but a pane may be waiting on it, so it is answered on the way
    // out rather than dropped in silence.
    queue.drop(function (job) {
      if (merged[job.org] !== undefined) return false
      _abandonJob(job)
      return true
    })

    _tick()
  }

  // The one copy loop. Everything here that a panel can reach is replaced
  // rather than mutated — QML only notices a `var` property when it is assigned
  // — so this is the shape most of the state changes in this file take.
  function _merge(source, changes) {
    var out = ({})
    for (var key in source) out[key] = source[key]
    for (var change in changes) out[change] = changes[change]
    return out
  }

  function _shallowCopy(source) {
    return _merge(source, null)
  }

  // Panels bind to these, so state has to be replaced rather than mutated —
  // QML only notices a `var` property when it is assigned.
  function _patch(org, changes) {
    var current = orgs[org]
    if (!current) return
    var next = _shallowCopy(orgs)
    next[org] = _merge(current, changes)
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

  function serverCount(org) {
    var state = orgs[String(org)]
    return state ? state.servers.length : 0
  }

  // The organization's credential verdict, derived rather than stored. One
  // writer — `_applyEnvelope`, on the account — and one join key, `state.account`,
  // which only `_reconcile` writes. Kept as a sentence rather than a flag
  // because every reader wants the words: the panel prints it, `summaryFor`
  // stands in for the server count with it, and `healthFor` only asks whether
  // it is empty.
  function accountErrorFor(org) {
    var state = orgs[String(org)]
    if (!state) return ""
    return accountState(state.account).hasToken === false
      ? "No token for " + accountLabel(state.account) : ""
  }

  // Aggregate health for one organization, accumulated through the same rank
  // table the bar folds *across* organizations with. One precedence, one place:
  // written as early returns here and as a table there, the two disagreed at
  // the top — inside an organization `setup` and `error` outranked `bad`, and
  // across them `bad` outranked both, so the same facts drew a different badge
  // depending only on how they happened to be split between organizations.
  function healthFor(org) {
    var key = String(org)
    if (key === "") return "setup"
    var state = orgs[key]
    if (!state) return "setup"

    var worst = "ok"
    if (accountErrorFor(key) !== "") worst = _worseHealth(worst, "setup")
    if (state.lastError !== "") worst = _worseHealth(worst, "error")

    // `bad` is the top of the table, so the first one found is the answer and
    // there is nothing left to accumulate.
    for (var i = 0; i < state.servers.length; i++)
      if (Model.serverTone(state.servers[i].state) === "bad") return "bad"

    // Walked per server rather than through a flattened list: nothing else
    // wanted one, and the sites the panel draws are exactly these.
    for (var id in state.sitesByServer) {
      var sites = state.sitesByServer[id]
      for (var j = 0; j < sites.length; j++) {
        var tone = Model.siteTone(sites[j])
        if (tone === "bad") return "bad"
        // A site in maintenance three rows up must not hide a running deploy
        // further down, which is what the fold gives for free.
        if (tone === "busy") worst = _worseHealth(worst, "busy")
        else if (tone === "warn") worst = _worseHealth(worst, "maintenance")
      }
    }
    return worst
  }

  // The precedence, and the only one: inside an organization and across them.
  // `error` and `setup` sit *below* `bad` deliberately — a credential problem
  // or a failed request is a reason to look, a server or a deploy that has
  // actually broken is a reason to act, and the icon judges what it can see.
  function _healthRank(health) {
    switch (health) {
    case "bad": return 5
    case "error": return 4
    case "setup": return 3
    case "busy": return 2
    // Below busy: deliberate, and not a thing that has gone wrong.
    case "maintenance": return 1
    }
    return 0
  }

  function _worseHealth(worst, health) {
    return _healthRank(health) > _healthRank(worst) ? health : worst
  }

  // One bar icon stands for every organization the widget shows, so the worst
  // thing among them is what it has to report.
  function healthForList(list) {
    if (needsSetup) return "setup"
    if (!list || list.length === 0) return "setup"
    var worst = "ok"
    for (var i = 0; i < list.length; i++)
      worst = _worseHealth(worst, healthFor(list[i]))
    return worst
  }

  function summaryFor(org) {
    var key = String(org)
    if (key === "") return "Not set up"
    var state = orgs[key]
    if (!state) return "Loading…"
    var accountError = accountErrorFor(key)
    if (accountError !== "") return accountError
    if (state.servers.length === 0) return state.refreshing ? "Loading…" : "No servers"
    var text = Model.pluralize(state.servers.length, "server")
    var config = _config[key]
    var count = Model.countSites(state.sitesByServer)
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
      sites += Model.countSites(state.sitesByServer)
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

  // ------------------------------------------------------- on-demand reads

  // The five reads a keypress can ask for — a deploy log, a server's event
  // feed, one event's output, the organization's recipes, a site's own log —
  // share one road, because what makes them a group is not the repetition but
  // the rule: each has a pane or a view waiting on a signal, so every way a
  // request can fail to happen owes it an answer. The three functions below
  // are that rule in one place. A sixth read kind is complete when it has an
  // arm in each of them, a line in `_pathFor` and one in `onExited`.

  // The key the answer will carry, which is also what makes two asks for the
  // same thing the same ask. Each shape is the one its signal is filtered by
  // on the panel, so the dedupe and the answer cannot drift apart.
  function _readRequestKey(job) {
    if (job.kind === "log")
      return logRequestKey(job.org, job.serverId, job.siteId, job.deploymentId)
    if (job.kind === "events") return eventsRequestKey(job.org, job.serverId)
    if (job.kind === "eventOutput")
      return eventOutputRequestKey(job.org, job.serverId, job.eventId)
    if (job.kind === "recipes") return recipesRequestKey(job.org)
    if (job.kind === "siteLog")
      return siteLogRequestKey(job.org, job.serverId, job.siteId, job.log)
    return ""
  }

  // The registry every drop site consults: an entry guard, an unwatched
  // organization, a hold, an error on the wire. Answers `true` when it
  // recognised the kind, so a caller with kinds of its own — the run watch's,
  // which owe a different farewell — can tell whether it has been dealt with.
  function _readRefused(job, message) {
    if (job.kind === "log" || job.kind === "eventOutput" || job.kind === "siteLog") {
      documentFetched(_readRequestKey(job), false, "", message)
      return true
    }
    if (job.kind === "events") {
      serverEventsFetched(_readRequestKey(job), false, [],
                          String(job.cursor || ""), "", message)
      return true
    }
    if (job.kind === "recipes") {
      recipesFetched(_readRequestKey(job), false, [],
                     String(job.cursor || ""), "", message)
      return true
    }
    return false
  }

  // Queued or already on the wire. The one question every dedupe asks, asked
  // in one place because `_current` is as much a reason not to send again as
  // the queue is.
  function _outstanding(matches) {
    return queue.contains(matches) || (_current !== null && matches(_current))
  }

  // The guards every on-demand read passes, in the order that matters: an
  // organization that is gone, then the hold, then the ceiling, then whether
  // this is already on its way. The first three refuse — a refusal is reported
  // rather than swallowed, because nothing comes along later to fill the pane
  // in — and the fourth returns silently, since the answer is already coming.
  //
  // It jumps the queue because it belongs to a keypress. A sweep behind it can
  // afford to arrive a second later; someone staring at a blank pane cannot.
  function _enqueueRead(job) {
    var state = orgs[job.org]
    if (!state) {
      _readRefused(job, "That organization is no longer being watched")
      return
    }

    job.account = state.account
    var held = budget.blockedMs(job.account)
    if (held > 0) {
      _readRefused(job, "Rate limited — try again in " + Math.ceil(held / 1000) + "s")
      return
    }
    if (budget.wouldExceed(job.account, 1)) {
      _readRefused(job, "Too close to the rate limit — try again shortly")
      return
    }

    // Same kind, same key, same page is the same request. The key carries the
    // ids, so a cursor is all that is left to compare — and for the two reads
    // that have one, a second page is a different ask.
    var key = _readRequestKey(job)
    var page = String(job.cursor || "")
    var pending = function (other) {
      return other.kind === job.kind && _readRequestKey(other) === key
        && String(other.cursor || "") === page
    }
    if (_outstanding(pending)) return

    queue.pushFront(job)
  }

  // A queued job thrown away because the organization it belongs to stopped
  // being watched. A sweep needs no farewell — the next tick is its answer —
  // but a read and a command look each have a pane waiting on a signal that is
  // no longer coming, and a pane left holding "queued…" forever is the same
  // silence `_holdAccount` was taught not to leave behind. The run itself may
  // well finish out on the box; there is simply nothing left here to watch it
  // with, so the watch goes with the organization.
  function _abandonJob(job) {
    var message = "That organization is no longer being watched"
    if (_readRefused(job, message)) return
    // Either kind of run: one watch slot, one signal, one farewell. Kept apart
    // from the reads above because a hold gives these a different answer —
    // there the ladder outlives the refusal, and here it does not.
    if (!Model.isRunJob(job)) return
    if (_commandCurrent(job)) {
      _commandWatch = null
      commandTimer.stop()
    }
    commandRunUpdated(job.requestKey, false, false, String(job.commandId || ""),
                      "", "", message)
  }

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
      if (!orgs[job.org]) { _abandonJob(job); continue }

      // Before the charge, deliberately: a kind neither table knows is a
      // mistake in this file, and the one thing it must not do is cost a
      // request and come back looking like an answer. It is said out loud and
      // given the farewell any pane behind it is owed.
      var path = _pathFor(job)
      if (path === "") {
        console.warn("omarchy-forge: unknown job kind \"" + String(job.kind) + "\" — dropped")
        _abandonJob(job)
        continue
      }

      _current = job
      _currentStartedMs = Date.now()
      budget.charge(budget.bucketFor(job.account))
      fetchProcess.command = [cliPath, "api", "--account", job.account, "GET", path]
      fetchProcess.running = true
      return
    }
  }

  // Named rather than defaulted, every one of them: a kind this doesn't know
  // would otherwise be sent to the org site list, which answers plausibly and
  // wrongly — charged for, published as a sweep window, or thrown inside the
  // handler and left the queue stalled. It answers `""` instead, and `_pump`
  // refuses the job before it costs anything.
  function _pathFor(job) {
    if (job.kind === "servers") return Model.serversPath(job.org, job.cursor)
    if (job.kind === "sites") return Model.sitesPath(job.org, job.cursor)
    if (job.kind === "serverSites")
      return Model.serverSitesPath(job.org, job.serverId, job.cursor)
    if (job.kind === "log")
      return Model.deploymentLogPath(job.org, job.serverId, job.siteId, job.deploymentId)
    if (job.kind === "commandFind")
      return Model.commandListPath(job.org, job.serverId, job.siteId)
    if (job.kind === "commandShow")
      return Model.commandPath(job.org, job.serverId, job.siteId, job.commandId)
    if (job.kind === "commandOutput")
      return Model.commandOutputPath(job.org, job.serverId, job.siteId, job.commandId)
    if (job.kind === "events")
      return Model.serverEventsPath(job.org, job.serverId, job.cursor)
    if (job.kind === "eventOutput")
      return Model.eventOutputPath(job.org, job.serverId, job.eventId)
    if (job.kind === "siteLog")
      return Model.siteLogPath(job.org, job.serverId, job.siteId, job.log)
    if (job.kind === "recipes") return Model.recipesPath(job.org, job.cursor)
    if (job.kind === "recipeFind")
      return Model.recipeRunListPath(job.org, job.recipeId, job.cursor)
    if (job.kind === "recipeShow")
      return Model.recipeRunLogPath(job.org, job.recipeId, job.commandId)
    return ""
  }

  // `_pathFor`'s twin, and the reason both are named: a kind in one table and
  // not the other is the mistake either would otherwise make quietly.
  //
  // It is also the first of the three terminal functions, one per `Process`,
  // and they share a rule worth stating once. Quickshell emits `runningChanged`
  // *without* `exited` when the binary cannot be started at all — a helper that
  // has moved, a `wl-copy` that was never installed — so a job retired only in
  // `onExited` would sit in its slot for the rest of the session with whatever
  // waited on it never answered. Each is therefore called from both signals,
  // and each empties its slot before doing anything else: on the ordinary path
  // `exited` comes first and the `runningChanged` behind it finds nothing to
  // do, so the null guard at the top is what makes calling twice harmless.
  function _finishFetch(text) {
    var job = _current
    if (!job) return
    _current = null
    if (_timedOut) {
      _timedOut = false
      text = JSON.stringify(Model.errorEnvelope("The Forge helper timed out"))
    }
    // The pump is in a `finally` because a handler that throws would otherwise
    // take the queue down with it — every later job left sitting until
    // something else happens to push.
    try {
      if (job.kind === "servers") _onServers(job, text)
      else if (job.kind === "sites") _onSites(job, text)
      else if (job.kind === "serverSites") _onServerSites(job, text)
      else if (job.kind === "log") _onLog(job, text)
      else if (job.kind === "commandFind") _onCommandFind(job, text)
      else if (job.kind === "commandShow") _onCommandShow(job, text)
      else if (job.kind === "commandOutput") _onCommandOutput(job, text)
      else if (job.kind === "events") _onEvents(job, text)
      else if (job.kind === "eventOutput") _onEventOutput(job, text)
      else if (job.kind === "siteLog") _onSiteLog(job, text)
      else if (job.kind === "recipes") _onRecipes(job, text)
      else if (job.kind === "recipeFind") _onRecipeFind(job, text)
      else if (job.kind === "recipeShow") _onRecipeShow(job, text)
      else console.warn("omarchy-forge: no handler for job kind \""
                        + String(job.kind) + "\" — answer dropped")
    } finally {
      _pump()
    }
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
    if (budget.blockedMs(state.account) > 0) return
    _patch(key, { refreshing: true, note: "" })
    queue.push({ org: key, account: state.account, kind: "servers",
                 page: 1, rows: [] })
  }

  function refreshList(list) {
    if (!list) return
    for (var i = 0; i < list.length; i++) refresh(list[i])
  }

  function _isMissingToken(envelope) {
    return envelope.status === 0
      && String(envelope.error || "").indexOf("No API token") !== -1
  }

  // `quiet` suppresses every per-organization write and nothing else. One
  // request belongs to a keypress rather than to the watch — the deploy log,
  // which Forge gates behind the *write* scope — and a read-only token's 403
  // there is a fact about that one request, not about the organization. Left
  // loud it would paint an error across rows that are perfectly healthy. The
  // account-level bookkeeping still runs either way: whether there is a token,
  // what the rate headers said, the hold a 429 imposes and the refund a
  // request that never left the machine is owed are all true regardless of
  // which request happened to discover them.
  function _applyEnvelope(org, account, envelope, quiet) {
    tokenKnown = true

    // The account's whole verdict, written once for every kind of answer.
    // Getting an answer at all — even a bad one — settles the question of
    // whether there is a token, and a stale `false` would otherwise keep
    // saying "no token" long after the token was restored, for as long as
    // anything else kept going wrong. What every organization behind the
    // account shows for it is derived from here by `accountErrorFor`, never
    // copied, which is what stops a `quiet` request from setting one without
    // the other.
    _patchAccount(account, { hasToken: !_isMissingToken(envelope) })

    if (envelope.ok) {
      if (org && !quiet) _patch(org, { lastError: "" })
      return true
    }

    if (_isMissingToken(envelope)) {
      // The request never left the machine, so the minute is owed it back.
      // Nothing is written to the organization: the missing-token line it
      // shows is the account's, derived.
      budget.refund(budget.bucketFor(account))
      if (org && !quiet) _patch(org, { lastError: "" })
      return false
    }

    // Being refused for the minute is the whole Forge identity's problem, and
    // every organization behind it has to stop rather than take turns being
    // told no. This is the choke point every response passes through, so one
    // branch covers the server list, the sweep and a deploy alike.
    if (envelope.status === 429) {
      _holdAccount(account, envelope)
      return false
    }

    // A rejected token is reported per organization, not per account. Forge
    // scopes membership and permissions to an organization, so a 401 or a 403
    // on one says nothing about the next — and an account-level verdict blanks
    // the server list the bar icon judges, which is the same reason the 429
    // above writes `lastError` rather than a credential fact.
    if (org && !quiet) _patch(org, { lastError: Model.envelopeError(envelope) })
    return false
  }

  // Everything already queued for this identity would land inside the same
  // closed minute, so it is thrown away rather than sent — and with it go the
  // `sweepDone` markers that would have ended those refreshes, which is why
  // each one is ended here instead.
  function _holdAccount(account, envelope) {
    var bucket = budget.bucketFor(account)
    budget.block(bucket, Model.backoffUntilMs(envelope, Date.now()))
    queue.drop(function (job) {
      if (budget.bucketFor(job.account) !== bucket) return false
      // A dropped sweep is picked up by the next tick and needs no farewell.
      // A dropped read has someone watching an empty pane for an answer that
      // is no longer coming, so it gets told.
      //
      // A dropped look at a command is not the end of the run — the hold is
      // this minute's, and the ladder outlives it — so the pane is told to
      // expect a wait rather than told the watch is over. Every job in the
      // bucket goes whether or not it was owed a word.
      if (!_readRefused(job, "Rate limited — try again shortly")
          && Model.isRunJob(job)) {
        commandRunUpdated(job.requestKey, true, true, String(job.commandId || ""),
                          "rate limited — looking again shortly", "", "")
        _scheduleCommandPoll()
      }
      return true
    })

    var message = Model.envelopeError(envelope)
    for (var org in _config) {
      var state = orgs[org]
      if (!state) continue
      if (budget.bucketFor(state.account) !== bucket) continue
      // The organization's error, not a credential fact: a "no token" verdict
      // blanks the server list further down, and the bar icon judges what it
      // can see.
      // The site walk starts over after the hold — its dropped continuation
      // was the only thing that could have advanced the cursor.
      _patch(org, { lastError: message, siteCursor: "", sweepSites: [] })
      if (state.refreshing) _finishRefresh(org)
    }
  }

  function _onServers(job, text) {
    var org = job.org
    var envelope = Model.parseEnvelope(text)
    if (!orgs[org]) return

    if (!_applyEnvelope(org, job.account, envelope)) {
      if (accountErrorFor(org) !== "")
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

    var account = orgs[org].account
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
                        lastStatus: _announce(job.org, sites, grouped, state, true) })
      return
    }

    // "cap" or "budget": the window ended mid-list, and the kept cursor
    // carries the walk into the next tick.
    var merged = Model.mergeSitesByServer(state.sitesByServer, sites, state.servers)
    _patch(job.org, { sitesByServer: merged,
                      siteCursor: Model.nextCursor(envelope.body),
                      sweepSites: swept,
                      lastStatus: _announce(job.org, sites, merged, state, false) })
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

    var account = state.account
    if (budget.blockedMs(account) > 0) return
    if (budget.wouldExceed(account, 1)) return

    var id = String(serverId)
    var stamp = key + "/" + id
    if (!force && Date.now() - (_serverSitesAskedAt[stamp] || 0) < 15000) return
    var pending = function (job) {
      return job.kind === "serverSites" && job.org === key && job.serverId === id
    }
    if (_outstanding(pending)) return

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
      lastStatus: _announce(job.org, sites, merged, state, false)
    })
  }

  // ------------------------------------------------------------ deploy log

  // One request, only when someone asks for it, so it costs nothing at rest.
  // It goes through the queue rather than the deploy path's own process: the
  // queue already charges the budget, honours a hold and throws work away for
  // an organization that stopped being watched, and `actionProcess` is
  // single-flight for every write — a log fetch waiting behind a deploy or a
  // reboot, or answering into `_finishAction`, is not what either wants.
  //
  // No debounce: pressing it again on a deploy still running is a reasonable
  // thing to want, and `_enqueueRead`'s dedupe already covers the only case
  // that would waste a request.
  function fetchDeploymentLog(org, serverId, siteId, deploymentId) {
    var job = { org: String(org), kind: "log", serverId: String(serverId),
                siteId: String(siteId), deploymentId: String(deploymentId) }
    if (job.deploymentId === "") {
      _readRefused(job, "This site has never deployed")
      return
    }
    _enqueueRead(job)
  }

  function _onLog(job, text) {
    var envelope = Model.parseEnvelope(text)

    // Quiet: see `_applyEnvelope`. Whatever went wrong is this pane's to say.
    if (!_applyEnvelope(job.org, job.account, envelope, true)) {
      // Forge gates deploy output behind `site:manage-deploys` — the scope that
      // *writes* — so a token deliberately kept read-only reads every server
      // and site and is still refused here. "Token is missing a scope for this"
      // is true but leaves the reader guessing which, on the one request where
      // the answer is surprising enough to be worth spelling out.
      _readRefused(job, envelope.status === 403
        ? "Your token can't read deploy logs — that needs the site:manage-deploys scope"
        : Model.envelopeError(envelope))
      return
    }

    // A deploy that printed nothing is a real answer and shows as an empty
    // pane; an `output` that isn't there at all is a malformed one.
    var output = Model.resourceText(envelope.body, "output")
    if (output === null) {
      _readRefused(job, "Forge returned no output for this deployment")
      return
    }
    // Handed on unguarded: `Model.logLines` is applied where the string enters
    // a `Text`, which is the boundary the guard is about.
    documentFetched(_readRequestKey(job), true, output, "")
  }

  // ---------------------------------------------------------- server events

  // The feed and one event's output take the log's road exactly — the same
  // `_enqueueRead` guards, the same queue-jump, the same rule that a refusal
  // answers. What differs is the scope — both want only `server:view`, so a
  // read-only token works here where the deploy log refuses it — and that the
  // feed is a page with a cursor after it, fetched again on request rather
  // than followed.
  function fetchServerEvents(org, serverId, cursor) {
    _enqueueRead({ org: String(org), kind: "events", serverId: String(serverId),
                   cursor: String(cursor || "") })
  }

  function fetchEventOutput(org, serverId, eventId) {
    _enqueueRead({ org: String(org), kind: "eventOutput",
                   serverId: String(serverId), eventId: String(eventId) })
  }

  // Quiet, like the log's: the refusal is this pane's to say. A 403 here is
  // the surprising kind — `server:view` is the scope every sweep already
  // needs — so it is named, on the chance the token was cut down further.
  function _eventError(job, envelope) {
    _readRefused(job, envelope.status === 403
      ? "Your token can't read server events — that needs the server:view scope"
      : Model.envelopeError(envelope))
  }

  function _onEvents(job, text) {
    var envelope = Model.parseEnvelope(text)
    if (!_applyEnvelope(job.org, job.account, envelope, true)) { _eventError(job, envelope); return }
    serverEventsFetched(_readRequestKey(job), true,
                        Model.eventsFrom(envelope.body), String(job.cursor || ""),
                        Model.nextCursor(envelope.body), "")
  }

  // ------------------------------------------------------------------ recipes

  // The organization's recipe list, on the event feed's road: front of the
  // queue because someone is looking at an empty view, `quiet` because the
  // refusal belongs to that view, and a page the reader asks for rather than a
  // chain this walks.
  function fetchRecipes(org, cursor) {
    _enqueueRead({ org: String(org), kind: "recipes", cursor: String(cursor || "") })
  }

  // Named, and for the deploy log's reason rather than the event feed's:
  // `recipe:view` is a scope no sweep needs, so a deliberately read-only token
  // is refused here and told which scope it wanted. Quiet, so that refusal
  // stays on this view instead of painting the organization's rows.
  function _onRecipes(job, text) {
    var envelope = Model.parseEnvelope(text)
    if (!_applyEnvelope(job.org, job.account, envelope, true)) {
      _readRefused(job, envelope.status === 403
        ? "Your token can't list recipes — that needs the recipe:view scope"
        : Model.envelopeError(envelope))
      return
    }
    recipesFetched(_readRequestKey(job), true,
                   Model.recipesFrom(envelope.body), String(job.cursor || ""),
                   Model.nextCursor(envelope.body), "")
  }

  function _onEventOutput(job, text) {
    var envelope = Model.parseEnvelope(text)
    if (!_applyEnvelope(job.org, job.account, envelope, true)) { _eventError(job, envelope); return }
    // As with the log: an event that printed nothing is an empty pane, and an
    // `output` that isn't there at all is a malformed answer.
    var output = Model.resourceText(envelope.body, "output")
    if (output === null) {
      _readRefused(job, "Forge returned no output for this event")
      return
    }
    documentFetched(_readRequestKey(job), true, output, "")
  }

  // ---------------------------------------------------------------- site logs

  // The deploy log's road once more: `_enqueueRead`'s guards, front of the
  // queue because a keypress is waiting on it, `quiet` because the refusal
  // belongs to the pane. Nothing here polls — a log is a tail Forge cuts at
  // the moment of asking, and `r` on the pane is how the reader takes another
  // look.
  function fetchSiteLog(org, serverId, siteId, kind) {
    var job = { org: String(org), kind: "siteLog", serverId: String(serverId),
                siteId: String(siteId), log: String(kind) }
    // Checked here rather than trusted from the row: a kind outside the three
    // would reach Forge as a 404, which reads on the pane like the site is
    // gone rather than like the request was wrong.
    if (!Model.isSiteLogKind(job.log)) {
      _readRefused(job, "There is no such log")
      return
    }
    _enqueueRead(job)
  }

  function _onSiteLog(job, text) {
    var envelope = Model.parseEnvelope(text)
    if (!_applyEnvelope(job.org, job.account, envelope, true)) {
      // Forge's spec puts these behind `server:manage-logs` — the scope that
      // *clears* a log — so a token kept to `server:view` reads every server
      // and site and is still refused here, the deploy log's situation with a
      // different scope on the sign.
      _readRefused(job, envelope.status === 403
        ? "Your token can't read site logs — that needs the server:manage-logs scope"
        : Model.envelopeError(envelope))
      return
    }
    // `content` here, where the deploy log and an event both say `output`. An
    // empty log is not an empty string either — see `Model.siteLogContent`.
    var content = Model.resourceText(envelope.body, "content")
    if (content === null) {
      _readRefused(job, "Forge returned no content for this log")
      return
    }
    documentFetched(_readRequestKey(job), true, Model.siteLogContent(content), "")
  }

  function _finishRefresh(org) {
    var state = orgs[org]
    var config = _config[org]
    var seconds = config ? config.refreshIntervalSec : 60
    var now = Date.now()
    // A hold on the account outlives the configured interval: coming back
    // before the minute resets only spends another refusal. Every path that
    // ends a refresh goes through here, so none of them can undercut it.
    var held = state ? budget.blockedMs(state.account) : 0
    _patch(org, { refreshing: false, nextDueMs: now + Math.max(seconds * 1000, held) })
  }

  // ----------------------------------------------------------- notifications

  // Deployment status per site key as of that site's *last observation* — a
  // rotation sees one window per tick, so an unobserved site keeps its last
  // word rather than losing it, and a key leaves the map only when `complete`
  // says the whole organization was seen. That retention is what lets a site
  // that briefly fell out of a window announce its next change exactly once
  // instead of never.
  //
  // It is also the seed: a site with no entry yet has an `undefined` previous
  // status, and that is what keeps an already-failed site from announcing
  // itself the moment the shell starts. The guard rests on this function being
  // the only writer of `lastStatus` — nothing may fill it in ahead of the
  // comparison below.
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
    if (!notify) return next
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

  // ------------------------------------------------------------------ writes

  // Every write — a deploy, a service restart, a reboot — goes out on
  // `actionProcess` rather than through the queue. It is single-flight, so one
  // press cannot become two requests, and it answers into `_finishAction` rather
  // than into a sweep. What the queue would have done for it, the budget hold
  // and the charge, it therefore has to do here by hand.
  property var _action: null
  // What `_currentStartedMs` and `_timedOut` are to `fetchProcess`, and for a
  // watchdog that matters more here: the helper looks the token up in the
  // keyring *before* curl ever runs, so a locked keyring hangs a write
  // somewhere `--max-time` cannot reach — and with no watchdog that pinned the
  // single-flight slot, and every write after it, for the rest of the session.
  property double _actionStartedMs: 0
  property bool _actionTimedOut: false

  // Answers whether the request went out. Both refusals below are reported to
  // the row either way, but a caller that has state to set up around the send —
  // `runSiteCommand`, whose whole point is what happens after it — has to know
  // that there is nothing to set it up for.
  function _startAction(job) {
    // A refusal is reported rather than swallowed: a keypress that looks like
    // it missed is worse than one that says why. Same reasoning as the guards
    // in `fetchDeploymentLog` — nothing comes along later to explain this one.
    if (actionProcess.running) {
      actionFinished(job.key, false, "Still sending the last one")
      return false
    }
    // The one site that still needs the fallback: a write can be sent for an
    // organization that is not in `orgs` at all — a row pressed as the state
    // file was being re-read — where there is no `state.account` to join on.
    var account = orgs[job.org] ? orgs[job.org].account : accountForOrg(job.org)
    // Sending it anyway would only earn another refusal and push the hold out
    // further, so say when it can be pressed again rather than spending it.
    var held = budget.blockedMs(account)
    if (held > 0) {
      actionFinished(job.key, false,
                     "Rate limited — try again in " + Math.ceil(held / 1000) + "s")
      return false
    }
    job.account = account
    // The job goes in its slot before the process starts, the order `_pump` and
    // `_pumpPipe` also use: it is what `onRunningChanged` looks for to tell a
    // start that failed from one already answered. See `_finishAction`.
    _action = job
    _actionStartedMs = Date.now()
    budget.charge(budget.bucketFor(account))
    // `-` is the helper's word for "the body is on stdin", and the body itself
    // is written in `onStarted`, because there is no stdin to write to until
    // the child exists. *Which* bodies travel that way is `_writeJob`'s to say.
    var piped = job.bodyStdin === true && !!job.body
    actionProcess.stdinEnabled = piped
    actionProcess.command = [cliPath, "api", "--account", account,
                             String(job.method || "POST"), job.path]
      .concat(piped ? ["-"] : job.body ? [JSON.stringify(job.body)] : [])
    actionProcess.running = true
    // Not a bare `true`: a start that failed on the spot has already run
    // `_finishAction` and emptied the slot, and a caller told the send happened
    // would open a pane onto a run that does not exist.
    return _action === job
  }

  // The one place an action entry becomes a job, and the reason the wrappers
  // below are wrappers: each of them used to copy its own subset of the entry,
  // so the job's shape was whatever the caller happened to remember. That is
  // how `bodyStdin` came to be declared in `Model` on the one action that needs
  // it and read from nowhere — the command's wrapper hard-coded it instead, so
  // the rule it exists for held by accident rather than by construction.
  //
  // Most bodies reach the helper in argv, unlike the token: they are fixed
  // action words built in `Model`, not credentials, and the rule the stdin
  // config exists for is about the one thing that must never appear in a
  // command line. The helper moves them onto that config for curl's sake.
  //
  // A command someone typed is the exception, and asks for `bodyStdin`. It is
  // not a credential either, but it can quote one, and /proc/<pid>/cmdline is
  // readable by every process on the machine — so it goes down the pipe the
  // clipboard and the file writer already use.
  //
  // The method rides the job too. Everything here was a POST until removing a
  // site's maintenance mode turned out to be a DELETE; the helper passes
  // whatever it is straight to curl, so this is the only place that knew.
  function _writeJob(org, serverId, action, key) {
    return { org: String(org), serverId: String(serverId), key: String(key),
             path: String(action.path),
             method: String(action.method || "POST"),
             body: action.body || null,
             bodyStdin: action.bodyStdin === true,
             done: String(action.done || "Sent"),
             scopeMessage: String(action.scopeMessage || ""),
             settleSites: action.settleSites === true,
             // As `Model` declares it — `"sites"` or `"org"` — rather than
             // split into a pair of booleans here and recombined downstream.
             refetch: String(action.refetch || "") }
  }

  // A deploy's 403 is the only one left loud, so it carries no `scopeMessage`:
  // it goes out on the same token and the same scope every sweep already needs,
  // which makes a refusal the organization's business rather than this row's.
  //
  // Its job is built by hand because it is reached from a key rather than from
  // a row of an action list, so there is no entry for `_writeJob` to copy.
  function deploy(org, site) {
    if (!site || String(org) === "") return
    if (!Model.canDeploy(site)) return
    _startAction({ org: String(org), serverId: String(site.serverId),
                   key: String(site.key), body: null,
                   path: Model.deployPath(org, site.serverId, site.id),
                   done: "Deployment queued", refetch: "sites" })
  }

  // Every other write, whatever its subject. `action` is a `Model.serverActions`
  // or `Model.siteActions` entry, so everything that varies — the path, the
  // body, the method, the 403 wording, what to re-read afterwards — was
  // declared beside the label that describes it rather than assembled here out
  // of whatever the panel happened to pass. `_writeJob` is what copies it, and
  // is what keeps this one function rather than one per subject: the next write
  // to be added is an entry in `Model`, not a fourth near-duplicate wrapper.
  //
  // `key` is the row's, not the subject's: rows can send to the same endpoint,
  // and only the one that was pressed should say so.
  function sendAction(org, serverId, action, key) {
    // An action with no path is one whose subject has gone from the API since
    // the row was built — a site dropped by the refresh that landed inside the
    // arm window. The press is spent either way, so it says so rather than
    // disappearing: silence here reads as a key that missed.
    if (!action || !action.path || String(org) === "") {
      actionFinished(String(key), false, "That is no longer listed")
      return
    }
    _startAction(_writeJob(org, serverId, action, key))
  }

  // Running a command is a write like any other, so it goes out on the same
  // single-flight process with the same job shape. It has its own door only
  // because of what happens *after* the 202: nothing else here has an answer
  // worth waiting for, and the coordinates the watch needs — which site, what
  // was typed, when — are not in an action's vocabulary.
  // Answers with the key its updates will carry, because the panel needs it to
  // filter them and the send time it is built from is minted here — and answers
  // `""` when nothing was sent, so the panel does not open a pane onto a run
  // that does not exist. Both ways out say why on the row first.
  function runSiteCommand(org, serverId, siteId, action, key) {
    if (!action || !action.path || String(org) === "") {
      actionFinished(String(key), false, "That site is no longer listed")
      return ""
    }
    var sentAtMs = Date.now()
    var requestKey = commandRequestKey(org, serverId, siteId, sentAtMs)
    // Only the watch's coordinates are added here. That this body travels on
    // stdin is `Model.siteCommandAction`'s to declare and `_writeJob`'s to
    // carry — asserting it here is what let the rule hold by coincidence.
    var job = _writeJob(org, serverId, action, key)
    job.kind = "command"
    job.siteId = String(siteId)
    job.sent = String(action.body ? action.body.command : "")
    job.sentAtMs = sentAtMs
    job.requestKey = requestKey
    return _startAction(job) ? requestKey : ""
  }

  // A recipe run, on `runSiteCommand`'s terms and for the same reason: the 202
  // carries no body, so the run has to be recognised afterwards, and the key
  // its updates will arrive on is minted here because the panel needs it before
  // the first one can land. Answers `""` when nothing was sent, so the panel
  // does not open a pane onto a run that does not exist.
  //
  // Unlike the command's, this body is decided in `Model.recipeRunAction` and
  // never typed, so it rides the argv the maintenance toggle's does — there is
  // nothing in it a user wrote.
  function runRecipe(org, serverId, action, key) {
    if (!action || !action.path || String(org) === "") {
      actionFinished(String(key), false, "That server is no longer listed")
      return ""
    }
    var sentAtMs = Date.now()
    var requestKey = recipeRequestKey(org, serverId, action.recipeId, sentAtMs)
    var job = _writeJob(org, serverId, action, key)
    job.kind = "recipe"
    job.recipeId = String(action.recipeId)
    job.sentAtMs = sentAtMs
    job.requestKey = requestKey
    return _startAction(job) ? requestKey : ""
  }

  // The write's terminal function, on the terms `_finishFetch` sets out: the
  // slot is emptied first and the null guard is what makes a second call — the
  // one `onRunningChanged` makes after `onExited` — do nothing.
  function _finishAction(text) {
    var job = _action
    if (!job) return
    _action = null
    if (_actionTimedOut) {
      _actionTimedOut = false
      text = JSON.stringify(Model.errorEnvelope("The Forge helper timed out"))
    }
    var envelope = Model.parseEnvelope(text)

    // Which refusals are the organization's business and which are this row's
    // is carried by the job rather than decided here. A deploy carries no
    // `scopeMessage`, so it stays loud: it uses the same token and the same
    // scope every sweep already needs. The rest are gated behind write scopes a
    // deliberately read-only token does not have, and left loud one keypress
    // would paint a scope error across rows that are perfectly healthy — the
    // reason `_onLog` is quiet, for the same kind of request.
    var quiet = !!job.scopeMessage
    if (!_applyEnvelope(job.org, job.account, envelope, quiet)) {
      var message = quiet && envelope.status === 403
        ? job.scopeMessage
        : Model.envelopeError(envelope)
      actionFinished(job.key, false, message)
      return
    }

    actionFinished(job.key, true, job.done)

    // The 202 for a command carries no body at all — a deploy hands its
    // resource back, this hands back nothing — so the run has to be found
    // before it can be followed. That is the watch's first look.
    if (job.kind === "command") { _startCommandWatch(job); return }

    // The same again, and for the same reason: a recipe's 202 carries no body
    // either. Nothing to re-read afterwards — a recipe changes whatever its
    // script changes, none of which the sweep reads.
    if (job.kind === "recipe") { _startRecipeWatch(job); return }

    // Forge does all of this asynchronously — every one of these endpoints
    // answers 202 — so what changed only shows a moment later. Look again
    // shortly rather than making the user wait out a whole refresh interval.
    if (!orgs[job.org]) return
    if (job.refetch !== "sites" && job.refetch !== "org") return
    _patch(job.org, { nextDueMs: Date.now() + 6000 })
    // A server's own state arrives with the server list, so pulling the org's
    // refresh forward is all a reboot needs. What a deploy or a maintenance
    // toggle changed rides the *sites* payload, so look at that server
    // directly: under rotation the re-poll only advances the window, which for
    // a large organization will usually be looking somewhere else entirely.
    if (job.refetch !== "sites") return
    fetchServerSites(job.org, job.serverId, true)
    if (job.settleSites) _armSettle(job.org, job.serverId)
  }

  // ---------------------------------------------------------------- settling

  // A deploy flips `deployment_status` the moment Forge queues it, so the
  // re-read above sees the change. A maintenance flip does not: Forge is out on
  // the box, `maintenance_mode.enabled` stays put, and the re-read is therefore
  // *guaranteed* to observe the transitional `status`. Nothing else is coming
  // for it either — the pulled-forward tick only advances the site rotation by
  // one window, which past 150 sites is usually a different server — so the row
  // would pulse `enabling…` until the rotation came back around, with the
  // toggle refusing every press while it did.
  //
  // Hence a bounded second look, for the jobs that ask for one. It stops as
  // soon as the flip has landed, so a settled toggle costs nothing extra, and
  // it gives up after two rather than polling: a flip that has not landed in
  // 16s is the ordinary refresh's problem, not this keypress's.
  property var _settle: null

  function _armSettle(org, serverId) {
    _settle = { org: String(org), serverId: String(serverId), left: 2 }
    settleTimer.restart()
  }

  function _serverIsFlipping(org, serverId) {
    var state = orgs[String(org)]
    if (!state) return false
    var sites = state.sitesByServer[String(serverId)]
    if (!sites) return false
    for (var i = 0; i < sites.length; i++)
      if (String(sites[i].maintenanceStatus) !== "") return true
    return false
  }

  function _onSettleTick() {
    var job = _settle
    if (!job) { settleTimer.stop(); return }
    // Nothing on that server is still moving, so there is nothing left to look
    // for — whether this tick's predecessor found it or the ordinary sweep did.
    if (!_serverIsFlipping(job.org, job.serverId)) {
      _settle = null
      settleTimer.stop()
      return
    }
    // Reassigned rather than counted down in place, for the reason `_patch`
    // exists — this one has nothing bound to it, but the rule is cheaper to
    // keep than to reason about per property.
    var left = job.left - 1
    _settle = left > 0 ? { org: job.org, serverId: job.serverId, left: left } : null
    if (left <= 0) settleTimer.stop()
    fetchServerSites(job.org, job.serverId, true)
  }

  // ----------------------------------------------------------- command runs

  // Watching a command from `waiting` to a terminal state, and then reading
  // what it printed. One watch for the whole session, like `_action` and for
  // the same reason: the run is single-flight on the way out, so there is only
  // ever one worth following back.
  //
  // It lives here rather than in `Panel` because it is polling, and a timer on
  // the panel would run once per monitor — the same reason the sweep is a
  // service. Panels hear it through `commandRunUpdated` and filter by key.
  //
  // The ladder rather than a fixed interval: a trivial command lands in about
  // ten seconds, so the first looks are close together, and a slow one earns
  // longer gaps instead of spending the minute's budget on it. Ten looks over
  // roughly a hundred seconds, and then it stops asking — a migration that has
  // not finished by then is not something to keep a poll alive for, and `r`
  // starts the ladder over for anyone still watching.
  readonly property var commandPollLadder: [3, 3, 5, 5, 8, 8, 13, 13, 21, 21]

  // How far a recipe's find will walk before giving that look up. Forge pages
  // this list 30 at a time whatever `page[size]` asks for and offers no sort,
  // so a recipe with a history can hold the new run past the first page. Three
  // pages is 90 rows, and the walk is only ever paid while the run has not
  // been recognised — once it has, every look after it addresses the id.
  readonly property int recipeFindPages: 3
  property var _commandWatch: null

  // The last run this session recognised, and which command on which site it
  // was. `Model.commandFrom` takes it as a floor: reading a failure and running
  // the same thing again a minute later — the ordinary way a command is
  // retried — would otherwise recognise the *previous* run as this one and
  // print its output as the new result. One slot rather than a table, because
  // the run a new one can be confused with is the one before it.
  property var _lastRun: null

  // The same floor for a recipe run, and the same reason: running a recipe
  // again after reading its failure is the ordinary retry, and without this the
  // find would recognise the previous run as the new one. A recipe log carries
  // no text to tell two apart, so what is kept is the *id* of the last run this
  // session adopted for the recipe-and-server it was on.
  property var _lastRecipeRun: null

  function _runSite(job) {
    return String(job.org) + "/" + String(job.serverId) + "/" + String(job.siteId)
  }

  // There is one watch for the session and a new run displaces whatever it was
  // following, so the pane left behind has to be told — two monitors is all it
  // takes, since the service is shared and the panels are not. Without this it
  // sits on "running…" with no lines and an `r` that answers nothing.
  function _displaceWatch(job) {
    if (_commandWatch && _commandWatch.requestKey !== job.requestKey)
      commandRunUpdated(_commandWatch.requestKey, false, false,
                        _commandWatch.commandId, "", "",
                        "Stopped following this run — another run was started")
    commandTimer.stop()
  }

  // A recipe's watch, the command's with a different find. The floor is an id
  // rather than a timestamp — see `Model.recipeRunFrom` — and it is carried on
  // the watch the way `afterMs` is, so every look asks the same question.
  function _startRecipeWatch(job) {
    _displaceWatch(job)
    var run = _recipeRun(job)
    _commandWatch = { kind: "recipe", org: job.org, account: job.account,
                      serverId: job.serverId, recipeId: job.recipeId,
                      run: run, sentAtMs: job.sentAtMs,
                      afterId: _lastRecipeRun && _lastRecipeRun.run === run
                        ? _lastRecipeRun.id : 0,
                      requestKey: job.requestKey, commandId: "",
                      // Where the walk over the run list has got to, and how
                      // far it has gone. Reset every time a look gives up, so
                      // the next one starts from the first page — by then the
                      // run Forge had not written down may be there.
                      findCursor: "", findPage: 0,
                      stage: "follow", header: "", step: 0 }
    // Before the first look, for `_startCommandWatch`'s reason: the pane opens
    // reading "queued" rather than sitting blank until a request comes back.
    commandRunUpdated(job.requestKey, true, true, "", "queued", "", "")
    _pollCommand()
  }

  // Which recipe on which server, which is the pair a run can be confused with.
  function _recipeRun(job) {
    return String(job.org) + "/" + String(job.serverId) + "/" + String(job.recipeId)
  }

  function _startCommandWatch(job) {
    _displaceWatch(job)
    var site = _runSite(job)
    _commandWatch = { kind: "command", org: job.org, account: job.account,
                      serverId: job.serverId, siteId: job.siteId,
                      site: site, sent: job.sent, sentAtMs: job.sentAtMs,
                      // Only the same text on the same site can be mistaken for
                      // this run, so anything else carries no floor at all.
                      afterMs: _lastRun && _lastRun.site === site
                        && _lastRun.sent === job.sent ? _lastRun.madeMs : 0,
                      requestKey: job.requestKey, commandId: "",
                      stage: "follow", header: "", step: 0 }
    // Said before the first look rather than after it, so the pane opens
    // reading "queued" instead of sitting blank until a request comes back.
    commandRunUpdated(job.requestKey, true, true, "", "queued", "", "")
    _pollCommand()
  }

  // Anyone who closed the pane. Keyed, so a second panel still watching the
  // same run is not what stops it — and a key that has moved on is ignored
  // rather than cancelling whatever replaced it.
  //
  // This, the output landing, and the next run are the *only* three things that
  // end a watch. A refusal never does: the run is out on the box whatever a
  // look at it came back with, so throwing the watch away would make it
  // unreachable for the rest of its life — see `_commandFailed`.
  function stopCommandWatch(requestKey) {
    if (!_commandWatch || _commandWatch.requestKey !== String(requestKey)) return
    _commandWatch = null
    commandTimer.stop()
  }

  // `r` in the pane. The ladder starts over, because someone asking again is
  // saying they are still watching — from wherever the watch had got to, so a
  // run whose output was the part that failed asks for the output again rather
  // than starting from the index. Answers whether there was anything left to
  // look at, so the panel does not report a look it never took.
  function refreshCommand(requestKey) {
    if (!_commandWatch || _commandWatch.requestKey !== String(requestKey)) return false
    _commandWatch = _commandCopy({ step: 0 })
    _pollCommand()
    return true
  }

  // Reassigned rather than mutated, the same rule the org state follows.
  function _commandCopy(changes) {
    return _commandWatch ? _merge(_commandWatch, changes) : null
  }

  // Every request the watch makes leaves through here, the output read
  // included: it is the one place that knows about the hold and the ceiling,
  // and a final read fired past them would earn a 429 that pushes the hold out
  // further for everything else.
  function _pollCommand() {
    var watch = _commandWatch
    if (!watch) return
    // Before the id is known the run has to be recognised in the index; after
    // it, it is addressed directly — one row of JSON instead of five, and no
    // chance of adopting a different run with the same text. Once it is over,
    // there is one thing left to ask for.
    // A recipe has one read fewer: its show carries the output, so a terminal
    // one *is* the landing and there is no third stage to reach.
    var kind = watch.kind === "recipe"
      ? (watch.commandId === "" ? "recipeFind" : "recipeShow")
      : watch.stage === "output" ? "commandOutput"
        : watch.commandId === "" ? "commandFind" : "commandShow"
    var key = watch.requestKey
    var pending = function (job) {
      return job.requestKey === key && Model.isRunJob(job)
    }
    if (_outstanding(pending)) return

    // A hold is not a reason to give up on the run — it is on the box either
    // way — so the pane is told how long and the ladder carries on. Same for
    // the ceiling: this is the on-demand spend the margin exists for, but not
    // at the cost of the sweep that watches everything else.
    var held = budget.blockedMs(watch.account)
    if (held > 0) {
      commandRunUpdated(key, true, true, watch.commandId,
                        "rate limited — looking again in "
                        + Math.ceil(held / 1000) + "s", "", "")
      _scheduleCommandPoll()
      return
    }
    if (budget.wouldExceed(watch.account, 1)) {
      commandRunUpdated(key, true, true, watch.commandId,
                        "waiting for the rate limit", "", "")
      _scheduleCommandPoll()
      return
    }

    // The job is an *address*, and nothing more: what the queue needs, what
    // `_pathFor` builds a path from, what a drop site answers on. The evidence
    // an answer is judged against — what was typed, when, the floor it must
    // beat, the state the run ended in — stays on the watch, because every
    // handler that reads it has already been through `_commandCurrent` and so
    // is holding this very watch. `commandId` is the id of the run being
    // followed, whichever kind that is. Fields the other kind does not use ride
    // along as `undefined`, which `_pathFor` never reaches.
    queue.pushFront({ org: watch.org, account: watch.account, kind: kind,
                      serverId: watch.serverId, siteId: watch.siteId,
                      recipeId: watch.recipeId, cursor: watch.findCursor,
                      commandId: watch.commandId, requestKey: key })
  }

  function _scheduleCommandPoll() {
    var watch = _commandWatch
    if (!watch) return
    if (watch.step >= commandPollLadder.length) {
      // Out of looks rather than out of run: the command is still going, and
      // saying so is more use than a pane that quietly stops updating. Unless
      // it is not still going — a ladder that ran out while the output was
      // what could not be read should say the part that is true.
      commandRunUpdated(watch.requestKey, true, true, watch.commandId,
                        watch.stage === "output"
                          ? "finished — press r to read the output"
                          : "still running — press r to look again", "", "")
      commandTimer.stop()
      return
    }
    commandTimer.interval = commandPollLadder[watch.step] * 1000
    _commandWatch = _commandCopy({ step: watch.step + 1 })
    commandTimer.restart()
  }

  // The three reads share a refusal: they belong to a keypress, so a hold or a
  // dropped job has to answer rather than vanish — the same rule the deploy
  // log's guards follow. `server:view` is all any of them wants, which is why
  // the 403 here reads differently from the one the send earns.
  //
  // The refusal path is the exception to `_pollCommand`'s rule. Everything
  // downstream of a successful `_commandAnswer` reads its evidence off the
  // watch; these say `job.commandId` instead, because a message about a request
  // that failed should name the run that request was addressed to. The two drop
  // sites — `_abandonJob` and `_holdAccount` — have the stronger reason: their
  // watch may be null or another run's entirely.
  function _commandRefused(job, envelope) {
    var message = envelope.status === 403
      ? (Model.isRecipeRunJob(job)
         ? "Your token can't read recipe runs — that needs the recipe:view scope"
         : "Your token can't read command runs — that needs the server:view scope")
      : Model.envelopeError(envelope)
    commandRunUpdated(job.requestKey, false, false, String(job.commandId || ""),
                      "", "", message)
  }

  // What a refused look does to the watch: nothing. The run is out on the box
  // whatever this one request came back with, so the watch outlives every
  // refusal — throwing it away here is what used to leave `r` flashing "Looking
  // again" at a run nothing could reach any more.
  //
  // The refusal decides only whether the ladder keeps ticking. A 429, a 500, a
  // timeout, an envelope that would not parse: all of them pass, so the pane
  // hears what went wrong and the next look is scheduled — the same answer
  // `_holdAccount` gives a command job it drops. A token without the scope
  // would say the same thing every time, so that one stops asking and reports
  // it, and `r` is still there for once the token has been fixed.
  function _commandFailed(job, envelope) {
    if (!_commandCurrent(job)) return
    if (envelope.status === 401 || envelope.status === 403
        || _isMissingToken(envelope)) {
      commandTimer.stop()
      _commandRefused(job, envelope)
      return
    }
    commandRunUpdated(job.requestKey, true, true, String(job.commandId || ""),
                      Model.envelopeError(envelope) + " — looking again", "", "")
    _scheduleCommandPoll()
  }

  // Still the watch this answer belongs to? A pane closed and reopened on a
  // second run would otherwise be updated by the first one's last look.
  function _commandCurrent(job) {
    return !!_commandWatch && _commandWatch.requestKey === job.requestKey
  }

  // The preamble all three answers share: the envelope when it is worth acting
  // on, and `null` when it was refused or belongs to a watch that has moved on.
  // Written once because the three copies of it had already drifted apart, and
  // a stale job's failure was stopping the current watch's ladder.
  function _commandAnswer(job, text) {
    var envelope = Model.parseEnvelope(text)
    if (!_applyEnvelope(job.org, job.account, envelope, true)) {
      _commandFailed(job, envelope)
      return null
    }
    return _commandCurrent(job) ? envelope : null
  }

  function _onCommandFind(job, text) {
    var envelope = _commandAnswer(job, text)
    if (!envelope) return

    // The watch, not the job: `_commandAnswer` answered, so this is the run
    // that was asked about. See `_pollCommand`.
    var watch = _commandWatch
    var found = Model.commandFrom(envelope.body, watch.sent, watch.sentAtMs,
                                  watch.afterMs)
    if (!found) {
      // Forge has not written the run down yet. That is ordinary in the first
      // second or two, so it is another look rather than an error — and the
      // ladder running out is what eventually says so.
      commandRunUpdated(job.requestKey, true, true, "", "queued", "", "")
      _scheduleCommandPoll()
      return
    }
    // Kept for the next run of the same command on this site, which is the one
    // thing that could be mistaken for this one. See `_lastRun`.
    _lastRun = { site: watch.site, sent: watch.sent, madeMs: found.madeMs }
    _commandWatch = _commandCopy({ commandId: found.id })
    _afterCommandState(job, found.attributes)
  }

  function _onCommandShow(job, text) {
    var envelope = _commandAnswer(job, text)
    if (!envelope) return

    _afterCommandState(job, Model.resourceAttributes(envelope.body))
  }

  // Where both looks land: either it is still going, and the ladder gets
  // another turn, or it is over and there is output to read.
  function _afterCommandState(job, attributes) {
    var state = Model.commandStateFrom(attributes)
    if (state.running) {
      commandRunUpdated(job.requestKey, true, true,
                        _commandWatch.commandId, state.header, "", "")
      _scheduleCommandPoll()
      return
    }
    // Deliberately silent here. Saying the run is over while the request for
    // what it printed is still in flight leaves the pane holding a finished
    // state and no lines, which is how it renders "this command printed
    // nothing" — a different fact, and the wrong one, for the second before the
    // output lands. The run is only over once there is something to show for
    // it, so `_onCommandOutput` is what says so.
    //
    // The state the run ended in rides the watch rather than this one job: the
    // read it belongs to goes out through `_pollCommand` like the other two, so
    // a hold can put a ladder step between here and the request that carries it.
    commandTimer.stop()
    _commandWatch = _commandCopy({ stage: "output", header: state.header })
    _pollCommand()
  }

  function _onCommandOutput(job, text) {
    var envelope = _commandAnswer(job, text)
    if (!envelope) return

    // Read out before the watch is cleared below: the state the run ended in
    // was written there by `_afterCommandState`, a ladder step ago.
    var watch = _commandWatch
    var logId = String(watch.commandId || "")

    // An empty string is a real answer here — plenty of commands print
    // nothing — so only a missing field is a failure to report. The watch stays
    // for it: an answer this shape is worth asking about again, and `r` is how.
    var output = Model.resourceText(envelope.body, "output")
    if (output === null) {
      commandRunUpdated(job.requestKey, false, false, logId, watch.header, "",
                        "Forge returned no output for this command")
      return
    }

    // The run is over and this was the last thing wanted from it.
    _commandWatch = null
    commandTimer.stop()
    commandRunUpdated(job.requestKey, true, false, logId, watch.header, output, "")
  }

  // The recipe's find. Same shape as the command's, different evidence — see
  // `Model.recipeRunFrom` — and the same answer when there is nothing yet:
  // Forge has not written the log down, which is ordinary in the first second
  // or two, so it is another look rather than an error.
  function _onRecipeFind(job, text) {
    var envelope = _commandAnswer(job, text)
    if (!envelope) return

    var watch = _commandWatch
    var found = Model.recipeRunFrom(envelope.body, job.serverId, watch.sentAtMs,
                                    watch.afterId)
    if (!found) {
      // Not on this page. Either Forge has not written the run down yet, which
      // is ordinary in the first second or two, or it is further along a list
      // that has no sort to bring it to the front. So walk — through
      // `_pollCommand`, which is the one place that charges the budget and
      // knows about the hold — and only so far.
      var next = Model.nextCursor(envelope.body)
      var page = Number(watch.findPage || 0) + 1
      if (next !== "" && page < recipeFindPages) {
        _commandWatch = _commandCopy({ findCursor: next, findPage: page })
        commandRunUpdated(job.requestKey, true, true, "", "looking", "", "")
        _pollCommand()
        return
      }
      // Out of pages, or out of list. The next look starts over from the
      // first page rather than from where this one stopped.
      _commandWatch = _commandCopy({ findCursor: "", findPage: 0 })
      commandRunUpdated(job.requestKey, true, true, "", "queued", "", "")
      _scheduleCommandPoll()
      return
    }
    // Kept for the next run of this recipe on this server, which is the one
    // thing that could be mistaken for this one. See `_lastRecipeRun`.
    _lastRecipeRun = { run: watch.run, id: Number(found.id) }
    // The walk is over — every look from here addresses the id — so the cursor
    // goes back to nothing rather than being left pointing mid-list.
    _commandWatch = _commandCopy({ commandId: found.id, findCursor: "", findPage: 0 })
    _afterRecipeState(job, found.attributes)
  }

  function _onRecipeShow(job, text) {
    var envelope = _commandAnswer(job, text)
    if (!envelope) return

    _afterRecipeState(job, Model.resourceAttributes(envelope.body))
  }

  // Where both recipe looks land. The command's equivalent is deliberately
  // silent when the run turns terminal, because the output is still a request
  // away and a finished pane with no lines reads as "printed nothing". Here it
  // is not: a recipe log carries its own `output`, so the state that ends the
  // run and the text that fills the pane arrive together, and this is the
  // landing that ends the watch.
  function _afterRecipeState(job, attributes) {
    var state = Model.recipeRunStateFrom(attributes)
    // The watch's id, like every other piece of evidence here: a run recognised
    // as *already* finished lands from the find, whose job was addressed before
    // there was an id to carry. It names the file `w` writes, so a job-shaped
    // one would be a file named after nothing.
    var logId = String(_commandWatch.commandId || "")
    if (state.running) {
      commandRunUpdated(job.requestKey, true, true, logId, state.header, "", "")
      _scheduleCommandPoll()
      return
    }
    // A recipe that printed nothing is a real answer — the empty string is
    // what lets the pane say so — and a null `output` is Forge saying it has
    // none to give, which for a run that failed before it started is the truth.
    var output = attributes ? attributes.output : null
    _commandWatch = null
    commandTimer.stop()
    commandRunUpdated(job.requestKey, true, false, logId, state.header,
                      typeof output === "string" ? output : "", "")
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

  // ---------------------------------------------------------- text out

  // Handing a whole document to another program, which is a different problem
  // from handing it a name. Linux caps one argv element at 128KB
  // (`MAX_ARG_STRLEN`), and a verbose deploy log can pass that — so the text
  // goes in on stdin, the same reason the token does in `api_request`. Nothing
  // here is an API request: no budget, no hold, no relation to `queue`.
  //
  // One process, so a second copy arriving mid-write waits rather than
  // clobbering the command of the one in flight.
  //
  // What it came to, told to the one screen that asked. Ticketed rather than
  // keyed by the path: a copy has no path at all, and two monitors saving the
  // same log would both answer to each other's. The words are minted with the
  // job — the caller's for a copy, the path's for a save — because whoever
  // asked knows what it was doing and the answer arrives long after it said so.
  signal pipeFinished(string ticket, bool ok, string message)

  property var _pipeJobs: []
  property int _pipeSeq: 0

  // Answers the ticket its `pipeFinished` will carry, the way `runSiteCommand`
  // answers the key its updates will.
  function _pipe(job) {
    job.ticket = String(++_pipeSeq)
    _pipeJobs = _pipeJobs.concat([job])
    _pumpPipe()
    return job.ticket
  }

  function _pumpPipe() {
    if (pipeProcess.running || _pipeJobs.length === 0) return
    var job = _pipeJobs[0]
    _pipeJobs = _pipeJobs.slice(1)
    pipeProcess.job = job
    pipeProcess.command = job.command
    // Armed here rather than re-armed after the last exit, so a start that
    // never happened cannot leave the next job with no stdin to write to.
    // `onStarted` turns it off again once it has written, which is what closes
    // the pipe. Same order as `_startAction`: the slot, then the process.
    pipeProcess.stdinEnabled = true
    pipeProcess.running = true
  }

  // `done` is what to say when it worked, because only the caller knows what it
  // just handed over — "Copied 412 lines" and "Copied ssh forge@…" are the same
  // request with different words.
  function copyToClipboard(text, done) {
    if (!text) return ""
    return _pipe({ text: String(text), command: ["wl-copy"],
                   done: String(done || "Copied"),
                   failed: "Could not copy — is wl-copy installed?" })
  }

  // `mkdir -p` because the download directory is a guess and may not exist yet.
  // The path is a positional argument, never part of the script, so it is data
  // to the shell rather than something it can be talked into running — and it
  // has already been through `Model.safeFileName` on the way here, so it cannot
  // have picked up a separator from a site name.
  function saveText(text, path) {
    return _pipe({ text: String(text || ""),
                   command: ["bash", "-c",
                             "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\"",
                             "forge-save", String(path)],
                   done: "Saved to " + String(path),
                   failed: "Could not write " + String(path) })
  }

  // `_finishFetch`'s terms, and the one place a copy or a save is answered.
  // A start that never happened arrives here with no exit code of its own, so
  // it is given one that cannot be mistaken for success.
  function _finishPipe(exitCode) {
    var job = pipeProcess.job
    if (!job) return
    pipeProcess.job = null
    var ok = exitCode === 0
    pipeFinished(job.ticket, ok, ok ? job.done : job.failed)
    _pumpPipe()
  }

  function downloadDir() {
    return Quickshell.env("XDG_DOWNLOAD_DIR")
      || (Quickshell.env("HOME") + "/Downloads")
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

  // Not folded into the ticker above: this one runs only in the seconds after a
  // write that asked for it, and its interval is chosen to outlast a flip
  // rather than to pace a refresh. See `_armSettle`.
  Timer {
    id: settleTimer
    interval: 8000
    repeat: true
    onTriggered: root._onSettleTick()
  }

  // Not `repeat`: every interval on the ladder is a different length, so each
  // tick is armed by the answer before it. See `_scheduleCommandPoll`.
  Timer {
    id: commandTimer
    interval: 3000
    repeat: false
    onTriggered: root._pollCommand()
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

  // The same watchdog for the write path, which needs one more than the read
  // path does: a hung read stalls the queue, and a hung write pins the only
  // slot there is — every later write answering "Still sending the last one"
  // and the row that asked stuck on `sending…` for the rest of the session.
  // Curl's own `--max-time` does not cover it, because the helper reads the
  // keyring first and a locked keyring never returns. Killing the child fires
  // `exited`, so the answer lands on the ordinary path.
  Timer {
    interval: 5000
    repeat: true
    running: actionProcess.running
    onTriggered: {
      if (Date.now() - root._actionStartedMs < root.requestTimeoutMs) return
      root._actionTimedOut = true
      actionProcess.running = false
    }
  }

  // The three processes below each answer through their terminal function, on
  // `exited` and again on `runningChanged`. See `_finishFetch` for why both.
  readonly property string failedToStart: "The Forge helper could not be started"

  Process {
    id: fetchProcess
    running: false
    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    onExited: root._finishFetch(String(fetchOut.text || ""))
    // A helper that never ran said nothing, so it is given something to say:
    // the job then fails through its own handler, which is what refuses the
    // pane behind it and pumps the queue.
    onRunningChanged: {
      if (!running && root._current)
        root._finishFetch(JSON.stringify(Model.errorEnvelope(root.failedToStart)))
    }
  }

  Process {
    id: pipeProcess
    property var job: null
    // Enabled in `_pumpPipe`, before the process starts. Written on `started`
    // rather than before it, because there is no stdin to write to until the
    // child exists — and disabling it again is what closes the pipe, which
    // `wl-copy` and `cat` both wait on: they read until EOF, and without the
    // close neither would ever finish.
    onStarted: {
      write(job ? job.text : "")
      stdinEnabled = false
    }
    onExited: function(exitCode) { root._finishPipe(exitCode) }
    onRunningChanged: { if (!running && job) root._finishPipe(-1) }
  }

  Process {
    id: actionProcess
    running: false
    // Enabled by `_startAction` when the job asked for `bodyStdin`, and written
    // the moment the child exists — the same dance `pipeProcess` does, and for
    // the same reason. The body is read off the job rather than copied here:
    // `_action` is the one home of the write in flight.
    stdinEnabled: false
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    onStarted: {
      if (!stdinEnabled || !root._action) return
      write(JSON.stringify(root._action.body))
      stdinEnabled = false
    }
    onExited: root._finishAction(String(actionOut.text || ""))
    onRunningChanged: {
      if (!running && root._action)
        root._finishAction(JSON.stringify(Model.errorEnvelope(root.failedToStart)))
    }
  }
}
