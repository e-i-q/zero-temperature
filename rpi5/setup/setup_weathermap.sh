#!/usr/bin/env bash
# =============================================================================
# setup_weathermap.sh — Provisions the OpenWeatherMap API key
# api/weathermap.php uses for the Forecast tab's weather map (cloud/rain/wind
# tile layers + thunderstorm markers, centered on the Czech Republic).
#
# Writes /etc/dht22-weathermap/apikey (chmod 640, root:www-data) — same
# "secret lives outside the repo and outside the nginx web root" convention
# as setup_sync_trigger.sh's /etc/dht22-sync/token, since setup/deploy_web.sh
# only ever copies web/ into the web root, and the key must never end up
# committed to git (see ../../.gitignore).
#
# USAGE:
#   sudo OWM_API_KEY=<your OpenWeatherMap API key> bash setup/setup_weathermap.sh
#
# Get a free key at https://home.openweathermap.org/api_keys — the free
# tier is plenty here: a few tile fetches per page view, plus at most a
# handful of current-conditions lookups every 30 minutes (see
# api/weathermap.php's THUNDER_CACHE_TTL).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

CONF_DIR="/etc/dht22-weathermap"
KEY_FILE="${CONF_DIR}/apikey"
OWM_API_KEY="${OWM_API_KEY:-}"
WEB_GROUP="${WEB_GROUP:-www-data}"

check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_key_given() {
  [[ -n "$OWM_API_KEY" ]] \
    || error "OWM_API_KEY is required — get a free key at https://home.openweathermap.org/api_keys and pass it: sudo OWM_API_KEY=<key> bash $0"
}

write_key() {
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$OWM_API_KEY" > "$KEY_FILE"
  chown "root:${WEB_GROUP}" "$KEY_FILE"
  chmod 640 "$KEY_FILE"
  success "API key written: ${KEY_FILE} (root:${WEB_GROUP}, 640)"
}

print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  Weather map configured on the Hive!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  The Forecast tab's weather map (Clouds/Rain/Wind/Thunderstorms,"
  echo -e "  centered on the Czech Republic) will now load — refresh the page."
  echo
}

main() {
  check_root
  check_key_given
  write_key
  print_summary
}

main "$@"
