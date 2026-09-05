# rpi5 — Hive dashboard

The whole-apartment web dashboard: reads every sensor's readings out of the
central PostgreSQL database (the "Hive", [`../../db`](../../db) project) and
shows them together. This is the central-Pi half of the
[Zero Temperature](../README.md) project — deploy this directory to the
Raspberry Pi 5 that already hosts the Hive database. The sensor-node half,
[`../rpi-zero`](../rpi-zero), is what runs on each Pi Zero.

Visual design follows [`../IoT Temperature Dashboard Wireframe`](<../IoT Temperature Dashboard Wireframe>)
(option 1a — tiles over stacked overlay charts): a tile per sensor, combined
temperature/humidity timelines with a linked crosshair, and a 12-month
long-term view. A second tab, Forecast, shows the Open-Meteo forecast for
the same location the sensors are in — ported from `../rpi-zero`'s weather
comparison chart, but looking forward instead of back. A third tab,
Settings, lets the Overview/Forecast time-span choice follow you across
browsers via a password-protected profile stored in the Hive database
(see "Settings tab" below).

```
PostgreSQL (Hive, this Pi)  →  api/readings.php, api/daily.php  →  dashboard
```

## Components

| Path | Purpose |
|---|---|
| `web/index.html`, `web/css/`, `web/js/` | Dashboard: Overview tab (per-sensor tiles, temperature/humidity timelines, 12-month long-term chart, recent-readings table) and Forecast tab (Open-Meteo forecast chart) |
| `web/api/db.php` | Shared read-only PDO connection to the Hive database |
| `web/api/readings.php` | JSON API: every sensor's readings in a requested time window, plus latest/min/avg/max per sensor |
| `web/api/daily.php` | JSON API: 12 months of daily mean/min/max temperature per sensor, aggregated in PostgreSQL |
| `web/api/forecast.php` | JSON API: Open-Meteo hourly forecast (temperature/humidity/wind/condition) for the Forecast tab. No database — a cached proxy, same pattern as `../rpi-zero/web/weather.php` |
| `web/api/settings.php` | JSON API backing the Settings tab: password-profile login/create/save/logout, session-cookie-backed. See its docstring |
| `web/api/sync_trigger.php` | JSON API backing the Settings tab's "Sync Now" buttons: relays a manual backlog-sync request to a specific Pi Zero's `web/sync.php`. See its docstring |
| `web/api/deploy_trigger.php` | JSON API backing the Settings tab's "Update Now" buttons: relays a manual pull+redeploy request to a specific Pi Zero's `web/deploy_trigger.php`. See its docstring |
| `web/api/deploy_webhook.php` | GitHub push webhook receiver: pulls + redeploys the Hive, then relays a deploy trigger to every Pi Zero. See "Push-to-deploy" below |
| `setup/setup_nginx_php.sh` | Installs and configures nginx + PHP-FPM (with `pdo_pgsql`) |
| `setup/deploy_web.sh` | Syncs `web/` into the nginx web root |
| `setup/git_deploy.sh` | Pulls the latest `main` and re-runs `deploy_web.sh` — what `deploy_webhook.php` actually runs |
| `setup/setup_sync_trigger.sh` | Provisions the shared secret used to authenticate `sync_trigger.php`'s requests to each Pi Zero |
| `setup/setup_deploy_webhook.sh` | Provisions push-to-deploy: the GitHub webhook secret, the fleet-wide deploy token, and the sudo rule `deploy_webhook.php` needs to redeploy as root |
| `setup/lib/log.sh` | Shared colored logging + quiet-by-default install output for the scripts above |

## Setup (Raspberry Pi 5)

Assumes the Hive database (`../../db`) is already deployed and running on
this Pi. Then, from this directory:

```bash
sudo bash setup/setup_nginx_php.sh   # nginx + PHP-FPM + pdo_pgsql
bash setup/deploy_web.sh             # copy web/ into the nginx web root
```

By default, package installs (`apt-get`, etc.) run quietly — you just see
which package is being installed, not its raw output. Pass `-v`/`--verbose`
to see the full output instead:

```bash
sudo bash setup/setup_nginx_php.sh --verbose
```

The dashboard connects as the `web_reader` role (read-only grants on
`sensors` and `readings` — see `../../db/database/sensors/meta.md`). Like
`rpi-zero/python/dht22_logger.py`'s writer role, no password is stored in
code or read from the environment — `setup_nginx_php.sh` prompts for
`web_reader`'s password near the start of the run (this is the same
password set via `WEB_READER_PASSWORD` when the role was created by the
`db` project's `setup_db.py`) and writes it to `www-data`'s `~/.pgpass`
for you, `chmod 600`. Set `WEB_READER_PASSWORD` in the environment
beforehand to skip the prompt (e.g. for unattended installs).

If you ever need to redo this by hand — a different host is running the
dashboard, `www-data`'s home directory isn't where the script expects, or
the password rotated outside of a re-run — the line the script writes is:

```
127.0.0.1:5432:sensors:web_reader:<password>
```

```bash
# NOTE: `sudo echo ... > file` doesn't work — the redirect runs as your
# own user, before sudo applies, so it hits Permission denied. Use tee:
echo "127.0.0.1:5432:sensors:web_reader:<password>" | sudo tee "$(getent passwd www-data | cut -d: -f6)/.pgpass" > /dev/null
sudo chown www-data:www-data "$(getent passwd www-data | cut -d: -f6)/.pgpass"
sudo chmod 600 "$(getent passwd www-data | cut -d: -f6)/.pgpass"
```

After setup, the dashboard is served at `http://<pi5-address>/`.

## Push-to-deploy

Optional: redeploy the whole fleet (this Pi + every Pi Zero) automatically
whenever `main` is pushed, instead of SSHing into each device and pulling
by hand. The Hive is the only Pi meant to be reachable from the internet —
one port forwarded on your router, pointed here — so GitHub's webhook
always lands on this Pi, which redeploys itself and then relays the same
trigger to every Pi Zero over the LAN (using each sensor's `ip_address`
from the database, same lookup `api/sync_trigger.php` uses for "Sync
Now").

```bash
sudo bash setup/setup_deploy_webhook.sh
```

This prints two things you still need to do by hand:

1. **Add a webhook in GitHub** (repo Settings → Webhooks → Add webhook)
   pointing at `http://<your-public-ip-or-ddns-name>/api/deploy_webhook.php`,
   content type `application/json`, secret = the webhook secret it printed,
   event = just `push`. GitHub sends a `ping` first, answered instantly
   without deploying anything, so "Recent Deliveries" confirms the webhook
   is wired up correctly before the first real push.
2. **Run `rpi-zero/setup/setup_deploy_trigger.sh` on every Pi Zero**, with
   the (different) deploy token it printed — this is what lets the Hive's
   relay reach that Pi Zero.

From then on, a push to `main` redeploys everything within a few seconds,
logged to `/var/log/git-deploy.log` on this Pi (`tail -f` it to watch a
deploy happen, or to debug a Pi Zero the relay couldn't reach). This only
ever fast-forwards (`git merge --ff-only`) — a checkout that's diverged
from `origin/main` (e.g. a commit made directly on a Pi) fails loudly
instead of being silently overwritten.

The same per-Pi-Zero step (`setup_deploy_trigger.sh`) also unlocks the
Settings tab's per-sensor "Update Now" button — see "Settings tab — manual
deploy trigger" below — for redeploying one sensor on demand instead of
waiting for the next push.

## Notes on scope

- **Ranges**: 12H / 24H / 2D / 5D / 1M / ALL by default — editable per
  logged-in Settings profile (see "Settings tab" below). `readings.php`
  queries PostgreSQL live for whichever window is selected (no caching —
  the point of centralizing is that this always reflects every Zero's
  latest write). "ALL" is capped at 20,000 rows as a payload-size safety
  net, not a time-window limit.
- **Long-term chart**: aggregated server-side (`daily.php`) rather than
  shipping a year of raw rows to the browser.
- **Night shading** on the timeline charts is a fixed 20:00–06:00
  local-time approximation, not real sunrise/sunset — unlike
  `rpi-zero`'s per-sensor dashboard, this avoids an Open-Meteo dependency
  for something that's only ever a rough visual cue here.
- **Offline sensors**: a sensor with no reading in the last 30 minutes
  (`OFFLINE_MINUTES` in `readings.php`) is shown greyed-out with a "last
  seen" time, rather than silently disappearing from the tile grid.
- **UPS battery status**: a sensor's tile badge reads OK / CHARGING &lt;pct&gt;%
  / BATTERY &lt;pct&gt;% instead of the plain OK/OFFLINE, driven by the
  `sensors.status` column — see `../rpi-zero/README.md`'s "UPS battery
  status" section for the Pi Zero side (`ups_ina219.py`, opt-in per sensor,
  needs a UPS HAT). An offline sensor still shows OFFLINE regardless of its
  last-known status; a sensor with no UPS HAT (or `status` not yet written)
  shows OK once online, same as before this column existed.
- **Sensor uptime**: the Settings tab's Sensors section shows each Pi Zero's
  uptime since it last booted (e.g. "3d 4h"), next to its online/offline
  badge and LAN address, driven by the `sensors.uptime_seconds` column — see
  `../rpi-zero/README.md`'s "Uptime reporting" section for the Pi Zero side
  (`uptime_reporter.py`, a cron job every 5 minutes). A sensor that's never
  run the reporter shows "no uptime on file".
- **Sensor version**: the same Sensors section also shows each Pi Zero's
  currently-deployed code version (short commit hash · summary · date),
  driven by the `sensors.commit_hash`/`commit_summary`/`commit_date`
  columns — see `../rpi-zero/README.md`'s "Version reporting" section for
  the Pi Zero side (`report_version.py`, run once per push-to-deploy, not on
  a timer). A sensor that's never run the reporter shows "no version on
  file".
- **Forecast tab**: `forecast.php` reuses the Overview tab's range-chip UI
  (12H/24H/2D/5D/1M/ALL) so both tabs feel the same, but it's inherently a
  forward-looking window — Open-Meteo's free `/v1/forecast` endpoint only
  looks `FORECAST_DAYS_MAX` (16) days ahead, so 1M/ALL are both clamped to
  that ceiling instead of their literal meaning. Fetched lazily (only once
  the tab is first opened) and cached server-side for 30 minutes, same as
  `../rpi-zero/web/weather.php`.
- **Settings tab**: not logged in, the Overview/Forecast range chips work
  exactly as they always have — the fixed 12H/24H/2D/5D/1M/ALL set,
  remembered per-browser in `localStorage`. Logging in — a password, no
  username — attaches those same chip clicks to a profile row in the Hive
  database (`settings`/`passwords` tables) instead, so the choice follows
  you to any other browser that logs into the same profile. "Make New
  Settings" creates a fresh profile from whatever you type. This is a
  convenience, not an access-control feature: see `web/api/settings.php`'s
  docstring and `../../db/database/sensors/meta.md` for why it deliberately
  reuses `web_reader`'s own DB credentials rather than adding a second role.
  A logged-in profile can also edit the chip set itself — add, remove, and
  reorder time spans, including ones that don't exist in the default set
  (any `<number><unit>` token, unit one of h/d/w/m, or "all") — and that
  edited list drives both tabs' chip rows, since they've always shown the
  same set. `readings.php`/`forecast.php` parse the token shape generally
  rather than matching a hardcoded list, to accept whatever a profile has
  defined.
- **Settings tab — sensor labels**: logged in, the Settings tab also lists
  every registered sensor with a text field for a friendly label ("Kitchen",
  "Bedroom", "Garage", ...), saved via `api/settings.php`'s
  `save_sensor_label` action into that profile's own `settings.sensor_labels`
  column (see `../../db/database/sensors/tables/settings.md`) — private to
  the logged-in profile, not the shared `sensors` registry, so two profiles
  on the same Hive can label the same sensor differently. A sensor with a
  label shows it in place of its device name everywhere the Overview tab
  displays sensor identity (tiles, legend, chart tooltip, recent-readings
  table) — the device name itself stays visible too, faded into the
  background of that sensor's tile, rather than disappearing. Clearing a
  field reverts to showing the device name only; logged out, the Overview
  tab always shows device names, same as the range chips falling back to
  their fixed default set.
- **Settings tab — manual sync trigger**: logged in, the Settings tab also
  lists every registered sensor with a "Sync Now" button. Clicking one asks
  `api/sync_trigger.php` to relay a request to that Pi Zero's own
  `web/sync.php`, which runs `sync_backlog.py` there and reports the result
  — see `../rpi-zero/README.md`'s "Offline backlog sync" section for why
  this has to be a relay rather than something the Hive can do on its own.
  Requires `setup/setup_sync_trigger.sh` to have been run here AND
  `rpi-zero/setup/setup_sync_trigger.sh` on each Pi Zero you want this to
  work for, sharing one token across the fleet. A sensor with no
  `sensors.ip_address` on file yet falls back to `<name>.local` (mDNS).
- **Settings tab — manual deploy trigger**: the same per-sensor row also has
  an "Update Now" button. Clicking one asks `api/deploy_trigger.php` to
  relay a request to that Pi Zero's own `web/deploy_trigger.php`, which
  pulls the latest `main` and redeploys there — the same thing a push to
  `main` triggers fleet-wide via `api/deploy_webhook.php` (see
  "Push-to-deploy" below), just for one sensor on demand instead of waiting
  for the next push (or for a sensor that missed that push's relay, e.g. it
  was offline at the time). Reuses that same push-to-deploy setup and
  shared token — no separate provisioning step.
