"""
report_version.py — Report the git commit this Pi Zero is currently
deployed at (short hash, subject line, author date) to the Hive database.

Usage:
    python3 report_version.py

Called once at the end of a successful `setup/git_deploy.sh` run — unlike
uptime_reporter.py this isn't a cron job, since there's nothing new to
report until the code actually changes. Also fine to run by hand (e.g.
after a manual `git pull`) to refresh the Hive's record without a full
redeploy.

Remote DB:
    Uses the same shared connection/config as dht22_logger.py — see
    remote_db.py for connection config and auth. Writes only
    `sensors.commit_hash` / `commit_summary` / `commit_date`, never
    `readings` — same reasoning as uptime_reporter.py: this is a live
    "what's currently deployed" fact, not history to keep.

Commit info source:
    `git log -1` against this checkout, not whatever SHA git_deploy.sh
    happened to observe mid-pull — so running this by hand always reflects
    whatever HEAD actually points at right now.
"""

import subprocess
import sys
from pathlib import Path

import psycopg2

import remote_db

REPO_DIR = Path(__file__).resolve().parent.parent

# \x1f (unit separator) as the field delimiter, not something printable
# like "|" — a commit subject can legitimately contain almost any
# character, but never a control character.
_FORMAT = "%h\x1f%s\x1f%cI"


def read_commit_info() -> tuple[str, str, str]:
    """Returns (short_hash, summary, iso_commit_date) for the commit
    currently checked out at REPO_DIR."""
    result = subprocess.run(
        ["git", "-C", str(REPO_DIR), "log", "-1", f"--format={_FORMAT}"],
        capture_output=True, text=True, check=True,
    )
    commit_hash, summary, commit_date = result.stdout.strip().split("\x1f")
    return commit_hash, summary, commit_date


def main() -> int:
    try:
        commit_hash, summary, commit_date = read_commit_info()
    except subprocess.CalledProcessError as e:
        print(f"WARNING: could not read commit info from {REPO_DIR}: {e}", file=sys.stderr)
        return 1

    hostname = remote_db.local_hostname()

    try:
        conn = remote_db.connect()
    except psycopg2.OperationalError as e:
        print(f"WARNING: could not connect to remote DB at {remote_db.PG_HOST}:{remote_db.PG_PORT}: {e}", file=sys.stderr)
        return 1

    try:
        remote_db.update_version(conn, hostname, commit_hash, summary, commit_date)
    except psycopg2.Error as e:
        conn.rollback()
        print(f"WARNING: remote DB write failed: {e}", file=sys.stderr)
        return 1
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
