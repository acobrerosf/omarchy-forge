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
ForgeLogView.qml        the deploy log pane, pure presentational.
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

That endpoint is the organization's, not the global `GET /sites` that spans every organization a
token can see. Folding a multi-org account's site requests into one sounds like the same trade the
org-wide fetch already made, and isn't: there is no global *servers* endpoint to match, the payload
attributes no organization to a site (no attribute, no relationship, no such include — only the
slug buried in `links.self.href`), and it filters only by name, so one shared window could not be
narrowed to the organizations actually watched, and one shared cursor would put every organization
behind a token on the same rotation and the same failure. TODO.md carries the arithmetic.

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

**The deploy log.** One request, only when someone asks, so it costs nothing at rest — the case the
budget's margin was left for. It goes through the queue rather than the deploy path's own process,
because the queue already charges the budget, honours a hold and throws work away for an
organization that stopped being watched, while `actionProcess` is single-flight for writes and
answers into `_onAction`. It is pushed to the *front*: a sweep behind it can afford to land a
second later, and someone staring at an empty pane cannot.

Two things about it differ from every other job. It answers through a signal
(`deploymentLogFetched`) rather than into `orgs`, for the reason `deployFinished` does — the answer
belongs to the one screen that asked, and tens of kilobytes have no business in a property every
panel re-reads. And it passes `quiet` to `_applyEnvelope`, which suppresses the per-organization
error writes and nothing else. Forge gates deploy output behind `site:manage-deploys`, the scope
that *writes*, so a deliberately read-only token is refused here and nowhere else; left loud, one
keypress would paint "Token is missing a scope for this" across rows that are perfectly healthy.
The account-level bookkeeping still runs either way — whether there is a token, what the rate
headers said, the hold a 429 imposes — because those are true whichever request found them.

A refusal is always reported. `fetchServerSites` can return silently because the rotation reaches
that server anyway; nothing comes along later to fill this pane in, so a hold, a ceiling, and the
jobs a 429 drops out of the queue each answer the signal instead of vanishing.

**Writes don't go through it.** A deploy, a service restart, a reboot and a maintenance toggle all
go out on `actionProcess`, which is single-flight: one press cannot become two requests, and the
answer arrives at `_onAction` rather than in the middle of a sweep. What the queue would have done
for them they do by hand — consult the hold, charge the budget — and `_startAction` is the one
place that does it, so each new kind of write was a job object and a path, not a second code path.

The job carries everything that varies, and all of it is declared in `Model` beside the label that
describes it — which is what leaves one wrapper rather than one per subject. `Service.sendAction`
turns any `serverActions`/`siteActions` entry into a job; `Service.deploy` is separate only because
it is reached from a key rather than from a row of that list:

- a **body** (`{"action":"reboot"}`, the PHP pool's version, `{"status":503}` for maintenance). It
  reaches the helper as an argument — it is not a credential — and the helper hands it to curl down
  the same stdin config the token rides, not because it is a secret but because stdin is already
  spoken for there and a temp file would be a second thing to clean up. Everything sent is decided
  in `Model`; no user-typed string has ever reached that argv, which is why the maintenance
  integration's optional `secret` and `redirect` are not offered.
- a **method**. Everything was a POST until removing a site's maintenance mode turned out to be a
  DELETE. `_startAction` defaults to POST and the helper passes whatever it is to `curl --request`,
  so no other layer knows.
- a **`scopeMessage`**, which decides both the 403 wording *and* whether the envelope is applied
  `quiet` — a job that has one is quiet. Only a deploy has none, and so is the only write left
  loud: it goes out on the same token and the same scope every sweep already needs, which makes a
  refusal the organization's business. The rest are gated behind write scopes a read-only token
  lacks (`server:manage-services`; `site:manage-commands` for maintenance, which is Forge's
  *run a command* scope rather than a separate integrations one — `site:manage-integrations` is
  declared in the spec's scope list, but no endpoint in it is gated behind that scope), and left
  loud one keypress would paint a scope error across rows that are perfectly healthy.
- **what to re-read**, as a `refetch` of `"org"` or `"sites"`. Forge answers all of them 202 — the
  work is asynchronous — so the flash says "requested", not "done". `"org"` pulls the organization's
  next refresh forward, which is all a reboot needs, since a server's state arrives with the server
  list. `"sites"` also re-reads that one server's sites directly, because what a deploy or a
  maintenance toggle changed rides the *sites* payload, and under rotation the pulled-forward sweep
  will usually be looking elsewhere.

Maintenance mode is the one where "requested" would have been a lie for several seconds: unlike a
queued deploy, which flips `deployment_status` immediately, `maintenance_mode.enabled` does not
move until Forge has finished out on the box. The payload's sibling `status` — `enabling` /
`disabling` — is what the row reports in the meantime, so the re-read has something true to say
rather than looking unchanged. `Model.sitesFrom` keeps it for that reason alone.

That is also why the maintenance entry is the one that declares **`settleSites`**. The re-read
`_onAction` fires goes out immediately, so for a flip it is *guaranteed* to observe the transitional
`status` — and nothing else is coming for it, because the pulled-forward tick only advances the site
rotation by one window, which past 150 sites is usually a different server. The toggle disables
itself while the flip is moving, so without a second look the row would pulse `enabling…` and refuse
every press until the rotation came back around. `Service._armSettle` gives it one: a timer that
re-reads that server up to twice more at 8s, and stops the moment no site on it is still flipping.
A settled toggle therefore costs nothing extra, and a flip that has not landed in 16s is handed back
to the ordinary refresh rather than polled for.

There is a `GET` on the same integration path, under the *read* scope, which would confirm a flip
directly. It is deliberately unused: a read belongs in the queue rather than on `actionProcess`, so
it would mean a new job kind and a new signal, and a second request per toggle charged against the
budget — to learn what `status` already delivers free.

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

A site's tone is `Model`'s to decide, not `rowView`'s: the row, the panel's hero and the service's
aggregate health all draw the same site and would otherwise each spell out the precedence —
maintenance mode outranks a settled deployment, a running or failed one outranks maintenance. That
lives in `_siteFact`, and the two public readers are thin over it. `siteStatus` returns the label
with the tone because the two have to agree; `siteTone` reads the fact directly rather than taking
`siteStatus().tone`, because `healthFor` walks every site of an organization on every sweep page and
the label it would throw away costs a lowercase, a regex and an object per site.

`siteStatus` also reports **`timed`** — whether the label is the deployment's, and so whether the
deployment's timestamp belongs beside it. The hero's `siteDetailLine` joins the two with a `·`, and
"maintenance · 2h ago" would date the wrong fact. The tree row ignores it: there the status and the
time sit on separate lines, and that column is the deployment's throughout.

That tone vocabulary has four values, and the fourth is distinguished by **shape rather than
colour**. `Color` exposes five values; `busyColor` and `okColor` are already the same one in a theme
that sets no accent, and `muted` falls back to the foreground `dimColor` derives from. So `warn` is
drawn as a ring where every other tone is a filled disc — the same move the busy pulse makes, and
legible in every theme rather than most of them. `ForgeIcon`'s badge does the same for the same
reason, so the bar and the rows under it speak one vocabulary; its ring is a separate badge value
because `warn` there is spoken for by `setup` and `error`. Both rings are the surface's foreground,
*not* the accent the panel binds to `badgeColor` — a theme with a distinct accent would otherwise
ring the bar badge in a colour the row beneath it does not use. Both scale their border with the
dot, since `Style.space` tracks the configured font size and a fixed hairline vanishes on a large
bar; the badge additionally clamps its border so the hole cannot close up, and fills that hole with
the background rather than leaving it transparent, because at the ~4px the bar draws it the mark's
own diagonals show through and the ring reads as a disc.

`ForgeRow.qml` follows the shell's own `notifications/components/NotificationCard.qml`: declared
scalar properties in, signals out, no reference back to the panel or the service. Per-screen
volatile state (cursor, armed, deploying, relative time) is bound directly on the delegate rather
than folded into `rowView`, so moving the cursor — or the clock ticking — doesn't re-derive every
row's text.

### Views

The panel is one surface — an `Ui/KeyboardPanel`, layer-shell, and only one surface at a time can
hold keyboard focus — so a site's actions are not a second window and could not be one. They are a
different `rows`.

`navStack` holds what has been pushed over the tree; `route` is its top. `rows` switches on it:
nothing pushed is the tree, a `site` or `server` route is that subject's actions, a `log` route is
empty because the log is a pane and not a list. Everything downstream is untouched — one cursor,
one delegate, one key handler, one clamp in `onRowsChanged` — which is the point. The server view
cost exactly what that predicted: a branch in `actionRows`, a `runAction` case, and no new
navigation model.

Two keys had to come from somewhere, and the horizontal axis is where. `PanelKeyCatcher` reads
`h j k l` as movement before `onTextKey` ever sees them, so a letter for "open the log" was never
available; and until sites had anything inside them, right and `l` were a second way to press `j`.
So right drills in, left goes back, and Escape goes back before it closes. `d` still deploys from
anywhere with its two presses, because an accelerator that survives the reorganisation is the
thing that makes the reorganisation cost nothing.

The server view came out of the same axis, and cost nothing for the same reason: on a server that
is *already* unfolded, right had nothing left to do — `drillIn` refused to re-toggle it, precisely
so that "deeper" could never mean "close this". That refusal is now the door.

It also cost the footer, twice, which is where that door had to be advertised. The hint line used
to name one set of keys per view; a key that only works on one *row* has nowhere to appear in that,
and `l` into a server duly stayed invisible until someone was told about it. So `hintText` reads
the row under the cursor, not just the route — which is what the line always claimed to be doing,
and is now a better line for it: four short lines instead of one wrapped list of everything. Two
rules keep it from being a nuisance. Every variant is short enough to stay one line, so moving the
cursor changes the words and not the height of the panel under them; and until the cursor is
*active* nothing is highlighted, so the line claims nothing about a particular row. The same rule
retires `[Y] confirm` from the server view's footer onto the reboot row alone, where it stops being
a puzzle.

The second cost was structural, and was a bug the whole time: the footer was the last thing inside
the scrolling `Column`, so a server with enough sites pushed it out of the viewport — the line that
says what you can do here disappeared exactly when the list got long enough to need it, under the
scroll bar. It is now a sibling of the `Flickable`, anchored to the bottom, and the `Flickable`
ends at its top. The panel's `contentHeight` adds both, and the scroll bar stops above the footer
rather than running over it.

And a key is not an affordance. `l` is invisible to anyone who navigates with a pointer, so a
server row carries a cog that opens the same view — `ForgeRow` draws it and raises
`actionsRequested`, a signal distinct from `activated` because clicking the row still folds it. It
shows on *every* server row, folded or not, where the key means this on unfolded ones only: `l` has
a second job on a folded server and the pointer does not, so making the icon match the key would
have been consistency bought with a worse mouse. It is dim at rest and lit under the pointer, and
its mouse area is larger than the glyph — a caption-sized mark is not a target.

A view's rows go through `Model.rowView` like every other row, as `kind: "action"`. Only an action
that writes carries an `actionKey` — that is what `armedKey` and `busyActionKey` compare against,
and handing it to `Open in Forge` as well would light up the whole list on one pending action.

Its value differs by action, and has to. Deploy declares `armsSubject`, so it arms on the *site's*
key: the tree's row for that site reports the same deploy and must light up with it. Everything
else arms on its own row's, because rows can post to the same endpoint and only the one that was
pressed should say so. This used to be a property of the *view* — every site action took the site's
key — which held only while the site view had exactly one write in it. A second one would have
armed in lockstep with the deploy and shown `sending…` beside it.

An action whose meaning depends on live state also declares an **`armIntent`**, folded into the
same key. `actionRows` is rebuilt on every refresh, and the maintenance row's label, method and
body are all derived from `maintenance_mode`; without this, a sweep landing inside the four-second
arm window would leave `armedKey` still matching a row that now means the opposite, and the second
press would send a DELETE where a POST was armed. Putting the intent in the key makes the flip
invalidate the arm instead of silently retargeting it — visibly, on the row, with no timer.

**Two confirms, not one.** A deploy and a service restart take the same two presses. A reboot takes
enter to arm and a capital `Y` to send, and every other key — a second enter, a lower-case `y` —
disarms and spends itself saying so. The letter matters less than where it isn't: `h j k l` are
movement, so nothing a mistyped navigation keypress can land on is ever the last press before a
server goes down. It follows that the mouse can arm a reboot but not confirm one, which is a cost
worth paying. `Model.serverActions` carries the `confirm` each row wants, so the rule is data
rather than a branch in the key handler.

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

A deployment log is the one string that arrives as a whole document rather than as a name, so it
gets a guard of its own — `Model.logText`, beside `externalUrl`, `notifyText` and `plainText`. It
differs from `plainText` twice, both deliberately: it keeps `<`, because a log lands in a `Text`
this repo owns and gives `Text.PlainText`, and a build that printed a generic type should show it;
and it keeps `\n` and `\t`, which are the log's own structure rather than noise in a name. It also
strips ANSI, since Forge colours its output, and resolves a bare `\r` to the last frame of its line
the way a terminal would — dropping it would run progress frames together as `10%20%30%`, and
turning it into a newline would be thirty lines of one progress bar.

Saving one adds a fifth guard for a fourth kind of sink. The file is named after the site, which
puts API data in a *path*, where the danger is neither markup nor an option parser but a separator:
a site called `../../.bashrc` must not be able to steer where the write lands, and one with a
leading dot must not be able to hide the file once it does. `Model.safeFileName` therefore keeps
the small set that is unambiguously a name — letters, digits, dot, underscore, hyphen — and turns
everything else into a hyphen, rather than trying to enumerate what is dangerous. The path then
reaches `bash -c` as a positional argument, never as part of the script, so it is data the shell
holds rather than something it can be talked into running.

Both the copy and the save hand the text to another program on **stdin**, not in an argv. Linux
caps one argument at 128KB (`MAX_ARG_STRLEN`) and a verbose deploy log can pass that, so
`execDetached` would fail with `E2BIG` on exactly the logs worth keeping. `pipeProcess` writes on
`started` and then sets `stdinEnabled: false`, which is what closes the pipe — `wl-copy` and `cat`
both read to EOF, and without the close neither would ever exit. Its little job list is unrelated
to `queue`: nothing here is an API request, so nothing here is charged, held or dropped.

That guard runs in `Panel.qml`, not in the service, and `Model.logLines` splits the log in the same
place. The rule is the one above: a guard belongs where the string crosses the boundary it guards
against, and that boundary is the `Text` — splitting a log the guard has not seen yet is how an
escape sequence gets to survive one.
