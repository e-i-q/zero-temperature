#!/usr/bin/env bash
# =============================================================================
# setup_sync_trigger.sh — Provisions web/sync.php's shared secret and paths,
# so the Hive dashboard's Settings tab can trigger a manual backlog sync on
# this Pi Zero over HTTP.
#
# Writes, outside the web root (so deploy_web.sh can never touch or expose
# them):
#   /etc/dht22-sync/token      the shared secret (chmod 640, root:www-data)
#   /etc/dht22-sync/config.php PYTHON_BIN / SYNC_SCRIPT_PATH / DB_PATH
#
# The SAME secret value must also end up in /etc/dht22-sync/token on the
# Hive (Pi 5) — see rpi5/setup/setup_sync_trigger.sh. This script prints the
# token at the end specifically so you can copy it over.
#
# USAGE:
#   sudo bash setup/setup_sync_trigger.sh
#   sudo SYNC_TOKEN=<value> bash setup/setup_sync_trigger.sh   # reuse a token
#                                                               # already set
#                                                               # up on other
#                                                               # Pi Zeros
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

# -- Config (override via env vars before running) -----------------------------
SYNC_SCRIPT_PATH="${SYNC_SCRIPT_PATH:-$(cd "${SCRIPT_DIR}/../python" && pwd)/sync_backlog.py}"
DB_PATH="${DB_PATH:-/mnt/sqlite_ram/sensors.db}"
CONF_DIR="/etc/dht22-sync"
TOKEN_FILE="${CONF_DIR}/token"
CONFIG_FILE="${CONF_DIR}/config.php"
SYNC_TOKEN="${SYNC_TOKEN:-}"          # generated below if not given
WEB_GROUP="${WEB_GROUP:-www-data}"    # group allowed to read the token file

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "+------------------------------------------------------+"
  echo "|   Sync Trigger Setup — RPi Zero                      |"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
  info "Sync script    : ${SYNC_SCRIPT_PATH}"
  info "Database path  : ${DB_PATH}"
  info "Config dir     : ${CONF_DIR}"
  echo
}

check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_sync_script_exists() {
  [[ -f "$SYNC_SCRIPT_PATH" ]] \
    || error "sync_backlog.py not found at ${SYNC_SCRIPT_PATH}. Set SYNC_SCRIPT_PATH=<path> and re-run."
}

detect_python() {
  PYTHON_BIN="$(command -v python3)" \
    || error "python3 not found on PATH."
  info "Python interpreter: ${PYTHON_BIN}"
}

write_token() {
  mkdir -p "$CONF_DIR"
  if [[ -z "$SYNC_TOKEN" ]]; then
    SYNC_TOKEN="$(openssl rand -hex 32)"
    info "Generated a new random sync token."
  else
    info "Using provided SYNC_TOKEN."
  fi
  printf '%s\n' "$SYNC_TOKEN" > "$TOKEN_FILE"
  chown "root:${WEB_GROUP}" "$TOKEN_FILE"
  chmod 640 "$TOKEN_FILE"
  success "Token written: ${TOKEN_FILE} (root:${WEB_GROUP}, 640)"
}

write_config() {
  cat > "$CONFIG_FILE" << EOF
<?php
// Written by setup_sync_trigger.sh — re-run it (or edit here) if any of
// these paths change. No secret in this file; see ${TOKEN_FILE}.
const PYTHON_BIN = '${PYTHON_BIN}';
const SYNC_SCRIPT_PATH = '${SYNC_SCRIPT_PATH}';
const DB_PATH = '${DB_PATH}';
EOF
  chown "root:${WEB_GROUP}" "$CONFIG_FILE"
  chmod 640 "$CONFIG_FILE"
  success "Config written: ${CONFIG_FILE}"
}

print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  Sync trigger configured!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}web/sync.php${NC} is deployed automatically the next time you run"
  echo -e "  ${CYAN}deploy_web.sh${NC} (it's just another file under web/)."
  echo
  echo -e "  ${YELLOW}Copy this SAME token into the Hive's own config${NC}"
  echo -e "  (rpi5/setup/setup_sync_trigger.sh SYNC_TOKEN=... — the Hive and"
  echo -e "  every Pi Zero must share one token):"
  echo
  echo -e "      ${SYNC_TOKEN}"
  echo
  echo -e "  ${CYAN}Test locally:${NC}"
  echo -e "    curl -X POST -H \"X-Sync-Token: ${SYNC_TOKEN}\" http://127.0.0.1/sync.php"
  echo
}

# =============================================================================
main() {
  banner
  check_root
  check_sync_script_exists
  detect_python

  write_token
  write_config

  print_summary
}

main "$@"
