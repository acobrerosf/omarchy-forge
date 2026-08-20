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

function sitesFrom(body, serverId) {
  var out = []
  var data = body && Array.isArray(body.data) ? body.data : []
  var index = includedIndex(body)

  for (var i = 0; i < data.length; i++) {
    var resource = data[i]
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
      key: String(serverId) + ":" + String(resource.id),
      id: String(resource.id),
      serverId: String(serverId),
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
    accountError: ""
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

function sitesPath(org, serverId, cursor) {
  return pagedPath("/orgs/" + encode(org) + "/servers/" + encode(serverId)
    + "/sites?include=latestDeployment&sort=name", cursor)
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
