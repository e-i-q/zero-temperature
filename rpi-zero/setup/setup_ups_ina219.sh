#!/usr/bin/env bash
# =============================================================================
# setup_ups_ina219.sh — UPS Battery Monitor Cron Setup — Raspberry Pi Zero
#
# Installs the Python dependencies ups_ina219.py needs, enables the I2C
# interface the INA219-based UPS HAT talks over, then installs a cron job
# that runs it on a fixed interval so `sensors.status` (OK / CHARGING <pct>%
# / BATTERY <pct>%, shown per-tile on the Hive dashboard's Overview tab)
# stays current without anyone starting it by hand.
#
# USAGE:
#   sudo bash setup/setup_ups_ina219.sh [-v|--verbose]
#
#   -v, --verbose   Show full output from package installs (apt-get, pip)
#                   instead of just a one-line progress message.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

# -- Config (override via env vars before running) ----------------------------
MONITOR_SCRIPT="${MONITOR_SCRIPT:-${SCRIPT_DIR}/../python/ups_ina219.py}"

RUN_USER="${RUN_USER:-${SUDO_USER:-$(whoami)}}"           # Must have I2C + DB access
I2C_ADDR="${I2C_ADDR:-0x43}"
I2C_BUS="${I2C_BUS:-1}"
CRON_INTERVAL_MIN="${CRON_INTERVAL_MIN:-5}"
LOG_FILE="${LOG_FILE:-/var/log/ups_ina219.log}"

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "+------------------------------------------------------+"
  echo "|   UPS Battery Monitor — Cron Setup (RPi Zero)        |"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
  info "Monitor script   : ${MONITOR_SCRIPT}"
  info "Run as user      : ${RUN_USER}"
  info "I2C address/bus  : ${I2C_ADDR} / ${I2C_BUS}"
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

check_monitor_script_exists() {
  [[ -f "$MONITOR_SCRIPT" ]] \
    || error "Monitor script not found at ${MONITOR_SCRIPT}. Set MONITOR_SCRIPT=<path> and re-run."
}

check_pgpass() {
  local home_dir pgpass_file perms
  home_dir="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  pgpass_file="${home_dir}/.pgpass"

  if [[ ! -f "$pgpass_file" ]]; then
    warn "${pgpass_file} not found — status updates to the Hive database will fail until it exists."
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
  info "Installing Python dependencies for the UPS battery monitor…"
  run_quiet apt-get update
  run_quiet apt-get install -y python3-smbus i2c-tools libpq5
  run_quiet pip3 install --break-system-packages psycopg2-binary
  success "Python dependencies installed"
}

# -- I2C --------------------------------------------------------------------
enable_i2c() {
  info "Checking the I2C interface is enabled…"
  local config_file
  if [[ -f /boot/firmware/config.txt ]]; then
    config_file=/boot/firmware/config.txt
  else
    config_file=/boot/config.txt
  fi

  if grep -q '^dtparam=i2c_arm=on' "$config_file" 2>/dev/null; then
    success "I2C already enabled in ${config_file}"
  else
    echo "dtparam=i2c_arm=on" >> "$config_file"
    warn "I2C enabled in ${config_file} — reboot before the monitor can talk to the HAT (sudo reboot)."
  fi

  run_quiet modprobe i2c-dev
}

# -- Cron job --------------------------------------------------------------------
setup_cron() {
  info "Installing cron job to run the UPS monitor every ${CRON_INTERVAL_MIN} minute(s)…"

  touch "$LOG_FILE"
  chown "${RUN_USER}:${RUN_USER}" "$LOG_FILE"

  CRON_LINE="*/${CRON_INTERVAL_MIN} * * * * ${RUN_USER} python3 ${MONITOR_SCRIPT} --addr ${I2C_ADDR} --bus ${I2C_BUS} >> ${LOG_FILE} 2>&1"
  echo "$CRON_LINE" > /etc/cron.d/ups_ina219
  chmod 644 /etc/cron.d/ups_ina219

  success "Cron job installed: /etc/cron.d/ups_ina219"
}

# -- Summary -------------------------------------------------------------------
print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  UPS battery monitor cron job installed!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}Cron entry:${NC}   /etc/cron.d/ups_ina219"
  echo -e "  ${CYAN}Log file:${NC}     ${LOG_FILE}"
  echo -e "  ${CYAN}Runs as:${NC}      ${RUN_USER}"
  echo
  echo -e "  ${CYAN}Manual test run:${NC}"
  echo -e "    sudo -u ${RUN_USER} python3 ${MONITOR_SCRIPT} --addr ${I2C_ADDR} --bus ${I2C_BUS}"
  echo
  echo -e "  ${CYAN}Tail the log:${NC}"
  echo -e "    tail -f ${LOG_FILE}"
  echo
  echo -e "  ${YELLOW}NOTE:${NC} the Hive database needs a 'status' column on its 'sensors'"
  echo -e "  table before this can write anything — see ../../db/database/sensors/tables/sensors.md"
  echo -e "  and re-run that project's setup_db.py if you haven't already."
  echo
}

# =============================================================================
main() {
  banner
  check_root
  check_user_exists
  check_monitor_script_exists
  check_pgpass

  install_python_deps
  enable_i2c
  setup_cron

  print_summary
}

main "$@"
