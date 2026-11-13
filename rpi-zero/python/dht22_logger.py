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

DHT22 read failures:
    read_samples() below keeps retrying (up to --max_attempts times) until
    it has --samples good reads. Every row this script stores — locally
    and on the remote DB — carries all three counts (successes as
    `sample_count`, always; total tries and the run's ceiling as
    `attempt_count`/`max_attempts`) so "Samples" can be shown as
    success/failed/max instead of a bare count. See readings.md in the
    `db` project.

    If *none* of the attempts succeed (the sensor came loose, a wiring
    fault, ...), there's no average to store — no row is written at all,
    same as before this feature existed. What's new: this now still
    reaches out to the remote DB, best-effort, just to flag the fault via
    remote_db.update_dht22_fault() — sensors.dht22_fault_at, cleared again
    the next time a run gets at least one successful read. That's what
    drives the Hive dashboard's "FAULTY DHT22" badge, independent of the
    ONLINE/OFFLINE badge (which the Hive derives by pinging this Pi
    directly — see ../../rpi5/bin/ping_sensors.php — precisely so a Zero
    with a loose DHT22 shows ONLINE + FAULTY DHT22 instead of a misleading
    OFFLINE).

On-demand readings (--ondemand-dir):
    Besides the cron schedule, the Hive dashboard's "Read Now" button can ask
    for a reading right away. The request lands as <dir>/request.json
    (written by web/ondemand.php), which a systemd path unit
    (dht22-ondemand.path, installed by setup/setup_dht22_logger.sh) turns
    into a run of this script with --ondemand-dir. Such a run claims (deletes)
    the request and writes live progress — attempt counter, success/error
    counts, the latest and running-average values — to <dir>/status.json
    after every single DHT22 attempt, which web/ondemand.php hands back to
    the Hive for its progress window. Otherwise it's a perfectly ordinary
    run: the reading is stored locally and mirrored like any other.

    Only one process can talk to the DHT22 at a time, so every run (cron or
    on-demand) first takes an exclusive lock next to the database file —
    whichever comes second simply waits for the first to finish.

Offline SD-card flushing (--sd-backup):
    The local SQLite file lives on a RAM disk that's normally copied to the
    SD card only once a day. While the remote DB is unreachable, that RAM
    copy is the only copy of every reading since the connection dropped —
    and an offline Zero is the one most likely to get unplugged to debug it.
    So whenever a run can't mirror its reading, it also flushes the database
    to the SD card (sd_backup.flush_to_sd()) if the last such flush is older
    than `offline_flush_hours` (default 3; 0 = off). That value is a Hive
    setting (Settings tab → `hive_config` table), fetched on every
    successful connection and cached in the local sync_state table, so it's
    still known while offline. The first offline run always flushes unless
    one happened within that interval.
"""

import argparse
import fcntl
import json
import os
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
import sd_backup
import sync_backlog

# ── Configuration ──────────────────────────────────────────────────────────
DEFAULT_PIN = 2             # BCM GPIO2 (physical pin 3)
DEFAULT_SAMPLES = 5         # Number of readings to average
DEFAULT_MAX_ATTEMPTS = 50   # Number of max iterations before reaching samples count
DEFAULT_DELAY = 2.5         # Seconds between readings (DHT22 needs >= 2s)
DEFAULT_DB_PATH = "/mnt/sqlite_ram/sensors.db"
DEFAULT_SENSOR_NAME = "dht22"
LOCK_FILE_NAME = "dht22_logger.lock"  # lives next to the database file
LOCK_TIMEOUT_S = 300                   # a full 50-attempt run takes ~2 minutes; never wait forever
DEFAULT_OFFLINE_FLUSH_HOURS = 3.0      # used until the Hive's hive_config.offline_flush_hours is first fetched


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class Progress:
    """Live progress of an on-demand run, written to <dir>/status.json after
    every DHT22 attempt — see the "On-demand readings" docstring section."""

    def __init__(self, directory: str, request_id: str, samples: int, max_attempts: int):
        self.path = Path(directory) / "status.json"
        self.data = {
            "id": request_id,
            "state": "waiting",       # waiting (for the sensor lock) -> reading -> done | error
            "samples": samples,
            "max_attempts": max_attempts,
            "attempt": 0,
            "success": 0,
            "errors": 0,
            "current_temp": None,     # latest successful read
            "current_hum": None,
            "avg_temp": None,         # running average of successful reads so far
            "avg_hum": None,
            "message": None,
            "started_at": _now_iso(),
            "updated_at": None,
            "finished_at": None,
        }

    def update(self, **fields) -> None:
        self.data.update(fields)
        self.data["updated_at"] = _now_iso()
        if fields.get("state") in ("done", "error"):
            self.data["finished_at"] = self.data["updated_at"]
        # Atomic replace, so web/ondemand.php never reads a half-written file.
        tmp = self.path.with_name(self.path.name + ".tmp")
        try:
            tmp.write_text(json.dumps(self.data))
            os.replace(tmp, self.path)
        except OSError as e:
            print(f"WARNING: could not write progress file {self.path}: {e}", file=sys.stderr)


def claim_ondemand_request(directory: str) -> str:
    """Reads and deletes <dir>/request.json (written by web/ondemand.php),
    returning its request id — deleting it is also what stops the systemd
    path unit from immediately re-triggering. Returns "" if there's no
    request file (e.g. --ondemand-dir passed by hand)."""
    req = Path(directory) / "request.json"
    try:
        data = json.loads(req.read_text())
    except FileNotFoundError:
        return ""
    except (OSError, ValueError):
        data = {}
    try:
        req.unlink()
    except FileNotFoundError:
        pass
    return str(data.get("id") or "") if isinstance(data, dict) else ""


def acquire_sensor_lock(db_path: Path):
    """Exclusive lock so a cron run and an on-demand run never read the
    DHT22 at the same time. Returns the open lock file (keep it referenced
    for the life of the process — the lock is released when it closes, i.e.
    on exit) or None if it couldn't be had within LOCK_TIMEOUT_S."""
    lock_file = open(db_path.parent / LOCK_FILE_NAME, "a")
    deadline = time.monotonic() + LOCK_TIMEOUT_S
    while True:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock_file
        except BlockingIOError:
            if time.monotonic() >= deadline:
                lock_file.close()
                return None
            time.sleep(1)


def read_samples(dht_device, samples, delay, max_attempts, progress: Progress | None = None):
    """Returns (temps, hums, attempts) — attempts is how many reads were
    actually tried (successes + failures), <= max_attempts: it stops early
    as soon as `samples` good reads are in hand, so a healthy sensor's
    attempts == len(temps) most runs, while a flaky one climbs toward
    max_attempts as failures eat into the budget. If `progress` is given
    (on-demand runs), it's updated after every attempt."""
    temps, hums = [], []
    attempts = 0
    for i in range(1, max_attempts + 1):
        attempts = i
        try:
            temperature = dht_device.temperature
            humidity = dht_device.humidity
            if temperature is not None and humidity is not None:
                temps.append(temperature)
                hums.append(humidity)
        except RuntimeError as e:
            print(f"  Error reading {i}/{max_attempts}: {e}")
        if progress is not None:
            progress.update(
                attempt=i,
                success=len(temps),
                errors=i - len(temps),
                current_temp=round(temps[-1], 2) if temps else None,
                current_hum=round(hums[-1], 2) if hums else None,
                avg_temp=round(average(temps), 2) if temps else None,
                avg_hum=round(average(hums), 2) if hums else None,
            )
        if len(temps) >= samples:
            break
        time.sleep(delay)
    return temps, hums, attempts


def average(values: list[float]) -> float:
    return sum(values) / len(values)


def store_reading(
    db_path: str,
    timestamp: str,
    sensor_name: str,
    temperature_c: float,
    humidity_pct: float,
    sample_count: int,
    attempt_count: int,
    max_attempts: int,
) -> int:
    conn = sqlite3.connect(db_path)
    try:
        local_db.ensure_schema(conn)
        cur = conn.execute(
            """
            INSERT INTO readings (recorded_at, sensor, temperature_c, humidity_pct, sample_count, attempt_count, max_attempts)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (timestamp, sensor_name, round(temperature_c, 2), round(humidity_pct, 2), sample_count, attempt_count, max_attempts),
        )
        conn.commit()
        row_id = cur.lastrowid
    finally:
        conn.close()

    print(f"Stored: {timestamp}  {temperature_c:.2f}°C  {humidity_pct:.2f}%  (n={sample_count}) → {db_path}")
    return row_id


def cache_offline_flush_hours(conn, db_path: str) -> None:
    """Fetch hive_config.offline_flush_hours over an open remote connection
    and cache it locally (see the "Offline SD-card flushing" docstring
    section). An unset/invalid value caches NULL → the default applies."""
    raw = remote_db.fetch_config(conn, "offline_flush_hours")
    try:
        hours = float(raw) if raw is not None else None
    except ValueError:
        hours = None
    if hours is not None and hours < 0:
        hours = None
    try:
        local_db.set_offline_flush_hours(db_path, hours)
    except sqlite3.Error as e:
        print(f"WARNING: could not cache offline_flush_hours locally: {e}", file=sys.stderr)


def flush_if_offline_due(db_path: str, backup_file: str) -> None:
    """Called after a run failed to reach the remote DB: copy the RAM
    database to the SD card if the last offline flush is older than the
    configured interval. Best-effort — a failure is logged, never fatal."""
    cached_hours, last_flush = local_db.get_offline_flush_state(db_path)
    hours = DEFAULT_OFFLINE_FLUSH_HOURS if cached_hours is None else cached_hours
    if hours <= 0:
        return
    now = datetime.now(timezone.utc)
    if last_flush:
        try:
            age_h = (now - datetime.fromisoformat(last_flush)).total_seconds() / 3600
        except ValueError:
            age_h = float("inf")
        if age_h < hours:
            return
    try:
        size = sd_backup.flush_to_sd(db_path, backup_file)
    except (OSError, sqlite3.Error) as e:
        print(f"WARNING: offline flush to SD card failed: {e}", file=sys.stderr)
        return
    local_db.set_last_sd_flush(db_path, now.isoformat(timespec="seconds"))
    print(f"Offline: flushed database to SD card → {backup_file} ({size} bytes, every {hours:g}h while offline)")


def store_reading_remote(
    db_path: str,
    hostname: str,
    timestamp: str,
    temperature_c: float,
    humidity_pct: float,
    sample_count: int,
    attempt_count: int,
    max_attempts: int,
) -> bool:
    """Mirror a reading to the remote PostgreSQL DB. Best-effort: any failure
    (unreachable host, auth error, ...) is logged as a warning, not raised.
    Returns whether the row is confirmed on the remote DB — the caller uses
    this (via sync_state) to detect an offline→online transition and trigger
    sync_backlog.sync_backlog() for anything missed while disconnected."""
    insert_sql = """
        INSERT INTO readings (recorded_at, sensor_id, temperature_c, humidity_pct, sample_count, attempt_count, max_attempts)
        VALUES (%s, (SELECT id FROM sensors WHERE name = %s), %s, %s, %s, %s, %s)
    """
    params = (
        timestamp, hostname, round(temperature_c, 2), round(humidity_pct, 2),
        sample_count, attempt_count, max_attempts,
    )

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
        # A reading only ever gets here with sample_count >= 1 (see main()'s
        # "all reads failed" branch above) — this run got at least one good
        # DHT22 read, so any previously-flagged fault has resolved.
        remote_db.update_dht22_fault(conn, hostname, False)
        print(f"Stored: {timestamp}  {temperature_c:.2f}°C  {humidity_pct:.2f}%  (n={sample_count}) → {remote_db.PG_HOST}/{remote_db.PG_DBNAME}")
        cache_offline_flush_hours(conn, db_path)
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
    parser.add_argument("--sd-backup", type=str, default=sd_backup.DEFAULT_BACKUP_FILE, help=f"SD card backup file flushed to while offline (default {sd_backup.DEFAULT_BACKUP_FILE}; see docstring)")
    parser.add_argument("--ondemand-dir", type=str, default=None, help="On-demand run: claim <dir>/request.json and write live progress to <dir>/status.json (see docstring)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.delay < 2.0:
        print("WARNING: DHT22 needs at least ~2s between reads; values may be unreliable.", file=sys.stderr)

    db_path = Path(args.db)
    db_path.parent.mkdir(parents=True, exist_ok=True)

    progress = None
    if args.ondemand_dir:
        request_id = claim_ondemand_request(args.ondemand_dir)
        progress = Progress(args.ondemand_dir, request_id, args.samples, args.max_attempts)
        print(f"On-demand run (request {request_id or 'n/a'}) at {progress.data['started_at']}")
        progress.update(state="waiting")

    lock = acquire_sensor_lock(db_path)  # held until this process exits
    if lock is None:
        print(f"ERROR: another DHT22 read still holds the sensor lock after {LOCK_TIMEOUT_S}s — giving up.", file=sys.stderr)
        if progress is not None:
            progress.update(state="error", message="Sensor busy — another reading did not finish in time.")
        return 1

    try:
        pin = getattr(board, f"D{args.pin}")
    except AttributeError:
        print(f"ERROR: board has no pin D{args.pin} (--pin {args.pin} is not a valid GPIO number).", file=sys.stderr)
        if progress is not None:
            progress.update(state="error", message=f"Invalid GPIO pin {args.pin}.")
        return 1
    dht_device = adafruit_dht.DHT22(pin)

    print(f"Reading DHT22 on GPIO{args.pin} — {args.samples} samples, {args.max_attempts} max attempts, {args.delay}s apart…")
    if progress is not None:
        progress.update(state="reading")
    temps, hums, attempts = read_samples(dht_device, args.samples, args.delay, args.max_attempts, progress)
    success_count = len(temps)

    if not temps:
        print(f"ERROR: All {attempts} sensor read(s) failed. Check wiring and pull-up resistor.", file=sys.stderr)
        if progress is not None:
            progress.update(state="error", message=f"All {attempts} read attempts failed — check the DHT22 wiring.")
        # Nothing to average, so no reading row — but still flag the fault
        # on the remote DB, best-effort, so the Hive dashboard can show
        # FAULTY DHT22 instead of just letting readings go stale. Separate
        # try/except from store_reading_remote()'s (there's no reading to
        # mirror here) but the same "never fatal" contract.
        hostname = remote_db.local_hostname()
        try:
            conn = remote_db.connect()
        except psycopg2.OperationalError as e:
            print(f"WARNING: could not connect to remote DB at {remote_db.PG_HOST}:{remote_db.PG_PORT}: {e}", file=sys.stderr)
            return 1
        try:
            remote_db.register_sensor(conn, hostname, remote_db.local_ip())
            remote_db.update_dht22_fault(conn, hostname, True)
        except psycopg2.Error as e:
            conn.rollback()
            print(f"WARNING: remote DB write failed: {e}", file=sys.stderr)
        finally:
            conn.close()
        return 1

    avg_temp = average(temps)
    avg_hum = average(hums)
    failed_count = attempts - success_count

    print(f"\nAveraged over {success_count}/{args.samples} successful readings ({attempts} attempt(s), {failed_count} failed, max {args.max_attempts}):")
    print(f"  Temperature: {avg_temp:.2f}°C")
    print(f"  Humidity:    {avg_hum:.2f}%")

    timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")

    row_id = store_reading(str(db_path), timestamp, args.sensor_name, avg_temp, avg_hum, success_count, attempts, args.max_attempts)

    hostname = remote_db.local_hostname()
    was_offline = not local_db.get_last_remote_ok(str(db_path))
    remote_ok = store_reading_remote(str(db_path), hostname, timestamp, avg_temp, avg_hum, success_count, attempts, args.max_attempts)
    local_db.set_last_remote_ok(str(db_path), remote_ok)

    if progress is not None:
        # Reported done as soon as the reading is safely stored — a (rare)
        # backlog sync below shouldn't keep the Hive's progress window busy.
        progress.update(
            state="done",
            avg_temp=round(avg_temp, 2),
            avg_hum=round(avg_hum, 2),
            message=None if remote_ok else "Stored locally only — the Hive database was unreachable.",
        )

    if not remote_ok:
        flush_if_offline_due(str(db_path), args.sd_backup)

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
