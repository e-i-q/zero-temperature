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
    (needed for the remote PostgreSQL mirror; see PG_* config below)

Remote DB:
    In addition to the local SQLite file, each reading is mirrored to a
    PostgreSQL database on another RPi (see PG_* constants below). That
    database's `readings.sensor_id` column references a `sensors` table
    (id, name, description). This script registers itself there under its
    hostname (`uname -n`) lazily: it only checks/creates the `sensors` row
    the first time the plain insert into `readings` fails (e.g. because the
    hostname isn't registered yet), instead of querying on every run.
    The remote write is best-effort — if 192.168.0.67 is unreachable, a
    warning is printed to stderr but the script still exits 0 as long as
    the local SQLite write succeeded.
"""

import argparse
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
import board
import adafruit_dht
import psycopg2
dht_device = adafruit_dht.DHT22(board.D2)  # D2 = GPIO2

# ── Configuration ──────────────────────────────────────────────────────────
DEFAULT_PIN = 2             # BCM GPIO2 (physical pin 3)
DEFAULT_SAMPLES = 5         # Number of readings to average
DEFAULT_MAX_ATTEMPTS = 50   # Number of max iterations before reaching samples count
DEFAULT_DELAY = 2.5         # Seconds between readings (DHT22 needs >= 2s)
DEFAULT_DB_PATH = "/mnt/sqlite_ram/sensors.db"
DEFAULT_SENSOR_NAME = "dht22"

# ── Remote PostgreSQL configuration ────────────────────────────────────────
PG_HOST = "192.168.0.67"
PG_PORT = 5432              # standard PostgreSQL port
PG_USER = "sensor_writer"
PG_DBNAME = "sensors"
PG_PASS_ENV = "SENSOR_WRITER_PASS"  # env var holding the password


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


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS readings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recorded_at TEXT NOT NULL,
            sensor TEXT NOT NULL,
            temperature_c REAL NOT NULL,
            humidity_pct REAL NOT NULL,
            sample_count INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_readings_recorded_at ON readings(recorded_at)"
    )
    conn.commit()


def store_reading(
    db_path: str,
    timestamp: str,
    sensor_name: str,
    temperature_c: float,
    humidity_pct: float,
    sample_count: int,
) -> None:
    conn = sqlite3.connect(db_path)
    try:
        ensure_schema(conn)
        conn.execute(
            """
            INSERT INTO readings (recorded_at, sensor, temperature_c, humidity_pct, sample_count)
            VALUES (?, ?, ?, ?, ?)
            """,
            (timestamp, sensor_name, round(temperature_c, 2), round(humidity_pct, 2), sample_count),
        )
        conn.commit()
    finally:
        conn.close()

    print(f"Stored: {timestamp}  {temperature_c:.2f}°C  {humidity_pct:.2f}%  (n={sample_count}) → {db_path}")


def local_hostname() -> str:
    """Equivalent of `uname -n` — used as this RPi's name in the remote `sensors` table."""
    return os.uname().nodename


def register_sensor(conn, hostname: str) -> None:
    """Add `hostname` to the remote `sensors` table if it isn't there yet."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO sensors (name, description)
            VALUES (%s, %s)
            ON CONFLICT (name) DO NOTHING
            """,
            (hostname, f"Auto-registered by dht22_logger.py on {hostname}"),
        )
    conn.commit()


def store_reading_remote(
    hostname: str,
    timestamp: str,
    temperature_c: float,
    humidity_pct: float,
    sample_count: int,
) -> None:
    """Mirror a reading to the remote PostgreSQL DB. Best-effort: any failure
    (unreachable host, auth error, ...) is logged as a warning, not raised."""
    pg_pass = os.environ.get(PG_PASS_ENV)
    if not pg_pass:
        print(f"WARNING: {PG_PASS_ENV} is not set; skipping remote DB write.", file=sys.stderr)
        return

    insert_sql = """
        INSERT INTO readings (recorded_at, sensor_id, temperature_c, humidity_pct, sample_count)
        VALUES (%s, (SELECT id FROM sensors WHERE name = %s), %s, %s, %s)
    """
    params = (timestamp, hostname, round(temperature_c, 2), round(humidity_pct, 2), sample_count)

    try:
        conn = psycopg2.connect(
            host=PG_HOST, port=PG_PORT, user=PG_USER, password=pg_pass, dbname=PG_DBNAME,
        )
    except psycopg2.OperationalError as e:
        print(f"WARNING: could not connect to remote DB at {PG_HOST}:{PG_PORT}: {e}", file=sys.stderr)
        return

    try:
        try:
            with conn.cursor() as cur:
                cur.execute(insert_sql, params)
            conn.commit()
        except psycopg2.Error:
            # Insert failed — most likely because `hostname` isn't registered
            # in `sensors` yet, so the subquery returned NULL and violated
            # the NOT NULL constraint on sensor_id. Register it and retry once.
            conn.rollback()
            register_sensor(conn, hostname)
            with conn.cursor() as cur:
                cur.execute(insert_sql, params)
            conn.commit()
        print(f"Stored: {timestamp}  {temperature_c:.2f}°C  {humidity_pct:.2f}%  (n={sample_count}) → {PG_HOST}/{PG_DBNAME}")
    except psycopg2.Error as e:
        print(f"WARNING: remote DB write failed: {e}", file=sys.stderr)
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

    store_reading(str(db_path), timestamp, args.sensor_name, avg_temp, avg_hum, success_count)
    store_reading_remote(local_hostname(), timestamp, avg_temp, avg_hum, success_count)

    return 0


if __name__ == "__main__":
    sys.exit(main())
