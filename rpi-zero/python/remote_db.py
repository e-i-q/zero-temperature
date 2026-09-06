"""
remote_db.py — Shared PostgreSQL connection/config for mirroring local
readings to the central Hive database on the Pi 5.

Used by both:
    dht22_logger.py   — live, best-effort mirror of each new reading
    sync_backlog.py   — catch-up sync for readings that missed the live
                        mirror while this Pi was offline

Auth: no password is passed in code or read from the environment —
psycopg2 (via libpq) picks it up from RUN_USER's ~/.pgpass. That file must
exist and be chmod 600, with a line of the form:
    192.168.0.67:5432:sensors:sensor_writer:<password>
If it's missing or unreadable, connect() just fails like any other
unreachable-remote-DB error.
"""

import os
import socket

import psycopg2

PG_HOST = "192.168.0.67"
PG_PORT = 5432
PG_USER = "sensor_writer"
PG_DBNAME = "sensors"


def connect():
    """Connect to the remote Hive database. Raises psycopg2.OperationalError
    on failure (unreachable host, auth error, ...) — callers treat that as
    "offline", not fatal."""
    return psycopg2.connect(host=PG_HOST, port=PG_PORT, user=PG_USER, dbname=PG_DBNAME)


def register_sensor(conn, hostname: str, ip_address: str | None = None) -> None:
    """Ensure `hostname` exists in the remote `sensors` table, and (re)set
    its `ip_address`. Called on every successful connection, not just once —
    unlike the row's mere existence, its IP can go stale (DHCP), and it's
    what the Hive dashboard's Settings tab uses to reach this Pi for a
    manual sync trigger (see rpi5/web/api/sync_trigger.php)."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO sensors (name, description, ip_address)
            VALUES (%s, %s, %s)
            ON CONFLICT (name) DO UPDATE SET ip_address = EXCLUDED.ip_address
            """,
            (hostname, f"Auto-registered by dht22_logger.py on {hostname}", ip_address),
        )
    conn.commit()


def update_status(conn, hostname: str, status: str, voltage_v: float, current_ma: float, power_w: float) -> None:
    """Set this Pi's `status` in the remote `sensors` table — the live
    OK/CHARGING <pct>%/BATTERY <pct>% label ups_ina219.py computes from the
    UPS HAT, shown per sensor tile on the Hive dashboard's Overview tab.
    Also sets `battery_voltage_v`/`battery_current_ma`/`battery_power_w` —
    the raw INA219 readings `status` was derived from — shown per sensor on
    the Hive dashboard's Settings tab, Sensors section (unlike `status`,
    these three aren't shown on the Overview tab's tiles).
    Same upsert shape as register_sensor() above: if this Pi doesn't have a
    `sensors` row yet (dht22_logger.py hasn't run here, or this is its very
    first write), the INSERT branch creates a placeholder one rather than
    silently doing nothing."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO sensors (name, description, status, battery_voltage_v, battery_current_ma, battery_power_w)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (name) DO UPDATE SET
                status = EXCLUDED.status,
                battery_voltage_v = EXCLUDED.battery_voltage_v,
                battery_current_ma = EXCLUDED.battery_current_ma,
                battery_power_w = EXCLUDED.battery_power_w
            """,
            (hostname, f"Auto-registered by ups_ina219.py on {hostname}", status, voltage_v, current_ma, power_w),
        )
    conn.commit()


def update_uptime(conn, hostname: str, uptime_seconds: int) -> None:
    """Set this Pi's `uptime_seconds` in the remote `sensors` table — how
    long it's been since this Pi last booted, shown per sensor on the Hive
    dashboard's Settings tab (Sensors section). Same upsert shape as
    update_status() above: if this Pi doesn't have a `sensors` row yet, the
    INSERT branch creates a placeholder one rather than silently doing
    nothing."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO sensors (name, description, uptime_seconds)
            VALUES (%s, %s, %s)
            ON CONFLICT (name) DO UPDATE SET uptime_seconds = EXCLUDED.uptime_seconds
            """,
            (hostname, f"Auto-registered by uptime_reporter.py on {hostname}", uptime_seconds),
        )
    conn.commit()


def update_version(conn, hostname: str, commit_hash: str, commit_summary: str, commit_date: str) -> None:
    """Set this Pi's `commit_hash`/`commit_summary`/`commit_date` in the
    remote `sensors` table — which git commit this Pi is currently deployed
    at, shown per sensor on the Hive dashboard's Settings tab (Sensors
    section). Same upsert shape as update_uptime() above: if this Pi
    doesn't have a `sensors` row yet, the INSERT branch creates a
    placeholder one rather than silently doing nothing."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO sensors (name, description, commit_hash, commit_summary, commit_date)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (name) DO UPDATE SET
                commit_hash = EXCLUDED.commit_hash,
                commit_summary = EXCLUDED.commit_summary,
                commit_date = EXCLUDED.commit_date
            """,
            (hostname, f"Auto-registered by report_version.py on {hostname}",
             commit_hash, commit_summary, commit_date),
        )
    conn.commit()


def update_dht22_fault(conn, hostname: str, faulty: bool) -> None:
    """Set/clear this Pi's `dht22_fault_at` in the remote `sensors` table —
    called by dht22_logger.py on every run, not just failing ones. Drives
    the "FAULTY DHT22" badge on the Hive dashboard's Overview tab
    (rpi5/web/js/script.js), shown independently of (and possibly
    alongside) the ONLINE/OFFLINE and power-status badges.

    faulty=True (a run got zero successful DHT22 reads — see
    dht22_logger.py's read_samples()) COALESCEs against the column's
    current value, so it only stamps `now()` the first time; a fault that
    was already flagged keeps its original "since" timestamp rather than
    creeping forward on every subsequent failing run. faulty=False (a run
    got at least one successful read) clears it back to NULL.

    Same upsert shape as update_status() above: if this Pi doesn't have a
    `sensors` row yet, the INSERT branch creates a placeholder one rather
    than silently doing nothing."""
    description = f"Auto-registered by dht22_logger.py on {hostname}"
    with conn.cursor() as cur:
        if faulty:
            cur.execute(
                """
                INSERT INTO sensors (name, description, dht22_fault_at)
                VALUES (%s, %s, now())
                ON CONFLICT (name) DO UPDATE SET
                    dht22_fault_at = COALESCE(sensors.dht22_fault_at, EXCLUDED.dht22_fault_at)
                """,
                (hostname, description),
            )
        else:
            cur.execute(
                """
                INSERT INTO sensors (name, description, dht22_fault_at)
                VALUES (%s, %s, NULL)
                ON CONFLICT (name) DO UPDATE SET dht22_fault_at = NULL
                """,
                (hostname, description),
            )
    conn.commit()


def local_hostname() -> str:
    """Equivalent of `uname -n` — used as this RPi's name in the remote `sensors` table."""
    return os.uname().nodename


def local_ip() -> str | None:
    """Best-effort LAN IP of this Pi — the address the outbound interface
    would use to reach PG_HOST, which is a reasonable proxy for "the address
    another device on this LAN can reach this Pi at". Returns None if it
    can't be determined (e.g. no network at all); callers just skip storing
    an address in that case rather than failing the whole write."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect((PG_HOST, PG_PORT))  # UDP "connect": picks a route, sends nothing
            return s.getsockname()[0]
    except OSError:
        return None
