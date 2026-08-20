# TODO

Ordered by priority: the groundwork that makes the rest affordable, then features we don't have.
Everything below was checked against the v2 OpenAPI spec
(`https://forge.laravel.com/api/docs.openapi`, 154 paths) and, where it says
*verified*, against the live API.

The security review that used to head this file is closed — every finding is fixed in 1.4.2, and
the three rules it produced live in [ARCHITECTURE.md](ARCHITECTURE.md) rather than here. The one
part that was never ours to fix is a known gap in [README.md](README.md).

---

## Groundwork

### 1. Fetch sites per organization, not per server

`GET /orgs/{org}/sites?include=server,latestDeployment` returns every site in an
organization with its server and its latest deployment in **one** request —
verified live (7 sites, 7 included resources, one call). Each site carries
`relationships.server.data.id`, so grouping by server still works.

A tick goes from `1 + N(ready servers)` to `2` per organization, flat. That
retires most of what [README.md](README.md#L137-L160) has to explain: the
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

### 2. Triage what the linter was never able to tell us

`CLAUDE.md` documented plain `qmllint`, which on Arch is **qt5-declarative's** — Quickshell is
Qt 6. Qt 5's parser predates typed function signatures, so the `function open(): void` form
that `IpcHandler` requires killed it on `Panel.qml` with **exit 255 and no output at all**:
no message, no line number, nothing to suggest it hadn't linted. Verified by bisection —
`function f(): void {}` alone reproduces it, `function f() {}` does not, and every other file
passed only because none of them declare IPC handlers. The command is now fixed in
`CLAUDE.md` to `/usr/lib/qt6/bin/qmllint`, which exits 0 on all four files.

So nothing here has ever been linted, and there is a backlog to work through:

- **`qs.*` doesn't resolve** with `-I /usr/share/omarchy/shell`, because Quickshell maps the
  shell root onto the `qs` namespace internally rather than on disk — `Commons/qmldir` says
  `module qs.Commons` but there is no `qs/` directory. Every `Style`/`Color`/`Util` reference
  then reads as unqualified access, and `BarIconButton`/`PanelHero`/`PanelSectionHeader` as
  missing types, which buries the real findings. A `qs -> /usr/share/omarchy/shell` symlink in
  a scratch directory passed as a second `-I` fixes it: `ForgeIcon.qml` drops to **0**
  warnings and `Service.qml` to 2. Worth deciding whether that shim belongs in the repo as a
  committed lint helper, or whether Quickshell offers a supported way to say this.
- **42 unqualified accesses in `Panel.qml`**, and 7 in `ForgeRow.qml`, once the shim is in
  place. Sampling them, they are genuine: `health`, `summary`, `needsSetup`, `tokenKnown` and
  friends read from inside delegates without a `root.` qualifier. They work, but QML resolves
  them by walking the scope chain at every evaluation, and they are the class of thing that
  breaks quietly when a delegate later gains a property of the same name.
- **Noise to leave alone**: `Member "caption"/"foreground" not found on type "QObject"` is
  qmllint failing to type Quickshell's singletons even when the import resolves, and
  `Service.qml`'s two `QProcess::ExitStatus … signal called exited` warnings are the same
  interop gap on `Process.exited`. Neither is actionable from this side.

Cheap, and it clears the ground before any of the features below add more QML.

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

[README.md](README.md#L238-L239) defers these deliberately. The arm-to-confirm
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
gives the log viewer (#3) somewhere natural to live.

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
