// Pure shaping of Forge API responses into the flat rows the panel draws.
// Nothing here touches QML types, so the whole file stays testable by reading.

.pragma library

// The API speaks JSON:API — every resource is {id, type, attributes}, and
// requested relationships arrive alongside the primary data in `included`.
// This flattens that into plain objects with the fields the panel uses.

function parseEnvelope(text) {
  try {
    var parsed = JSON.parse(String(text || ""))
    if (parsed && typeof parsed === "object") return parsed
  } catch (e) {}
  return { ok: false, status: 0, rateRemaining: null, rateReset: null, body: null,
           error: "The Forge helper returned something that wasn't JSON" }
}

function envelopeError(envelope) {
  if (!envelope) return "No response"
  if (envelope.error) return String(envelope.error)
  // Status before the body's own message: Forge words a 429 as "Too Many
  // Attempts.", which says nothing about what the widget just did with it.
  if (envelope.status === 401) return "Token rejected"
  if (envelope.status === 403) return "Token is missing a scope for this"
  if (envelope.status === 404) return "Not found"
  if (envelope.status === 429) return "Rate limited — backing off"
  var body = envelope.body
  if (body && body.message) return String(body.message)
  return "HTTP " + envelope.status
}

// When to start sending again after a refusal. `rateReset` is seconds from now
// when the helper could read it off the response; a 429 without one still has
// to wait, or the next tick just spends another request inside the same closed
// minute. The ceiling keeps a nonsense header from parking the widget.
var backoffFallbackSec = 60
var backoffCeilingSec = 300

function backoffUntilMs(envelope, now) {
  var seconds = Number(envelope ? envelope.rateReset : NaN)
  if (!isFinite(seconds) || seconds <= 0) seconds = backoffFallbackSec
  return now + Math.min(seconds, backoffCeilingSec) * 1000
}

// -------------------------------------------------------------------- servers

// Forge reports readiness across three fields that can disagree: a revoked
// server is gone, an unready one is still provisioning, and a ready one can
// still have lost its SSH connection. Collapse them into one state so both the
// bar icon and the rows read from the same judgement.
function serverState(attributes) {
  if (!attributes) return "unknown"
  if (attributes.revoked === true) return "revoked"
  if (attributes.is_ready !== true) return "provisioning"

  // connection_status is documented as a bare nullable string with no
  // enumeration, and what it actually returns for a healthy server is
  // "successful" — not something worth guessing at. So match known failures
  // rather than known successes: a value nobody has seen yet then reads as
  // healthy, instead of lighting up every server on the bar.
  var connection = String(attributes.connection_status || "").toLowerCase()
  if (connection === "") return "ready"
  if (/fail|error|refus|timeout|timed.?out|unreachable|denied|disconnect|lost/.test(connection))
    return "unreachable"
  if (/pending|connecting|checking|queued/.test(connection)) return "provisioning"
  return "ready"
}

function serverStateLabel(state) {
  switch (state) {
  case "ready": return "ready"
  case "provisioning": return "provisioning"
  case "unreachable": return "unreachable"
  case "revoked": return "revoked"
  }
  return "unknown"
}

function serversFrom(body) {
  var out = []
  var data = body && Array.isArray(body.data) ? body.data : []
  for (var i = 0; i < data.length; i++) {
    var resource = data[i]
    var a = resource.attributes || {}
    out.push({
      key: String(resource.id),
      id: String(resource.id),
      name: String(a.name || "server"),
      slug: String(a.slug || ""),
      kind: String(a.type || ""),
      provider: String(a.provider || ""),
      region: String(a.region || ""),
      ip: a.ip_address ? String(a.ip_address) : "",
      sshPort: Number(a.ssh_port) || 22,
      phpVersion: a.php_version ? String(a.php_version) : "",
      state: serverState(a)
    })
  }
  return out
}

function serverMeta(server) {
  var parts = []
  if (server.provider) parts.push(server.provider)
  if (server.region) parts.push(server.region)
  var location = parts.join(" · ")
  return server.ip ? (location ? location + " · " + server.ip : server.ip) : location
}

function sshCommand(server) {
  if (!server || !server.ip) return ""
  // This ends up on the clipboard for the user to paste into a terminal, so an
  // address from the API carrying anything but address characters is refused
  // rather than handed over as a command that would run more than ssh. The
  // class covers IPv4, IPv6 and hostnames; sshPort is already a Number.
  if (!/^[A-Za-z0-9.\-:]+$/.test(server.ip)) return ""
  var port = server.sshPort && server.sshPort !== 22 ? " -p " + server.sshPort : ""
  return "ssh forge@" + server.ip + port
}

// ---------------------------------------------------------------------- sites

// `?include=latestDeployment` returns the deployment as a sibling of the site
// rather than nested inside it, so build an id → resource map first.
function includedIndex(body) {
  var index = {}
  var included = body && Array.isArray(body.included) ? body.included : []
  for (var i = 0; i < included.length; i++) {
    var resource = included[i]
    if (!resource || !resource.type) continue
    index[String(resource.type) + ":" + String(resource.id)] = resource
  }
  return index
}

function relatedResource(resource, name, index) {
  var relationships = resource ? resource.relationships : null
  var relation = relationships ? relationships[name] : null
  var identifier = relation ? relation.data : null
  if (!identifier || !identifier.type) return null
  return index[String(identifier.type) + ":" + String(identifier.id)] || null
}

// Which server a site belongs to, read off its relationship linkage rather
// than from the path it was fetched through. The `include=server` that puts
// the linkage there at all is ARCHITECTURE.md's to explain.
function serverIdOf(resource) {
  var relationships = resource ? resource.relationships : null
  var relation = relationships ? relationships.server : null
  var identifier = relation ? relation.data : null
  return identifier && identifier.id ? String(identifier.id) : ""
}

function sitesFrom(body) {
  var out = []
  var data = body && Array.isArray(body.data) ? body.data : []
  var index = includedIndex(body)

  for (var i = 0; i < data.length; i++) {
    var resource = data[i]
    // A site with no server to sit under is not a row this panel can draw —
    // every key, every path and the whole tree are built from that id.
    var serverId = serverIdOf(resource)
    if (serverId === "") continue

    var a = resource.attributes || {}
    var repository = a.repository || {}
    var deployment = relatedResource(resource, "latestDeployment", index)
    var d = deployment ? (deployment.attributes || {}) : null
    var commit = d && d.commit ? d.commit : {}

    // The site's own deployment_status is the live one; the latest deployment
    // record is what finished last. Prefer the live value when there is one,
    // because a running deploy has not produced a record yet.
    var status = String(a.deployment_status || (d ? d.status : "") || "")

    var maintenance = a.maintenance_mode || {}

    out.push({
      key: serverId + ":" + String(resource.id),
      id: String(resource.id),
      serverId: serverId,
      name: String(a.name || "site"),
      url: a.url ? String(a.url) : "",
      https: a.https === true,
      siteStatus: String(a.status || ""),
      deploymentStatus: status,
      // The log endpoint addresses a deployment by id, and this is the only
      // place that id is ever in reach — it costs nothing to keep, because
      // `include=latestDeployment` has already paid for it.
      deploymentId: deployment ? String(deployment.id) : "",
      branch: repository.branch ? String(repository.branch) : "",
      repoUrl: repository.url ? String(repository.url) : "",
      quickDeploy: a.quick_deploy === true,
      deployedAt: d ? String(d.ended_at || d.started_at || "") : "",
      commitHash: commit.hash ? String(commit.hash).substring(0, 7) : "",
      commitMessage: commit.message ? String(commit.message).split("\n")[0] : "",
      // The rest of what the site payload already carries, for the detail
      // view. `aliases` comes back null rather than empty when there are none.
      // Deliberately absent: `deployment_url`, which carries a live deploy
      // token in a query parameter and has no business on a screen.
      phpVersion: a.php_version ? String(a.php_version) : "",
      appType: a.app_type ? String(a.app_type) : "",
      isolated: a.isolated === true,
      zeroDowntime: a.zero_downtime_deployments === true,
      usesEnvoyer: a.uses_envoyer === true,
      wildcards: a.wildcards === true,
      deploymentRetention: Number(a.deployment_retention || 0),
      healthcheckUrl: a.healthcheck_url ? String(a.healthcheck_url) : "",
      aliases: Array.isArray(a.aliases) ? a.aliases.map(String) : [],
      maintenance: maintenance.enabled === true,
      // Forge does the flip out on the box, so `enabled` stays put for a few
      // seconds after a toggle is accepted and `status` is the only thing that
      // moves. Keeping it is what lets a row report the flip instead of
      // looking unchanged until the next sweep: "enabling" | "disabling".
      maintenanceStatus: maintenance.status ? String(maintenance.status) : ""
    })
  }
  return out
}

// Sites sort here because their endpoint accepts `sort` with a 200 and
// ignores it. localeCompare, not `<`: the server level arrives API-sorted by
// name, and two levels of one tree ordered by different collations read as
// disorder — `Zeta` before `admin`.
function sortSites(list) {
  return (list || []).slice().sort(function (a, b) {
    return a.name.localeCompare(b.name)
  })
}

// Ids are API data, so a map keyed by them gets no prototype and its reads no
// inherited fallbacks — an id spelled `constructor` has to be a key like any
// other, not a function `push` blows up on.
function idMap() {
  return Object.create(null)
}

function hasKey(map, key) {
  return map ? Object.prototype.hasOwnProperty.call(map, key) : false
}

// This and the two builders after it are the only ways `sitesByServer` is
// ever built, so the key form — String(server.id) — cannot drift. Which one
// runs is a statement about how much of the organization the caller has seen;
// ARCHITECTURE.md lays out the split.
//
// Here the caller has the whole site list, so every server gets a key and an
// empty one means "genuinely no sites" — this is the one publish allowed to
// make a deleted site disappear.
function groupSitesByServer(sites, servers) {
  var out = idMap()
  var list = servers || []
  for (var i = 0; i < list.length; i++) out[String(list[i].id)] = []

  var sorted = sortSites(sites)
  for (var j = 0; j < sorted.length; j++) {
    // A site whose server did not come back — the server list was cut short at
    // the page cap, or the server went away between the two requests — has
    // nowhere to sit, so it is dropped rather than given a home of its own.
    if (hasKey(out, sorted[j].serverId)) out[sorted[j].serverId].push(sorted[j])
  }
  return out
}

// The window builder: `observed` is one rotation window's worth of an org
// list that arrives in no useful order, so a window can hold two of a
// server's ten sites — replacing a server's list from it would delete the
// eight it never reached. Observed sites update in place (by site id,
// observed wins), every other site is kept exactly as it was, and deletions
// wait for the wrap. With `observed` empty this is the orphan prune: servers
// still present keep their lists, servers gone lose them.
function mergeSitesByServer(previous, observed, servers) {
  var byServer = idMap()
  var seen = observed || []
  for (var i = 0; i < seen.length; i++) {
    if (!hasKey(byServer, seen[i].serverId)) byServer[seen[i].serverId] = []
    byServer[seen[i].serverId].push(seen[i])
  }

  var out = idMap()
  var list = servers || []
  for (var j = 0; j < list.length; j++) {
    var id = String(list[j].id)
    var kept = hasKey(previous, id) ? previous[id] : []
    if (!hasKey(byServer, id)) { out[id] = kept; continue }

    var byId = idMap()
    for (var k = 0; k < kept.length; k++) byId[kept[k].id] = kept[k]
    var fresh = byServer[id]
    for (var l = 0; l < fresh.length; l++) byId[fresh[l].id] = fresh[l]
    var merged = []
    for (var key in byId) merged.push(byId[key])
    out[id] = sortSites(merged)
  }
  return out
}

// The single-server builder: the per-server endpoint is complete for exactly
// that server, so its list is replaced outright while every other server
// keeps what it had — the one replace that needs no wrap to be safe.
function replaceServerSites(previous, serverId, sites, servers) {
  var target = String(serverId)
  var out = idMap()
  var list = servers || []
  for (var i = 0; i < list.length; i++) {
    var id = String(list[i].id)
    out[id] = id === target ? sortSites(sites)
      : hasKey(previous, id) ? previous[id] : []
  }
  return out
}

// The rotation's memory: everything observed since the walk last started, so
// the wrap can rebuild the whole organization from it. Deduped by site key
// with the later observation winning — a list shifting under the cursor can
// serve one row to two windows, and an on-unfold fetch can outrun the walk.
function mergeSweepSites(accumulated, observed) {
  var byKey = idMap()
  var all = (accumulated || []).concat(observed || [])
  for (var i = 0; i < all.length; i++) byKey[all[i].key] = all[i]
  var out = []
  for (var key in byKey) out.push(byKey[key])
  return out
}

// A page whose rows all lack the server linkage is not an empty organization —
// it is the API no longer honouring `include=server`, or a token scoped to
// see sites but not servers. Silence here would publish zero sites under a
// healthy icon, so the caller turns it into an error instead. A page where
// only some rows lack it keeps the rows that have one.
function sitesLinkageMissing(body, sites) {
  var data = body && Array.isArray(body.data) ? body.data : []
  return data.length > 0 && (sites || []).length === 0
}

// Counts what the panel actually draws — the note quoting this is a promise
// about the screen, so rows dropped at grouping must not be counted.
function countSites(sitesByServer) {
  var total = 0
  for (var id in sitesByServer) total += sitesByServer[id].length
  return total
}

// A site can be deployed to when it has a repository at all — a site with no
// repo (a static vhost, a load balancer entry) has nothing to deploy.
function canDeploy(site) {
  return !!(site && site.repoUrl)
}

// --------------------------------------------------------------------- events

// One page of a server's feed, flattened. An event carries no status — Forge
// records what it did and what that printed, not whether it worked — so there
// is nothing here for a tone to report, and a row is a description and a time.
// The site is the *name*, deliberately: a row carrying a `siteId` would be one
// `currentSite` resolves, and `d` on an event must not arm a deploy of the site
// the event happened to mention. Sorted here as well as by the request, on the
// `sortSites` precedent: an order the panel depends on is imposed locally.
function eventsFrom(body) {
  var out = []
  var data = body && Array.isArray(body.data) ? body.data : []
  var index = includedIndex(body)
  for (var i = 0; i < data.length; i++) {
    var resource = data[i]
    var a = resource.attributes || {}
    var site = relatedResource(resource, "site", index)
    var siteName = site && site.attributes ? site.attributes.name : ""
    out.push({
      id: String(resource.id),
      description: String(a.description || "event"),
      ranAs: a.ran_as ? String(a.ran_as) : "",
      siteName: siteName ? String(siteName) : "",
      createdAt: a.created_at ? String(a.created_at) : ""
    })
  }
  return out.sort(function (x, y) {
    return (Date.parse(y.createdAt) || 0) - (Date.parse(x.createdAt) || 0)
  })
}

// -------------------------------------------------------------------- recipes

// An organization's saved scripts, flattened. The `script` itself is not kept:
// nothing draws it, and a recipe is a whole shell program — tens of kilobytes
// of it in a property every panel re-reads is the deploy log's mistake made at
// rest. The first line is kept instead, which is what a row can show.
//
// Sorted here for `sortSites`'s reason and then some: this endpoint takes no
// `sort` parameter at all, so the order Forge sends is the only one there is.
function recipesFrom(body) {
  var out = []
  var data = body && Array.isArray(body.data) ? body.data : []
  for (var i = 0; i < data.length; i++) {
    var resource = data[i]
    var a = resource.attributes || {}
    var script = String(a.script || "")
    out.push({
      id: String(resource.id),
      name: String(a.name || "recipe"),
      user: String(a.user || ""),
      firstLine: script.split("\n")[0].trim(),
      updatedAt: a.updated_at ? String(a.updated_at) : ""
    })
  }
  return out.sort(function (x, y) {
    return x.name.localeCompare(y.name)
  })
}

// ------------------------------------------------------------- site actions

// The three logs Forge keeps for a site, in the order the view lists them: the
// application log first because it is the one a Laravel site's own errors land
// in, then nginx's two with the error log ahead of the access log — a site that
// answers 500 is the reason anyone opens this, and the access log is a tail of
// hits, which is rarely what is being looked for.
//
// One table rather than three literals: the actions, the request, the pane's
// breadcrumb and the saved file's name all have to agree on both halves of a
// pair, and this is the only place either is written down.
var siteLogKinds = [
  { kind: "application", label: "Application log" },
  { kind: "nginx-error", label: "Nginx error log" },
  { kind: "nginx-access", label: "Nginx access log" }
]

function siteLogs() {
  return siteLogKinds.slice()
}

function isSiteLogKind(kind) {
  var wanted = String(kind || "")
  for (var i = 0; i < siteLogKinds.length; i++)
    if (siteLogKinds[i].kind === wanted) return true
  return false
}

// Falls back to the kind itself rather than to an empty string: an unknown kind
// reaching a breadcrumb is a bug, and one that reads "nginx-error" points at it
// where a blank crumb hides it.
function siteLogLabel(kind) {
  var wanted = String(kind || "")
  for (var i = 0; i < siteLogKinds.length; i++)
    if (siteLogKinds[i].kind === wanted) return siteLogKinds[i].label
  return wanted
}

// What the site view offers, in the order it offers it. Pure: the panel turns
// these into rows and decides what a keypress does with one, and the labels
// and the reasons live here beside the predicates that disable them.
//
// `hint` is the key that reaches the same action straight from the list, so
// the view teaches the accelerator rather than hiding it. An unavailable
// action is still listed — a missing "Deployment log" would read as a bug,
// where one that says "never deployed" answers the question. `armable` marks
// the two that write: it is what `rowView` hangs the arm key on, and seven of
// these ten change nothing on a server — `command` is the third that writes,
// and only because of what the prompt it opens eventually sends.
//
// Takes the org because the maintenance toggle sends somewhere, and a path
// cannot be built without it — the same reason `serverActions` takes one.
function siteActions(org, site) {
  var deployable = canDeploy(site)
  var deployed = !!(site && site.deploymentId)
  var url = site ? externalUrl(site.url) : ""
  // The subject can be gone from the API — see the panel's `actionRows`. Every
  // predicate here answers for that rather than reaching into nothing.
  var parked = !!(site && site.maintenance)
  var moving = site ? String(site.maintenanceStatus) : ""
  // The three logs, on the same terms as `log` below: an id the panel switches
  // on, no `armable` and no `path`, because what they open is a pane. Generated
  // from `siteLogKinds` rather than written out, so the order and the wording
  // stay one decision. The `log` on each is what the request needs and the
  // labels do not carry.
  var logs = siteLogKinds.map(function (entry) {
    return { id: "site-log:" + entry.kind, log: entry.kind, label: entry.label,
             hint: "", available: !!site, reason: "not listed" }
  })
  return [
    { id: "deploy", label: "Deploy", hint: "d", armable: true,
      // The arm belongs to the *site*, not to this row: the tree's row for the
      // same site reports the same deploy and has to light up with it.
      armsSubject: true,
      available: deployable, reason: deployable ? "" : "no repository" },
    // Takes the site offline for everyone who visits it, and brings it back on
    // the same two presses — so the deploy's confirm is the right weight, and
    // the reboot's `Y` would be miscalibrated for something this reversible.
    //
    // `armIntent` rides into the arm key. The label and the method here are
    // derived from live state, and this list is rebuilt on every refresh, so a
    // sweep landing inside the arm window would otherwise turn a "press again
    // to take the site offline" into a DELETE. Folding the intent into the key
    // means the flip invalidates the arm instead of silently retargeting it.
    { id: "maintenance", hint: "",
      label: parked ? "Disable maintenance mode" : "Enable maintenance mode",
      armable: true, confirm: "again", armIntent: parked ? "off" : "on",
      // Forge is out on the box doing the flip; pressing again until it lands
      // would only race it.
      available: !!site && moving === "",
      reason: !site ? "not listed" : moving ? moving + " now" : "",
      armedText: parked ? "press again to bring the site back"
                        : "press again to take the site offline",
      done: parked ? "Maintenance mode off — requested"
                   : "Maintenance mode on — requested",
      method: parked ? "DELETE" : "POST",
      scopeMessage: "Your token can't change maintenance mode — that needs "
        + "the site:manage-commands scope",
      // What changed rides the *sites* payload rather than the server list, and
      // `enabled` does not move until Forge has finished out on the box — so
      // one look is not enough to see the flip land. See `Service._armSettle`.
      refetch: "sites", settleSites: true,
      path: site ? maintenancePath(org, site.serverId, site.id) : "",
      // `status` is the only field Forge requires, and 503 is the one value in
      // its enum that means "come back later". `secret` and `redirect` are the
      // other two it accepts and both stay out: they are free text with no
      // reading on a row, and a maintenance toggle is not the place to type.
      // Running a command is, and it is the one body here a user writes — so it
      // travels on stdin rather than in the argv this one rides. See
      // `siteCommandAction`.
      body: parked ? null : { status: 503 } },
    // No `armable` and no path: this one opens a prompt, the way `log` opens a
    // pane. What it eventually sends is declared in `siteCommandAction`, which
    // cannot be built until there is a command to put in it.
    { id: "command", label: "Run a command", hint: "",
      available: !!site, reason: "not listed" },
    { id: "log", label: "Deployment log", hint: "",
      available: deployed, reason: deployed ? "" : "never deployed" }
  ].concat(logs, [
    { id: "open", label: "Open site", hint: "o",
      available: url !== "", reason: url !== "" ? "" : "no address" },
    { id: "forge", label: "Open in Forge", hint: "f", available: true, reason: "" },
    { id: "ssh", label: "Copy ssh command", hint: "s", available: true, reason: "" }
  ])
}

// The row the command prompt arms, built from what has been typed rather than
// from the site alone — which is why it is a function of its own and not a
// seventh entry in `siteActions`. Everything else about it is an ordinary write
// job, so `Panel.runWriteAction` and `Service._startAction` need no special
// case beyond the two below.
//
// `confirm: "Y"` rather than the deploy's "again": this is arbitrary remote
// code execution, so it takes the same second key a reboot does, and for the
// same reason — the press that sends it should be one nothing else means.
//
// `bodyStdin` is the other difference. Every other body here is a fixed word
// decided in this file; this one is what someone typed, and while it is not a
// credential it can quote one, so it does not go in an argv that
// /proc/<pid>/cmdline hands to every process on the machine.
//
// The text is trimmed once, here, and everything downstream uses what this
// sends: Forge stores the command as it received it and `commandFrom` compares
// the two exactly, so a trailing space typed into the field would leave the run
// unfindable — it would be on the box and the pane would never see it.
function siteCommandAction(org, site, command) {
  var text = String(command === undefined || command === null ? "" : command).trim()
  var ready = !!site && text !== ""
  return { id: "command-run", label: "Run", hint: "",
           armable: true, confirm: "Y",
           // Rides into the arm key, for the reason the maintenance toggle's
           // does — and more so: this row *is* its text. The field can still be
           // typed into for one turn of the event loop after enter has armed it
           // (see `Panel.stopCommandEditing`), and without the intent that
           // keystroke would leave the arm matching a row that now runs
           // something else.
           armIntent: text,
           available: ready,
           reason: !site ? "not listed" : "type a command first",
           armedText: "press Y to run",
           // Forge answers 202 and goes off to the box, the same as every other
           // write here — the pane that opens next is what says how it went.
           done: "Command sent",
           method: "POST",
           scopeMessage: "Your token can't run commands — that needs the "
             + "site:manage-commands scope",
           path: site ? commandsPath(org, site.serverId, site.id) : "",
           body: { command: text }, bodyStdin: true }
}

// ------------------------------------------------------------ command runs

// Forge's five states, split the one way the pane cares about. `waiting` is
// queued and `running` is on the box; both mean look again.
function commandIsTerminal(status) {
  var value = String(status || "")
  return value === "finished" || value === "timeout" || value === "failed"
}

// The line above the output. `status` is the only field that has always been
// populated — a command run long enough ago comes back with a null `exit_code`
// and a null `error_output` even when it plainly failed — so the state word
// leads and everything else is added only when it is there.
function commandStateFrom(attributes) {
  var attrs = attributes || {}
  var status = String(attrs.status || "")
  var parts = [status === "" ? "unknown" : status]
  var duration = String(attrs.duration || "")
  if (duration !== "") parts.push(duration)
  if (typeof attrs.exit_code === "number") parts.push("exit " + attrs.exit_code)
  var failure = plainText(attrs.error_output || "")
  if (failure !== "") parts.push(failure)
  return { running: !commandIsTerminal(status), status: status,
           bad: status === "failed" || status === "timeout",
           header: parts.join(" · ") }
}

// The header's first word is always the state — see `commandStateFrom` — and it
// is what decides whether the line is drawn as a failure. Read back rather than
// carried alongside, so the two never disagree about which words are bad.
function commandHeaderBad(header) {
  var word = String(header || "").split(" ")[0]
  return word === "failed" || word === "timeout"
}

// Which row of the index is the run that was just sent. Forge answers the POST
// 202 with no body at all — unlike a deploy, which hands its resource back — so
// the id has to be recognised rather than received.
//
// Matching on the command text alone would adopt an identical run somebody
// started from the dashboard an hour ago, so the send time is the other half of
// it. The margin is generous because `created_at` is Forge's clock, not this
// machine's, and only has to separate this run from the history behind it.
var commandClockSkewMs = 120000

// Which leaves the run the *user* just made themselves, and that margin is far
// too wide for: re-running the same command a minute later, which is what
// reading a failure and trying again is, would adopt the failure. So the caller
// carries `afterMs` — the `created_at` of the last run it adopted for this site
// and this text — and a candidate has to be newer than that. Exact rather than
// generous, because this half compares one Forge timestamp with another and no
// clock skew comes into it. It is a floor rather than a single id, so three
// repeats in a row are covered by the same number as two.
function commandFrom(body, sent, sinceMs, afterMs) {
  var rows = body && body.data ? body.data : []
  if (!rows.length) return null
  var text = String(sent || "")
  var floor = Math.max(Number(sinceMs || 0) - commandClockSkewMs,
                       Number(afterMs || 0) + 1)
  for (var i = 0; i < rows.length; i++) {
    var attrs = rows[i].attributes || {}
    if (String(attrs.command || "") !== text) continue
    var made = Date.parse(String(attrs.created_at || ""))
    if (isNaN(made) || made < floor) continue
    // `madeMs` is what the caller keeps to become the next run's `afterMs`.
    return { id: String(rows[i].id), attributes: attrs, madeMs: made }
  }
  return null
}

// Running one of the organization's recipes on one server. The body is decided
// here rather than typed, so unlike the site command it rides the argv the way
// the maintenance toggle's does — there is nothing in it a user wrote.
//
// `Y` rather than two presses, on the reboot's reasoning and more of it: a
// recipe is an arbitrary script, usually run as root, and this widget cannot
// show what is in it. No `armIntent`: neither the path nor the body depends on
// live state, so a refresh landing inside the arm window rebuilds a row that
// means exactly what it meant — and a recipe deleted under the arm loses its
// row entirely, which `confirmArmed` already reports.
function recipeRunAction(org, server, recipe) {
  var state = server ? String(server.state) : "unknown"
  var ready = state === "ready"
  // Forge takes the server as a number. An id that is not one would reach the
  // API as `null` inside the array, so the row refuses instead of sending it.
  var serverId = server ? parseInt(server.id, 10) : NaN
  var addressable = !!recipe && isFinite(serverId)
  var available = addressable && ready
  return { id: "recipe-run", label: recipe ? String(recipe.name) : "",
           hint: "", armable: true, confirm: "Y",
           available: available,
           reason: available ? "" : !addressable ? "not listed" : serverStateLabel(state),
           armedText: "press Y to run on " + (server ? String(server.name) : "this server"),
           // Forge answers 202 and goes off to the box; the pane that opens
           // next is what says how it went.
           done: "Recipe run requested",
           method: "POST",
           scopeMessage: "Your token can't run recipes — that needs the "
             + "recipe:manage scope",
           recipeId: recipe ? String(recipe.id) : "",
           path: addressable ? recipeRunsPath(org, recipe.id) : "",
           body: addressable ? { servers: [serverId] } : null }
}

// -------------------------------------------------------------- recipe runs

// Forge's four, split the one way the pane cares about — the same shape the
// command's status has, minus `timeout`, which a recipe cannot report.
function recipeRunIsTerminal(status) {
  var value = String(status || "")
  return value === "finished" || value === "failed"
}

// The line above the output, on `commandStateFrom`'s terms: the state word
// leads, so `commandHeaderBad` reads a recipe's header as well as a command's,
// and everything after it is added only when it is there. A recipe log carries
// no `duration` of its own, so the two timestamps make one — and only when
// both parse, because a run still on the box has no `finished_at` at all.
function recipeRunStateFrom(attributes) {
  var attrs = attributes || {}
  var status = String(attrs.status || "")
  var parts = [status === "" ? "unknown" : status]
  var started = Date.parse(String(attrs.started_at || ""))
  var finished = Date.parse(String(attrs.finished_at || ""))
  if (!isNaN(started) && !isNaN(finished) && finished >= started)
    parts.push(Math.max(1, Math.round((finished - started) / 1000)) + "s")
  return { running: !recipeRunIsTerminal(status), status: status,
           bad: status === "failed",
           header: parts.join(" · ") }
}

// Which row of the recipe's run list is the run that was just sent. Forge
// answers this POST 202 with no body either, so this is `commandFrom`'s job
// with different evidence — and the evidence is thinner, because a recipe log
// has no text to match on and no `created_at`. What it has instead is a
// `server_id`, and a run this widget sends goes to exactly one server.
//
// So: the right server, then the same two floors the command uses, in the same
// two flavours. `started_at` is the generous one — Forge's clock against this
// machine's — and it is null until the run leaves the queue, which is the
// ordinary state of a log a second after sending, so a null passes. The id
// floor is the exact one: it separates this run from the user's own previous
// run of the same recipe on the same server, which is what reading a failure
// and running it again is, and it compares two Forge ids with no skew in it.
//
// The highest id wins rather than the first row, because the order this list
// comes back in is not documented and not verified — see ARCHITECTURE.md.
function recipeRunFrom(body, serverId, sinceMs, afterId) {
  var rows = body && body.data ? body.data : []
  var server = Number(serverId)
  var floor = Number(afterId || 0)
  var skewFloor = Number(sinceMs || 0) - commandClockSkewMs
  var best = null
  for (var i = 0; i < rows.length; i++) {
    var attrs = rows[i].attributes || {}
    if (Number(attrs.server_id) !== server) continue
    var id = Number(rows[i].id)
    if (!isFinite(id) || id <= floor) continue
    // Not started yet is not evidence against it — that is what a run waiting
    // in Forge's queue looks like, and it is the state this arrives in.
    var startedAt = String(attrs.started_at || "")
    if (startedAt !== "") {
      var started = Date.parse(startedAt)
      if (!isNaN(started) && started < skewFloor) continue
    }
    if (!best || id > Number(best.id)) best = { id: String(rows[i].id), attributes: attrs }
  }
  return best
}

// ----------------------------------------------------------- server actions

// Which PHP pool a PHP action would act on. Forge runs one FPM pool per version
// and the endpoint takes the version rather than inferring it, so a server that
// reported none has nothing to send. The class is the same idea as
// `sshCommand`'s: Forge's enum runs `php5` through `php85` with one `-old`
// variant, and a value outside it would earn a 422 — a worse answer than a row
// that says it doesn't know which pool it would restart. It also makes the
// version safe to put in a label.
function phpPoolVersion(server) {
  var value = server ? String(server.phpVersion || "") : ""
  return /^php[0-9]{1,3}(-old)?$/.test(value) ? value : ""
}

// What the server view offers. Shaped like `siteActions` — the same
// {id,label,hint,available,reason} the panel turns into rows — plus what a
// write needs: the path and body to send, what the row says while it is armed,
// what to flash when Forge takes it, and how it has to be confirmed.
//
// Only the everyday restarts are here. The API also offers `stop` on every
// service and `power-cycle` on the server; neither belongs on a keypress from a
// bar, and a service stopped from here is one nothing in this widget could
// start again.
//
// A server that is provisioning or revoked answers 4xx to all of this, so the
// row says the state instead of spending a request to be told it. Rebooting is
// the exception that stays available when the server is unreachable: it is the
// one action that might fix that, and Forge refusing it is a better answer than
// a row that won't try.
function serverActions(org, server) {
  var state = server ? String(server.state) : "unknown"
  var ready = state === "ready"
  var stateReason = server ? serverStateLabel(state) : "not listed"
  var php = phpPoolVersion(server)
  var hasPhp = ready && php !== ""
  var rebootable = ready || state === "unreachable"
  var ssh = sshCommand(server)
  var id = server ? server.id : ""
  var suffix = php ? " (" + php + ")" : ""
  // All four writes here go out on the one scope, so the refusal is written
  // once. It rides the action rather than the service because it is the wording
  // for *this* endpoint, and the wrapper that sends it is shared.
  var scopeMessage = "Your token can't manage servers — that needs "
    + "the server:manage-services scope"
  return [
    { id: "nginx-restart", label: "Restart nginx", hint: "",
      available: ready, reason: ready ? "" : stateReason,
      armable: true, confirm: "again",
      armedText: "press again to restart nginx",
      done: "nginx restart requested",
      scopeMessage: scopeMessage,
      path: serviceActionPath(org, id, "nginx"),
      body: { action: "reboot" } },
    { id: "php-reload", label: "Reload PHP-FPM" + suffix, hint: "",
      available: hasPhp, reason: hasPhp ? "" : !ready ? stateReason : "no PHP version reported",
      armable: true, confirm: "again",
      armedText: "press again to reload PHP-FPM",
      done: "PHP-FPM reload requested",
      scopeMessage: scopeMessage,
      path: serviceActionPath(org, id, "php"),
      body: { action: "reload", version: php } },
    { id: "php-restart", label: "Restart PHP-FPM" + suffix, hint: "",
      available: hasPhp, reason: hasPhp ? "" : !ready ? stateReason : "no PHP version reported",
      armable: true, confirm: "again",
      armedText: "press again to restart PHP-FPM",
      done: "PHP-FPM restart requested",
      scopeMessage: scopeMessage,
      path: serviceActionPath(org, id, "php"),
      body: { action: "reboot", version: php } },
    // The one row here that takes every site on the server down with it, so it
    // is confirmed by a key nothing else in the panel uses and no movement key
    // could reach. See the panel's `runWriteAction`.
    { id: "reboot", label: "Reboot server", hint: "",
      available: rebootable, reason: rebootable ? "" : stateReason,
      armable: true, confirm: "Y",
      armedText: "press Y to reboot",
      done: "Reboot requested",
      scopeMessage: scopeMessage,
      // A restarted service changes nothing this widget draws. A rebooting
      // server changes its own state, and that arrives with the server list.
      refetch: "org",
      path: serverActionPath(org, id),
      body: { action: "reboot" } },
    // Always available: an unreachable server is exactly the one whose feed is
    // worth reading, and a read is what the row is.
    { id: "events", label: "Server events", hint: "e", available: true, reason: "" },
    // A door rather than a write: what it opens is the organization's recipe
    // list, and the row pressed there is the one that sends. Always available
    // for the list's sake — the recipes are the organization's, so there are
    // some to read even when this server is in no state to run one, and the
    // row there says so.
    { id: "recipes", label: "Run a recipe…", hint: "", available: true, reason: "" },
    { id: "forge", label: "Open in Forge", hint: "f", available: true, reason: "" },
    { id: "ssh", label: "Copy ssh command", hint: "s",
      available: ssh !== "", reason: ssh !== "" ? "" : "no public IP" }
  ]
}

// The rest of the site payload, which `sitesFrom` keeps and nothing showed
// until now. Every one of these arrived in the same response the panel already
// pays for, so the detail block costs no request at all. Empty values are
// dropped rather than shown blank, so a site says only what is true of it.
function siteDetails(site) {
  if (!site) return []
  var out = []
  var add = function (label, value) { if (value !== "" && value !== null) out.push({ label: label, value: String(value) }) }

  add("PHP", site.phpVersion)
  add("Type", site.appType)
  add("Status", site.siteStatus)
  // "enabling"/"disabling" while Forge is still working on the flip, so the
  // block says which way it is going rather than lagging a refresh behind.
  if (site.maintenanceStatus) add("Maintenance", site.maintenanceStatus)
  else if (site.maintenance) add("Maintenance", "on")
  if (site.isolated) add("Isolation", "isolated user")
  if (site.zeroDowntime) add("Deploys", "zero downtime")
  if (site.usesEnvoyer) add("Deploys", "via Envoyer")
  if (site.deploymentRetention > 0) add("Keeps", pluralize(site.deploymentRetention, "release"))
  if (site.aliases && site.aliases.length > 0) add("Aliases", site.aliases.join(" · "))
  add("Healthcheck", site.healthcheckUrl)
  return out
}

// -------------------------------------------------------------------- status

// Three tones is all the panel needs: something is wrong, something is
// happening, or everything is quiet.
function deploymentTone(status) {
  switch (String(status || "").toLowerCase()) {
  case "failed":
  case "failed-build":
    return "bad"
  case "deploying":
  case "pending":
  case "queued":
  case "installing":
  case "creating":
    return "busy"
  case "finished":
  case "deployed":
  case "installed":
    return "ok"
  }
  return "idle"
}

// Which fact a site reports — its deployment's, unless maintenance mode
// outranks it. A running or failed deploy still wins: those are the transient
// thing you opened the panel to look at, and a site that is both parked and
// broken is worth knowing about as broken.
//
// The precedence is spelled out here and nowhere else; `siteTone` and
// `siteStatus` are both thin readers of it. The two maintenance verdicts are
// named rather than toned because the tone alone could not tell `siteStatus`
// which words to use: a flip Forge is still working on pulses exactly like a
// deploy does, and one it has finished is a settled state of its own.
function _siteFact(site) {
  if (!site) return "idle"
  var tone = deploymentTone(site.deploymentStatus)
  if (tone === "busy" || tone === "bad") return tone
  if (site.maintenanceStatus) return "flip"
  if (site.maintenance) return "parked"
  return tone
}

// What a site reports and in what tone. Both halves come back together because
// they have to agree, and everything that draws a site asks here — the row and
// the panel's hero — rather than each spelling the precedence out again.
//
// `timed` says whether the label is the *deployment's*, which is the only one
// the deployment's timestamp belongs beside: "maintenance · 2h ago" would date
// the wrong fact. See the panel's `siteDetailLine`.
function siteStatus(site) {
  var fact = _siteFact(site)
  if (fact === "flip")
    return { label: String(site.maintenanceStatus) + "…", tone: "busy", timed: false }
  if (fact === "parked") return { label: "maintenance", tone: "warn", timed: false }
  return { label: site ? deploymentLabel(site.deploymentStatus) : "",
           tone: fact, timed: !!site }
}

// The tone alone, for the two callers that colour something without labelling
// it — the service's aggregate health and the panel's hero badge. It reads the
// fact directly rather than `siteStatus().tone` because those two walk every
// site of an organization on every sweep page, and the label they would throw
// away costs a lowercase, a regex and an object each time.
function siteTone(site) {
  var fact = _siteFact(site)
  return fact === "flip" ? "busy" : fact === "parked" ? "warn" : fact
}

function serverTone(state) {
  switch (state) {
  case "unreachable":
  case "revoked":
    return "bad"
  case "provisioning":
    return "busy"
  case "ready":
    return "ok"
  }
  return "idle"
}

function deploymentLabel(status) {
  var value = String(status || "").toLowerCase()
  if (value === "") return "never deployed"
  if (value === "failed-build") return "build failed"
  return value.replace(/-/g, " ")
}

// -------------------------------------------------------------------- rows

// One panel row's text and tone, whatever the row stands for. The panel
// resolves a row into its facts and hands them over as `ctx`; the branching on
// which kind it is lives here, in one readable place, rather than repeated
// inside four separate bindings in the delegate. The site view's action rows
// come through here too, so every view draws with the same delegate.
//
// ctx: { server, site, orgLabel, orgHealth, orgSummary, siteCount,
//        showOrgHeaders, action, event, recipe, armKey }
//
// Nothing here may touch a QML type, so the result carries `depth` rather than
// a pixel indent and `tone` rather than a colour — ForgeRow owns the metrics
// and the palette those turn into.
// A site row in the tree arms without going through an action at all — `d`
// reaches it directly — so the deploy's wording is the default rather than
// something the deploy action has to carry.
var defaultArmedText = "press again to deploy"

function rowView(row, ctx) {
  var kind = row ? String(row.kind) : ""
  var c = ctx || {}

  if (kind === "org") {
    // An organization row stands for everything under it, so it wears the
    // same verdict the bar icon would give that one.
    var health = String(c.orgHealth || "setup")
    var tone = health === "bad" || health === "error" ? "bad"
      : health === "setup" ? "idle"
      : health === "busy" ? "busy"
      : health === "maintenance" ? "warn" : "ok"
    // The slug is what the dashboard URL uses, so it is worth showing when the
    // name differs from it.
    var slug = String(row.org)
    return {
      kind: kind,
      label: String(c.orgLabel || slug),
      detail: String(c.orgLabel || slug) === slug ? "" : slug,
      status: String(c.orgSummary || ""),
      tone: tone,
      depth: 0,
      showChevron: true,
      actionKey: "",
      armedText: "",
      timeAt: ""
    }
  }

  // An action row belongs to the site view rather than to the tree, so it has
  // no depth and no dot: there is no hierarchy to place it in and no remote
  // state for a tone to report. What it does carry is its accelerator, in the
  // slot a site row uses for its deployment state, and — when it can't be run
  // — the reason, where a site row puts its branch.
  if (kind === "action") {
    var action = c.action || {}
    return {
      kind: kind,
      label: String(action.label || ""),
      detail: action.available === false ? String(action.reason || "") : "",
      status: action.hint ? "[" + String(action.hint) + "]" : "",
      tone: "idle",
      depth: 0,
      showChevron: false,
      // The key the arm and the send are reported on. Only an action that
      // writes carries one: handing it to `Open in Forge` as well would light
      // up the whole list on one pending action. In the site view it is the
      // site's own key, because the tree's site row reports the same deploy and
      // has to light up with it; in the server view it is the row's, because
      // two of the four rows send to the same endpoint and only the one that
      // was pressed should say so.
      actionKey: action.armable === true ? String(c.armKey || "") : "",
      armedText: String(action.armedText || defaultArmedText),
      timeAt: ""
    }
  }

  if (kind === "site") {
    var site = c.site
    var parts = []
    if (site && site.branch) parts.push(site.branch)
    if (site && site.commitHash) parts.push(site.commitHash)
    var reported = siteStatus(site)
    return {
      kind: kind,
      label: site ? String(site.name) : "",
      detail: parts.join(" · "),
      status: reported.label,
      tone: reported.tone,
      // Servers sit under their organization when there is one to sit under,
      // and sites under their server either way.
      depth: (c.showOrgHeaders ? 1 : 0) + 1,
      showChevron: false,
      actionKey: site ? String(site.key) : "",
      armedText: defaultArmedText,
      timeAt: site ? site.deployedAt : ""
    }
  }

  // An event row is a line of a feed: what Forge did, to which site, and when.
  // It has no dot and no tone because an event has no status to report — see
  // `eventsFrom` — and the time goes where a site's deploy time goes.
  if (kind === "event") {
    var event = c.event || {}
    return {
      kind: kind,
      label: String(event.description || ""),
      detail: String(event.siteName || event.ranAs || ""),
      status: "",
      tone: "idle",
      depth: 0,
      showChevron: false,
      actionKey: "",
      armedText: "",
      timeAt: String(event.createdAt || "")
    }
  }

  // A recipe row is an action wearing a list row's clothes: it carries the
  // send's arm key the way an action row in a view does, but its label is the
  // recipe's name and its detail says what running it would mean here — who it
  // runs as and what its first line is, or why this server can't take it.
  //
  // No `timeAt`. The only timestamp a recipe has is when it was last edited,
  // and in the column a site's deploy time occupies that would read as when it
  // last ran — a different fact, and one this row does not know.
  if (kind === "recipe") {
    var recipe = c.recipe || {}
    var recipeAction = c.action || {}
    var about = []
    if (recipe.user) about.push("as " + String(recipe.user))
    if (recipe.firstLine) about.push(String(recipe.firstLine))
    return {
      kind: kind,
      label: String(recipe.name || ""),
      detail: recipeAction.available === false
        ? String(recipeAction.reason || "") : about.join(" · "),
      status: "",
      tone: "idle",
      depth: 0,
      showChevron: false,
      actionKey: recipeAction.armable === true ? String(c.armKey || "") : "",
      armedText: String(recipeAction.armedText || defaultArmedText),
      timeAt: ""
    }
  }

  var server = c.server
  var count = Number(c.siteCount || 0)
  return {
    kind: "server",
    label: server ? String(server.name) : "",
    detail: server ? serverMeta(server) : "",
    status: !server ? ""
      : server.state !== "ready" ? serverStateLabel(server.state)
      : count > 0 ? pluralize(count, "site") : "ready",
    tone: server ? serverTone(server.state) : "idle",
    depth: c.showOrgHeaders ? 1 : 0,
    showChevron: true,
    actionKey: "",
    armedText: "",
    timeAt: ""
  }
}

// ----------------------------------------------------------------- org state

// The shape the panel reads for one organization. Defined here so the service
// and a panel whose service has not loaded yet agree on what "nothing yet"
// looks like, rather than each inventing its own blank.
function emptyState() {
  return {
    servers: [],
    sitesByServer: {},
    refreshing: false,
    lastError: "",
    note: "",
    lastRefreshMs: 0,
    // Which credential this organization is polled through, and why it can't
    // be — a missing token is a fact about the account, not about the org.
    account: "",
    accountError: "",
    // When the ticker owes this organization its next look.
    nextDueMs: 0,
    // Where the site walk resumes next tick ("" = start over), and everything
    // it has observed since it last started — the wrap rebuilds the whole
    // organization from that accumulation.
    siteCursor: "",
    sweepSites: [],
    // Deployment status per site key as of that site's last observation, and
    // whether a first sweep has landed — the seeding that keeps an
    // already-failed site from announcing itself at shell start.
    lastStatus: {},
    seeded: false
  }
}

// -------------------------------------------------------------- setup state

// `~/.local/state/omarchy/forge.json`, as written by the helper — and
// hand-editable, so nothing in it is trusted to be the type it should be.
// Understood here in one place, rather than in the service and the panel
// separately.
function parseSetup(text) {
  var parsed = null
  try { parsed = JSON.parse(String(text || "{}")) } catch (e) { parsed = null }
  if (!parsed || typeof parsed !== "object") parsed = {}

  var setup = {
    defaultOrganization: parsed.organization ? String(parsed.organization) : "",
    // name → {label, user}. `user` is the Forge identity behind the token,
    // which is what the rate limit is actually counted against.
    accounts: {},
    // slug → {account, name}, in the order they were added.
    organizations: {},
    organizationList: []
  }

  var accounts = parsed.accounts
  if (accounts && typeof accounts === "object") {
    for (var name in accounts) {
      var a = accounts[name] || {}
      setup.accounts[String(name)] = {
        label: String(a.label || name),
        user: String(a.user || "")
      }
    }
  }

  var orgs = parsed.organizations
  if (orgs && typeof orgs === "object") {
    for (var slug in orgs) {
      var o = orgs[slug] || {}
      setup.organizations[String(slug)] = {
        account: String(o.account || "default"),
        name: String(o.name || "")
      }
      setup.organizationList.push(String(slug))
    }
  }

  if (setup.defaultOrganization === "" && setup.organizationList.length > 0)
    setup.defaultOrganization = setup.organizationList[0]

  return setup
}

function emptySetup() {
  return parseSetup("{}")
}

// An organization typed into a widget's settings but never added through the
// helper still has to be polled through something; the default account is the
// only sensible guess, and the helper will report a missing token if it is
// the wrong one.
function accountForOrg(setup, org, fallback) {
  var entry = setup && setup.organizations ? setup.organizations[String(org)] : null
  if (entry && entry.account) return entry.account
  return fallback || "default"
}

// What the rate ledger is keyed by. Forge counts 60 requests a minute against
// a *user*, so two tokens issued by the same person share one budget and must
// share one bucket; only when the identity is unknown does the account name
// have to stand in for it.
function budgetBucket(setup, account) {
  var entry = setup && setup.accounts ? setup.accounts[String(account)] : null
  if (entry && entry.user) return "user:" + entry.user
  return "account:" + String(account)
}

// The organization's own name when the helper recorded one, its slug
// otherwise. Slugs are what the dashboard uses, so they are never wrong,
// just less readable.
function orgLabel(setup, org) {
  var entry = setup && setup.organizations ? setup.organizations[String(org)] : null
  return entry && entry.name ? entry.name : String(org)
}

// A widget's `organization` setting, read as a filter over what is being
// watched: empty means everything, otherwise a comma-separated pick. An
// organization named here but not in the state file is still honoured — it
// may have been typed in before being added — so the panel can say something
// useful about it rather than silently showing nothing.
function organizationsInView(setup, filter) {
  var watched = setup && setup.organizationList ? setup.organizationList : []
  var text = String(filter || "").trim()
  if (text === "") return watched.slice()

  var out = []
  var parts = text.split(",")
  for (var i = 0; i < parts.length; i++) {
    var slug = parts[i].trim()
    if (slug === "" || out.indexOf(slug) !== -1) continue
    out.push(slug)
  }
  return out
}

// ------------------------------------------------------------------ formatting

function relativeTime(iso, nowMs) {
  if (!iso) return ""
  var then = Date.parse(String(iso))
  if (!isFinite(then)) return ""
  return relativeMs(then, nowMs)
}

function relativeMs(thenMs, nowMs) {
  if (!thenMs) return ""
  var seconds = Math.max(0, Math.round((nowMs - thenMs) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.round(hours / 24)
  if (days < 30) return days + "d ago"
  return Math.round(days / 30) + "mo ago"
}

function pluralize(count, singular) {
  return count + " " + singular + (count === 1 ? "" : "s")
}

// ------------------------------------------------------------------- requests

function encode(value) {
  return encodeURIComponent(String(value))
}

// Forge caps a page at 30 however large `page[size]` asks for, and says so
// only in `meta.per_page` — no error, no warning. Asking for a bigger number
// therefore buys nothing but the illusion of a complete list, so ask for what
// is actually available and follow the cursor for the rest.
var pageSize = 30

function pagedPath(path, cursor) {
  var url = path + (path.indexOf("?") === -1 ? "?" : "&") + "page%5Bsize%5D=" + pageSize
  return cursor ? url + "&page%5Bcursor%5D=" + encode(cursor) : url
}

// Pagination is cursor-based rather than offset-based, and `meta.next_cursor`
// is the only signal worth reading: `links` comes back as an empty *array*
// when there is nothing to link to, so probing it for `.next` would work on
// every page but the last one, which is the only page that matters.
function nextCursor(body) {
  var meta = body ? body.meta : null
  var cursor = meta ? meta.next_cursor : null
  return cursor ? String(cursor) : ""
}

function serversPath(org, cursor) {
  return pagedPath("/orgs/" + encode(org) + "/servers?sort=name", cursor)
}

// One request for the whole organization rather than one per server. The
// `include=server` is load-bearing and the walk over this list is a rotation;
// both are ARCHITECTURE.md's to explain. `sort` is accepted here with a 200
// and silently ignored, so the order is `sortSites`'s to impose.
function sitesPath(org, cursor) {
  return pagedPath("/orgs/" + encode(org) + "/sites?include=server,latestDeployment", cursor)
}

// The per-server list the sweep stopped using, kept for the fetch that wants
// exactly one server fresh — unfolding a row. Same includes as `sitesPath` so
// `sitesFrom` reads both alike.
function serverSitesPath(org, serverId, cursor) {
  return pagedPath(serverPath(org, serverId) + "/sites?include=server,latestDeployment", cursor)
}

// Everything addressed to one server hangs off this, and everything addressed
// to one site off `sitePath` below it, so the segments are encoded in one place
// rather than once per endpoint.
function serverPath(org, serverId) {
  return "/orgs/" + encode(org) + "/servers/" + encode(serverId)
}

function sitePath(org, serverId, siteId) {
  return serverPath(org, serverId) + "/sites/" + encode(siteId)
}

function deployPath(org, serverId, siteId) {
  return sitePath(org, serverId, siteId) + "/deployments"
}

// Maintenance mode is an *integration* in Forge's model: POST installs it,
// DELETE removes it. Both are gated behind `site:manage-commands` — the same
// scope that runs arbitrary commands on the site — so the service reports their
// 403 on the row rather than across the organization.
function maintenancePath(org, serverId, siteId) {
  return sitePath(org, serverId, siteId) + "/integrations/laravel-maintenance"
}

// A write against the server itself, and one against a service running on it.
// Both are gated behind `server:manage-services` — the scope a deliberately
// read-only token lacks — which is why the service reports their 403 on the row
// rather than across the organization, the way the deploy log's is.
function serverActionPath(org, serverId) {
  return serverPath(org, serverId) + "/actions"
}

// `service` is never API data: it comes from the fixed list in `serverActions`.
function serviceActionPath(org, serverId, service) {
  return serverPath(org, serverId) + "/services/" + encode(service) + "/actions"
}

// What Forge itself has done to a server — provisioning steps, deploys, key
// installs — and what each of those printed. Both want only `server:view`, so
// unlike the deploy log they work on a read-only token; the service still
// reports their refusals on the pane rather than across the organization,
// because they belong to a keypress. Newest first has to be asked for: the
// default order is oldest first, which for a feed is the wrong end. The
// `include=site` is load-bearing — without it the site relationship comes back
// empty, and a row could not say which site an event was about.
function serverEventsPath(org, serverId, cursor) {
  return pagedPath(serverPath(org, serverId) + "/events?sort=-created_at&include=site", cursor)
}

function eventOutputPath(org, serverId, eventId) {
  return serverPath(org, serverId) + "/events/" + encode(eventId) + "/output"
}

// The deploy log, fetched only when someone asks for it. Note the scope: this
// is gated behind `site:manage-deploys`, the *write* scope, so a token that can
// read every server and site can still be refused here — which is why the
// service reports this one's 403 inline instead of as an organization error.
function deploymentLogPath(org, serverId, siteId, deploymentId) {
  return deployPath(org, serverId, siteId) + "/" + encode(deploymentId) + "/log"
}

// A site's own logs — what the application wrote, and nginx's two. The kind is
// a path segment rather than a parameter, and it is one of exactly three; the
// service refuses anything else before building this, because a fourth would
// reach Forge as a 404 that reads like the site is gone.
//
// The scope the spec names is `server:manage-logs` — "allow members to clear
// server and site logs" — so despite being a read it sits behind the scope that
// empties them, and a token kept to `server:view` is refused. That is why the
// service reports this one's 403 on the pane, the deploy log's way, rather than
// across the organization's rows.
function siteLogPath(org, serverId, siteId, kind) {
  return sitePath(org, serverId, siteId) + "/logs/" + encode(kind)
}

// Running a command on a site, and reading back what it did. Note that the
// scopes are split across the same four paths, which no other endpoint here
// does: the POST is gated behind `site:manage-commands` — Forge's *run a
// command* scope, which maintenance mode also sits behind — while all three
// reads want only `server:view`. So a token that can watch a server can follow
// a run it is not allowed to start, and the 403 belongs on the row that sent
// rather than on the pane that reads.
function commandsPath(org, serverId, siteId) {
  return sitePath(org, serverId, siteId) + "/commands"
}

// Newest first, because the run being looked for is the one just sent — see
// `commandFrom`. `pagedPath` is what percent-encodes `page[size]`: curl reads a
// literal bracket as a glob and refuses the URL outright.
function commandListPath(org, serverId, siteId) {
  return pagedPath(commandsPath(org, serverId, siteId) + "?sort=-created_at")
}

function commandPath(org, serverId, siteId, commandId) {
  return commandsPath(org, serverId, siteId) + "/" + encode(commandId)
}

function commandOutputPath(org, serverId, siteId, commandId) {
  return commandPath(org, serverId, siteId, commandId) + "/output"
}

// An organization's recipes, and one recipe's runs. The scopes split across
// these the way the command's do: the POST wants `recipe:manage`, the three
// reads want `recipe:view`. Unlike the command's reads, though, `recipe:view`
// is a scope no sweep already needs — so this is the deploy log's situation
// rather than the event feed's, and a deliberately read-only token can be
// refused the list. The service names that 403 on the view.
function recipesPath(org, cursor) {
  return pagedPath("/orgs/" + encode(org) + "/recipes", cursor)
}

// The POST target, and so deliberately unpaged — a `page[size]` on a write is
// noise at best. `recipeRunListPath` is the same address as a read.
function recipeRunsPath(org, recipeId) {
  return "/orgs/" + encode(org) + "/recipes/" + encode(recipeId) + "/runs"
}

// The run being looked for is the one just sent, so newest first is what this
// wants — and this endpoint has no `sort` to ask for it with. It answers 200
// to any `sort` at all, where `/servers` refuses an unknown one with a 400 and
// the list of what it takes, so the parameter is not read here: `sort=-id` and
// `sort=nonsense` are the same request. Verified live, 2026-09-05.
//
// Two things follow, and both live in the reader rather than the URL.
// `recipeRunFrom` takes the highest matching id on the page instead of the
// first row, so neither order can fool it; and the watch walks the cursor when
// a page holds no candidate, because Forge's other cursor lists default to
// *oldest* first — the event feed's does, verified — which would otherwise put
// a new run beyond page one for any recipe with a history.
function recipeRunListPath(org, recipeId, cursor) {
  return pagedPath(recipeRunsPath(org, recipeId), cursor)
}

function recipeRunLogPath(org, recipeId, logId) {
  return recipeRunsPath(org, recipeId) + "/" + encode(logId)
}

// The three reads above, as a question a queued job can be asked. Named here
// beside the paths they take rather than spelled out at each of the places in
// the service that has to recognise one — a job dropped without an answer is a
// pane waiting forever, so every drop site asks this.
function isCommandJob(job) {
  var kind = job ? String(job.kind || "") : ""
  return kind === "commandFind" || kind === "commandShow"
    || kind === "commandOutput"
}

// The two reads a recipe run's watch makes. Deliberately *not* grouped with
// the recipe list below: these answer `commandRunUpdated` and the list answers
// `recipesFetched`, so a drop site that treated them alike would send a pane's
// farewell to a view or the other way round.
function isRecipeRunJob(job) {
  var kind = job ? String(job.kind || "") : ""
  return kind === "recipeFind" || kind === "recipeShow"
}

// What the run watch is following, whichever kind of run it is. The watch is
// one slot and one signal, so the drop sites ask this rather than the two.
function isRunJob(job) {
  return isCommandJob(job) || isRecipeRunJob(job)
}

// The two event reads, on the same terms and for the same reason.
function isEventJob(job) {
  var kind = job ? String(job.kind || "") : ""
  return kind === "events" || kind === "eventOutput"
}

// And the site log read, which is one kind but asks the same question at the
// same three drop sites.
function isSiteLogJob(job) {
  return (job ? String(job.kind || "") : "") === "siteLog"
}

// The API never hands out a web link, so the dashboard address is a template
// the user can correct rather than something derived. A server row has no site
// to point at, so `{site}` and the separator in front of it drop out together.
//
// `{server}` is the server's slug, which is what the dashboard addresses a
// server by. The slug is assigned at creation and does NOT follow a rename, so
// it has to come from the API rather than be derived from the name — a server
// built for one project and later renamed keeps its original slug, and only
// that original still resolves. Sites carry no slug at all; the dashboard
// addresses those by id.
function dashboardUrl(template, org, server, siteId) {
  var url = String(template)

  // A server row has no site to point at. Blank the placeholder and tidy up
  // whatever separator it leaves stranded — a trailing slash, a bare `?`, or
  // an emptied query parameter. Deleting the surrounding run of text instead
  // would swallow any neighbour sharing that run, so `{server}-{site}` or
  // `?site={site}` would lose the server too.
  url = siteId
    ? url.replace(/\{site\}/g, encode(siteId))
    : url.replace(/\{site\}/g, "")
         .replace(/[?&][^\/?&=]*=$/, "")
         .replace(/[?&]$/, "")
         .replace(/\/+$/, "")

  url = url.replace(/\{org\}/g, encode(org))
  if (server.id) url = url.replace(/\{serverId\}/g, encode(server.id))
  if (server.slug) url = url.replace(/\{server\}/g, encode(server.slug))

  // Anything still in braces is something this server can't supply — a slug
  // the API omitted, or a typo in the template. Returning nothing lets the
  // caller say so, rather than opening a link already known to 404. A
  // slug-less server still resolves a template written against {serverId}.
  return /\{[^}]*\}/.test(url) ? "" : externalUrl(url)
}

// The companion to externalUrl for the other kind of string that leaves this
// process: an API string handed to another program as an argv element is as
// untrusted as one handed to a shell. `omarchy-notification-send` takes the
// headline and the description positionally with no `--` in front of them, and
// two parsers read a leading `-` there as a flag — its own option loop, which
// recognises `--exec` and friends and would swallow the next argument as the
// value, and notify-send's GLib parser, which permutes and so reads options
// after positionals. So a site named `--hint=string:omarchy-exec:…` becomes the
// command the toast runs on click. Leading hyphens go, and the whitespace
// around them, in whatever order and however many — and the C0 controls with
// them, so a name can't smuggle a newline into an argv either. A leading hyphen
// is not legal in a domain, which is what a Forge site name is, so nothing real
// is lost. Returns "" for a string that was nothing else, like externalUrl;
// the caller decides what to say instead.
function notifyText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001F\u007F]/g, " ")
    .replace(/^[\s-]+/, "")
    .replace(/\s+$/, "")
}

// The third member of that family, for a string entering a `Text` this plugin
// does not own. A `Text` with no `textFormat` is `Text.AutoText`: Qt sniffs the
// string and renders it as HTML the moment it looks like markup, and an `<img
// src="http://…">` inside a server name is fetched when the text is laid out —
// a beacon with an attacker-chosen scheme and host, which `elide` does not
// prevent. Our own elements declare `Text.PlainText` and need nothing else, but
// the shell's `PanelHero`, `BarIconButton` and `NotificationCard` take a string
// and render it in a `Text` we cannot reach, so the guard moves to the caller.
// The notification is the one that matters most: its card asks for
// `Text.StyledText`, which renders `<img>` too, and a toast fetches on arrival
// without being opened and is persisted so it can do it again after a restart.
//
// Dropping `<` is enough: it is the only character that makes Qt decide a
// string might be rich text. Escaping it to `&lt;` would be worse — the
// receiving `Text` would then find no markup, choose plain rendering, and show
// the entity literally. The C0 controls go the way `notifyText` sends them,
// since these strings also reach a bar tooltip and an argv.
function plainText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001F\u007F]/g, " ")
    .replace(/</g, "")
}

// The fourth member of the family, for the one string that arrives as a whole
// document rather than a name: a deployment log. It is remote text, written by
// whatever the deploy script echoed, so it is scrubbed like the rest — but the
// scrub differs in two ways.
//
// It keeps `<`, because unlike the three sinks `plainText` guards, the log
// lands in a `Text` this repo owns and gives `Text.PlainText`, and a build that
// printed a generic type or an XML tag should show it. And it keeps `\n` and
// `\t`, which are the log's own structure — dropping those would leave one
// unreadable line. Everything else in C0 goes.
//
// A bare `\r` is resolved rather than dropped or turned into a line break: it
// means "overwrite what I just wrote", so a progress bar that printed thirty
// frames is one line, the last one, the way a terminal would have shown it.
// Turning each frame into its own line would be thirty lines of noise, and
// deleting the `\r` outright would run them together as `10%20%30%`.
//
// ANSI goes too. Forge colours its output, and the escapes are the noisiest
// thing in the file when rendered literally. Three forms cover what a deploy
// script can emit: CSI (the colours), OSC (title sets, terminated by BEL or
// ST), and everything else — the two-character sequences and the nF ones like
// `ESC ( B`, which share the shape "ESC, any intermediates, one final byte".
// Stripping beats interpreting: the tone a row needs is already known from the
// deployment's status, and re-deriving colour here would buy nothing.
var ansiPattern = /\u001B(?:\[[0-?]*[ -\/]*[@-~]|\][\s\S]*?(?:\u0007|\u001B\\)|[ -\/]*[0-~])/g

// A log saved to disk is named after the site it came from, which makes the
// file findable and the name API data. That is a path component, so the guard
// is a different one again: `externalUrl` refuses what isn't an address and
// `notifyText` strips what an option parser would read, but here the danger is
// a separator. A site called `../../.bashrc` — or one with a newline, or a
// leading dot — must not be able to steer where the write lands or hide the
// file once it does. So this keeps the small set that is unambiguously a name
// and turns everything else into a hyphen, rather than trying to enumerate
// what is dangerous.
var fileNameCap = 80

function safeFileName(value) {
  var name = String(value === undefined || value === null ? "" : value)
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^[.-]+/, "")
    .replace(/[.-]+$/, "")
  if (name.length > fileNameCap) name = name.substring(0, fileNameCap)
  return name === "" ? "site" : name
}

function logFileName(siteName, deploymentId) {
  return "forge-" + safeFileName(siteName) + "-" + safeFileName(deploymentId) + ".log"
}

// Both halves again: the site name is API data and the id is a path segment,
// and a separator in either is what `safeFileName` is here to stop.
function commandFileName(siteName, commandId) {
  return "forge-" + safeFileName(siteName) + "-" + safeFileName(commandId) + ".out"
}

// Named after the server rather than a site, because an event is the server's.
// `serversFrom` never leaves a name empty, so `safeFileName`'s "site" fallback
// is not reachable from here.
function eventFileName(serverName, eventId) {
  return "forge-" + safeFileName(serverName) + "-event-" + safeFileName(eventId) + ".log"
}

// Two API strings and an id in one path, so all three go through the guard —
// a recipe is named by whoever wrote it, and nothing else here has checked it.
function recipeFileName(serverName, recipeName, logId) {
  return "forge-" + safeFileName(serverName) + "-recipe-"
    + safeFileName(recipeName) + "-" + safeFileName(logId) + ".out"
}

// A site log's file. The kind goes through the guard with the name even though
// the three are literals here: what stops a separator reaching a path should
// not depend on the caller having picked the kind out of the table.
function siteLogFileName(siteName, kind) {
  return "forge-" + safeFileName(siteName) + "-" + safeFileName(kind) + ".log"
}

// A cap on what is kept in memory and laid out. Forge's own logs run to tens
// of kilobytes; a runaway deploy script could print without limit, and the
// pane would try to lay out every line of it.
var logCharCap = 512 * 1024
var logLineCap = 5000

function logText(value) {
  var text = String(value === undefined || value === null ? "" : value)
  if (text.length > logCharCap) text = text.substring(text.length - logCharCap)
  return text
    .replace(ansiPattern, "")
    .replace(/\r\n/g, "\n")
    // `.` stops at a newline under /m, so this keeps only what follows the
    // last carriage return on each line.
    .replace(/^.*\r/gm, "")
    .replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "")
}

// The log as lines, which is what the pane's ListView takes as a model. Kept
// beside the guard so nothing is tempted to split a string the guard has not
// seen. Truncation happens at the *front*: the answer is always in the tail.
function logLines(value) {
  var lines = logText(value).split("\n")
  // A log almost always ends with a newline, which splits into one empty
  // trailing line. Dropping it stops the pane opening on a blank row.
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
  if (lines.length > logLineCap) lines = lines.slice(lines.length - logLineCap)
  return lines
}

// Forge does not hand back an empty string for an empty site log: it hands back
// one line saying so, which the pane would render as content and the reader
// would take for the log's first line. Turning it into "" is what lets the
// pane's own empty text say it instead — the same answer a deploy that printed
// nothing gets. Verified against the live API on an untouched nginx access log.
//
// Matched whole rather than by prefix: a real log line that happens to contain
// this is still a log line. If Forge ever changes the wording, the sentence
// shows through verbatim, which is wrong but not misleading.
var emptyLogSentinel = "=== Empty log file ==="

function siteLogContent(value) {
  var text = String(value === undefined || value === null ? "" : value)
  return text.trim() === emptyLogSentinel ? "" : text
}

// Every address that leaves this plugin passes through here first.
//
// A site's URL arrives from the API, and a deployment notification puts it
// inside a command string that the shell hands to `bash -lc` when the toast is
// clicked (see ARCHITECTURE.md). That makes it untrusted input crossing into a
// shell, so it is checked rather than trusted: only an absolute http(s) URL
// with a plain authority gets through, and every character outside the set RFC
// 3986 permits unescaped is percent-encoded — so no space, quote, backtick or
// newline survives even if the quoting downstream were ever lost. Refusing
// returns "", like dashboardUrl, rather than a mangled link.
function externalUrl(value) {
  var parts = /^(https?:\/\/)([^\/?#]+)([\/?#][\s\S]*)?$/i.exec(String(value || "").trim())
  // Userinfo is never part of a Forge address, and is the classic way to make
  // a hostile host read as a familiar one.
  if (!parts || parts[2].indexOf("@") !== -1) return ""
  return parts[1].toLowerCase() + encodeUrlChars(parts[2]) + encodeUrlChars(parts[3] || "")
}

// What RFC 3986 allows unescaped, less the apostrophe: it is a legal
// sub-delimiter but the one character that would close a single-quoted shell
// literal, and no real address needs it. The other sub-delimiters stay — a
// query string is built from them, and single-quoting already makes them
// inert. A `%` not already starting an escape triplet is encoded rather than
// left meaning two things, and surrogate pairs match whole so an astral
// character encodes instead of splitting into two halves neither of which can.
var urlSafe = /[\uD800-\uDBFF][\uDC00-\uDFFF]|%(?![0-9A-Fa-f]{2})|[^A-Za-z0-9\-._~:\/?#\[\]@!$&()*+,;=%]/g

function encodeUrlChars(text) {
  return String(text).replace(urlSafe, function (c) {
    // encodeURIComponent leaves the apostrophe alone — it is a legal URL
    // character — and that is precisely the one that has to go.
    if (c === "'") return "%27"
    // An unpaired surrogate can't be part of an address; drop it rather than
    // let encodeURIComponent throw.
    try { return encodeURIComponent(c) } catch (e) { return "" }
  })
}
