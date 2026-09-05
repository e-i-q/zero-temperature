"""
uptime_reporter.py — Report this Pi Zero's own system uptime to the Hive
database.

Usage:
    python3 uptime_reporter.py

Requires:
    pip3 install psycopg2-binary --break-system-packages
    (needed for the remote PostgreSQL write; see remote_db.py)

Remote DB:
    Uses the same shared connection/config as dht22_logger.py — see
    remote_db.py for connection config and auth. Like ups_ina219.py this
    writes only `sensors.uptime_seconds`, never `readings` — there's no
    history to keep here, just a live "how long has this Pi been up"
    figure — so there's no local SQLite mirror and no offline backlog to
    replay. The write is best-effort: if the remote host is unreachable, a
    warning goes to stderr and the script exits non-zero, but there's
    nothing else to do locally — the next cron run (5 minutes later, see
    setup/setup_uptime_reporter.sh) just tries again.

Uptime source:
    Linux's own `/proc/uptime` — the first field is seconds since boot
    (a float; this rounds down to whole seconds since the Hive dashboard
    only ever shows uptime at day/hour/minute granularity, see
    ../../rpi5/web/js/script.js's formatUptime()). No `psutil` dependency
    needed for a single-field read.
"""

import sys

import psycopg2

import remote_db


def read_uptime_seconds() -> int:
    with open("/proc/uptime") as f:
        return int(float(f.read().split()[0]))


def main() -> int:
    uptime_seconds = read_uptime_seconds()
    hostname = remote_db.local_hostname()

    try:
        conn = remote_db.connect()
    except psycopg2.OperationalError as e:
        print(f"WARNING: could not connect to remote DB at {remote_db.PG_HOST}:{remote_db.PG_PORT}: {e}", file=sys.stderr)
        return 1

    try:
        remote_db.update_uptime(conn, hostname, uptime_seconds)
    except psycopg2.Error as e:
        conn.rollback()
        print(f"WARNING: remote DB write failed: {e}", file=sys.stderr)
        return 1
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
