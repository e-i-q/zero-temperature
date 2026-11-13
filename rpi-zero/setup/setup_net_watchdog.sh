#!/usr/bin/env bash
# =============================================================================
# setup_net_watchdog.sh — keep a Pi Zero online on its own — Raspberry Pi Zero
#
# Fixes for Zeros that drop off the network and never come back, found
# stuck either on a "Wi-Fi password" dialog or on the desktop login screen:
#
#   1. Wi-Fi secrets owned by the system, not by a desktop user.
#      On Raspberry Pi OS (Bookworm, NetworkManager) a network joined from
#      the desktop can keep its password "agent-owned" — stored in the
#      logged-in user's keyring and only handed to NetworkManager by that
#      user's desktop session. Then:
#        - after a power cut the Pi sits on the login screen with no Wi-Fi,
#          because nobody's logged in to hand over the password, and
#        - after any failed handshake (weak signal, router reboot)
#          NetworkManager asks the desktop for the password again — the
#          dialog seen on the monitor — and stops auto-connecting until
#          someone answers it.
#      This script moves every saved Wi-Fi connection's password into
#      NetworkManager's own system config (psk-flags 0), makes the
#      connection available to all users, retries auto-connecting forever
#      instead of 4 times, and turns Wi-Fi power saving off (a well-known
#      cause of Pi Zero W Wi-Fi drop-outs).
#   2. A network watchdog (net_watchdog.sh → /usr/local/sbin/net_watchdog,
#      net-watchdog.timer, every minute): reconnects Wi-Fi after a few
#      minutes offline, reboots after REBOOT_AFTER_MIN (with back-off) —
#      see that script's header for the exact rules.
#   3. The hardware watchdog (systemd RuntimeWatchdogSec): if the kernel
#      itself hangs, the SoC resets the Pi instead of it sitting frozen.
#   4. Optional (BOOT_TO_CONSOLE=1): boot to the text console with
#      auto-login instead of the desktop — no login screen, no desktop
#      dialogs, and less RAM used on a 512 MB Zero.
#
# If a connection's password is agent-owned, NetworkManager can't hand it
# over to a root shell, so pass it in: WIFI_PSK=<password>. Without it, that
# connection is left as it is (with a warning) — everything else still
# applies.
#
# Re-run after pulling a change to net_watchdog.sh (it's installed as a
# copy, so a root-run script never executes straight from a user-writable
# checkout).
#
# USAGE:
#   sudo bash setup/setup_net_watchdog.sh
#   sudo WIFI_PSK='<wifi password>' bash setup/setup_net_watchdog.sh
#   sudo BOOT_TO_CONSOLE=1 bash setup/setup_net_watchdog.sh
#   sudo REBOOT_AFTER_MIN=60 bash setup/setup_net_watchdog.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

# -- Config (override via env vars before running) ----------------------------
WATCHDOG_SRC="${SCRIPT_DIR}/net_watchdog.sh"
WATCHDOG_BIN="/usr/local/sbin/net_watchdog"
CONFIG_FILE="/etc/default/net_watchdog"
HIVE_HOST="${HIVE_HOST:-192.168.0.67}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
RECONNECT_AFTER_MIN="${RECONNECT_AFTER_MIN:-3}"
RECONNECT_EVERY_MIN="${RECONNECT_EVERY_MIN:-5}"
REBOOT_AFTER_MIN="${REBOOT_AFTER_MIN:-30}"
MAX_REBOOT_AFTER_MIN="${MAX_REBOOT_AFTER_MIN:-720}"
WIFI_PSK="${WIFI_PSK:-}"
HW_WATCHDOG="${HW_WATCHDOG:-1}"
BOOT_TO_CONSOLE="${BOOT_TO_CONSOLE:-0}"

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "+------------------------------------------------------+"
  echo "|   Network Watchdog + Wi-Fi Hardening (RPi Zero)      |"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
  info "Wi-Fi interface  : ${WIFI_IFACE}"
  info "Hive (reachability check) : ${HIVE_HOST}"
  info "Reconnect after  : ${RECONNECT_AFTER_MIN} min offline, then every ${RECONNECT_EVERY_MIN} min"
  info "Reboot after     : ${REBOOT_AFTER_MIN} min offline (doubling per fruitless reboot, max ${MAX_REBOOT_AFTER_MIN} min; 0 = never)"
  echo
}

check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_numbers() {
  local v
  for v in RECONNECT_AFTER_MIN RECONNECT_EVERY_MIN REBOOT_AFTER_MIN MAX_REBOOT_AFTER_MIN; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || error "${v} must be a whole number of minutes (got '${!v}')."
  done
  if (( REBOOT_AFTER_MIN > 0 && REBOOT_AFTER_MIN < 10 )); then
    error "REBOOT_AFTER_MIN=${REBOOT_AFTER_MIN} is too aggressive — use 10 or more (or 0 to disable rebooting)."
  fi
}

# -- 1. Wi-Fi hardening (NetworkManager) ----------------------------------------
harden_wifi_connections() {
  if ! systemctl is-active --quiet NetworkManager; then
    warn "NetworkManager isn't running (older dhcpcd/wpa_supplicant image) — skipping connection hardening."
    warn "Wi-Fi passwords in /etc/wpa_supplicant/wpa_supplicant.conf are already system-wide there."
    return
  fi

  local uuid type name changed=0
  while IFS=: read -r uuid type name; do
    [[ "$type" == "802-11-wireless" ]] || continue
    name="${name//\\:/:}"
    info "Wi-Fi connection '${name}'…"

    local args=(
      connection.autoconnect yes
      connection.autoconnect-retries 0      # 0 = retry forever (default gives up after 4)
      connection.permissions ""             # usable before/without any user login
      802-11-wireless.powersave 2           # 2 = disable power saving
    )

    local key_mgmt flags psk
    key_mgmt="$(nmcli -g 802-11-wireless-security.key-mgmt connection show uuid "$uuid" 2>/dev/null || true)"
    if [[ "$key_mgmt" == wpa-psk* || "$key_mgmt" == sae* ]]; then
      flags="$(nmcli -g 802-11-wireless-security.psk-flags connection show uuid "$uuid" 2>/dev/null || true)"
      if [[ "$flags" != 0* ]]; then
        psk="$(nmcli -s -g 802-11-wireless-security.psk connection show uuid "$uuid" 2>/dev/null || true)"
        psk="${psk:-$WIFI_PSK}"
        if [[ -z "$psk" ]]; then
          warn "  password is stored in a desktop user's keyring (psk-flags: ${flags:-?}) and wasn't passed in —"
          warn "  re-run with WIFI_PSK='<password>' to move it to the system. Leaving the password as is."
        else
          args+=(802-11-wireless-security.psk-flags 0 802-11-wireless-security.psk "$psk")
          info "  moving the password from the user keyring into the system connection"
        fi
      fi
    fi

    if nmcli connection modify uuid "$uuid" "${args[@]}"; then
      success "  hardened (system-wide, autoconnect forever, power saving off)"
      changed=1
    else
      warn "  nmcli could not modify '${name}' — left as is"
    fi
  done < <(nmcli -t -f UUID,TYPE,NAME connection show)

  (( changed )) || warn "No saved Wi-Fi connections found — nothing to harden."
}

# Covers dhcpcd images too, and NetworkManager until a connection re-activates.
disable_power_save_now() {
  if command -v iw &>/dev/null && iw dev "$WIFI_IFACE" set power_save off &>/dev/null; then
    success "Wi-Fi power saving off on ${WIFI_IFACE} (the watchdog re-applies this every minute)"
  fi
}

# -- 2. Watchdog script + timer -------------------------------------------------
install_watchdog() {
  [[ -f "$WATCHDOG_SRC" ]] || error "net_watchdog.sh not found at ${WATCHDOG_SRC}."
  install -m 755 -o root -g root "$WATCHDOG_SRC" "$WATCHDOG_BIN"

  cat > "$CONFIG_FILE" << EOF
# Written by setup_net_watchdog.sh — read by ${WATCHDOG_BIN} on every run.
HIVE_HOST="${HIVE_HOST}"
WIFI_IFACE="${WIFI_IFACE}"
RECONNECT_AFTER_MIN="${RECONNECT_AFTER_MIN}"
RECONNECT_EVERY_MIN="${RECONNECT_EVERY_MIN}"
REBOOT_AFTER_MIN="${REBOOT_AFTER_MIN}"
MAX_REBOOT_AFTER_MIN="${MAX_REBOOT_AFTER_MIN}"
EOF

  cat > /etc/systemd/system/net-watchdog.service << EOF
[Unit]
Description=Network watchdog — reconnect Wi-Fi / reboot when offline
After=network.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_BIN}
EOF

  cat > /etc/systemd/system/net-watchdog.timer << EOF
[Unit]
Description=Run the network watchdog every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

  touch /var/log/net_watchdog.log
  systemctl daemon-reload
  systemctl enable --now net-watchdog.timer
  success "Watchdog installed: ${WATCHDOG_BIN}, config ${CONFIG_FILE}, net-watchdog.timer enabled"
}

# -- 3. Hardware watchdog ---------------------------------------------------------
enable_hw_watchdog() {
  if [[ "$HW_WATCHDOG" != "1" ]]; then
    info "HW_WATCHDOG=0 — leaving the hardware watchdog alone"
    return
  fi
  mkdir -p /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/hw-watchdog.conf << EOF
# Written by setup_net_watchdog.sh — the SoC resets the Pi if systemd stops
# petting the hardware watchdog for this long (kernel hang, total freeze).
[Manager]
RuntimeWatchdogSec=15
RebootWatchdogSec=2min
EOF
  systemctl daemon-reexec
  success "Hardware watchdog enabled (RuntimeWatchdogSec=15)"
}

# -- 4. Optional: console boot ------------------------------------------------------
maybe_boot_to_console() {
  if [[ "$BOOT_TO_CONSOLE" != "1" ]]; then
    return
  fi
  command -v raspi-config &>/dev/null || { warn "raspi-config not found — can't switch boot mode."; return; }
  raspi-config nonint do_boot_behaviour B2
  success "Boot mode set to console with auto-login (takes effect on next boot)"
}

print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  Network watchdog installed!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}Watch it:${NC}       tail -f /var/log/net_watchdog.log"
  echo -e "  ${CYAN}Timer status:${NC}   systemctl list-timers net-watchdog.timer"
  echo -e "  ${CYAN}Wi-Fi config:${NC}   nmcli -f connection.permissions,802-11-wireless-security.psk-flags,802-11-wireless.powersave connection show <name>"
  echo
  if [[ "$BOOT_TO_CONSOLE" != "1" ]]; then
    echo -e "  ${YELLOW}Tip:${NC} a sensor node doesn't need the desktop. BOOT_TO_CONSOLE=1 boots straight"
    echo -e "  to an auto-logged-in console instead — no login screen, no desktop dialogs."
    echo
  fi
}

# =============================================================================
main() {
  banner
  check_root
  check_numbers

  harden_wifi_connections
  disable_power_save_now
  install_watchdog
  enable_hw_watchdog
  maybe_boot_to_console

  print_summary
}

main "$@"
