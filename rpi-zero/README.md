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
| `python/dht22_logger.py` | Reads the DHT22, averages multiple samples, writes a row to SQLite, mirrors it live to the central DB — see "DHT22 fault reporting" below for what happens when every read fails |
| `python/ups_ina219.py` | Reads the INA219-based UPS HAT and writes this Pi's live power status to the central DB — see "UPS battery status" below |
| `python/uptime_reporter.py` | Reads this Pi's own system uptime and writes it to the central DB — see "Uptime reporting" below |
| `python/report_version.py` | Reads this Pi's currently-deployed git commit and writes it to the central DB — see "Version reporting" below |
| `python/remote_db.py` | Shared PostgreSQL connection/config, used by `dht22_logger.py`, `ups_ina219.py`, `uptime_reporter.py`, `report_version.py` and `sync_backlog.py` |
| `python/sync_backlog.py` | Pushes any local readings not yet confirmed on the central DB — see "Offline backlog sync" below |
| `python/sd_backup.py` | Copies the RAM-disk database to the SD card more often while offline — see "Offline SD-card backups" below |
| `web/index.html`, `web/css/`, `web/js/` | Dashboard: live readings, min/max/avg stats, timeline chart with sunrise/sunset markers |
| `web/readings.php` | JSON API the dashboard polls; queries the SQLite database read-only |
| `web/sync.php` | Runs `sync_backlog.py` on demand, gated by a shared secret — see "Manual sync trigger (from the Hive)" below |
| `web/deploy_trigger.php` | Pulls + redeploys this Pi Zero on demand, gated by a shared secret — see "Push-to-deploy (from the Hive)" below |
| `web/ondemand.php` | Starts an on-demand reading and serves its live progress, gated by the sync secret — see "On-demand reading (from the Hive)" below |
| `setup/setup_sqlite_ramdisk.sh` | Mounts a tmpfs RAM disk for the SQLite DB, with daily SD backup + restore-on-boot |
| `setup/setup_nginx_php.sh` | Installs and configures nginx + PHP-FPM (with `pdo_sqlite`) |
| `setup/setup_dht22_logger.sh` | Installs Python deps and a cron job that runs the logger periodically |
| `setup/setup_ups_ina219.sh` | Installs Python deps, enables I2C, and a cron job that runs the UPS monitor periodically |
| `setup/setup_uptime_reporter.sh` | Installs Python deps and a cron job that runs the uptime reporter every 5 minutes |
| `setup/setup_sync_trigger.sh` | Provisions `web/sync.php`'s shared secret and script/DB paths |
| `setup/deploy_web.sh` | Syncs `web/` into the nginx web root |
| `setup/git_deploy.sh` | Pulls the latest `main`, re-runs `deploy_web.sh`, and reports the new commit to the Hive — what `deploy_trigger.php` actually runs |
| `setup/setup_deploy_trigger.sh` | Provisions `web/deploy_trigger.php`'s shared secret and the sudo rule it needs to redeploy as root |
| `setup/net_watchdog.sh` | Network watchdog run every minute: reconnects Wi-Fi when offline, reboots as a last resort — see "Staying online" below |
| `setup/setup_net_watchdog.sh` | Installs the watchdog and hardens Wi-Fi so it reconnects without anyone logged in — see "Staying online" below |
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
sudo bash setup/setup_uptime_reporter.sh  # installs deps + cron job for uptime reporting
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

## DHT22 fault reporting

`dht22_logger.py` retries a failed read (up to `--max_attempts`, default
50) until it has `--samples` good ones. Every row it stores — locally and
on the central DB — carries all three counts, so the dashboards' Samples
column reads success/failed/max (e.g. `4/1/50`) instead of a bare count;
see `../../db/database/sensors/tables/readings.md`.

If a run exhausts every attempt without a single success (the sensor came
loose, a wiring fault, ...), there's no average to store, so — same as
before this feature existed — no row is written at all. What's new: the
script still reaches out to the central DB, best-effort, just to set
`sensors.dht22_fault_at`, which drives a FAULTY DHT22 badge on that
sensor's tile in the Hive dashboard's Overview tab (`../rpi5`). It clears
itself the moment a later run gets at least one successful read — nothing
to reset by hand. This badge is independent of ONLINE/OFFLINE, which the
Hive derives by pinging this Pi directly (see `../rpi5/bin/ping_sensors.php`)
rather than from reading recency, precisely so a Zero with a loose DHT22
shows ONLINE + FAULTY DHT22 instead of a misleading OFFLINE.

## UPS battery status

Pi Zeros fitted with an INA219-based UPS HAT (battery info over I2C) can run
`python/ups_ina219.py` on a cron job (`setup/setup_ups_ina219.sh`, every 5
minutes by default) to report their live power state into the central
database's `sensors.status` column — shown as a badge on that sensor's tile
in the Hive dashboard's Overview tab (`../rpi5`):

- **OK** — on mains, battery full
- **CHARGING &lt;pct&gt;%** — on mains, battery topping up
- **BATTERY &lt;pct&gt;%** — mains lost, running on battery

The same run also reports the raw INA219 readings that badge is derived
from — bus voltage, current and power — into `sensors.battery_voltage_v` /
`battery_current_ma` / `battery_power_w`, shown per sensor on the Hive
dashboard's Settings tab, Sensors section (unlike the badge above, these
aren't shown on the Overview tab's tiles).

This is entirely optional and independent of `dht22_logger.py` — a Zero
without a UPS HAT just never writes any of the four columns above, and the
dashboard shows OK (and no battery readings) for it whenever it's otherwise
online. It needs the same central-DB columns set up first (see
`../../db/database/sensors/tables/sensors.md`), and the same `~/.pgpass`
entry as `dht22_logger.py` for the `sensor_writer` role.

```bash
sudo bash setup/setup_ups_ina219.sh     # installs deps, enables I2C, cron job
```

## Uptime reporting

`python/uptime_reporter.py` runs on a cron job (`setup/setup_uptime_reporter.sh`,
every 5 minutes by default) and reports this Pi's own `/proc/uptime` — seconds
since it last booted — into the central database's `sensors.uptime_seconds`
column, shown per sensor on the Hive dashboard's Settings tab, Sensors section
(`../rpi5`).

This is entirely optional and independent of `dht22_logger.py` — a Zero that's
never run the reporter just never writes `uptime_seconds`, and the dashboard
shows "no uptime on file" for it. It needs the same central-DB
`uptime_seconds` column set up first (see
`../../db/database/sensors/tables/sensors.md`), and the same `~/.pgpass` entry
as `dht22_logger.py` for the `sensor_writer` role.

```bash
sudo bash setup/setup_uptime_reporter.sh   # installs deps, cron job
```

## Version reporting

`python/report_version.py` reports the git commit this Pi is currently
deployed at — short hash, subject line and author date — into the central
database's `sensors.commit_hash` / `commit_summary` / `commit_date`
columns, shown per sensor on the Hive dashboard's Settings tab, Sensors
section (`../rpi5`).

Unlike the uptime reporter above this isn't a cron job: `setup/git_deploy.sh`
runs it once, automatically, right after every successful pull + redeploy
(see "Push-to-deploy" below) — there's nothing new to report until the code
actually changes. It needs the same central-DB columns set up first (see
`../../db/database/sensors/tables/sensors.md`), and the same `~/.pgpass`
entry as `dht22_logger.py` for the `sensor_writer` role. You can also run it
by hand at any time to refresh the Hive's record without a full redeploy:

```bash
python3 python/report_version.py
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

## On-demand reading (from the Hive)

The Hive dashboard's Overview tab has a "Read Now" button that takes a
fresh reading on every online Pi Zero at once and shows each one's live
progress (attempt counter, successes/errors, latest and average
temperature). On this Pi it works like this:

```
Hive api/ondemand.php ─POST→ web/ondemand.php ─writes→ /run/dht22-ondemand/request.json
                                                         │ (dht22-ondemand.path notices it)
                                                         ▼
                      dht22-ondemand.service: dht22_logger.py --ondemand-dir /run/dht22-ondemand
                                                         │ rewrites status.json after every attempt
Hive api/ondemand.php ─GET (1×/s)→ web/ondemand.php ─reads┘
```

The reading itself is an ordinary logger run — stored locally and mirrored
to the Hive like any cron reading. A run and a cron run never touch the
DHT22 at the same time: both take a lock file next to the database, and
whichever comes second waits.

Setup: re-run `sudo bash setup/setup_dht22_logger.sh` (it installs the
path/service units and the `/run/dht22-ondemand` directory), and make sure
the sync trigger above is configured — `web/ondemand.php` authenticates
the Hive with that same shared token.

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

This same setup also backs the Hive dashboard's Settings tab "Update Now"
button for this sensor (`../rpi5/web/api/deploy_trigger.php`) — a way to
redeploy this one Pi Zero on demand, e.g. right after it comes back online
having missed the last push's fleet-wide relay, without waiting for the
next push.

## Staying online

Symptoms this addresses: a Zero drops off the network and stays off,
and a monitor shows either a **"Wi-Fi password" dialog** or the **desktop
login screen** asking for the OS password.

Both point at the same root cause on Raspberry Pi OS (NetworkManager): a
Wi-Fi network joined from the desktop can keep its password in the
desktop user's keyring ("agent-owned") instead of in NetworkManager's
system config. NetworkManager then only gets the password from a
logged-in desktop session — so after a reboot that lands on the login
screen there's no Wi-Fi at all, and after any failed handshake (weak
signal, router restart) it asks the desktop for the password again and
stops auto-connecting until someone answers the dialog.

```bash
sudo bash setup/setup_net_watchdog.sh
# if it warns that a password lives in a user keyring:
sudo WIFI_PSK='<wifi password>' bash setup/setup_net_watchdog.sh
# recommended for sensor nodes — no desktop, no login screen:
sudo BOOT_TO_CONSOLE=1 bash setup/setup_net_watchdog.sh
```

What it does:

- **Wi-Fi hardening** — every saved Wi-Fi connection gets its password
  stored system-wide (`psk-flags 0`), is usable without any user logged in,
  auto-connect retries forever instead of giving up after 4 tries, and
  Wi-Fi power saving is off (a classic Pi Zero W drop-out cause).
- **Network watchdog** (`net-watchdog.timer`, every minute, logs to
  `/var/log/net_watchdog.log`) — online means the gateway, the Hive, *or*
  the Hive's PostgreSQL port answers, so a Hive outage alone never
  triggers anything. After 3 minutes offline it cycles the Wi-Fi radio and
  explicitly re-activates the saved networks (which also clears
  NetworkManager's "waiting for a password" block), repeating every 5
  minutes. After 30 minutes offline it flushes the database to the SD card
  and reboots; each reboot that doesn't bring the network back doubles
  that wait (up to 12 h), so a Zero taken out of Wi-Fi range doesn't
  reboot-loop. Connectivity coming back resets it. Tunables:
  `RECONNECT_AFTER_MIN`, `RECONNECT_EVERY_MIN`, `REBOOT_AFTER_MIN` (0 =
  never reboot), `MAX_REBOOT_AFTER_MIN` — as env vars to the setup script,
  saved in `/etc/default/net_watchdog`.
- **Hardware watchdog** (`RuntimeWatchdogSec=15`) — resets the Pi if the
  kernel itself freezes. `HW_WATCHDOG=0` to skip.

The watchdog is installed as a copy (`/usr/local/sbin/net_watchdog`), so
re-run the setup script after pulling a change to `net_watchdog.sh`.

## Offline SD-card backups

While this Pi can't reach the Hive, its RAM disk holds the only copy of
every reading since the connection dropped — and an offline Zero is
exactly the one that gets unplugged or rebooted to debug it. So every
logger run that fails to mirror its reading also copies the database to
the SD card (`python/sd_backup.py`, same file and format as the daily
flush, so the boot-time restore picks it up unchanged) if the last such
copy is older than the **offline backup interval** — 3 hours by default,
set fleet-wide on the Hive's Settings tab → Sensors (0 = off). The
interval is fetched from the Hive on every successful connection and
cached locally, since it's needed precisely when the Hive is unreachable.
The first offline run copies right away.

Needs the `hive_config` table on the Hive (re-run the `db` project's
`setup_db.py`); until then the 3-hour default applies. Nothing to set up
here — the logger writes `/var/lib/sqlite_backup/sensors.db.gz` itself
(`--sd-backup` to change), which `setup_sqlite_ramdisk.sh` already made
owned by the logger's user.

## Why SQLite on a RAM disk?

The Pi Zero's SD card wears out under frequent writes. The live database
lives in a tmpfs RAM disk, gets flushed to the SD card once a day (and on
graceful shutdown), and is restored from that backup on boot — trading up to
24h of data loss on a hard power failure for far fewer SD writes. While
offline that window shrinks to the offline backup interval (see above),
since then nothing else holds a copy.
