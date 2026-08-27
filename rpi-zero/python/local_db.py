"""
local_db.py — Shared local SQLite schema/state helpers.

Used by both:
    dht22_logger.py   — creates/migrates the schema on every run
    sync_backlog.py   — needs the same schema when run standalone (e.g. by
                        hand, right after a trip) without depending on
                        dht22_logger.py's hardware imports (board, adafruit_dht)
"""

import sqlite3


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

    # NULL = not yet confirmed mirrored to the remote DB (see sync_backlog.py).
    # Existing databases predate this column, so add it on the fly instead of
    # requiring a manual migration.
    existing_cols = {row[1] for row in conn.execute("PRAGMA table_info(readings)")}
    if "synced_at" not in existing_cols:
        conn.execute("ALTER TABLE readings ADD COLUMN synced_at TEXT")

    # Single-row table remembering whether the *previous* dht22_logger.py run
    # reached the remote DB. Comparing that against the current run's result
    # is how an offline→online transition gets detected — see
    # dht22_logger.py's "Offline backlog sync" docstring section.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS sync_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            last_remote_ok INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    conn.execute("INSERT OR IGNORE INTO sync_state (id, last_remote_ok) VALUES (1, 0)")
    conn.commit()


def get_last_remote_ok(db_path: str) -> bool:
    conn = sqlite3.connect(db_path)
    try:
        ensure_schema(conn)
        row = conn.execute("SELECT last_remote_ok FROM sync_state WHERE id = 1").fetchone()
        return bool(row[0]) if row else False
    finally:
        conn.close()


def set_last_remote_ok(db_path: str, ok: bool) -> None:
    conn = sqlite3.connect(db_path)
    try:
        ensure_schema(conn)
        conn.execute("UPDATE sync_state SET last_remote_ok = ? WHERE id = 1", (1 if ok else 0,))
        conn.commit()
    finally:
        conn.close()


def mark_synced(db_path: str, row_id: int, when: str) -> None:
    conn = sqlite3.connect(db_path)
    try:
        conn.execute("UPDATE readings SET synced_at = ? WHERE id = ?", (when, row_id))
        conn.commit()
    finally:
        conn.close()
