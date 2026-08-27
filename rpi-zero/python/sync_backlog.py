#!/usr/bin/env python3
"""
sync_backlog.py — Push local SQLite readings that never made it to the
central Hive database while this Pi Zero was offline (e.g. taken out on
battery power, away from any network it recognizes).

Normally you don't run this by hand: dht22_logger.py calls sync_backlog()
itself, exactly once, the moment it notices its live per-reading mirror has
gone from failing to succeeding (tracked in the local `sync_state` table) —
i.e. right after connectivity comes back. That keeps this off the hot path
entirely: it costs nothing while offline, and it doesn't run again until the
next offline→online transition. No cron job, no timer, no network-state
polling of its own.

Manual use (e.g. to push a backlog right now instead of waiting for the next
scheduled reading):
    python3 sync_backlog.py --db /mnt/sqlite_ram/sensors.db

Rows are matched to the remote sensors.id by this Pi's hostname (uname -n),
same as the live mirror in dht22_logger.py. Each push is deduped against the
remote `readings` table on (recorded_at, sensor_id) — safe to re-run, and
safe even for rows that, unknown to the local DB, actually already made it
to the remote DB before `synced_at` tracking existed.
"""

import argparse
import sqlite3
import sys
from datetime import datetime, timezone

import psycopg2

import local_db
import remote_db

# NOT EXISTS guards against double-inserting a row that's already remote —
# relevant for local rows recorded before `synced_at` tracking was added,
# where "not yet confirmed synced" doesn't necessarily mean "never sent".
INSERT_SQL = """
    INSERT INTO readings (recorded_at, sensor_id, temperature_c, humidity_pct, sample_count)
    SELECT %s, s.id, %s, %s, %s
    FROM sensors s
    WHERE s.name = %s
      AND NOT EXISTS (
          SELECT 1 FROM readings r2 WHERE r2.recorded_at = %s AND r2.sensor_id = s.id
      )
"""


def pending_rows(db_path: str):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        local_db.ensure_schema(conn)  # safe to call even when run standalone, before the logger ever has
        return conn.execute(
            "SELECT id, recorded_at, temperature_c, humidity_pct, sample_count "
            "FROM readings WHERE synced_at IS NULL ORDER BY recorded_at ASC"
        ).fetchall()
    finally:
        conn.close()


def sync_backlog(db_path: str, hostname: str) -> tuple[int, int]:
    """Push every local row not yet confirmed on the remote DB, oldest
    first. Returns (confirmed, total_pending) — confirmed counts rows
    pushed or already present remotely. Best-effort: stops at the first
    remote failure and leaves the rest marked pending for the next
    attempt, so confirmed < total_pending signals an incomplete sync (used
    by main()'s exit code, which web/sync.php's manual trigger relies on)."""
    rows = pending_rows(db_path)
    total = len(rows)
    if not rows:
        return 0, 0

    try:
        pg_conn = remote_db.connect()
    except psycopg2.OperationalError as e:
        print(f"WARNING: backlog sync skipped, remote unreachable: {e}", file=sys.stderr)
        return 0, total

    confirmed = 0
    try:
        remote_db.register_sensor(pg_conn, hostname, remote_db.local_ip())
        for row in rows:
            params = (
                row["recorded_at"], row["temperature_c"], row["humidity_pct"],
                row["sample_count"], hostname, row["recorded_at"],
            )
            try:
                with pg_conn.cursor() as cur:
                    cur.execute(INSERT_SQL, params)
                pg_conn.commit()
            except psycopg2.Error as e:
                pg_conn.rollback()
                print(f"WARNING: backlog sync stopped at {row['recorded_at']}: {e}", file=sys.stderr)
                break
            local_db.mark_synced(db_path, row["id"], datetime.now(timezone.utc).isoformat(timespec="seconds"))
            confirmed += 1
    finally:
        pg_conn.close()

    print(
        f"Backlog sync: confirmed {confirmed}/{total} pending row(s) "
        f"on {remote_db.PG_HOST}/{remote_db.PG_DBNAME}"
    )
    return confirmed, total


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Push local readings not yet confirmed on the remote DB.")
    parser.add_argument("--db", type=str, default="/mnt/sqlite_ram/sensors.db", help="Path to the local SQLite database")
    parser.add_argument("--hostname", type=str, default=None, help="Override the hostname used to look up sensors.id (default: uname -n)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    hostname = args.hostname or remote_db.local_hostname()
    confirmed, total = sync_backlog(args.db, hostname)
    # Nonzero on an incomplete sync (unreachable remote, or it stopped
    # partway through) — web/sync.php's manual trigger reports "ok" based on
    # this exit code, so a partial sync needs to surface as a failure there.
    return 0 if confirmed == total else 1


if __name__ == "__main__":
    sys.exit(main())
