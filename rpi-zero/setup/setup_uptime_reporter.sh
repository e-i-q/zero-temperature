#!/usr/bin/env bash
# =============================================================================
# setup_uptime_reporter.sh — Uptime Reporter Cron Setup — Raspberry Pi Zero
#
# Installs the Python dependencies uptime_reporter.py needs, then installs a
# cron job that runs it on a fixed interval so `sensors.uptime_seconds`
# (shown per sensor on the Hive dashboard's Settings tab, Sensors section)
# stays current without anyone starting it by hand.
#
# USAGE:
#   sudo bash setup/setup_uptime_reporter.sh [-v|--verbose]
#
#   -v, --verbose   Show full output from package installs (apt-get, pip)
#                   instead of just a one-line progress message.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

# -- Config (override via env vars before running) ----------------------------
REPORTER_SCRIPT="${REPORTER_SCRIPT:-${SCRIPT_DIR}/../python/uptime_reporter.py}"

RUN_USER="${RUN_USER:-${SUDO_USER:-$(whoami)}}"           # Must have DB access
CRON_INTERVAL_MIN="${CRON_INTERVAL_MIN:-5}"
LOG_FILE="${LOG_FILE:-/var/log/uptime_reporter.log}"

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "+------------------------------------------------------+"
  echo "|   Uptime Reporter — Cron Setup (RPi Zero)            |"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
  info "Reporter script  : ${REPORTER_SCRIPT}"
  info "Run as user      : ${RUN_USER}"
  info "Interval         : every ${CRON_INTERVAL_MIN} minute(s)"
  echo
}

# -- Preflight -----------------------------------------------------------------
check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_user_exists() {
  id "$RUN_USER" &>/dev/null \
    || error "User '${RUN_USER}' does not exist. Set RUN_USER=<your-user> and re-run."
}

check_reporter_script_exists() {
  [[ -f "$REPORTER_SCRIPT" ]] \
    || error "Reporter script not found at ${REPORTER_SCRIPT}. Set REPORTER_SCRIPT=<path> and re-run."
}

check_pgpass() {
  local home_dir pgpass_file perms
  home_dir="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  pgpass_file="${home_dir}/.pgpass"

  if [[ ! -f "$pgpass_file" ]]; then
    warn "${pgpass_file} not found — uptime updates to the Hive database will fail until it exists."
    warn "As ${RUN_USER}, create it with a line like:"
    warn "  192.168.0.67:5432:sensors:sensor_writer:<password>"
    warn "then:  chmod 600 ${pgpass_file}"
    return
  fi

  perms="$(stat -c '%a' "$pgpass_file")"
  if [[ "$perms" != "600" ]]; then
    warn "${pgpass_file} has permissions ${perms}, not 600 — libpq will refuse to use it."
    warn "Fix with:  chmod 600 ${pgpass_file}"
  fi
}

# -- Install --------------------------------------------------------------------
install_python_deps() {
  info "Installing Python dependencies for the uptime reporter…"
  run_quiet apt-get update
  run_quiet apt-get install -y libpq5
  run_quiet pip3 install --break-system-packages psycopg2-binary
  success "Python dependencies installed"
}

# -- Cron job --------------------------------------------------------------------
setup_cron() {
  info "Installing cron job to run the uptime reporter every ${CRON_INTERVAL_MIN} minute(s)…"

  touch "$LOG_FILE"
  chown "${RUN_USER}:${RUN_USER}" "$LOG_FILE"

  CRON_LINE="*/${CRON_INTERVAL_MIN} * * * * ${RUN_USER} python3 ${REPORTER_SCRIPT} >> ${LOG_FILE} 2>&1"
  echo "$CRON_LINE" > /etc/cron.d/uptime_reporter
  chmod 644 /etc/cron.d/uptime_reporter

  success "Cron job installed: /etc/cron.d/uptime_reporter"
}

# -- Summary -------------------------------------------------------------------
print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  Uptime reporter cron job installed!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}Cron entry:${NC}   /etc/cron.d/uptime_reporter"
  echo -e "  ${CYAN}Log file:${NC}     ${LOG_FILE}"
  echo -e "  ${CYAN}Runs as:${NC}      ${RUN_USER}"
  echo
  echo -e "  ${CYAN}Manual test run:${NC}"
  echo -e "    sudo -u ${RUN_USER} python3 ${REPORTER_SCRIPT}"
  echo
  echo -e "  ${CYAN}Tail the log:${NC}"
  echo -e "    tail -f ${LOG_FILE}"
  echo
  echo -e "  ${YELLOW}NOTE:${NC} the Hive database needs an 'uptime_seconds' column on its 'sensors'"
  echo -e "  table before this can write anything — see ../../db/database/sensors/tables/sensors.md"
  echo -e "  and re-run that project's setup_db.py if you haven't already."
  echo
}

# =============================================================================
main() {
  banner
  check_root
  check_user_exists
  check_reporter_script_exists
  check_pgpass

  install_python_deps
  setup_cron

  print_summary
}

main "$@"
