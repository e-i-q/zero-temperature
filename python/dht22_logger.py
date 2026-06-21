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
    pip3 install Adafruit_DHT --break-system-packages
    (Note: Adafruit_DHT is deprecated upstream. If installation fails on a
    newer Raspberry Pi OS, switch to 'adafruit-circuitpython-dht' instead —
    see the comment block at the bottom of this file for the equivalent code.)
"""

import argparse
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
import board
import adafruit_dht
dht_device = adafruit_dht.DHT22(board.D2)  # D2 = GPIO2

try:
    import Adafruit_DHT
except ImportError:
    print(
        "ERROR: Adafruit_DHT is not installed.\n"
        "Install it with:\n"
        "    pip3 install Adafruit_DHT --break-system-packages\n",
        file=sys.stderr,
    )
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────
SENSOR = Adafruit_DHT.DHT22
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
    sensor_name: str,
    temperature_c: float,
    humidity_pct: float,
    sample_count: int,
) -> None:
    timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")

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

    store_reading(str(db_path), args.sensor_name, avg_temp, avg_hum, success_count)

    return 0


if __name__ == "__main__":
    sys.exit(main())
