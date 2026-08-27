#!/usr/bin/env bash
# =============================================================================
# setup_sync_trigger.sh — Provisions the shared secret api/sync_trigger.php
# sends to a Pi Zero's web/sync.php when the Settings tab's "Sync Now"
# button is used.
#
# Writes /etc/dht22-sync/token (chmod 640, root:www-data) — the SAME value
# must also be written to /etc/dht22-sync/token on EVERY Pi Zero via
# rpi-zero/setup/setup_sync_trigger.sh. There's one shared token for the
# whole fleet, not one per sensor.
#
# USAGE:
#   sudo SYNC_TOKEN=<value from a Pi Zero's setup> bash setup/setup_sync_trigger.sh
#
# Run a Pi Zero's own setup_sync_trigger.sh FIRST (it prints a freshly
# generated token if you don't already have one), then pass that same value
# here — this script never generates its own, since the token must match
# what's on the other end.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

CONF_DIR="/etc/dht22-sync"
TOKEN_FILE="${CONF_DIR}/token"
SYNC_TOKEN="${SYNC_TOKEN:-}"
WEB_GROUP="${WEB_GROUP:-www-data}"

check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_token_given() {
  [[ -n "$SYNC_TOKEN" ]] \
    || error "SYNC_TOKEN is required — copy the value printed by a Pi Zero's setup_sync_trigger.sh and pass it: sudo SYNC_TOKEN=<value> bash $0"
}

write_token() {
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$SYNC_TOKEN" > "$TOKEN_FILE"
  chown "root:${WEB_GROUP}" "$TOKEN_FILE"
  chmod 640 "$TOKEN_FILE"
  success "Token written: ${TOKEN_FILE} (root:${WEB_GROUP}, 640)"
}

print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  Sync trigger configured on the Hive!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  The Settings tab's Sync Now button will now work for any sensor"
  echo -e "  whose Pi Zero has this same token set up."
  echo
  echo -e "  ${CYAN}Add another Pi Zero to the fleet:${NC}"
  echo -e "    sudo SYNC_TOKEN=${SYNC_TOKEN} bash setup/setup_sync_trigger.sh   # on that Pi Zero"
  echo
}

main() {
  check_root
  check_token_given
  write_token
  print_summary
}

main "$@"
