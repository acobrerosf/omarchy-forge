# Forge

[Laravel Forge](https://forge.laravel.com) servers and deployments in the [Omarchy](https://omarchy.org/)
bar. The icon tells you whether anything is broken; the panel tells you what, and lets you fix it
without opening a browser.

Uses the Forge **v2** API. One icon covers every organization you have a token for.

<img src="screenshots/panel.png" alt="The panel, with two organizations and a server unfolded into its sites" width="420">

## Getting started

**1. Install the plugin.**

```sh
omarchy plugin add https://github.com/acobrerosf/omarchy-forge.git --enable
```

**2. Create a Forge API token** at <https://forge.laravel.com/profile/api>.

Tick these scopes:

| Scope | What it buys you |
|---|---|
| `user:view` | required — confirms the token works |
| `organization:view` | required — finds the organizations to watch |
| `server:view` | required — servers, sites, deployment status |
| `site:manage-deploys` | deploy from the bar, and read deployment logs |
| `server:manage-services` | restart nginx or PHP-FPM, reboot a server |
| `site:manage-commands` | run a command on a site, toggle maintenance mode |

The first three are the minimum. Leave the rest off and the widget is read-only — everything that
would change something says which scope it wanted instead of failing quietly.

**3. Add the token.** Click **Set up Forge** in the panel, or run:

```sh
~/.config/omarchy/plugins/acobrerosf.forge/omarchy-forge setup
```

It asks for the token, then lets you pick which of that token's organizations to watch.

**4. That's it.** The Forge mark appears in the bar. Click it, or press its key, and the panel opens
with your organizations. Move with `j`/`k`, press enter to unfold, press `d` twice on a site to
deploy it.

Tokens are stored in your login keyring, never in a config file, and the widget never handles them
— every request is made by the bundled `omarchy-forge` helper.

## Reading the bar

<img src="screenshots/bar.png" alt="The Forge mark in the Omarchy bar" width="224">

The mark carries one badge for everything being watched, showing the worst thing it can see:

| Badge | Meaning |
|---|---|
| none | everything is up and no deployment is failing |
| hollow | a site is in maintenance mode |
| pulsing | a deployment is running |
| warning | no token, a missing token, or the last request errored |
| solid | a server is unreachable, or a deployment failed |

Middle-click the icon to refresh.

## Using the panel

Organizations unfold into servers, servers into sites with their latest deployment, branch and
commit. A server whose site starts failing unfolds itself once.

| Key | Action |
|---|---|
| `j` `k` or ↑ ↓ | move the cursor |
| enter / space | unfold an organization or server, or open a site |
| `l` or → | go deeper — on an unfolded server, opens its actions |
| `h` or ← | back, or fold up the current row |
| `d` | deploy the site under the cursor (press twice) |
| `e` | the server's event feed — what Forge has done to it, newest first |
| `o` | open the site's URL, or a server's page in Forge |
| `f` | open the row in the Forge dashboard |
| `s` | copy an `ssh forge@…` command for the server |
| `r` | refresh now |
| `a` | add an organization |
| `Y` | confirm a reboot or a command that enter has armed |
| esc | back one level, or close |

Anything that changes something takes **two presses**: the first arms the row and says so, the
second sends it. Arms expire after a few seconds. A reboot and a command need a capital `Y` for the
second press rather than enter, so a mistyped `j` or `k` can never be the last key before a server
goes down.

The line at the bottom of the panel names what the row under the cursor can do.

Mouse: left click a row to unfold it or open a site; click the ⚙ on a server row for its actions;
right click to open it in Forge. Inside a view, the trail at the top left is the way back.

<img src="screenshots/deploy.png" alt="A site row armed, reading 'press again to deploy'" width="420">

### A site

Opening a site gives you its actions and its details, all from data the refresh already fetched.

| | |
|---|---|
| **Actions** | deploy, toggle maintenance mode, run a command, read the deployment log, open the site, open it in Forge, copy its ssh command |
| **Details** | PHP version, app type, status, maintenance mode, isolation, zero-downtime, releases kept, aliases, healthcheck |

An action that can't run says why — a site with no repository, or one that has never deployed.

**Maintenance mode** takes the site offline behind a 503, and brings it back on the same two
presses. Forge does the work out on the server, so the row says `enabling…` until it has landed.

**Run a command** opens a prompt: type a command, enter to arm, `Y` to run. It runs as `forge` in
the site's directory. Nothing is remembered between opens — no history, no repeat key, on purpose.
The output arrives when the run finishes.

**Deployment log** opens the latest deploy's output, ANSI stripped, scrolled to the bottom.

| Key | In a log, a command's output, or an event's output |
|---|---|
| `j` `k` or ↑ ↓ | scroll |
| `g` / `G` | top / bottom |
| `c` | copy the whole thing |
| `w` | save it to `~/Downloads/` — the panel says where it landed |
| `r` | look at a command run or an event's output again |
| `h` or esc | back |

### A server

Press `l` on an unfolded server, or click the ⚙ on any server row.

| | |
|---|---|
| **Restart nginx** | two presses |
| **Reload PHP-FPM** | a graceful reload of the server's PHP version |
| **Restart PHP-FPM** | the harder version |
| **Reboot server** | enter to arm, capital `Y` to send |
| **Server events** | what Forge has done to the server, newest first — also `e` from any row |

Forge does all of this asynchronously, so the answer is "requested" — what changed shows up in the
next refresh.

#### Events

Every deploy, command run, key install and environment change Forge performs on a server is an
event, and the feed lists them thirty at a time with the site each was about and when. Enter on one
opens what it printed, in the same pane as a deployment log and with the same keys; enter on the
last row, *Older events…*, fetches the next thirty. An unreachable server's feed is where the
reason usually is.

Forge records what an event did and what it printed, **not whether it succeeded** — there is no
status on an event, so the feed has no red rows. Open the output to find out. Reading events needs
only the `server:view` scope, so unlike deployment logs this works on a read-only token.

### Notifications

Deployments that finish or fail between refreshes raise a desktop notification, naming the
organization when more than one is watched. Clicking it opens the site.

## More than one organization

One token belongs to an **account**; an account can see several **organizations**. A token that
already sees three organizations only needs adding once. An organization on somebody else's Forge
account needs a token of its own.

Press `a` in the panel, or:

```sh
omarchy-forge add                          # store a token, pick its organizations
omarchy-forge accounts                     # who is configured, and what each one watches
omarchy-forge login --account clientco     # replace a token after rotating it
omarchy-forge remove acme                  # stop watching one organization
omarchy-forge remove --account clientco    # drop an account, its token, and its orgs
```

All of them show in one list, grouped per organization. Nothing needs restarting — a new
organization is picked up within a refresh.

## Settings

Editable in Setup → Plugins, or in `~/.config/omarchy/shell.json`:

| Key | Default | What |
|---|---|---|
| `refreshIntervalSec` | `60` | seconds between refreshes (15–3600) |
| `watchDeployments` | `true` | also fetch sites and deployment status |
| `notifyDeployments` | `true` | notify when a deployment finishes or fails |
| `organization` | `""` | which organizations this copy shows — empty for all |
| `dashboardUrlTemplate` | `https://forge.laravel.com/{org}/{server}/{site}` | where `f` and right-click point — `{org}`/`{server}` are slugs, `{site}` an id, `{serverId}` also available |

`organization` is a filter, not a second place to configure one. A slug narrows the widget to that
organization; a comma-separated list narrows it to those. You can put a second copy in the bar
pinned to one organization if you would rather have separate icons.

## Rate limits

Forge allows **60 requests a minute per Forge account**, shared with anything else on it —
including its own dashboard in a browser tab.

A refresh costs **two requests per organization**, whatever your server count, and that figure
doesn't change with the number of monitors. Opening a deployment log is one more, and so is a
server's event feed — one per page of thirty, and one for each event's output you open. Running a
command costs about a dozen, spread over a hundred seconds.

The widget keeps a budget per account and backs off before it runs out, telling you on the row
rather than failing silently. If Forge refuses anyway, the panel says "rate limited" and everything
on that account waits until the limit resets, then resumes on its own.

Organizations with more than 150 sites are checked in rotation across several refreshes — nothing
is dropped, but a status change at the far end can be noticed one rotation late. The panel says
when that is happening.

## The CLI

`omarchy-forge` works on its own, and is useful for scripting even if you never open the panel:

```sh
omarchy-forge setup           # guided setup
omarchy-forge add             # store a token and pick organizations to watch
omarchy-forge accounts        # accounts, tokens, and what each one watches
omarchy-forge orgs [account]  # organizations a token can see
omarchy-forge org [slug]      # show or set the default organization
omarchy-forge remove <slug>   # stop watching an organization
omarchy-forge rename OLD NEW  # give an account a different CLI handle
omarchy-forge logout [account]             # remove an account's token
omarchy-forge status [--org SLUG]          # server health as a table
omarchy-forge doctor                       # every account: token, auth, rate limit left
omarchy-forge api --account default GET /orgs/acme/servers      # raw request
```

To have it on your `PATH`:

```sh
ln -sf ~/.config/omarchy/plugins/acobrerosf.forge/omarchy-forge ~/.local/bin/omarchy-forge
```

`api` always prints one JSON envelope, whatever went wrong:

```json
{"ok": true, "status": 200, "rateRemaining": 57, "rateReset": null, "body": { }, "error": null}
```

A third argument is a JSON request body; pass `-` to read it from stdin instead. `--account` names
the credential to use and `--org` picks it by organization; with neither, the default organization's
account is used. `$FORGE_TOKEN` (with `$FORGE_ACCOUNT`) overrides the keyring for one run.

State lives in `~/.local/state/omarchy/forge.json` — which accounts exist, which organizations each
reaches, and which is the default. Tokens are never in there.

## Requirements

- Omarchy 4.0 or newer
- `curl`, `jq`, `secret-tool` — all on a stock Omarchy install
- `wl-copy` for the copy actions
- `gum`, optionally — nicer organization picking; there is a numbered fallback without it

## Known limits

- **The dashboard URL is a template.** The Forge API hands out no web link, so
  `dashboardUrlTemplate` is a setting.
- **The server view stops at four writes.** Stopping a service and power-cycling a server are
  deliberately absent, as are the database and queue services.
- **Events have no status.** Forge's event record says what was done and what it printed, not
  whether it worked, so the feed cannot colour a failed step — open its output to find out.
- **The server list stops at 150 rows** and says so rather than quietly showing a prefix. Sites are
  not capped — past 150 they are checked in rotation.
- **A command run has no history and no partial output.** You see the run you just started, and its
  output arrives when it finishes.
- **Deployment logs need a write scope.** That is Forge's choice, not this plugin's — a strictly
  read-only token can watch a deployment fail and not be told why.

## License

MIT
