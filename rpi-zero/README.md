# rpi-zero

A DHT22 temperature/humidity sensor station for the Raspberry Pi Zero, with a
live web dashboard. This is the sensor-node half of the
[Zero Temperature](../README.md) project — deploy this directory to every
Pi Zero. The other half, [`../rpi5`](../rpi5), is the whole-apartment
dashboard that runs on the central Raspberry Pi 5.

```
DHT22 sensor → dht22_logger.py (cron) → SQLite (RAM disk) → readings.php → dashboard
                                     └─→ central PostgreSQL DB (Pi 5) → ../rpi5 dashboard
```

Each reading is written locally to SQLite (so this Pi Zero's own dashboard
keeps working even if the network or the Pi 5 is down) and mirrored,
best-effort, to the central database — see the `Remote DB` section of
`python/dht22_logger.py`'s docstring for the mirroring/auth details.

If the Pi Zero is offline for a while (e.g. taken out on battery power),
readings still land in local SQLite even though the live mirror keeps
failing. Nothing needs to be done by hand to catch back up: see
"Offline backlog sync" below.

## Components

| Path | Purpose |
|---|---|
| `python/dht22_logger.py` | Reads the DHT22, averages multiple samples, writes a row to SQLite, mirrors it live to the central DB |
| `python/remote_db.py` | Shared PostgreSQL connection/config, used by both `dht22_logger.py` and `sync_backlog.py` |
| `python/sync_backlog.py` | Pushes any local readings not yet confirmed on the central DB — see "Offline backlog sync" below |
| `web/index.html`, `web/css/`, `web/js/` | Dashboard: live readings, min/max/avg stats, timeline chart with sunrise/sunset markers |
| `web/readings.php` | JSON API the dashboard polls; queries the SQLite database read-only |
| `web/sync.php` | Runs `sync_backlog.py` on demand, gated by a shared secret — see "Manual sync trigger (from the Hive)" below |
| `setup/setup_sqlite_ramdisk.sh` | Mounts a tmpfs RAM disk for the SQLite DB, with daily SD backup + restore-on-boot |
| `setup/setup_nginx_php.sh` | Installs and configures nginx + PHP-FPM (with `pdo_sqlite`) |
| `setup/setup_dht22_logger.sh` | Installs Python deps and a cron job that runs the logger periodically |
| `setup/setup_sync_trigger.sh` | Provisions `web/sync.php`'s shared secret and script/DB paths |
| `setup/deploy_web.sh` | Syncs `web/` into the nginx web root |
| `setup/lib/log.sh` | Shared colored logging + quiet-by-default install output for the scripts above |

## Hardware

DHT22 data pin → GPIO2 (BCM numbering / physical pin 3), with a 10kΩ pull-up
resistor between DATA and VCC if your breakout board doesn't already include
one.

## Setup (Raspberry Pi Zero)

Run from the project root, in order:

```bash
sudo bash setup/setup_sqlite_ramdisk.sh   # RAM-backed SQLite DB + backup/restore
sudo bash setup/setup_nginx_php.sh        # nginx + PHP-FPM + pdo_sqlite
bash setup/deploy_web.sh                  # copy web/ into the nginx web root
sudo bash setup/setup_dht22_logger.sh     # installs deps + cron job for the logger
```

Each script is configurable via environment variables (e.g. `RUN_USER`,
`DB_PATH`, `WEB_ROOT`, `CRON_INTERVAL_MIN`) — see the top of each script for
the available overrides.

By default, package installs (`apt-get`, `pip3`, etc.) run quietly — you
just see which package is being installed, not its raw output. Pass
`-v`/`--verbose` to any setup script to see the full output instead:

```bash
sudo bash setup/setup_nginx_php.sh --verbose
```

After setup, the dashboard is served at `http://<pi-address>/`.

## Manual logger run

```bash
python3 python/dht22_logger.py --samples 5 --delay 2.5 --db /mnt/sqlite_ram/sensors.db
```

Requires `adafruit-circuitpython-dht` (`pip3 install adafruit-circuitpython-dht --break-system-packages`).

## Offline backlog sync

Every local `readings` row has a `synced_at` column, NULL until its live
mirror to the central DB is confirmed. A one-row `sync_state` table
remembers whether the *previous* run of `dht22_logger.py` reached the
central DB. When a run's mirror succeeds right after a run where it
didn't, that's treated as an offline→online transition, and the logger
calls `sync_backlog.py` once to push everything else still marked
unsynced (deduped against the remote table, so it's safe even for rows
predating this tracking).

This is deliberately *not* a timer or a periodic connectivity check: the
backlog sync only ever runs on that fail→success edge, so it costs
nothing extra while offline and nothing extra once everything is already
caught up. You can also run it by hand at any time (e.g. right after
getting back from a trip, instead of waiting for the next scheduled
reading):

```bash
python3 python/sync_backlog.py --db /mnt/sqlite_ram/sensors.db
```

## Manual sync trigger (from the Hive)

The Hive dashboard's Settings tab (`../rpi5`) has a "Sync Now" button per
sensor, for a Pi Zero you don't want to wait on (e.g. it doesn't have the
offline→online auto-trigger above deployed yet, or you just want to force
a catch-up right now). It works by calling `web/sync.php` here, which runs
`sync_backlog.py` and reports the result back.

This needs setup on **both** ends, sharing one secret token across the
whole fleet:

```bash
sudo bash setup/setup_sync_trigger.sh   # here, on this Pi Zero — prints a token
# then, on the Hive:
sudo SYNC_TOKEN=<token printed above> bash setup/setup_sync_trigger.sh
```

`web/sync.php` itself is deployed like any other file under `web/` — no
separate step beyond `deploy_web.sh`. Without this setup, the Settings
tab's button for this sensor just reports the trigger isn't configured;
everything else (the automatic offline→online sync) keeps working
regardless.

## Why SQLite on a RAM disk?

The Pi Zero's SD card wears out under frequent writes. The live database
lives in a tmpfs RAM disk, gets flushed to the SD card once a day (and on
graceful shutdown), and is restored from that backup on boot — trading up to
24h of data loss on a hard power failure for far fewer SD writes.
