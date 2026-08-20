# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Omarchy shell plugin (Quickshell/QML + a bash helper) that shows Laravel Forge server health
and site deployments in the bar, across several Forge organizations and accounts, with one-key
deploys. Forge **v2** API only. `README.md` is the user-facing contract — settings, keys, CLI
surface and rate-limit behaviour described there are promises; keep it in sync with changes.

## Working on it

The plugin directory is a symlink to this repo:
`~/.config/omarchy/plugins/acobrerosf.forge -> /home/acobrerosf/Work/omarchy-forge`, so edits are
live. Saving a file under `~/.config/omarchy/plugins/` reloads plugin code automatically.

```sh
omarchy-shell shell rescanPlugins      # force a plugin reload if a save didn't take
omarchy restart shell                  # full shell restart (drops all service state)
                                       # ^ needed for Service.qml: rescanPlugins rebuilds
                                       #   the panels but keeps the running service instance
journalctl -t omarchy-shell -f         # QML console.warn/errors and load failures land here
omarchy plugin validate "$PWD"         # manifest.json against the plugin schema (silent = ok)
qmllint -I /usr/share/omarchy/shell Panel.qml Service.qml ForgeRow.qml ForgeIcon.qml
bash -n omarchy-forge
```

Drive the panel without the mouse:

```sh
omarchy-shell acobrerosf.forge toggle    # also: open, close, refresh, status
```

There is no test suite. Verification is: lint, exercise the CLI directly, then reload the shell
and watch the journal.

```sh
./omarchy-forge doctor                                     # every account: token, auth, rate left
./omarchy-forge status --org acme
./omarchy-forge api --account default GET /orgs/acme/servers
FORGE_TOKEN=… FORGE_ACCOUNT=default ./omarchy-forge doctor  # try a token without storing it
```

State the widget reads: `~/.local/state/omarchy/forge.json` (accounts, organizations, default).
Tokens are in the login keyring under service `omarchy-forge`, never in that file.

## Architecture

Five QML/JS files and a bash helper, three layers, one rule that shapes all of them: **the QML
process never touches a token**.

```
omarchy-forge  (bash)   credentials + HTTP. Reads the keyring, hands the token to curl on stdin,
                        prints one JSON envelope per request. Also the whole setup/admin CLI.
Service.qml             one instance per session (plugin kind "service"). Polling, scheduling,
                        the rate ledger, the request queue, deploys, notifications.
Panel.qml               one instance per monitor (bar widget). Cursor, folding, arm-to-deploy,
                        row assembly. Owns nothing that outlives a screen.
ForgeRow.qml            one panel row, pure presentational. Declared properties in, signals out;
                        no service reference, no Model import.
Model.js                pure functions: JSON:API → flat rows, state derivation, path building.
                        `.pragma library`, no QML types, no I/O.
ForgeIcon.qml           the bar mark + badge (Shape/CurveRenderer).
```

**`ARCHITECTURE.md` is the design document of record** — the envelope contract, accounts vs
organizations, the rate budget, the queue and pagination, subscriptions, and how a row is
rendered. Read it before changing any of those, and update it rather than re-explaining a
decision in a file header. Two couplings from it are worth repeating here because they break
silently: `Model.parseEnvelope`/`envelopeError` expect the exact envelope shape, and
`Service._isMissingToken` matches the literal prefix `"No API token"` produced by `api_request`.
Don't reword that message without changing both.

### Conventions that matter

- **Reassign, never mutate.** QML only notices a `var` property when it is assigned. `_patch`,
  `_patchAccount` and `_shallowCopy` exist for this; the panel's folding maps do the same. Mutating
  `orgs[key].servers` in place silently fails to update any binding. The one deliberate exception
  is the `budget` and `queue` objects inside `Service.qml`: nothing binds to their internals, so
  they mutate in place. Anything a panel can reach follows the rule.
- **Rendering splits three ways.** `Model.rowView` derives a row's text and tone and may return no
  QML type — `depth` not pixels, `tone` not a colour. `ForgeRow.qml` owns the metrics and palette
  and takes no service reference. `Panel.qml` binds volatile per-screen state (cursor, armed,
  deploying, relative time) directly on the delegate rather than through `rowView`, so a cursor
  move doesn't re-derive every row's text.
- **Notification seeding.** `state.seeded` guards the first sweep so an already-failed site doesn't
  announce itself at shell start. `lastStatus` is the previous sweep's per-site status.
- **`manifest.json` is the source of truth for settings.** Its `barWidget.defaults` + `schema` feed
  Setup → Plugins; `Panel.setting(key, fallback)` reads them. Adding a setting means: manifest
  defaults, manifest schema entry, the `setting()` call, the README table, and — if the service
  needs it — `watchConfig` plus `_normalizeConfig`. Users can hand-edit `shell.json`, so
  `_normalizeConfig` coerces strings and clamps ranges rather than trusting types.
- **Style.** QML/JS here: 2-space indent, no trailing semicolons, `var` not `let`. Comments explain
  *why* a thing is shaped the way it is, not what the line does — match that density. A note that
  explains the line it sits next to belongs in the code; one that orients you to a subsystem
  belongs in `ARCHITECTURE.md`. Bash: `set -euo pipefail`,
  errors via `die`, all state reads go through `state()` which normalises the legacy pre-accounts
  shape so no command sees more than one.
- **Backwards compatibility.** A pre-accounts install (flat `{"organization": …}` state, token under
  keyring account `api-token`) must keep working; `STATE_NORMALIZE`, `adopt_legacy_token` and the
  `default`-account fallback in `token_read`/`token_clear` are that path.
- Bump `manifest.json` `version` for user-visible changes.

## Known gaps (from README)

A 429 is reported but does not lengthen the interval; the dashboard URL is a template because the
API hands out no web link; server actions beyond deploy are deliberately absent; a cursor chain
stops at 5 pages (150 rows) or when the account's minute is nearly spent, and says so.
