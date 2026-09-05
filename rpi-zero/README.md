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
| `python/ups_ina219.py` | Reads the INA219-based UPS HAT and writes this Pi's live power status to the central DB — see "UPS battery status" below |
| `python/remote_db.py` | Shared PostgreSQL connection/config, used by `dht22_logger.py`, `ups_ina219.py` and `sync_backlog.py` |
| `python/sync_backlog.py` | Pushes any local readings not yet confirmed on the central DB — see "Offline backlog sync" below |
| `web/index.html`, `web/css/`, `web/js/` | Dashboard: live readings, min/max/avg stats, timeline chart with sunrise/sunset markers |
| `web/readings.php` | JSON API the dashboard polls; queries the SQLite database read-only |
| `web/sync.php` | Runs `sync_backlog.py` on demand, gated by a shared secret — see "Manual sync trigger (from the Hive)" below |
| `web/deploy_trigger.php` | Pulls + redeploys this Pi Zero on demand, gated by a shared secret — see "Push-to-deploy (from the Hive)" below |
| `setup/setup_sqlite_ramdisk.sh` | Mounts a tmpfs RAM disk for the SQLite DB, with daily SD backup + restore-on-boot |
| `setup/setup_nginx_php.sh` | Installs and configures nginx + PHP-FPM (with `pdo_sqlite`) |
| `setup/setup_dht22_logger.sh` | Installs Python deps and a cron job that runs the logger periodically |
| `setup/setup_ups_ina219.sh` | Installs Python deps, enables I2C, and a cron job that runs the UPS monitor periodically |
| `setup/setup_sync_trigger.sh` | Provisions `web/sync.php`'s shared secret and script/DB paths |
| `setup/deploy_web.sh` | Syncs `web/` into the nginx web root |
| `setup/git_deploy.sh` | Pulls the latest `main` and re-runs `deploy_web.sh` — what `deploy_trigger.php` actually runs |
| `setup/setup_deploy_trigger.sh` | Provisions `web/deploy_trigger.php`'s shared secret and the sudo rule it needs to redeploy as root |
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
sudo bash setup/setup_ups_ina219.sh       # optional — only for Zeros with a UPS HAT
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

## UPS battery status

Pi Zeros fitted with an INA219-based UPS HAT (battery info over I2C) can run
`python/ups_ina219.py` on a cron job (`setup/setup_ups_ina219.sh`, every 5
minutes by default) to report their live power state into the central
database's `sensors.status` column — shown as a badge on that sensor's tile
in the Hive dashboard's Overview tab (`../rpi5`):

- **OK** — on mains, battery full
- **CHARGING &lt;pct&gt;%** — on mains, battery topping up
- **BATTERY &lt;pct&gt;%** — mains lost, running on battery

This is entirely optional and independent of `dht22_logger.py` — a Zero
without a UPS HAT just never writes `status`, and the dashboard shows OK for
it whenever it's otherwise online. It needs the same central-DB `status`
column set up first (see `../../db/database/sensors/tables/sensors.md`), and
the same `~/.pgpass` entry as `dht22_logger.py` for the `sensor_writer` role.

```bash
sudo bash setup/setup_ups_ina219.sh     # installs deps, enables I2C, cron job
```

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

## Push-to-deploy (from the Hive)

Optional: have this Pi Zero redeploy itself automatically whenever `main`
is pushed, instead of SSHing in and pulling by hand. This Pi Zero isn't
reachable from the internet itself — the Hive is the only Pi with a port
forwarded, so it's the one GitHub's webhook reaches, and it relays a
deploy trigger here over the LAN. See `../rpi5/README.md`'s
"Push-to-deploy" section for the full setup — **run
`rpi5/setup/setup_deploy_webhook.sh` there first**, it prints a
`DEPLOY_TOKEN` value this Pi needs:

```bash
sudo DEPLOY_TOKEN=<token printed on the Hive> bash setup/setup_deploy_trigger.sh
```

`web/deploy_trigger.php` itself is deployed like any other file under
`web/` — no separate step beyond `deploy_web.sh`. Without this setup, a
push still redeploys the Hive; this Pi Zero just doesn't get the relay and
needs deploying by hand, same as before.

## Why SQLite on a RAM disk?

The Pi Zero's SD card wears out under frequent writes. The live database
lives in a tmpfs RAM disk, gets flushed to the SD card once a day (and on
graceful shutdown), and is restored from that backup on boot — trading up to
24h of data loss on a hard power failure for far fewer SD writes.
