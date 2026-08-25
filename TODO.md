# TODO

Ordered by priority: the groundwork that makes the rest affordable, then features we don't have.
Everything below was checked against the v2 OpenAPI spec
(`https://forge.laravel.com/api/docs.openapi`, 154 paths) and, where it says
*verified*, against the live API.

---

## Features

### 3. Server and service actions

`POST .../servers/{server}/actions` — `reboot`, `power-cycle`.
`POST .../servers/{server}/services/{nginx,php,mysql,postgres,redis,supervisor}/actions`
— `reboot`/`stop`, plus `reload` for php. Scope `server:manage-services`.
The php endpoint additionally requires a `version` in the body.

[README.md](README.md) defers these deliberately under *Known gaps*. The arm-to-confirm
pattern deploying already uses is the right precedent, but rebooting a server is
a different order of destructive from redeploying a site — a stronger
confirmation, and never on a bare keypress that a mistyped `j` could reach.

Probably: nginx/php reload and restart first (the everyday ones), server reboot
behind something more deliberate, `stop` and `power-cycle` not at all.

### 4. Maintenance mode

`Model.sitesFrom` now keeps `maintenance_mode.enabled` and the site view's
DETAILS block says so when it is on. What is left is the row and the bar badge —
a site in maintenance is worth seeing without opening it — and the toggle.

Toggling is `POST`/`DELETE .../sites/{site}/integrations/laravel-maintenance`,
scope `site:manage-integrations`. Splitting this in two is reasonable: show it
now (free), toggle it later.

### 6. Run a site command

`POST .../sites/{site}/commands` then `GET .../commands/{id}/output`, scope
`site:manage-commands`. "Run `php artisan migrate` from the bar" is a genuinely
useful thing to have during a deploy that half-failed.

This is arbitrary remote code execution, so it wants deliberate friction: a
prompt rather than a keystroke, no history of one-key repeats, and a clear
statement of which site and server it will run on. The pane it would show the
output in already exists — `ForgeLogView.qml` — and so does the place to put the
action, which is the site view's ACTIONS list.

### 7. Server events feed

`GET .../servers/{server}/events` and `/events/{event}/output`, scope
`server:view`. A feed of what Forge itself is doing to a server — provisioning
steps, service restarts, failures. Would give an "unreachable" server row a
*reason* instead of a state word. One request per server when opened, so on
demand only.

### 8. Site logs

`GET .../sites/{site}/logs/{application,nginx-error,nginx-access}`, scope
`server:view` — note it is the *read* scope, unlike deployment output, so this
one works on a read-only token where the deploy log does not. The nginx error
log is the natural companion to a site that is up but returning 500s. It reuses
`ForgeLogView.qml` and adds three entries to the site view's ACTIONS list; the
service already has the shape of the request in `fetchDeploymentLog`.

### 9. Recipes

`GET /orgs/{org}/recipes` and `POST /orgs/{org}/recipes/{recipe}/runs`, scopes
`recipe:view` / `recipe:manage`. Run a saved script across servers from the bar.
Real value for people who already keep recipes; nothing at all for people who
don't, which is why it sits below the rest.

### 10. Monitors and heartbeats

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
