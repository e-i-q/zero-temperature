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
| `setup/setup_nginx_php.sh` | Installs and configures nginx + PHP-FPM (with `pdo_pgsql`) |
| `setup/deploy_web.sh` | Syncs `web/` into the nginx web root |
| `setup/setup_sync_trigger.sh` | Provisions the shared secret used to authenticate `sync_trigger.php`'s requests to each Pi Zero |
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
  `save_sensor_label` action to the `sensors.label` column (see
  `../../db/database/sensors/tables/sensors.md`). A sensor with a label
  shows it in place of its device name everywhere the Overview tab displays
  sensor identity (tiles, legend, chart tooltip, recent-readings table) —
  the device name itself stays visible too, faded into the background of
  that sensor's tile, rather than disappearing. Not per-profile — like the
  sensor registry itself, a label is global to the Hive, just gated behind
  being logged into *some* profile. Clearing a field reverts to showing the
  device name only.
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
