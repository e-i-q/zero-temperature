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


def update_status(conn, hostname: str, status: str) -> None:
    """Set this Pi's `status` in the remote `sensors` table — the live
    OK/CHARGING <pct>%/BATTERY <pct>% label ups_ina219.py computes from the
    UPS HAT, shown per sensor tile on the Hive dashboard's Overview tab.
    Same upsert shape as register_sensor() above: if this Pi doesn't have a
    `sensors` row yet (dht22_logger.py hasn't run here, or this is its very
    first write), the INSERT branch creates a placeholder one rather than
    silently doing nothing."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO sensors (name, description, status)
            VALUES (%s, %s, %s)
            ON CONFLICT (name) DO UPDATE SET status = EXCLUDED.status
            """,
            (hostname, f"Auto-registered by ups_ina219.py on {hostname}", status),
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
