# TODO

Ordered by priority: the groundwork that makes the rest affordable, then features we don't have.
The groundwork came out of a whole-codebase audit and is the urgent half — it is what the
features below are cheaper to build on top of. Everything under *Features* was checked against
the v2 OpenAPI spec (`https://forge.laravel.com/api/docs.openapi`, 154 paths) and, where it says
*verified*, against the live API.

---

## Groundwork — do this first

An audit of every subsystem (2026-09-05, against `fdac3be`) for simplifications in data
structures, state representation, control flow and ownership. Sixteen findings, grouped below
into five slices; each slice is one commit on `develop`, lintable and verifiable on its own.
Line numbers are as of `fdac3be` and will drift — the surrounding names are the real address.

One shape recurs and is worth naming once, because ten of the sixteen are instances of it: **a
fact with two homes and two writers**. Each of those is a pair of representations kept in step
by hand, and three of the pairs have already drifted. The fix is always to derive one from the
other or to delete the copy, never to add a third place that synchronises them.

Two findings change what the user sees (2b's badge, 3c's flash) and are marked. The rest are
invisible, which is what makes them safe to do in a batch.

### 1. Panel — one pane state, one arm-key rule — **done** (`2e24685`)

**1a. `eventOutput*` is the fourth set of pane properties ARCHITECTURE forbids.** *(high, small)*
`Panel.qml` 93-96 declares `eventOutputRequestKey/Lines/Error/Loading` beside the deploy log's
`log*` at 73-80. ARCHITECTURE 226-230 explains why a site log deliberately does *not* get its own
set — only one pane is ever open, so a fourth set "would have to be cleared in the same places and
could never hold a different value" — and both halves of that prediction are true here.
`popView` 446-448 and `onOpenedChanged` 1358 call `clearLog()` and `clearEventOutput()` back to
back; `clearEventOutput` 1024-1030 is `clearLog` 951-957 with the names swapped, down to both
zeroing `saveRequestedPath`; `onEventOutputFetched` 1488-1493 is `onSiteLogFetched` 1446-1451 with
the names swapped; and `paneLines`/`paneLoading`/`paneError` 1129-1134 each carry a three-way
ternary whose middle arm exists only for this set. A log route is always the top of the stack and
an `eventOutput` route can only be pushed from the feed (whose rows carry no `siteId`), so the two
sets are never both live. The request keys already differ in shape (`Service.qml` 55-58, 75-77,
86-89), which is the same thing that tells a site log from a deploy log.

It is a leftover rather than a decision: the feed landed in `ed0c3fa`, the site log in `b95f443`,
and the rule was written for the second one. Delete `eventOutput*` and `clearEventOutput`; let
`openEventOutput`, `refreshEventOutput` and `onEventOutputFetched` read and write `log*` the way
the site log does; collapse the three ternaries to `runPane ? command* : log*`. `paneLoadingText`
and `paneEmptyText` keep their `routeKind` switch — the words are what tell the panes apart.
Update ARCHITECTURE 226-230 and the CLAUDE.md sentence to say "a site log and an event's output".

*Optional, and it contradicts a recorded decision, so decide rather than assume:* with one `log*`
set, `onDeploymentLogFetched`, `onSiteLogFetched` and `onEventOutputFetched` are three identical
handlers behind three signals. `Service.qml` 79-83 justifies the separate `siteLogFetched` by "a
shared handler would have to ask which it was answering" — but the panel's handlers never ask,
because the 403 wording is chosen in the service's `_on*`. One `documentFetched` signal would
leave one handler. Only worth it if 2a is being done in the same pass. — **taken in slice 2**:
one `documentFetched`, one `onDocumentFetched`, and the recorded justification rewritten.

**1b. One `actionRow(...)` constructor; make `armKey !== ""` mean "this row writes".**
*(medium-high, small)* The rule — row key is `prefix + action.id`, arm key is the subject's key
when `armsSubject` and otherwise the row's own plus `/armIntent` — is implemented at `actionRows`
355-358 and then re-spelled by hand for the command row at 294-298, with a seven-line comment
repeating what 350-354 already says. Two more `kind: "action"` rows are hand-built literals at
379-383 and 408-412, differing only in id and label.

The sharper half: 355-357 hands a non-empty `armKey` to *every* view action, including the seven
that write nothing (`open`, `forge`, `ssh`, `log`, `command`, the three `site-log:*`). Only
`Model.rowView` 1033 papers over it, by gating on `armable`. So `runWriteAction` 848-853 — which
says in a comment that it wants `armKey === ""` to be the guarantee that a row is not a write, and
that "the two-press guarantee should not rest on" the availability check staying correct — cannot
actually rest on it either. Give the constructor the rule (`""` for non-armable, subject key for
`armsSubject`, else own key plus intent) and the invariant becomes true on the row itself.

That in turn retires the duplication in `runAction` 821-825, which enumerates five write ids to
route them to `runWriteAction` and so restates what `Model` already declares with `armable` +
`path`. ARCHITECTURE says a new write should be "a job object and a path, not a second code path";
today it is also a case in that switch. With the invariant, it becomes
`default: if (row.armKey !== "") runWriteAction(row)`, with `deploy` and `command-run` staying
explicit above it. `Model.rowView`'s comment at 1026-1032 still describes the pre-`armsSubject`
design and should be corrected in the same pass.

Watch two things: the command row with empty text loses its trailing `command-run/` (unreachable
as an armed key, since `available` is false with no text), and non-armable rows lose their
`armKey` (every reader checked — the delegate uses the already-gated `view.actionKey`,
`confirmArmed` compares against a non-empty `armedKey`, `openRecipeOutput` scans recipe rows).

**1c. One run-pane reset.** *(high, tiny — fixes a real drift)* `sendWriteAction`'s `command-run`
branch 899-916 and `recipe-run` branch 920-936 each call their door, return on `""`, then reset
the same five properties — except the recipe branch also clears `commandId` (933) and the command
branch does not. Since `onCommandRunUpdated` 1418 only assigns `commandId` when it is non-empty, a
command run started after a recipe run carries the *recipe log's* id until the run is recognised,
and `w` in that window names the file after the wrong run. One `beginRun(key)` setting all six,
called from both. `clearCommand` 1177-1191 can share it.

**1d. Draw "this route is about a server" once.** *(medium, tiny)* The predicate
`routeKind === "server" || "events" || "recipes"` is spelled five times: the crumb's `aboutServer`
1750-1751, the hero's title 1790-1791, meta 1801-1802 and detail 1810-1811, and `heroTone`
715-716. The file already draws `paneRoute` and `runPane` once for exactly this reason (55-69);
this third grouping was missed. And the health-to-badge table (`bad→bad`, `busy→busy`,
`maintenance→maintenance`, `setup|error→warn`, else `none`) is written twice — `heroTone` 723-726
and the bar button's switch 1564-1573 — which agree today and are one edit from not. A
`serverRoute` property and a `Model.badgeForHealth(health)`; the hero's `ForgeIcon.badge`
1822-1825 is then an identity ternary and becomes `badge: root.heroTone`.

### 2. Service, read path — one road, and a dispatch that cannot miss — **done**

**2a. One enqueue helper and one refusal dispatcher for the five on-demand reads.**
*(high, small-medium)* `fetchDeploymentLog` 1037-1056, `fetchServerEvents` 1115-1127,
`fetchEventOutput` 1147-1159, `fetchRecipes` 1213-1225 and `fetchSiteLog` 1294-1306 repeat the
same four guards — organization exists, hold, ceiling, dedupe — with the same three refusal
strings; the dedupe line is identical at 1062, 1133, 1165, 1231, 1312, and again at 976 and 1861.
Three of the five have a `_xRefused(job, message)` helper (1174, 1236, 1318) and the deploy log
does not, so its farewell is written out inline at 595-596 and 805-806.

The cost is not the repetition, it is where the rule lives. ARCHITECTURE says three separate times
that every drop site owes a refusal, and the two places that actually enforce it are the four-arm
ladders in `_abandonJob` 594-601 and `_holdAccount` 804-809. They are the real registry of "reads
that owe an answer", and nothing connects them to `_pathFor` — so a sixth read kind wired into the
path table and forgotten in the ladders reproduces exactly the pane-waiting-forever bug the
document warns about. `Model.isEventJob` and `isSiteLogJob` (1495-1504) exist only to be asked
there.

So: `_readRequestKey(job)` and `_readRefused(job, message)` switching on `job.kind` over the five
read kinds, the latter answering whether it handled the kind; `_enqueueRead(job)` running the
shared guards, setting `job.account`, and pushing to the front; a root-level
`_outstanding(matches)` for "queued or in flight". Each entry function keeps only its own
pre-check — the empty deployment id at 1032, `isSiteLogKind` at 1292 — and a job literal. Both
ladders become `if (_readRefused(job, msg)) …`. The run-job arms stay separate on purpose: abandon
ends the watch, a hold keeps it, and that difference is documented. Drop the `log` job's `page: 1,
rows: []` (1064-1066) while there — `_onLog` never reads them.

Note the dedupe for `log` and `siteLog` gains `serverId`, which is harmless (a site has one
server), and that `_holdAccount`'s drop callback must still return `true` for every job in the
bucket whether or not the dispatcher recognised it.

**2b. Make the job-kind dispatch total.** *(medium, tiny)* `_pathFor` 634-636 opens with a comment
saying kinds are "named rather than defaulted" because an unknown one "would otherwise be sent to
the org site list, which answers plausibly and wrongly" — and then line 659 is that default, with
`onExited` 2287 as its twin. `_pump` 625-629 charges the budget and sends before anything has
checked the kind was recognised. A job whose kind matches neither table is therefore paid for,
sent as the org site list, and handed to `_onSites`: carrying `rows` it is *published* as a sweep
window, and without them `job.rows.concat` throws inside `onExited`, which skips `root._pump()` at
2289 and stalls the queue until the next push.

Name `sites` in both tables; have `_pathFor` return `""` on a miss; compute the path in `_pump`
after the `sweepDone` and unwatched-org checks and *before* `budget.charge`, warning and
abandoning on `""`; end `onExited` with a warning branch and wrap its dispatch in
`try … finally { root._pump() }` so no handler can stall the queue again. Do it after 2a, so
`_abandonJob` already answers every pane kind.

**2c. Move the single-resource JSON:API walk into `Model`.** *(medium, tiny)*
`var data = envelope.body ? envelope.body.data : null; var attributes = data ? data.attributes :
null` appears at 1087-1091, 1261-1265, 1335-1339 and, in its attributes-only form, at 1995,
2028-2033 and 2090. Every other JSON:API shape read in the plugin lives in `Model.js`, which
ARCHITECTURE 18 says is where it belongs. One `Model.resourceText(body, field)` returning the
string or `null`. The handlers stay separate — the `output`/`content` split, the empty-log
sentinel and the three 403 wordings are all deliberate. Fold this into 2a or 5b rather than doing
it alone.

### 3. Service, write path — one job shape, one in-flight owner — **done**

**3a. One `_writeJob(org, serverId, action, key)`.** *(medium, small)* `sendAction` 1529-1540,
`runSiteCommand` 1559-1569 and `runRecipe` 1589-1598 each copy a *different* subset of the action
entry into a job, so the job's shape is whatever each wrapper remembered. Two consequences, one of
them a live hole in a documented rule:

- `Model.js` 579 declares `bodyStdin: true` on the command action and 548-551 explains it as the
  field that distinguishes it — but nothing reads `action.bodyStdin`. `sendAction` omits it and
  `runSiteCommand` hard-codes `bodyStdin: true` at 1564. So "nothing a user typed reaches an argv"
  holds only because the command happens to go through that wrapper; an action entry declaring
  `bodyStdin` and sent through `sendAction` would ride the argv, exactly as the rule forbids.
- `Model` carries `refetch: "sites" | "org"` (513, 832); `sendAction` splits it into two booleans
  (1539-1540) that `_onAction` immediately recombines (1641, 1648), and the two run wrappers spell
  out three `false` no-ops. The pair also admits `{refetchSites: true, refetchOrg: true}`, which
  nothing produces and nothing would handle sensibly.

One constructor copying `path`, `method`, `body`, `bodyStdin`, `done`, `scopeMessage`,
`settleSites` and `refetch` once; `_finishAction` reads `job.refetch`. The run wrappers then add only
what is genuinely theirs — the kind, the subject id, `sentAtMs`, `requestKey` — which is what
makes visible that they differ by nothing else. `deploy` keeps its hand-built job (it has no
action entry, and that separation is documented) but takes `refetch: "sites"`.

**3b. `_action` alone owns "a write is in flight".** *(medium, tiny)* `busyActionKey` 44 and
`_action` 1446 are set together at 1470-1471 and cleared together at 1605-1606, so the first is
always `_action ? _action.key : ""`; `actionProcess.stdinBody` 2327 is a copy of the job's body
made at 1489 and consumed once; and the gate itself is a fourth reading of the same fact
(`actionProcess.running`, 1456). Make `busyActionKey` a `readonly` binding, write the body
straight from `root._action` in `onStarted`, and delete `stdinBody`. In-flight state is then the
job plus the OS fact.

That matters because of what is missing: `actionProcess` has no watchdog where `fetchProcess` has
one (2250-2259), and the helper runs `secret-tool lookup` *before* curl's `--max-time`, so a
locked keyring pins all three fields for the rest of the session — every write answering "Still
sending the last one" and one row stuck on `sending…`. With one owner the watchdog is two lines.

**3c. Tie a process's job to `running`, not only to `exited`.** *(high that the hole is real,
tiny per process — changes what the user sees)* Quickshell's `Process` emits `runningChanged`
without `exited` when the binary fails to start. Every job here is retired only in `onExited`:
`pipeProcess` 2305-2318, `_onAction` via 2337, `_current` via 2273. So a missing `wl-copy` leaves
`pipeProcess.job` set while `running` is false, strands everything behind it in `_pipeJobs`, and
never fires `textSaved` — leaving `saveRequestedPath` armed and the user with no message at all,
which is the one thing `Panel.qml` 1495-1496 says that signal exists to prevent. The fetch
watchdog cannot cover its own case either, because `running` is already false.

One terminal function per process, called from `onExited` and from `onRunningChanged` when
`!running && job`; the null guard makes the second call a no-op on the normal path, where `exited`
comes first. Move the pipe's `stdinEnabled` re-arm into `_pumpPipe` before `running = true`, which
is the shape `_startAction` already uses. Do `actionProcess` after 3b. Related: `copyPane`
1148-1152 flashes "Copied N lines" before the copy has run, so a failed copy currently reads as a
success — worth an answer once failures are reportable. — **taken in the same slice**:
`textSaved` became `pipeFinished(ticket, ok, message)`, a copy is answered on the same terms as a
save, and neither says anything until the program it handed the text to has actually run.

### 4. Service, org state — one home per fact, one precedence — **done**

**4a. Derive the account's verdict; stop copying it into every organization.** *(medium, medium)*
`accountStates` is declared as `name → {hasToken, rateRemaining, error}` (147-153) and only
`hasToken` is ever read, once, at line 36. `rateRemaining` and `error` are written at 745, 749,
757 and 781 and read nowhere. Meanwhile the verdict that *is* displayed lives per organization as
`accountError` (`Model.emptyState` 1142-1143), written at 761-762, cleared by hand in four places
(291, 751, 788, 830), and then de-duplicated again in `Panel.problems` 214-225 under
`"account/" + state.account`. ARCHITECTURE 62-65 says the account is the home of credential facts;
the code does that for `hasToken` only.

They can already disagree. A `quiet` request — a deploy log, a site log, the feed, the recipe list
— that finds no token sets `hasToken = false` (756-758) and deliberately skips the org write
(760), so `needsSetup` turns the bar icon to `setup` while `healthFor(org)` and `summaryFor(org)`
still report a healthy organization with its servers and sites. The reverse leaves a stale "No
token for …" on every org behind the account until the next loud sweep.

Trim `accountStates` to `{hasToken}`, drop `accountError` from `emptyState`, and add
`accountErrorFor(org)` deriving the sentence from `accountState(state.account)`. `state.account`
is written only by `_reconcile`, so it is the join key. One writer, no clearing sites, and `quiet`
can no longer split an account from its organizations. The dead `state.account || accountForOrg(…)`
fallback — eleven sites, and `Model.accountForOrg` never returns empty — goes with it.

Decide one thing while in there: `_applyEnvelope` 777-778 says a 401/403 is "worth saying once
rather than once per organization behind it", but the only account-level write it makes is to the
dead `error` field, and the visible report goes to per-org `lastError` at 788. Either revive the
field as the account's verdict or correct the comment; today the code does neither.
— **decided: correct the comment.** Forge scopes membership and permissions per organization, so a
401 or a 403 on one says nothing about the next, and an account-level verdict blanks the server
list the bar icon judges — the same reason the 429 branch already writes `lastError`. The account
keeps `hasToken` and nothing else.

**4b. One health precedence.** *(medium, small — changes what the user sees)* `healthFor` 374-396
encodes the order inside an organization as early returns (`accountError` → `setup`, `lastError` →
`error`, then servers, then sites). `_healthRank` 398-408 encodes the order *across* organizations
as a table: `bad 5 > error 4 > setup 3 > busy 2 > maintenance 1`. They disagree at the top. Within
one organization `setup` and `error` outrank `bad`; across organizations `bad` outranks both. So
the same facts produce a different bar badge depending only on how they happen to be split across
organizations.

The comment at 826-827 makes the intent explicit — a 429 writes `lastError` rather than
`accountError` precisely so the icon still "judges what it can see" — and `healthFor` then returns
`error` before judging a single server, which is the opposite. Only `maintenance < busy` is
documented as deliberate (404); this inversion is not documented anywhere.

Fold `healthFor` through `_healthRank`, the shape `healthForList` already has. The `busy` and
`maintenance` booleans at 386-395 and the comment justifying them disappear, because a rank fold
accumulates for free. Walking `sitesByServer` directly then leaves `allSites` with two
`.length` callers, both of which become `Model.countSites`. **This is visible**: an organization
holding both an error and a failing server moves from the `warn` ring to the urgent disc. That is
what the documentation already claims happens, so the alternative is equally acceptable — decide
the other way, and then fix the comment at 826-827 and ARCHITECTURE 115 to say so. What should not
survive is the code and the prose disagreeing.
— **decided: fold through `_healthRank`**, which is the direction the prose already claimed, so
only the code moved. An organization holding both an error and a failing server now draws the
urgent disc. `allSites` went with the fold — its two remaining callers count with
`Model.countSites`.

**4c. Delete `seeded`.** *(high that it is redundant, tiny)* `_announce` 1387 guards with
`if (!state.seeded || !notify)` and then skips any site whose previous status is `undefined`. When
`seeded` is false `lastStatus` is `{}`, so every lookup is `undefined` and nothing announces
anyway; the flag cannot change an outcome. It is written only at 935, 946 and 1009 — always beside
a `lastStatus` write — and reset only through `emptyState`. It does not even mean what it says:
1009 sets it from a single server's fetch, where CLAUDE.md's "Notification seeding" bullet and the
comment at 1366-1367 both claim it marks a first *sweep*. The `undefined` check is the seed guard
and always was. Delete the field and reword both, noting that `_announce` must stay the only
writer of `lastStatus` — that is the property the guard actually rests on.

**4d. The look job is an address; the watch is the evidence.** *(medium, small)* `_pollCommand`
1885-1891 copies thirteen fields onto every look. Nine are needed by the queue, `_pathFor` or a
drop site. The other four — `sent`, `sentAtMs`, `afterMs`/`afterId`, `header` — are read only by
handlers that have already passed `_commandAnswer`, which returns an envelope solely when
`_commandCurrent(job)` holds (1968), so the watch is guaranteed to be the same one. The handlers
then take some evidence from the job (1975, 2035, 2054) and some from the watch (1986, 2063, 2079,
2005, 2106), and the one place the two genuinely differ — `commandId` on a find job — already
earned an explaining comment at 2102-2105. Let the job carry only what addresses the request and
have every answer handler read evidence off `_commandWatch`; the exception becomes the rule and
`header` stops needing to ride the job at all. The four sites that run *before* `_commandCurrent`
— `_commandRefused`, `_commandFailed`, `_abandonJob`, `_holdAccount` — must keep reading
`job.commandId`, because their watch may be null or someone else's.

### 5. Helper and contract

**5a. One `watch_orgs`, one repoint-the-default fragment.** *(high, tiny)* `cmd_add` 623-631 and
`cmd_org_pick` 776-783 hold the identical loop — resolve the name with `awk`, `state_apply` the
same two-clause filter, echo "Watching: …". A state-file write filter living in two commands is
kept in step by hand for no reason. And `cmd_remove` writes the same "the default organization was
just removed, repoint it" invariant twice, in two different spellings (817-820 tests `== $s`,
832-836 tests `[.organization] == null`); the null form covers both cases.

**5b. Build the envelope in one place per language.** *(medium, tiny)* The envelope is the
contract ARCHITECTURE 47-54 calls brittle, and it is spelled out four times: `envelope()` at
248-263 and again inline in `api_request` 356-369 (with `envelope` as its own fallback at 370), and
on the QML side as `parseEnvelope`'s fallback (`Model.js` 15-16) and the watchdog's synthetic reply
(`Service.qml` 2270-2271). Give the bash function an optional body file and let `api_request` call
it in both branches; add `Model.errorEnvelope(message)` for the two JS sites. Keep the `tonumber?`
coercions byte-identical.

**Only the bash half is left.** `Model.errorEnvelope` landed in slice 3, which needed a third and a
fourth synthetic reply — a write that timed out, a helper that could not start — and so would have
had to hand-write the shape twice more. `parseEnvelope`, both watchdogs and both failed-start paths
now build it there.

### Where to start, and what to leave alone

Do them in the order above: 1 is Panel-only and touches no contract, 2 and 3 are Service-only and
independent of each other, 4 changes what is drawn and wants its own look, 5 is the helper. Within
4, do 4a before 4b — the latter reads `accountErrorFor`. Slices 1, 2, 3 and 4 are done; **only the
bash half of 5 remains**.

Verification is the usual: `./lint` for the file, `omarchy restart shell` (not `rescanPlugins`,
for anything in `Service.qml`), `journalctl -t omarchy-shell -f`, then walk the affected keys by
hand. The specific passes worth doing per slice: for 1, open every view and both panes and confirm
nothing leaks between them; for 2, open all five on-demand reads, then remove an organization from
`forge.json` while a pane is loading, then press one key twice and confirm a single request in the
journal, then lower `budget.ceiling` temporarily to see each refusal; for 3, send one of every
write kind and confirm the command's argv still ends in `-` (`ps -o args`), then hide `wl-copy`
from `PATH` and confirm a copy failure no longer strands the save behind it; for 4, clear the only
token from the keyring and watch the badge, the single problem line and the blanked servers, then
restore it; for 5, `bash -n omarchy-forge` plus `add`, `org`, `remove <slug>` of the default, and
`remove --account` of the account holding it.

Several things were looked at and deliberately left alone, and are worth recording so they are not
re-opened: a full `kind → {path, handler, refuse}` registry (same entry count, and `refuse` cannot
be one slot because a run job owes a different farewell to an abandon than to a hold — a
relocation, not a simplification); merging `runSiteCommand` and `runRecipe` (would push watch
coordinates into the action vocabulary, which ARCHITECTURE declines); a shared list state for the
feed and the recipe list (unlike the panes, those two genuinely coexist on the stack, which is why
`popView` clears each by the kind it popped); the three folding maps (`autoExpanded` records a
different fact that has to outlive a user's re-collapse); one slot for both run floors (`_lastRun`
and `_lastRecipeRun` hold different types and each has to survive the other kind's run); making
the watch's phase an explicit field (trades one unreachable combination for another); and indexing
`serverById` (a fourth field to keep in sync on every `servers` patch, for a scan over at most 150
rows at keypress time).

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
