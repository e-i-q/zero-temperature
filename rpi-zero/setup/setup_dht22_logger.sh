#!/usr/bin/env bash
# =============================================================================
# setup_dht22_logger.sh — DHT22 Logger Cron Setup — Raspberry Pi Zero
#
# Installs the Python dependencies dht22_logger.py needs, then installs a
# cron job that runs it on a fixed interval so readings keep landing in the
# SQLite database without anyone having to start it by hand.
#
# USAGE:
#   sudo bash setup/setup_dht22_logger.sh
# =============================================================================

set -euo pipefail

# -- Colours ------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# -- Config (override via env vars before running) ----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGGER_SCRIPT="${LOGGER_SCRIPT:-${SCRIPT_DIR}/../python/dht22_logger.py}"

RUN_USER="${RUN_USER:-eiq}"                              # Must have GPIO + DB access
DB_PATH="${DB_PATH:-/mnt/sqlite_ram/sensors.db}"
SAMPLES="${SAMPLES:-10}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-50}"
DELAY="${DELAY:-2.5}"
CRON_INTERVAL_MIN="${CRON_INTERVAL_MIN:-10}"
LOG_FILE="${LOG_FILE:-/var/log/dht22_logger.log}"

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "+------------------------------------------------------+"
  echo "|   DHT22 Logger — Cron Setup (RPi Zero)               |"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
  info "Logger script    : ${LOGGER_SCRIPT}"
  info "Run as user      : ${RUN_USER}"
  info "Database path    : ${DB_PATH}"
  info "Reading config   : ${SAMPLES} samples, ${MAX_ATTEMPTS} max attempts, ${DELAY}s delay"
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

check_logger_script_exists() {
  [[ -f "$LOGGER_SCRIPT" ]] \
    || error "Logger script not found at ${LOGGER_SCRIPT}. Set LOGGER_SCRIPT=<path> and re-run."
}

check_pgpass() {
  local home_dir pgpass_file perms
  home_dir="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  pgpass_file="${home_dir}/.pgpass"

  if [[ ! -f "$pgpass_file" ]]; then
    warn "${pgpass_file} not found — remote PostgreSQL mirroring will be skipped until it exists."
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
  info "Installing Python dependencies for the DHT22 logger…"
  apt-get update -qq
  apt-get install -y python3-pip libpq5
  pip3 install --break-system-packages adafruit-circuitpython-dht
  pip3 install --break-system-packages psycopg2-binary
  success "Python dependencies installed"
}

# -- Cron job --------------------------------------------------------------------
setup_cron() {
  info "Installing cron job to run the logger every ${CRON_INTERVAL_MIN} minute(s)…"

  touch "$LOG_FILE"
  chown "${RUN_USER}:${RUN_USER}" "$LOG_FILE"

  CRON_LINE="*/${CRON_INTERVAL_MIN} * * * * ${RUN_USER} python3 ${LOGGER_SCRIPT} --samples ${SAMPLES} --max_attempts ${MAX_ATTEMPTS} --delay ${DELAY} --db ${DB_PATH} >> ${LOG_FILE} 2>&1"
  echo "$CRON_LINE" > /etc/cron.d/dht22_logger
  chmod 644 /etc/cron.d/dht22_logger

  success "Cron job installed: /etc/cron.d/dht22_logger"
}

# -- Summary -------------------------------------------------------------------
print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  DHT22 logger cron job installed!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}Cron entry:${NC}   /etc/cron.d/dht22_logger"
  echo -e "  ${CYAN}Log file:${NC}     ${LOG_FILE}"
  echo -e "  ${CYAN}Runs as:${NC}      ${RUN_USER}"
  echo
  echo -e "  ${CYAN}Manual test run:${NC}"
  echo -e "    sudo -u ${RUN_USER} python3 ${LOGGER_SCRIPT} --samples ${SAMPLES} --max_attempts ${MAX_ATTEMPTS} --delay ${DELAY} --db ${DB_PATH}"
  echo
  echo -e "  ${CYAN}Tail the log:${NC}"
  echo -e "    tail -f ${LOG_FILE}"
  echo
}

# =============================================================================
main() {
  banner
  check_root
  check_user_exists
  check_logger_script_exists
  check_pgpass

  install_python_deps
  setup_cron

  print_summary
}

main "$@"
