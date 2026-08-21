#!/usr/bin/env bash
# =============================================================================
# deploy_web.sh — Sync web/ (index.html, api/, css/, js/) into the nginx
# web root.
#
# db.php connects to the Hive database as 127.0.0.1:5432/sensors — see
# web/api/db.php if that ever needs to change (e.g. the dashboard is moved
# off the same host as PostgreSQL).
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

# -a preserves the api/css/js subdirectories; trailing slashes copy contents
# of SRC_DIR into WEB_ROOT rather than nesting a "web" folder.
sudo cp -a "${SRC_DIR}/." "${WEB_ROOT}/"

sudo chown -R "${RUN_USER}:${RUN_USER}" "$WEB_ROOT"

echo "Deployed ${SRC_DIR} -> ${WEB_ROOT} (owned by ${RUN_USER})"
