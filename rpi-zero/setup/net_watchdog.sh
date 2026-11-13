#!/usr/bin/env bash
# =============================================================================
# net_watchdog.sh — keeps a Pi Zero on the network: reconnects Wi-Fi when the
# LAN is unreachable, and reboots as a last resort.
#
# Installed by setup/setup_net_watchdog.sh as /usr/local/sbin/net_watchdog
# and run as root once a minute by net-watchdog.timer. Each run:
#
#   1. Checks connectivity: the default gateway (ping), the Hive (ping) and
#      the Hive's PostgreSQL port (TCP). ANY answer counts as online — so a
#      Hive that's down for maintenance never makes the whole fleet reboot,
#      as long as the router still answers.
#   2. Online → clears the offline timer and the reboot back-off.
#   3. Offline for RECONNECT_AFTER_MIN → tries to bring Wi-Fi back, then
#      again every RECONNECT_EVERY_MIN: turns Wi-Fi power saving off, cycles
#      the radio and explicitly re-activates every saved Wi-Fi connection
#      (NetworkManager), or reconfigures wpa_supplicant and bounces the
#      interface (dhcpcd-based images). The explicit `nmcli connection up` is
#      what un-sticks NetworkManager after a failed handshake: it otherwise
#      blocks autoconnect for that network ("no secrets") until someone
#      types the password into a dialog — the dialog seen on the monitor.
#   4. Offline for REBOOT_AFTER_MIN → flushes the SQLite RAM disk to the SD
#      card and reboots. The threshold doubles after every watchdog reboot
#      that didn't bring the network back (capped at MAX_REBOOT_AFTER_MIN),
#      so a Zero taken somewhere with no known Wi-Fi isn't rebooted every
#      30 minutes forever. Connectivity coming back resets the back-off.
#
# The offline timer lives in /run (cleared by a reboot, so each boot gets
# the full grace period again); the reboot count lives in /var/lib.
#
# Config: /etc/default/net_watchdog (written by setup_net_watchdog.sh) —
# any variable below can be overridden there.
# Log:    /var/log/net_watchdog.log (actions/state changes only) + syslog.
# =============================================================================

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/default/net_watchdog}"
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

HIVE_HOST="${HIVE_HOST:-192.168.0.67}"
HIVE_PORT="${HIVE_PORT:-5432}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
RECONNECT_AFTER_MIN="${RECONNECT_AFTER_MIN:-3}"
RECONNECT_EVERY_MIN="${RECONNECT_EVERY_MIN:-5}"
REBOOT_AFTER_MIN="${REBOOT_AFTER_MIN:-30}"      # 0 disables rebooting
MAX_REBOOT_AFTER_MIN="${MAX_REBOOT_AFTER_MIN:-720}"
FLUSH_SCRIPT="${FLUSH_SCRIPT:-/usr/local/bin/sqlite_flush_to_sd}"

RUN_STATE_DIR="${RUN_STATE_DIR:-/run/net_watchdog}"
PERSIST_STATE_DIR="${PERSIST_STATE_DIR:-/var/lib/net_watchdog}"
LOG_FILE="${LOG_FILE:-/var/log/net_watchdog.log}"

OFFLINE_SINCE_FILE="${RUN_STATE_DIR}/offline_since"
LAST_RECONNECT_FILE="${RUN_STATE_DIR}/last_reconnect"
REBOOT_COUNT_FILE="${PERSIST_STATE_DIR}/reboot_count"

mkdir -p "$RUN_STATE_DIR" "$PERSIST_STATE_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
  logger -t net_watchdog -- "$*"
}

read_num() { local v; v="$(cat "$1" 2>/dev/null)"; [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "${2:-0}"; }

has_networkmanager() { systemctl is-active --quiet NetworkManager 2>/dev/null; }

# -- Connectivity -------------------------------------------------------------
is_online() {
  local gw
  gw="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
  [[ -n "$gw" ]] && ping -c 1 -W 3 "$gw" &>/dev/null && return 0
  ping -c 1 -W 3 "$HIVE_HOST" &>/dev/null && return 0
  timeout 4 bash -c "exec 3<>/dev/tcp/${HIVE_HOST}/${HIVE_PORT}" &>/dev/null && return 0
  return 1
}

# -- Recovery -----------------------------------------------------------------
disable_power_save() {
  command -v iw &>/dev/null && iw dev "$WIFI_IFACE" set power_save off &>/dev/null
}

reconnect_wifi() {
  disable_power_save
  if has_networkmanager; then
    log "Reconnect: cycling Wi-Fi radio and re-activating saved Wi-Fi connections (NetworkManager)"
    nmcli radio wifi off &>/dev/null
    sleep 5
    nmcli radio wifi on &>/dev/null
    sleep 10
    nmcli device wifi rescan ifname "$WIFI_IFACE" &>/dev/null
    sleep 5
    local uuid type autoconnect priority name
    # Every saved, autoconnecting Wi-Fi connection, highest
    # autoconnect-priority first; stop at the first one that comes up.
    # (UUID first: unlike NAME it never contains an escaped ':'.)
    while IFS=: read -r uuid type autoconnect priority name; do
      [[ "$type" == "802-11-wireless" && "$autoconnect" == "yes" ]] || continue
      if nmcli --wait 40 connection up uuid "$uuid" ifname "$WIFI_IFACE" &>/dev/null; then
        log "Reconnect: '${name}' is up"
        return 0
      fi
      log "Reconnect: could not bring up '${name}'"
    done < <(nmcli -t -f UUID,TYPE,AUTOCONNECT,AUTOCONNECT-PRIORITY,NAME connection show 2>/dev/null | sort -t: -k4,4 -rn)
  else
    log "Reconnect: reconfiguring wpa_supplicant and bouncing ${WIFI_IFACE}"
    wpa_cli -i "$WIFI_IFACE" reconfigure &>/dev/null
    ip link set "$WIFI_IFACE" down &>/dev/null
    sleep 3
    ip link set "$WIFI_IFACE" up &>/dev/null
    systemctl restart dhcpcd &>/dev/null
  fi
  return 1
}

reboot_now() {
  local count="$1" offline_min="$2"
  log "Reboot: offline for ${offline_min} min (watchdog reboot #$((count + 1)) without connectivity) — flushing DB to SD and rebooting"
  echo $((count + 1)) > "$REBOOT_COUNT_FILE"
  sync
  if [[ -x "$FLUSH_SCRIPT" ]]; then
    timeout 60 "$FLUSH_SCRIPT" &>/dev/null || log "Reboot: SD flush failed (rebooting anyway; the shutdown flush will retry)"
  fi
  systemctl reboot
}

# -- Main ---------------------------------------------------------------------
now="$(date +%s)"

if is_online; then
  if [[ -f "$OFFLINE_SINCE_FILE" ]]; then
    since="$(read_num "$OFFLINE_SINCE_FILE" "$now")"
    log "Online again after $(( (now - since) / 60 )) min offline"
    rm -f "$OFFLINE_SINCE_FILE" "$LAST_RECONNECT_FILE"
  fi
  if [[ "$(read_num "$REBOOT_COUNT_FILE")" != "0" ]]; then
    log "Connectivity restored — resetting reboot back-off"
    echo 0 > "$REBOOT_COUNT_FILE"
  fi
  exit 0
fi

if [[ ! -f "$OFFLINE_SINCE_FILE" ]]; then
  echo "$now" > "$OFFLINE_SINCE_FILE"
  log "Offline: gateway, ${HIVE_HOST} and ${HIVE_HOST}:${HIVE_PORT} all unreachable"
  exit 0
fi

since="$(read_num "$OFFLINE_SINCE_FILE" "$now")"
offline_min=$(( (now - since) / 60 ))

# Reboot first if it's due — no point attempting one more reconnect.
if (( REBOOT_AFTER_MIN > 0 )); then
  count="$(read_num "$REBOOT_COUNT_FILE")"
  threshold="$REBOOT_AFTER_MIN"
  for (( i = 0; i < count && threshold < MAX_REBOOT_AFTER_MIN; i++ )); do
    threshold=$(( threshold * 2 ))
  done
  (( threshold > MAX_REBOOT_AFTER_MIN )) && threshold="$MAX_REBOOT_AFTER_MIN"
  if (( offline_min >= threshold )); then
    reboot_now "$count" "$offline_min"
    exit 0
  fi
fi

if (( offline_min >= RECONNECT_AFTER_MIN )); then
  last="$(read_num "$LAST_RECONNECT_FILE")"
  if (( now - last >= RECONNECT_EVERY_MIN * 60 )); then
    echo "$now" > "$LAST_RECONNECT_FILE"
    reconnect_wifi
  fi
fi
exit 0
