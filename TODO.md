# TODO

Ordered by priority: the groundwork that makes the rest affordable, then features we don't have.
The groundwork came out of a whole-codebase audit and is now complete — it is what the features
below are cheaper to build on top of. Everything under *Features* was checked against
the v2 OpenAPI spec (`https://forge.laravel.com/api/docs.openapi`, 154 paths) and, where it says
*verified*, against the live API.

---

## Features

### 1. Monitors and heartbeats

`GET .../servers/{server}/monitors` (scope `server:view`) and the site
`heartbeats` endpoints. Forge's own alerting, surfaced in the bar. Would need
its own idea of what "unhealthy" means on top of the four tones we have, so
it is a bigger design question than it looks.

### 2. The rest of the services

Done: nginx restart, PHP-FPM reload and restart, and server reboot behind a
`Y` confirm, in a server view reached with `l`. What that left out, in the order
it might be worth having:

- **supervisor and redis restarts.** Same endpoint shape, one row each, and
  "the queue workers are wedged" is as everyday as "PHP is wedged". The reason
  they are not in already is that four rows is a view and eight is a list.
- **mysql/postgres restart.** Needs `database_type` off the server payload —
  `Model.serversFrom` doesn't keep it — to know which of the two endpoints a
  server even has.
- **A site's own PHP version.** The server view acts on the server default,
  which is right for it; an isolated site on another version wants a row in the
  *site* view, sending to the same endpoint with a different `version`.

`stop` and `power-cycle` stay out. Both are listed under *Known gaps* in
[README.md](README.md) with the reasoning.

---

## Not planned

Running a recipe on several servers at once — the API takes a list, the bar
takes one server, and a multi-select is a worse thing to build here than the
two presses it would save. Creating or editing a recipe, and Forge's own
`/forge-recipes`. Server creation and deletion, databases and backups, DNS and
certificates, firewall rules, teams and roles, storage providers, PHP version
management, nginx template editing. All in the API; all things where a bar widget is a worse
place to do the work than the dashboard, and where a mistake is expensive.
