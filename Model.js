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

    out.push({
      key: serverId + ":" + String(resource.id),
      id: String(resource.id),
      serverId: serverId,
      name: String(a.name || "site"),
      url: a.url ? String(a.url) : "",
      https: a.https === true,
      siteStatus: String(a.status || ""),
      deploymentStatus: status,
      branch: repository.branch ? String(repository.branch) : "",
      repoUrl: repository.url ? String(repository.url) : "",
      quickDeploy: a.quick_deploy === true,
      deployedAt: d ? String(d.ended_at || d.started_at || "") : "",
      commitHash: commit.hash ? String(commit.hash).substring(0, 7) : "",
      commitMessage: commit.message ? String(commit.message).split("\n")[0] : ""
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
// which of the three kinds it is lives here, in one readable place, rather
// than repeated inside four separate bindings in the delegate.
//
// ctx: { server, site, orgLabel, orgHealth, orgSummary, siteCount,
//        showOrgHeaders }
//
// Nothing here may touch a QML type, so the result carries `depth` rather than
// a pixel indent and `tone` rather than a colour — ForgeRow owns the metrics
// and the palette those turn into.
function rowView(row, ctx) {
  var kind = row ? String(row.kind) : ""
  var c = ctx || {}

  if (kind === "org") {
    // An organization row stands for everything under it, so it wears the
    // same verdict the bar icon would give that one.
    var health = String(c.orgHealth || "setup")
    var tone = health === "bad" || health === "error" ? "bad"
      : health === "setup" ? "idle"
      : health === "busy" ? "busy" : "ok"
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
      siteKey: "",
      deployedAt: ""
    }
  }

  if (kind === "site") {
    var site = c.site
    var parts = []
    if (site && site.branch) parts.push(site.branch)
    if (site && site.commitHash) parts.push(site.commitHash)
    return {
      kind: kind,
      label: site ? String(site.name) : "",
      detail: parts.join(" · "),
      status: site ? deploymentLabel(site.deploymentStatus) : "",
      tone: site ? deploymentTone(site.deploymentStatus) : "idle",
      // Servers sit under their organization when there is one to sit under,
      // and sites under their server either way.
      depth: (c.showOrgHeaders ? 1 : 0) + 1,
      showChevron: false,
      siteKey: site ? String(site.key) : "",
      deployedAt: site ? site.deployedAt : ""
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
    siteKey: "",
    deployedAt: ""
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
  return pagedPath("/orgs/" + encode(org) + "/servers/" + encode(serverId)
    + "/sites?include=server,latestDeployment", cursor)
}

function deployPath(org, serverId, siteId) {
  return "/orgs/" + encode(org) + "/servers/" + encode(serverId)
    + "/sites/" + encode(siteId) + "/deployments"
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
