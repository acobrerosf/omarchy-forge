# TODO

Nothing is queued. What follows is what the v2 OpenAPI spec
(`https://forge.laravel.com/api/docs.openapi`) offers and this widget deliberately leaves alone,
so the question isn't asked twice.

---

## Not planned

Running a recipe on several servers at once — the API takes a list, the bar
takes one server, and a multi-select is a worse thing to build here than the
two presses it would save. Creating or editing a recipe, and Forge's own
`/forge-recipes`. Server creation and deletion, databases and backups, DNS and
certificates, firewall rules, teams and roles, storage providers, PHP version
management, nginx template editing. All in the API; all things where a bar widget is a worse
place to do the work than the dashboard, and where a mistake is expensive.

Stopping a service and power-cycling a server. Both are one keypress from a bar and neither can be
undone from it — *Known limits* in [README.md](README.md) has the reasoning.
