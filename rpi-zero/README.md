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

## Components

| Path | Purpose |
|---|---|
| `python/dht22_logger.py` | Reads the DHT22, averages multiple samples, writes a row to SQLite |
| `web/index.html`, `web/css/`, `web/js/` | Dashboard: live readings, min/max/avg stats, timeline chart with sunrise/sunset markers |
| `web/readings.php` | JSON API the dashboard polls; queries the SQLite database read-only |
| `setup/setup_sqlite_ramdisk.sh` | Mounts a tmpfs RAM disk for the SQLite DB, with daily SD backup + restore-on-boot |
| `setup/setup_nginx_php.sh` | Installs and configures nginx + PHP-FPM (with `pdo_sqlite`) |
| `setup/setup_dht22_logger.sh` | Installs Python deps and a cron job that runs the logger periodically |
| `setup/deploy_web.sh` | Syncs `web/` into the nginx web root |

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

After setup, the dashboard is served at `http://<pi-address>/`.

## Manual logger run

```bash
python3 python/dht22_logger.py --samples 5 --delay 2.5 --db /mnt/sqlite_ram/sensors.db
```

Requires `adafruit-circuitpython-dht` (`pip3 install adafruit-circuitpython-dht --break-system-packages`).

## Why SQLite on a RAM disk?

The Pi Zero's SD card wears out under frequent writes. The live database
lives in a tmpfs RAM disk, gets flushed to the SD card once a day (and on
graceful shutdown), and is restored from that backup on boot — trading up to
24h of data loss on a hard power failure for far fewer SD writes.
