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

Cost per tick per organization: 1 (server list) + 1 per ready server (sites, with
`?include=latestDeployment` folding deployments in). Independent of monitor count — that is the
whole reason polling lives in the service and not the widget.

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

A `sweepDone` marker job lets interleaved organizations publish their sites atomically —
publishing per-server as they land would shuffle rows under the user's cursor. A continuation page
belongs to a fetch already under way, so it jumps the queue; otherwise the marker would fire on a
half-walked sweep and publish it.

A single 5s ticker schedules every org off `nextDueMs` rather than a Timer per org. A separate
watchdog kills only a request that has actually overrun `requestTimeoutMs` (25s, against curl's
own 15s) — a fixed ticker aborting whatever happened to be in flight would cut healthy requests
off at random, and an aborted request comes back as an empty reply, which reads downstream as a
malformed one.

**Pagination.** Forge hands out 30 rows at a time and points at the rest with a cursor, so one
logical list is a chain of requests. The chain is unbounded by nature, so two things stop it: a
page cap (5 pages, 150 rows) and the same budget ceiling that guards the sweep. Either way the
list ends up short, and a short list that doesn't say so is indistinguishable from a complete one
— so both stops leave a note.

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
