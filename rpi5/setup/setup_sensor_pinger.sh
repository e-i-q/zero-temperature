#!/usr/bin/env bash
# =============================================================================
# setup_sensor_pinger.sh — Sensor Liveness Pinger Cron Setup — Raspberry Pi 5 (Hive)
#
# Installs a cron job that runs bin/ping_sensors.php every minute — a short
# TCP reachability check against every registered Pi Zero's port 80,
# stamping `sensors.last_ping_at` on success. This is what api/readings.php
# actually uses to decide each sensor's ONLINE/OFFLINE badge (see that
# file's PING_STALE_SECONDS), independent of whether its DHT22 is currently
# producing readings — see ../../db/database/sensors/tables/sensors.md.
#
# Assumes setup/setup_nginx_php.sh has already run (php-cli comes from its
# `php-fpm php-pgsql php-cli` install) and that the `db` project's
# setup_db.py has created the `sensor_pinger` role (see
# ../../db/database/sensors/meta.md).
#
# USAGE:
#   sudo bash setup/setup_sensor_pinger.sh
#
#   SENSOR_PINGER_PASSWORD=<pwd>   Set beforehand to skip the interactive
#                                  password prompt (e.g. unattended installs).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

# -- Config (override via env vars before running) ----------------------------
PINGER_SCRIPT="${PINGER_SCRIPT:-${SCRIPT_DIR}/../bin/ping_sensors.php}"
RUN_USER="${RUN_USER:-www-data}"   # must match ping_sensors.php's own PG_USER expectations via ~/.pgpass
LOG_FILE="${LOG_FILE:-/var/log/sensor_pinger.log}"

# Must match bin/ping_sensors.php's PG_HOST/PG_PORT/PG_DBNAME/PG_USER constants.
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_DBNAME="${PG_DBNAME:-sensors}"
PG_ROLE="${PG_ROLE:-sensor_pinger}"
# SENSOR_PINGER_PASSWORD: set this beforehand to skip the interactive prompt.

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "+------------------------------------------------------+"
  echo "|   Sensor Pinger — Cron Setup (Hive)                  |"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
  info "Pinger script  : ${PINGER_SCRIPT}"
  info "Run as user    : ${RUN_USER}"
  info "Interval       : every minute"
  echo
}

# -- Preflight -----------------------------------------------------------------
check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_pinger_script_exists() {
  [[ -f "$PINGER_SCRIPT" ]] \
    || error "Pinger script not found at ${PINGER_SCRIPT}. Set PINGER_SCRIPT=<path> and re-run."
}

check_php_cli() {
  command -v php &>/dev/null \
    || error "php-cli not found. Run setup/setup_nginx_php.sh first (installs php-fpm/php-pgsql/php-cli)."
}

check_user_exists() {
  id "$RUN_USER" &>/dev/null \
    || error "User '${RUN_USER}' does not exist. Set RUN_USER=<your-user> and re-run."
}

# -- www-data's PostgreSQL credentials -----------------------------------------
# Asked up front, before any file is touched, so the run isn't interrupted
# partway through waiting on input. Same shape as setup_nginx_php.sh's
# prompt_for_password(), for the sensor_pinger role instead of web_reader.
prompt_for_password() {
  if [[ -n "${SENSOR_PINGER_PASSWORD:-}" ]]; then
    info "Using SENSOR_PINGER_PASSWORD from the environment for '${PG_ROLE}'"
    return
  fi
  if [[ ! -t 0 ]]; then
    warn "Not running interactively and SENSOR_PINGER_PASSWORD is not set —"
    warn "~/.pgpass will not be configured automatically. Set SENSOR_PINGER_PASSWORD"
    warn "and re-run, or configure ~/.pgpass by hand afterwards (see README)."
    return
  fi

  info "The pinger connects to the Hive database (${PG_HOST}:${PG_PORT}/${PG_DBNAME})"
  info "as the '${PG_ROLE}' role — this is the same password used when that role"
  info "was created by the db project's setup_db.py (SENSOR_PINGER_PASSWORD there)."
  read -r -s -p "Enter the PostgreSQL password for '${PG_ROLE}' (leave blank to configure ~/.pgpass manually later): " SENSOR_PINGER_PASSWORD
  echo
  export SENSOR_PINGER_PASSWORD
}

# Writes/updates RUN_USER's ~/.pgpass with the line ping_sensors.php needs.
# ~/.pgpass supports multiple lines, matched by host:port:db:role, so this
# is safe to run on a Hive whose RUN_USER already has a web_reader entry
# from setup_nginx_php.sh — that line is left untouched, only the
# sensor_pinger one is added/replaced.
setup_pgpass() {
  local home_dir pgpass_file match_prefix line

  home_dir="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  if [[ -z "$home_dir" || "$home_dir" == "/nonexistent" ]]; then
    warn "Could not find a usable home directory for '${RUN_USER}' (getent says '${home_dir:-<empty>}')."
    warn "Set one (e.g. 'usermod -d /var/www ${RUN_USER}') or create ~/.pgpass by hand — see README."
    return
  fi
  pgpass_file="${home_dir}/.pgpass"

  if [[ -z "${SENSOR_PINGER_PASSWORD:-}" ]]; then
    warn "No password collected — skipping ~/.pgpass setup."
    warn "The pinger will fail to connect until ${pgpass_file} has a line:"
    warn "  ${PG_HOST}:${PG_PORT}:${PG_DBNAME}:${PG_ROLE}:<password>   (chmod 600, owned by ${RUN_USER})"
    return
  fi

  mkdir -p "$home_dir"
  touch "$pgpass_file"

  match_prefix="${PG_HOST}:${PG_PORT}:${PG_DBNAME}:${PG_ROLE}:"
  line="${match_prefix}${SENSOR_PINGER_PASSWORD}"
  if grep -qF "$match_prefix" "$pgpass_file" 2>/dev/null; then
    info "Replacing existing ~/.pgpass entry for ${PG_HOST}:${PG_PORT}/${PG_DBNAME} (${PG_ROLE})"
    grep -vF "$match_prefix" "$pgpass_file" > "${pgpass_file}.tmp"
    mv "${pgpass_file}.tmp" "$pgpass_file"
  fi
  echo "$line" >> "$pgpass_file"

  chown "${RUN_USER}:${RUN_USER}" "$pgpass_file"
  chmod 600 "$pgpass_file"
  success "~/.pgpass written: ${pgpass_file} (role ${PG_ROLE}, owned by ${RUN_USER}, mode 600)"
}

# -- Cron job --------------------------------------------------------------------
setup_cron() {
  info "Installing cron job to run the pinger every minute…"

  touch "$LOG_FILE"
  chown "${RUN_USER}:${RUN_USER}" "$LOG_FILE"

  CRON_LINE="* * * * * ${RUN_USER} php ${PINGER_SCRIPT} >> ${LOG_FILE} 2>&1"
  echo "$CRON_LINE" > /etc/cron.d/sensor_pinger
  chmod 644 /etc/cron.d/sensor_pinger

  success "Cron job installed: /etc/cron.d/sensor_pinger"
}

# -- Summary -------------------------------------------------------------------
print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  Sensor pinger cron job installed!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}Cron entry:${NC}   /etc/cron.d/sensor_pinger"
  echo -e "  ${CYAN}Log file:${NC}     ${LOG_FILE}"
  echo -e "  ${CYAN}Runs as:${NC}      ${RUN_USER}"
  echo
  echo -e "  ${CYAN}Manual test run:${NC}"
  echo -e "    sudo -u ${RUN_USER} php ${PINGER_SCRIPT}"
  echo
  echo -e "  ${YELLOW}NOTE:${NC} the Hive database needs 'last_ping_at' and 'dht22_fault_at' columns"
  echo -e "  on 'sensors', plus the 'sensor_pinger' role, before this can write anything —"
  echo -e "  see ../../db/database/sensors/{tables/sensors.md,meta.md} and re-run that"
  echo -e "  project's setup_db.py if you haven't already."
  echo
}

# =============================================================================
main() {
  banner
  check_root
  check_pinger_script_exists
  check_php_cli
  check_user_exists
  prompt_for_password
  setup_pgpass
  setup_cron

  print_summary
}

main "$@"
