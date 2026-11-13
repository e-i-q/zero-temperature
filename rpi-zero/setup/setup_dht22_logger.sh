#!/usr/bin/env bash
# =============================================================================
# setup_dht22_logger.sh — DHT22 Logger Cron Setup — Raspberry Pi Zero
#
# Installs the Python dependencies dht22_logger.py needs, then installs a
# cron job that runs it on a fixed interval so readings keep landing in the
# SQLite database without anyone having to start it by hand.
#
# Also installs the on-demand reading trigger used by the Hive dashboard's
# "Read Now" button (see web/ondemand.php and dht22_logger.py's
# "On-demand readings" docstring section):
#   /etc/tmpfiles.d/dht22-ondemand.conf   ONDEMAND_DIR (RAM, recreated every
#                                         boot), RUN_USER:www-data, setgid
#   dht22-ondemand.path                   watches ONDEMAND_DIR/request.json
#   dht22-ondemand.service                runs the logger once, as RUN_USER,
#                                         with --ondemand-dir
#
# USAGE:
#   sudo bash setup/setup_dht22_logger.sh [-v|--verbose]
#
#   -v, --verbose   Show full output from package installs (apt-get, pip)
#                   instead of just a one-line progress message.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

# -- Config (override via env vars before running) ----------------------------
LOGGER_SCRIPT="${LOGGER_SCRIPT:-${SCRIPT_DIR}/../python/dht22_logger.py}"

RUN_USER="${RUN_USER:-${SUDO_USER:-$(whoami)}}"           # Must have GPIO + DB access
DB_PATH="${DB_PATH:-/mnt/sqlite_ram/sensors.db}"
SAMPLES="${SAMPLES:-10}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-50}"
DELAY="${DELAY:-2.5}"
CRON_INTERVAL_MIN="${CRON_INTERVAL_MIN:-10}"
LOG_FILE="${LOG_FILE:-/var/log/dht22_logger.log}"
ONDEMAND_DIR="${ONDEMAND_DIR:-/run/dht22-ondemand}"
WEB_GROUP="${WEB_GROUP:-www-data}"   # group PHP-FPM runs as (writes request.json)

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
  run_quiet apt-get update
  run_quiet apt-get install -y python3-pip libpq5
  run_quiet pip3 install --break-system-packages adafruit-circuitpython-dht
  run_quiet pip3 install --break-system-packages psycopg2-binary
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

# -- On-demand trigger ("Read Now" on the Hive) --------------------------------
setup_ondemand() {
  if ! getent group "$WEB_GROUP" &>/dev/null; then
    warn "Group '${WEB_GROUP}' not found — skipping on-demand trigger (install nginx/PHP first, then re-run)."
    return
  fi
  info "Installing on-demand reading trigger (${ONDEMAND_DIR})…"

  local logger_abs python_bin
  logger_abs="$(realpath "$LOGGER_SCRIPT")"
  python_bin="$(command -v python3)"

  # setgid + group-writable: www-data (web/ondemand.php) drops request.json
  # in here, RUN_USER (the logger) deletes it and writes status.json.
  echo "d ${ONDEMAND_DIR} 2775 ${RUN_USER} ${WEB_GROUP} -" > /etc/tmpfiles.d/dht22-ondemand.conf
  systemd-tmpfiles --create /etc/tmpfiles.d/dht22-ondemand.conf

  cat > /etc/systemd/system/dht22-ondemand.service << EOF
[Unit]
Description=On-demand DHT22 reading (requested from the Hive dashboard)

[Service]
Type=oneshot
User=${RUN_USER}
ExecStart=${python_bin} ${logger_abs} --samples ${SAMPLES} --max_attempts ${MAX_ATTEMPTS} --delay ${DELAY} --db ${DB_PATH} --ondemand-dir ${ONDEMAND_DIR}
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
EOF

  cat > /etc/systemd/system/dht22-ondemand.path << EOF
[Unit]
Description=Watch for on-demand DHT22 reading requests

[Path]
PathExists=${ONDEMAND_DIR}/request.json
Unit=dht22-ondemand.service

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now dht22-ondemand.path
  success "On-demand trigger installed: dht22-ondemand.path -> dht22-ondemand.service"
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
  echo -e "  ${CYAN}On-demand reading (what the Hive's Read Now button does):${NC}"
  echo -e "    echo '{\"id\":\"test\"}' > ${ONDEMAND_DIR}/request.json; sleep 40; cat ${ONDEMAND_DIR}/status.json"
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
  setup_ondemand

  print_summary
}

main "$@"
