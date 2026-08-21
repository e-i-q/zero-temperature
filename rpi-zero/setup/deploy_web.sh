#!/usr/bin/env bash
# =============================================================================
# deploy_web.sh — Sync web/ (index.html, readings.php, css/, js/) into the
# nginx web root.
#
# Update DB_PATH in web/readings.php if your SQLite RAM disk lives somewhere
# other than /mnt/sqlite_ram/sensors.db.
#
# USAGE:
#   bash setup/deploy_web.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "${SCRIPT_DIR}/../web" && pwd)"

WEB_ROOT="${WEB_ROOT:-/var/www/html}"
RUN_USER="${RUN_USER:-www-data}"

sudo mkdir -p "$WEB_ROOT"

# -a preserves the css/ and js/ subdirectories; trailing slashes copy
# contents of SRC_DIR into WEB_ROOT rather than nesting a "web" folder.
sudo cp -a "${SRC_DIR}/." "${WEB_ROOT}/"

sudo chown -R "${RUN_USER}:${RUN_USER}" "$WEB_ROOT"

echo "Deployed ${SRC_DIR} -> ${WEB_ROOT} (owned by ${RUN_USER})"
