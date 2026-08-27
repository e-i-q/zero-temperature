#!/usr/bin/env python3
"""
dht22_logger.py — Read a DHT22 sensor, average multiple samples, store to SQLite.

Hardware:
    DHT22 data pin → GPIO2 (BCM numbering / physical pin 3)
    Don't forget a 10kΩ pull-up resistor between DATA and VCC if your
    breakout board doesn't already include one.

Usage:
    python3 dht22_logger.py
    python3 dht22_logger.py --samples 5 --delay 2.5
    python3 dht22_logger.py --db /mnt/sqlite_ram/sensors.db

Requires:
    pip3 install adafruit-circuitpython-dht --break-system-packages
    (Adafruit_DHT, the older library, is deprecated/archived upstream —
    adafruit-circuitpython-dht is the maintained replacement.)

    pip3 install psycopg2-binary --break-system-packages
    (needed for the remote PostgreSQL mirror; see remote_db.py)

Remote DB:
    In addition to the local SQLite file, each reading is mirrored to a
    PostgreSQL database on another RPi — see remote_db.py for connection
    config and auth. That database's `readings.sensor_id` column references
    a `sensors` table (id, name, description, ip_address). This script
    (re)registers itself there under its hostname (`uname -n`) on every
    successful connection, not just the first time — that also keeps
    `sensors.ip_address` current, which the Hive dashboard's Settings tab
    relies on to reach this Pi for a manual sync trigger (see
    rpi5/web/api/sync_trigger.php and web/sync.php). The remote write is
    best-effort — if the remote host is unreachable, a warning is printed to
    stderr but the script still exits 0 as long as the local SQLite write
    succeeded.

Offline backlog sync:
    Every local row gets a `synced_at` column, NULL until its remote mirror
    is confirmed. A `sync_state` table remembers whether the *previous* run
    managed to reach the remote DB. When a run's own mirror succeeds right
    after a run where it didn't, that's an offline→online transition, and
    this script fires sync_backlog.sync_backlog() once to push everything
    else still marked unsynced (e.g. a whole trip's worth of readings taken
    with no connectivity). Otherwise the backlog sync never runs — not on a
    timer, not on every reading — so there's no added cost while offline or
    once everything is already caught up. See sync_backlog.py.
"""

import argparse
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
import board
import adafruit_dht
import psycopg2
import local_db
import remote_db
import sync_backlog
dht_device = adafruit_dht.DHT22(board.D2)  # D2 = GPIO2

# ── Configuration ──────────────────────────────────────────────────────────
DEFAULT_PIN = 2             # BCM GPIO2 (physical pin 3)
DEFAULT_SAMPLES = 5         # Number of readings to average
DEFAULT_MAX_ATTEMPTS = 50   # Number of max iterations before reaching samples count
DEFAULT_DELAY = 2.5         # Seconds between readings (DHT22 needs >= 2s)
DEFAULT_DB_PATH = "/mnt/sqlite_ram/sensors.db"
DEFAULT_SENSOR_NAME = "dht22"


def read_samples(pin, samples, delay, max_attempts):
    temps, hums = [], []
    for i in range(1, max_attempts + 1):
        try:
            temperature = dht_device.temperature
            humidity = dht_device.humidity
            if temperature is not None and humidity is not None:
                temps.append(temperature)
                hums.append(humidity)
        except RuntimeError as e:
            print(f"  Error reading {i}/{max_attempts}: {e}")
        if len(temps) >= samples:
            return temps, hums
        time.sleep(delay)
    return temps, hums


def average(values: list[float]) -> float:
    return sum(values) / len(values)


def store_reading(
    db_path: str,
    timestamp: str,
    sensor_name: str,
    temperature_c: float,
    humidity_pct: float,
    sample_count: int,
) -> int:
    conn = sqlite3.connect(db_path)
    try:
        local_db.ensure_schema(conn)
        cur = conn.execute(
            """
            INSERT INTO readings (recorded_at, sensor, temperature_c, humidity_pct, sample_count)
            VALUES (?, ?, ?, ?, ?)
            """,
            (timestamp, sensor_name, round(temperature_c, 2), round(humidity_pct, 2), sample_count),
        )
        conn.commit()
        row_id = cur.lastrowid
    finally:
        conn.close()

    print(f"Stored: {timestamp}  {temperature_c:.2f}°C  {humidity_pct:.2f}%  (n={sample_count}) → {db_path}")
    return row_id


def store_reading_remote(
    hostname: str,
    timestamp: str,
    temperature_c: float,
    humidity_pct: float,
    sample_count: int,
) -> bool:
    """Mirror a reading to the remote PostgreSQL DB. Best-effort: any failure
    (unreachable host, auth error, ...) is logged as a warning, not raised.
    Returns whether the row is confirmed on the remote DB — the caller uses
    this (via sync_state) to detect an offline→online transition and trigger
    sync_backlog.sync_backlog() for anything missed while disconnected."""
    insert_sql = """
        INSERT INTO readings (recorded_at, sensor_id, temperature_c, humidity_pct, sample_count)
        VALUES (%s, (SELECT id FROM sensors WHERE name = %s), %s, %s, %s)
    """
    params = (timestamp, hostname, round(temperature_c, 2), round(humidity_pct, 2), sample_count)

    try:
        conn = remote_db.connect()
    except psycopg2.OperationalError as e:
        print(f"WARNING: could not connect to remote DB at {remote_db.PG_HOST}:{remote_db.PG_PORT}: {e}", file=sys.stderr)
        return False

    try:
        # Register/refresh up front (see remote_db.register_sensor's
        # docstring) so this Pi's `sensors` row — including its ip_address —
        # is guaranteed to exist and be current before the insert below,
        # rather than only fixing it up reactively on a failed insert.
        remote_db.register_sensor(conn, hostname, remote_db.local_ip())
        with conn.cursor() as cur:
            cur.execute(insert_sql, params)
        conn.commit()
        print(f"Stored: {timestamp}  {temperature_c:.2f}°C  {humidity_pct:.2f}%  (n={sample_count}) → {remote_db.PG_HOST}/{remote_db.PG_DBNAME}")
        return True
    except psycopg2.Error as e:
        conn.rollback()
        print(f"WARNING: remote DB write failed: {e}", file=sys.stderr)
        return False
    finally:
        conn.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read DHT22 sensor and log averaged values to SQLite.")
    parser.add_argument("--pin", type=int, default=DEFAULT_PIN, help=f"GPIO pin (BCM numbering, default {DEFAULT_PIN})")
    parser.add_argument("--samples", type=int, default=DEFAULT_SAMPLES, help=f"Number of readings to average (default {DEFAULT_SAMPLES})")
    parser.add_argument("--max_attempts", type=int, default=DEFAULT_MAX_ATTEMPTS, help=f"Maximum number of attempt of readings (default {DEFAULT_MAX_ATTEMPTS})")
    parser.add_argument("--delay", type=float, default=DEFAULT_DELAY, help=f"Seconds between readings (default {DEFAULT_DELAY}, min recommended 2.0)")
    parser.add_argument("--db", type=str, default=DEFAULT_DB_PATH, help=f"Path to SQLite database file (default {DEFAULT_DB_PATH})")
    parser.add_argument("--sensor-name", type=str, default=DEFAULT_SENSOR_NAME, help=f"Label stored in the 'sensor' column (default {DEFAULT_SENSOR_NAME})")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.delay < 2.0:
        print("WARNING: DHT22 needs at least ~2s between reads; values may be unreliable.", file=sys.stderr)

    db_path = Path(args.db)
    db_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"Reading DHT22 on GPIO{args.pin} — {args.samples} samples, {args.max_attempts} max attempts, {args.delay}s apart…")
    temps, hums = read_samples(args.pin, args.samples, args.delay, args.max_attempts)

    if not temps:
        print("ERROR: All sensor reads failed. Check wiring and pull-up resistor.", file=sys.stderr)
        return 1

    avg_temp = average(temps)
    avg_hum = average(hums)
    success_count = len(temps)

    print(f"\nAveraged over {success_count}/{args.samples} successful readings:")
    print(f"  Temperature: {avg_temp:.2f}°C")
    print(f"  Humidity:    {avg_hum:.2f}%")

    timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")

    row_id = store_reading(str(db_path), timestamp, args.sensor_name, avg_temp, avg_hum, success_count)

    hostname = remote_db.local_hostname()
    was_offline = not local_db.get_last_remote_ok(str(db_path))
    remote_ok = store_reading_remote(hostname, timestamp, avg_temp, avg_hum, success_count)
    local_db.set_last_remote_ok(str(db_path), remote_ok)

    if remote_ok:
        local_db.mark_synced(str(db_path), row_id, timestamp)
        if was_offline:
            # Previous run couldn't reach the remote DB, this one just did —
            # push everything else that piled up locally while disconnected.
            print("Remote connection restored — syncing backlog of readings taken while offline…")
            sync_backlog.sync_backlog(str(db_path), hostname)

    return 0


if __name__ == "__main__":
    sys.exit(main())
