# TODO

Ordered by priority: things that are wrong first, then the groundwork that makes
the rest affordable, then features we don't have. Everything below was checked
against the v2 OpenAPI spec (`https://forge.laravel.com/api/docs.openapi`, 154
paths) and, where it says *verified*, against the live API.

---

## Bugs

### 1. A 429 is reported but not absorbed

The panel says "rate limited" and then retries on the same schedule.
`X-RateLimit-Reset` is returned by every response and
[omarchy-forge:349](omarchy-forge#L349) only greps `x-ratelimit-remaining`, so
the service has no idea how long to wait.

Fix: carry `rateReset` through the envelope alongside `rateRemaining`, and on a
429 push `nextDueMs` past the reset instead of the configured interval. The
envelope shape is a contract with `Model.parseEnvelope` — adding a field is
additive, but the helper's `envelope()` and the OpenAPI-free parsing in
[Model.js:10](Model.js#L10) both need it.

Note the budget ledger already prevents most of this; a 429 in practice means
something *else* on the same Forge user burned the minute (the dashboard in a
browser tab, another script). Backing off is about not making that worse.

---

## Groundwork

### 2. Fetch sites per organization, not per server

`GET /orgs/{org}/sites?include=server,latestDeployment` returns every site in an
organization with its server and its latest deployment in **one** request —
verified live (7 sites, 7 included resources, one call). Each site carries
`relationships.server.data.id`, so grouping by server still works.

A tick goes from `1 + N(ready servers)` to `2` per organization, flat. That
retires most of what [README.md](README.md#L137-L150) has to explain: the
"deployment check skipped to stay inside the rate limit" note, most of the
reason `watchDeployments` exists as an escape hatch, and the advice to raise the
interval if you have a lot of servers. It also makes every on-demand fetch below
(a deployment log, a command's output) obviously affordable.

Keep the server list request: the sites response only mentions servers that
*have* sites, and the bar icon depends on seeing every server, including a
freshly provisioned empty one.

Watch out:
- The org-wide endpoint takes `filter[name]`, `page` and `include` but **no
  `sort`** — ordering moves into [Model.js](Model.js#L125) client-side.
- `sitesFrom(body, serverId)` currently takes the server id as an argument;
  it would read it from the relationship instead.
- The cursor chain is already in place, which is what makes this affordable:
  30 sites a page is now the whole organization's list rather than one
  server's, so an organization with more sites than that costs extra pages.

There is also a global `GET /sites` covering every organization a token can see,
which would collapse a multi-org account further. Unverified whether the
response attributes an organization to each site; if it does, worth a look.

---

## Features

### 3. Deployment log viewer

`GET /orgs/{org}/servers/{server}/sites/{site}/deployments/{deployment}/log` —
verified: 42KB, 369 lines, ANSI-coloured, and the answer is always in the tail.

Today the panel tells you a deploy failed and then makes you open a browser to
learn why, which is exactly the trip this plugin exists to avoid. This closes
the loop.

Shape: `l` on a site row fetches on demand — one request, only when asked, so it
costs nothing at rest — and opens a scrollable pane showing the tail with ANSI
stripped. A failed deploy offers it in the row. The deployment id we need is
already in `include=latestDeployment`.

Wrinkle worth deciding early: the log is gated behind `site:manage-deploys`, the
*write* scope. A deliberately read-only token cannot read deployment output, so
the scope table in the README needs a line saying so, and the panel needs to
report a 403 here as "your token can't read this" rather than as an error.

### 4. Server and service actions

`POST .../servers/{server}/actions` — `reboot`, `power-cycle`.
`POST .../servers/{server}/services/{nginx,php,mysql,postgres,redis,supervisor}/actions`
— `reboot`/`stop`, plus `reload` for php. Scope `server:manage-services`.
The php endpoint additionally requires a `version` in the body.

[README.md](README.md#L230-L231) defers these deliberately. The arm-to-confirm
pattern deploying already uses is the right precedent, but rebooting a server is
a different order of destructive from redeploying a site — a stronger
confirmation, and never on a bare keypress that a mistyped `j` could reach.

Probably: nginx/php reload and restart first (the everyday ones), server reboot
behind something more deliberate, `stop` and `power-cycle` not at all.

### 5. Maintenance mode

The site payload we already fetch carries `maintenance_mode: {enabled, status}`
and [Model.js](Model.js#L125) throws it away. Showing it costs **nothing** — a
site in maintenance should say so in its row, and arguably reach the bar badge.

Toggling is `POST`/`DELETE .../sites/{site}/integrations/laravel-maintenance`,
scope `site:manage-integrations`. Splitting this in two is reasonable: show it
now (free), toggle it later.

### 6. More of the site payload

Also already in the response and discarded: `php_version`, `isolated`,
`healthcheck_url`, `deployment_retention`, `aliases`, `app_type`, `uses_envoyer`,
`zero_downtime_deployments`. A site detail view — enter on an already-unfolded
site row, say — could show these without a single extra request. Cheap, and it
gives the log viewer (#4) somewhere natural to live.

### 7. Run a site command

`POST .../sites/{site}/commands` then `GET .../commands/{id}/output`, scope
`site:manage-commands`. "Run `php artisan migrate` from the bar" is a genuinely
useful thing to have during a deploy that half-failed.

This is arbitrary remote code execution, so it wants deliberate friction: a
prompt rather than a keystroke, no history of one-key repeats, and a clear
statement of which site and server it will run on. Worth doing after #3, which
builds the output-viewing pane it would reuse.

### 8. Server events feed

`GET .../servers/{server}/events` and `/events/{event}/output`, scope
`server:view`. A feed of what Forge itself is doing to a server — provisioning
steps, service restarts, failures. Would give an "unreachable" server row a
*reason* instead of a state word. One request per server when opened, so on
demand only.

### 9. Site logs

`GET .../sites/{site}/logs/{application,nginx-error,nginx-access}`, scope
`server:view` — note it is the *read* scope, unlike deployment output. The
nginx error log is the natural companion to a site that is up but returning 500s.
Same viewer as #3.

### 10. Recipes

`GET /orgs/{org}/recipes` and `POST /orgs/{org}/recipes/{recipe}/runs`, scopes
`recipe:view` / `recipe:manage`. Run a saved script across servers from the bar.
Real value for people who already keep recipes; nothing at all for people who
don't, which is why it sits below the rest.

### 11. Monitors and heartbeats

`GET .../servers/{server}/monitors` (scope `server:view`) and the site
`heartbeats` endpoints. Forge's own alerting, surfaced in the bar. Would need
its own idea of what "unhealthy" means on top of the three tones we have, so
it is a bigger design question than it looks.

---

## Not planned

Server creation and deletion, databases and backups, DNS and certificates,
firewall rules, teams and roles, storage providers, PHP version management,
nginx template editing. All in the API; all things where a bar widget is a worse
place to do the work than the dashboard, and where a mistake is expensive.
