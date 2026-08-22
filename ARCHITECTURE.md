# Architecture

Why the code is shaped the way it is. `README.md` is the user-facing contract — settings, keys,
CLI surface, rate-limit behaviour; this file is for anyone changing the code behind it.

## The three layers, and the one rule

```
omarchy-forge  (bash)   credentials + HTTP. Reads the keyring, hands the token to curl on stdin,
                        prints one JSON envelope per request. Also the whole setup/admin CLI.
Service.qml             one instance per session (plugin kind "service"). Polling, scheduling,
                        the rate ledger, the request queue, deploys, notifications.
Panel.qml               one instance per monitor (bar widget). Cursor, folding, arm-to-deploy,
                        rendering. Owns nothing that outlives a screen.
ForgeRow.qml            one panel row, pure presentational. Declared properties in, signals out;
                        no service reference, no Model import.
Model.js                pure functions: JSON:API → flat rows, state derivation, path building.
                        `.pragma library`, no QML types, no I/O.
ForgeIcon.qml           the bar mark + badge (Shape/CurveRenderer).
```

The rule that shapes all of them: **the QML process never touches a token.** Every request is
`omarchy-forge api --account NAME METHOD /path`; the helper reads the keyring and pipes the token
to curl on stdin. No token reaches this process, and none is ever assembled into an argv here.

The service exists as a separate instance for a related reason. A bar widget is created once per
monitor, so a poller living inside the widget would multiply its request rate and its
notifications by the number of screens — against a budget Forge measures per *user*. One service
per session, panels subscribe to it.

## The envelope

The helper always prints exactly one object on stdout, whatever failed:

```json
{"ok": bool, "status": int, "rateRemaining": int|null, "rateReset": int|null,
 "body": any, "error": string|null}
```

`rateReset` is **seconds from now**, not a header value. Forge is Laravel, so a refusal carries
`Retry-After` (seconds) and `X-RateLimit-Reset` (a unix timestamp) and a successful response
carries neither. Folding both into one number in the helper keeps header formats in the file that
already parses headers, and keeps the widget from comparing its clock against another machine's.


Transport failures, HTTP errors and success arrive through the same door. Two brittle couplings
live here:

- `Model.parseEnvelope` / `Model.envelopeError` expect this exact shape.
- `Service._isMissingToken` matches the literal prefix `"No API token"` produced by `api_request`,
  to tell "not set up" apart from "failed".

Don't reword that message without changing both.

## Accounts vs organizations

One token belongs to an **account**; an account sees several **organizations**; an organization is
reached through exactly one account (org slugs are globally unique in Forge, so org → account is a
function).

Everything downstream is keyed by organization while the credential varies: per-org poll state,
per-org panel rows. But facts about a *credential* — has a token, token rejected, rate remaining —
belong to the account (`accountStates`), so three organizations behind one bad token report one
problem, not three.

## Rate budget

Forge allows 60 requests/minute **per Forge user**, shared with their browser dashboard. The
ledger is therefore keyed by the Forge identity behind an account (`Model.budgetBucket`), not by
the account name — two tokens from the same person share one budget.

`budget.ceiling` is 40, a deliberate margin. When a sweep would breach it, the *sites* sweep is
dropped for that tick and the panel says so; the **server list is never dropped**, because the bar
icon depends on it. A request that never left the machine (no token) is refunded.

Cost per tick per organization: **2** — the server list, then one *window* of the organization's
site list through `/orgs/{org}/sites?include=server,latestDeployment`. For an organization of 150
sites or fewer the window is the whole list, so the cost is 2 flat, independent of the server
count — which is what makes an on-demand fetch (one server's sites on unfold today; a deployment
log, a command's output tomorrow) obviously affordable — and independent of the monitor count,
which is the whole reason polling lives in the service and not the widget. Past 150 sites, a tick
spends up to `maxPages` continuations walking the next window of the rotation described below.

The server list is not redundant with the site list: the sites response only mentions servers that
*have* sites, and the bar icon has to see every server, including a freshly provisioned empty one.
Two couplings hold the site request together, and this paragraph is their single home.
`include=server` is what puts a `server` relationship on a site at all — without it the site's
`relationships` carries only `latestDeployment`, `Model.serverIdOf` reads nothing, and the panel
would draw no sites; a page of rows that all lack the linkage is therefore treated as an error
(`Model.sitesLinkageMissing` → `lastError`), never as an empty organization, because a token
scoped to see sites but not servers or a quiet API change would otherwise publish zero sites
under a healthy icon. And `sort` is accepted with a 200 and silently ignored, so the order is
imposed locally by `Model.sortSites` (`localeCompare`, matching the API-sorted server level).

The ledger lives in the `budget` object inside `Service.qml`. Nothing outside the service reads
it, so unlike the state panels bind to it is mutated in place rather than copy-on-write.

**Absorbing a 429.** The ledger counts only what this process spent, so a browser tab or another
script on the same Forge user can burn the minute behind its back. A refusal therefore holds the
*bucket* — `budget.block` / `budget.blockedMs`, keyed the same way the ledger is, so every
organization behind that identity waits together. Three things follow from it: work already queued
for the bucket is dropped, because it would land inside the same closed minute and the `sweepDone`
markers going with it are why `_holdAccount` ends those refreshes by hand; `refresh()` is the one
gate that consults the hold, since `nextDueMs` alone cannot hold anything through a `_reconcile`
that zeroes it; and `deploy()` refuses with the time remaining rather than spending a request that
would only push the hold further out. The refusal is reported as the organization's `lastError` —
`accountError` would read as "not set up" and blank the server list the bar icon judges.

## Queue, scheduling, pagination

One request at a time for the entire session. Two organizations coming due together interleave
rather than racing, and the queue doubles as the place where work for a dropped organization is
thrown away.

**The rotating site sweep.** The org site list arrives flat, 30 rows at a time, in no useful
order — so a chain cut short does not hold "some servers' sites", it holds an arbitrary slice
that can carry two of a server's ten. The sweep therefore never fills once; it *rotates*. Each
tick walks one window (up to `maxPages` pages) from the cursor saved in the org's `siteCursor`,
and the walk carries on next tick from where it stopped, wrapping around when the list ends.
Forge's cursors are stateless keyset watermarks (verified live: one held for 95 seconds resumed
correctly), so a cursor kept across ticks costs nothing and cannot expire; any failed sites page
still resets it, because the cursor may be the very thing that failed.

Publishing is never destructive, and `sitesByServer` is only ever built by three functions in
`Model.js`, side by side so the key form cannot drift. `mergeSitesByServer` lands a cut-short
window: sites the window observed update in place, every other site stays exactly as it was,
because deleting on a partial view means deleting sites the window simply never reached.
`groupSitesByServer` lands a wrap — the accumulated `sweepSites` is the whole organization, so
this is the one publish allowed to delete, which is what lets a server that genuinely lost its
last site go empty. `replaceServerSites` lands the on-demand per-server fetch
(`fetchServerSites`, wired to unfolding a server row and to a just-queued deploy), whose endpoint
is complete for exactly one server — the one replace that needs no wrap to be safe. Its rows also
feed `sweepSites`, so a site fetched at a list position the rotation has already passed does not
vanish at the wrap. The fetch is debounced (15s per server), deduped against the queue, and
refused under a hold or past the ceiling; `force` — the post-deploy look — bypasses only the
debounce.

`lastStatus`, which deployment notifications diff against, follows the same rule: it holds each
site's status *as of its last observation*, a partial publish only overwrites the keys it
observed, and keys are pruned only at a wrap. An unobserved site therefore keeps its last word,
and a site that briefly fell out of a window announces its next change exactly once instead of
never.

A `sweepDone` marker job still trails every sweep, with one remaining duty: closing the refresh
(`_finishRefresh`) once every site fetch queued ahead of it has landed — including a refresh
whose sites request errored and answered nothing. A continuation page belongs to a fetch already
under way, so it jumps the queue; otherwise the marker would fire mid-window and close the
refresh under it.

A single 5s ticker schedules every org off `nextDueMs` rather than a Timer per org. A separate
watchdog kills only a request that has actually overrun `requestTimeoutMs` (25s, against curl's
own 15s) — a fixed ticker aborting whatever happened to be in flight would cut healthy requests
off at random, and an aborted request comes back as an empty reply, which reads downstream as a
malformed one.

**Pagination.** Forge hands out 30 rows at a time and points at the rest with a cursor, so one
logical list is a chain of requests. The chain is unbounded by nature, so two things stop it: a
page cap (5 pages, 150 rows — per chain, per tick) and the same budget ceiling that guards the
sweep. Either way the list ends up short, and a short list that doesn't say so is
indistinguishable from a complete one — so both stops leave a note. What a stop *means* differs
by chain: for the server list it is a hard coverage limit, while for the org site list it merely
ends the tick's window — the rotation resumes from the kept cursor next tick, and the note says
sites are being checked in rotation rather than pretending the list is complete.

The ceiling applies to continuations only, which is not a hole in "the server list is never
dropped": the first page is enqueued unconditionally, so the bar icon always has servers to judge.
It is pages 2-onward that are discretionary.

**What `queue` is and isn't.** The `queue` object holds the pending list and nothing else — push,
push-front, take, drop-by-org. The dispatch policy (`_pump`) stays on the service root, because it
reads `orgs`, charges the budget, builds paths through `Model` and drives `fetchProcess`; moving
it into the object would need back-references or a signal indirection and would not be an
improvement. `_current`, `_currentStartedMs`, `_timedOut` and `requestTimeoutMs` likewise stay at
root — they describe the in-flight request and pair with `fetchProcess` and the watchdog, not with
the pending list.

## Subscriptions

Panels call `subscribe(config)` / `update(id, …)` / `unsubscribe(id)` with the set of orgs they
show. Subscriptions are keyed by an issued token rather than by anything the panel might not keep
stable — panels come and go with monitors and with config reloads. One watcher can name several
organizations, so a panel showing all of them is still one subscription.

`_reconcile()` merges every watcher's demands per organization — **most demanding wins** (shortest
interval, deployments watched if anyone wants them), because nobody should be handed staler data
than they asked for just because someone else asked for less. Two screens on the same org collapse
into one poll and one notification.

`_reconcile()` also runs on every state-file change, because that is what decides which account an
org is reached through; `FileView { watchChanges: true }` on `forge.json` means `omarchy-forge add`
is picked up without a restart.

## Strings that leave the process

Everything this plugin opens, copies or hands to another program is built from API data, and one
of those paths ends in a shell. `omarchy-notification-send --exec` does not take an argv array
like every other command here — it takes a shell **string**, which it parks in a libnotify hint,
and the shell's own notification service runs that hint through `bash -lc` when the toast is
clicked. A site's `url` reaching that string unquoted is arbitrary code execution on click, and
the hint is persisted alongside the popup, so it stays clickable across a shell restart.

So every address goes through `Model.externalUrl` first: absolute `http`/`https` only, no
userinfo, and everything outside the set RFC 3986 permits unescaped gets percent-encoded. It
returns `""` for anything it won't vouch for, the same refusal `dashboardUrl` uses, and the caller
decides what to say — `Panel.openCurrent` falls back to the Forge link, `openInBrowser` declines.
`dashboardUrl` ends by calling it, so a hand-edited `dashboardUrlTemplate` is held to the same
rule as the API's own values.

The notification path then *also* wraps the result in `Util.shellQuote`. That is deliberate
belt-and-braces: validation without quoting would make the encoder's character class
load-bearing, and quoting without validation would still hand the browser a `javascript:` URL or
a leading `-` read as a flag. Neither layer should be the only thing standing between a remote
string and a shell.

The same argv carries two strings that are not addresses — the notification's
headline and description — and they sit in a position two parsers read as options.
`omarchy-notification-send`'s own option loop recognises `--exec` and friends there and
swallows the argument after them as the value; notify-send's GLib parser permutes, so it
reads options *after* positionals. Neither call is given a `--`, so a site named
`--hint=string:omarchy-exec:…` becomes the command the toast runs on click. Both
positionals therefore go through `Model.notifyText`, which strips leading hyphens and the
C0 controls. The rule that generalises from it: **an API string handed to another program
as an argv element is as untrusted as one handed to a shell**, and gets a guard on the way
out even when no shell is involved.

`Model.sshCommand` is the same problem with a human in the loop — its output goes to the
clipboard for the user to paste into a terminal — so it refuses an `ip` that isn't plain address
characters.

## Rendering

`Panel.qml` flattens organizations, servers and sites into one `rows` list, so the cursor is a
single index and `j`/`k` walks all three without caring which is which.

Each row's *text and tone* is derived by `Model.rowView(row, ctx)` — a pure function, so the
branching on "is this an org, a server or a site" is readable in one place. It returns strings and
a `depth`, never QML types: `Style.space()` and the tone→colour mapping belong to `ForgeRow.qml`,
which owns the palette.

`ForgeRow.qml` follows the shell's own `notifications/components/NotificationCard.qml`: declared
scalar properties in, signals out, no reference back to the panel or the service. Per-screen
volatile state (cursor, armed, deploying, relative time) is bound directly on the delegate rather
than folded into `rowView`, so moving the cursor — or the clock ticking — doesn't re-derive every
row's text.

### Text is never left to guess

Almost everything drawn here is API data — server and site names, provider and region, the
organization label, error messages — and a `Text` without a `textFormat` is `Text.AutoText`, which
means Qt sniffs the string and renders it as HTML the moment it looks like markup. An `<img
src="http://…">` inside a server name is then *fetched* when the text is laid out: a blind beacon
with an attacker-chosen scheme and host, which `elide` does not prevent. So the third rule, beside
the address rule and the argv rule above: **an API string entering a `Text` gets an explicit
`textFormat`.** Every `Text` in this repo declares `Text.PlainText`, static ones included — a rule
that holds for all of them is checkable at a glance, where one that holds for "the ones bound to
API data" has to be re-derived every time a binding changes.

Three strings leave for a `Text` this plugin does not own and cannot give a format to:
`PanelHero`'s `title` and `meta`, and `BarIconButton`'s `tooltipText`. The organization label is
API-derived (`omarchy-forge add` stores the org's `name` from the API in the state file) and the
summary can be an account's error message, so those go through `Model.plainText` on the way out
instead — the same shape as `externalUrl` and `notifyText`, a guard applied where the string
crosses a boundary. It drops `<`, which is the only character that makes Qt decide a string might
be rich text.

That one `StyledText` is the fourth sink, and the worst of them. The shell draws every toast with
`notifications/components/NotificationCard.qml`, which asks for `Text.StyledText` — and StyledText
renders `<img>`. So a site name carrying one is fetched on a notification the user never opened,
and the toast is persisted under `~/.local/state/omarchy/notifications/`, so it outlives a
restart. `_notify` therefore applies both guards, and the order is load-bearing: `plainText`
runs first because dropping a `<` can turn `<--exec…` into `--exec…`, which is exactly what
`notifyText` is there to strip.
