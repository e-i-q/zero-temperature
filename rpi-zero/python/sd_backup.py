"""
sd_backup.py — Copy the live RAM-disk SQLite database to the SD card.

The RAM disk (see setup/setup_sqlite_ramdisk.sh) is normally flushed to the
SD card only once a day by root's cron (/usr/local/bin/sqlite_flush_to_sd)
and on a graceful shutdown. That's fine while this Pi Zero is online — every
reading is mirrored to the Hive the moment it's taken — but an offline Zero
holds its only copy of everything since it lost the connection in RAM, and
an offline Zero is exactly the one that tends to get unplugged or rebooted
to debug it. So while offline, dht22_logger.py calls flush_to_sd() every
`offline_flush_hours` (a Hive setting — see local_db.py and the `db`
project's hive_config.md), default 3.

Same result as the shell flush script, so its restore-on-boot counterpart
reads it unchanged: a gzip of an SQLite online backup at BACKUP_FILE, the
previous one rotated to BACKUP_FILE.prev. Done in Python rather than by
calling that script because it runs as the logger's own (non-root) user:
the backup directory is owned by that user (setup_backup_dir()), so every
write here goes through a temp file + os.replace() in that directory —
which works even when the file being replaced was created by root's cron.
"""

import gzip
import os
import shutil
import sqlite3
from pathlib import Path

DEFAULT_BACKUP_FILE = "/var/lib/sqlite_backup/sensors.db.gz"


def flush_to_sd(db_path: str, backup_file: str = DEFAULT_BACKUP_FILE) -> int:
    """Back up db_path to backup_file (gzipped), rotating the previous
    backup to <backup_file>.prev. Returns the new backup's size in bytes.
    Raises OSError/sqlite3.Error on failure, leaving any existing backup
    untouched."""
    backup = Path(backup_file)
    backup_dir = backup.parent
    tmp_db = backup_dir / f".tmp_offline_{Path(db_path).name}"
    tmp_gz = backup_dir / f".tmp_offline_{backup.name}"
    tmp_prev = backup_dir / f".tmp_offline_{backup.name}.prev"

    try:
        # SQLite's online backup API — consistent even if the DB is in use.
        src = sqlite3.connect(db_path)
        try:
            dst = sqlite3.connect(tmp_db)
            try:
                src.backup(dst)
            finally:
                dst.close()
        finally:
            src.close()

        with open(tmp_db, "rb") as f_in, open(tmp_gz, "wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb") as f_out:
                shutil.copyfileobj(f_in, f_out)
            # Make sure the bytes are really on the SD card before the
            # rename — the whole point is surviving a power cut.
            raw.flush()
            os.fsync(raw.fileno())

        if backup.exists():
            shutil.copyfile(backup, tmp_prev)
            os.replace(tmp_prev, backup.with_name(backup.name + ".prev"))
        os.replace(tmp_gz, backup)
        return backup.stat().st_size
    finally:
        for leftover in (tmp_db, tmp_gz, tmp_prev):
            try:
                leftover.unlink()
            except FileNotFoundError:
                pass
