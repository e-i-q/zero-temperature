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
long-term view.

```
PostgreSQL (Hive, this Pi)  →  api/readings.php, api/daily.php  →  dashboard
```

## Components

| Path | Purpose |
|---|---|
| `web/index.html`, `web/css/`, `web/js/` | Dashboard: per-sensor tiles, temperature/humidity timelines, 12-month long-term chart, recent-readings table |
| `web/api/db.php` | Shared read-only PDO connection to the Hive database |
| `web/api/readings.php` | JSON API: every sensor's readings in a requested time window, plus latest/min/avg/max per sensor |
| `web/api/daily.php` | JSON API: 12 months of daily mean/min/max temperature per sensor, aggregated in PostgreSQL |
| `setup/setup_nginx_php.sh` | Installs and configures nginx + PHP-FPM (with `pdo_pgsql`) |
| `setup/deploy_web.sh` | Syncs `web/` into the nginx web root |

## Setup (Raspberry Pi 5)

Assumes the Hive database (`../../db`) is already deployed and running on
this Pi. Then, from this directory:

```bash
sudo bash setup/setup_nginx_php.sh   # nginx + PHP-FPM + pdo_pgsql
bash setup/deploy_web.sh             # copy web/ into the nginx web root
```

The dashboard connects as the `web_reader` role (read-only grants on
`sensors` and `readings` — see `../../db/database/sensors/meta.md`). Like
`rpi-zero/python/dht22_logger.py`'s writer role, no password is stored in
code or read from the environment: `www-data` needs a `~/.pgpass` entry:

```
127.0.0.1:5432:sensors:web_reader:<password>
```

```bash
sudo -u www-data bash -c 'echo "127.0.0.1:5432:sensors:web_reader:<password>" >> ~/.pgpass && chmod 600 ~/.pgpass'
```

After setup, the dashboard is served at `http://<pi5-address>/`.

## Notes on scope

- **Ranges**: 12H / 24H / 2D / 5D / 1M / ALL. `readings.php` queries
  PostgreSQL live for whichever window is selected (no caching — the
  point of centralizing is that this always reflects every Zero's latest
  write). "ALL" is capped at 20,000 rows as a payload-size safety net, not
  a time-window limit.
- **Long-term chart**: aggregated server-side (`daily.php`) rather than
  shipping a year of raw rows to the browser.
- **Night shading** on the timeline charts is a fixed 20:00–06:00
  local-time approximation, not real sunrise/sunset — unlike
  `rpi-zero`'s per-sensor dashboard, this avoids an Open-Meteo dependency
  for something that's only ever a rough visual cue here.
- **Offline sensors**: a sensor with no reading in the last 30 minutes
  (`OFFLINE_MINUTES` in `readings.php`) is shown greyed-out with a "last
  seen" time, rather than silently disappearing from the tile grid.
