#!/usr/bin/env bash
# =============================================================================
# SQLite on RAM Disk — Setup Script for Raspberry Pi Zero
#
# WHY SQLITE INSTEAD OF POSTGRESQL?
#   - Single file, no server process, no WAL bloat by default
#   - Trivial to put on tmpfs: just point the file path at a RAM-backed dir
#   - Much more predictable footprint for a tiny ~20 MB budget
#
# STRATEGY:
#   1. Install sqlite3
#   2. Create a small tmpfs (RAM disk) mount
#   3. On boot: restore latest SD backup → RAM (or create empty DB if none)
#   4. Once per day (cron): copy RAM DB → compressed backup on SD card
#   5. On shutdown: flush once more, so graceful reboots never lose data
#
# TRADEOFFS:
#   - SD card writes drop from constant → once/day  ✓
#   - If Pi loses power unexpectedly, you lose up to 24h of data  ⚠
#   - DB lives in RAM — capped by RAMDISK_SIZE, monitor it           ⚠
#
# USAGE:
#   sudo bash sqlite_ramdisk_setup.sh [-v|--verbose]
#
#   -v, --verbose   Show full output from package installs (apt-get, etc.)
#                   instead of just a one-line progress message.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

# ── Config (override via env vars before running) ─────────────────────────────
RAMDISK_SIZE="${RAMDISK_SIZE:-20m}"                       # RAM disk cap
RAMDISK_MOUNT="${RAMDISK_MOUNT:-/mnt/sqlite_ram}"         # tmpfs mount point
DB_NAME="${DB_NAME:-sensors.db}"                          # SQLite filename
DB_RAM_PATH="${RAMDISK_MOUNT}/${DB_NAME}"                 # Live DB location (RAM)

SD_BACKUP_DIR="${SD_BACKUP_DIR:-/var/lib/sqlite_backup}"  # SD card backup dir
BACKUP_FILE="${SD_BACKUP_DIR}/${DB_NAME}.gz"
RESTORE_LOG="/var/log/sqlite_ram_restore.log"
FLUSH_LOG="/var/log/sqlite_flush.log"

CRON_HOUR="${CRON_HOUR:-3}"      # Daily flush time (24h)
CRON_MINUTE="${CRON_MINUTE:-0}"

RUN_USER="${RUN_USER:-eiq}"       # System user that will own/access the DB
FLUSH_SCRIPT="/usr/local/bin/sqlite_flush_to_sd"
RESTORE_SCRIPT="/usr/local/bin/sqlite_restore_from_sd"

# Set RESET=1 to wipe the SD card backup (and its .prev rotation copy) before
# restoring, so a schema change in create_example_table() actually takes
# effect instead of being silently overwritten by an old backup on every run.
# Without this, the restore step always wins because it runs before table
# creation — CREATE TABLE IF NOT EXISTS is a no-op against a restored table.
RESET="${RESET:-0}"

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║   SQLite on RAM Disk — Setup (RPi Zero SD Saver)    ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  info "RAM disk mount   : ${RAMDISK_MOUNT}  (max ${RAMDISK_SIZE})"
  info "Live DB path     : ${DB_RAM_PATH}"
  info "SD backup file   : ${BACKUP_FILE}"
  info "Daily flush time : ${CRON_HOUR}:$(printf '%02d' ${CRON_MINUTE})"
  info "DB owner         : ${RUN_USER}"
  if [[ "$RESET" == "1" ]]; then
    warn "RESET=1 is set — existing SD backup and RAM database will be WIPED"
  fi
  echo
}

# ── Preflight ─────────────────────────────────────────────────────────────────
check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_user_exists() {
  id "$RUN_USER" &>/dev/null \
    || error "User '${RUN_USER}' does not exist. Set RUN_USER=<your-user> and re-run."
}

check_free_ram() {
  FREE_MB=$(free -m | awk '/^Mem:/{print $7}')
  RAM_MB=$(echo "$RAMDISK_SIZE" | grep -oP '\d+')
  info "Available RAM: ${FREE_MB} MB, requested RAM disk: ${RAM_MB} MB"
  (( FREE_MB > RAM_MB + 32 )) \
    || error "Not enough free RAM. Free: ${FREE_MB} MB, need: $((RAM_MB + 32)) MB minimum."
}

# ── Install ────────────────────────────────────────────────────────────────────
install_sqlite() {
  info "Installing sqlite3…"
  run_quiet apt-get update
  run_quiet apt-get install -y sqlite3
  success "sqlite3 installed: $(sqlite3 --version)"
}

# ── Web user access (so PHP-FPM / nginx can read the live DB) ────────────────
grant_web_user_access() {
  if id www-data &>/dev/null; then
    info "Adding 'www-data' to group '${RUN_USER}' so PHP-FPM can read the live database…"
    usermod -aG "$RUN_USER" www-data
    success "www-data added to group ${RUN_USER}"
    info "Note: PHP-FPM must be restarted to pick up the new group membership"
    NEED_PHP_FPM_RESTART=1
  else
    warn "User 'www-data' not found — skipping web user group setup (install nginx/PHP first if needed)"
  fi
}

# ── tmpfs mount ───────────────────────────────────────────────────────────────
setup_tmpfs_mount() {
  info "Setting up tmpfs mount at ${RAMDISK_MOUNT}…"
  mkdir -p "$RAMDISK_MOUNT"

  RUN_UID=$(id -u "$RUN_USER")
  RUN_GID=$(id -g "$RUN_USER")

  # mode=0775: owner (RUN_USER) and group (also RUN_USER's group, which now
  # includes www-data) can read+write the mount dir; others get no access.
  #
  # IMPORTANT: always REPLACE any existing fstab line for this mount point,
  # rather than skipping when one is found. Skipping means re-running this
  # script after a permissions fix (e.g. mode=0755 -> 0775) silently keeps
  # the OLD stale entry forever, since the mount point itself never changes.
  if grep -qF "$RAMDISK_MOUNT" /etc/fstab; then
    info "Existing fstab entry found for ${RAMDISK_MOUNT} — replacing with current settings"
    sed -i "\|${RAMDISK_MOUNT}|d" /etc/fstab
  fi
  echo "tmpfs  ${RAMDISK_MOUNT}  tmpfs  defaults,noatime,nosuid,nodev,size=${RAMDISK_SIZE},uid=${RUN_UID},gid=${RUN_GID},mode=0775  0 0" \
    >> /etc/fstab
  info "fstab entry written (owned by ${RUN_USER}, group-readable+writable)"

  if mountpoint -q "$RAMDISK_MOUNT"; then
    warn "${RAMDISK_MOUNT} already mounted — remounting with current settings"
    umount "$RAMDISK_MOUNT" || error "Could not unmount ${RAMDISK_MOUNT} — stop whatever has it open (e.g. sqlite3, php-fpm) and re-run"
  fi
  mount "$RAMDISK_MOUNT"
  success "tmpfs mounted at ${RAMDISK_MOUNT}, owned by ${RUN_USER} (uid=${RUN_UID}), group-readable+writable"
}

# ── Initial backup dir ────────────────────────────────────────────────────────
setup_backup_dir() {
  info "Creating SD backup directory: ${SD_BACKUP_DIR}"
  mkdir -p "$SD_BACKUP_DIR"
  chown "${RUN_USER}:${RUN_USER}" "$SD_BACKUP_DIR"
}

# ── Wipe old SD backup when RESET=1 ───────────────────────────────────────────
wipe_sd_backup_if_reset() {
  if [[ "$RESET" != "1" ]]; then
    return
  fi

  warn "RESET=1 — wiping SD card backup so a fresh schema/database is created"
  warn "This deletes ${BACKUP_FILE} and any rotated .prev copy. This is"
  warn "PERMANENT — any data only stored on the SD backup will be lost."

  rm -f "$BACKUP_FILE" "${BACKUP_FILE}.prev"

  # Also clear the live RAM copy and its WAL/SHM sidecars, in case this is
  # being re-run against an already-mounted tmpfs with stale data in it.
  if [[ -f "$DB_RAM_PATH" ]]; then
    rm -f "$DB_RAM_PATH" "${DB_RAM_PATH}-wal" "${DB_RAM_PATH}-shm"
    info "Cleared live RAM database at ${DB_RAM_PATH}"
  fi

  success "SD backup and RAM copy wiped — restore step will create a brand-new database"
}

# ── Flush script (RAM → SD) ───────────────────────────────────────────────────
write_flush_script() {
  info "Writing flush script: ${FLUSH_SCRIPT}"
  cat > "$FLUSH_SCRIPT" << EOF
#!/usr/bin/env bash
# sqlite_flush_to_sd — copy the live RAM database to SD card (compressed)
# Uses SQLite's online backup via '.backup' so it's safe even with the DB in use.

set -euo pipefail
DB_RAM_PATH="${DB_RAM_PATH}"
BACKUP_FILE="${BACKUP_FILE}"
BACKUP_DIR="\$(dirname "\$BACKUP_FILE")"
TMP_BACKUP="\${BACKUP_DIR}/.tmp_\$(basename "\$DB_RAM_PATH")"
LOG="${FLUSH_LOG}"
TS="\$(date '+%Y-%m-%d %H:%M:%S')"

echo "[\$TS] Starting SQLite flush to SD card…" | tee -a "\$LOG"

if [[ ! -f "\$DB_RAM_PATH" ]]; then
  echo "[\$TS] No database found at \$DB_RAM_PATH — skipping flush." | tee -a "\$LOG"
  exit 0
fi

# Rotate previous backup
if [[ -f "\$BACKUP_FILE" ]]; then
  cp "\$BACKUP_FILE" "\${BACKUP_FILE}.prev"
fi

# Use SQLite's built-in '.backup' — safe for a live/open database (uses the
# SQLite backup API, not a raw file copy, so it won't grab a half-written page)
if sqlite3 "\$DB_RAM_PATH" ".backup '\$TMP_BACKUP'"; then
  gzip -f "\$TMP_BACKUP"
  mv "\${TMP_BACKUP}.gz" "\$BACKUP_FILE"
  SIZE=\$(du -sh "\$BACKUP_FILE" | awk '{print \$1}')
  echo "[\$TS] Flush OK → \$BACKUP_FILE (\$SIZE)" | tee -a "\$LOG"
else
  echo "[\$TS] FLUSH FAILED — previous backup retained at \${BACKUP_FILE}.prev" | tee -a "\$LOG"
  rm -f "\$TMP_BACKUP"
  exit 1
fi
EOF
  chmod +x "$FLUSH_SCRIPT"
  success "Flush script written"
}

# ── Restore script (SD → RAM, runs at boot) ───────────────────────────────────
write_restore_script() {
  info "Writing restore script: ${RESTORE_SCRIPT}"
  cat > "$RESTORE_SCRIPT" << EOF
#!/usr/bin/env bash
# sqlite_restore_from_sd — restore the SQLite DB from SD backup into RAM disk
# Runs at boot, before anything tries to use the database.

set -euo pipefail
RAMDISK_MOUNT="${RAMDISK_MOUNT}"
DB_RAM_PATH="${DB_RAM_PATH}"
BACKUP_FILE="${BACKUP_FILE}"
RUN_USER="${RUN_USER}"
LOG="${RESTORE_LOG}"
TS="\$(date '+%Y-%m-%d %H:%M:%S')"

echo "[\$TS] sqlite_restore_from_sd starting…" | tee -a "\$LOG"

if ! mountpoint -q "\$RAMDISK_MOUNT"; then
  mount "\$RAMDISK_MOUNT" || { echo "[\$TS] ERROR: failed to mount \$RAMDISK_MOUNT" | tee -a "\$LOG"; exit 1; }
fi

if [[ -f "\$BACKUP_FILE" ]]; then
  echo "[\$TS] Restoring from \$BACKUP_FILE…" | tee -a "\$LOG"
  gunzip -c "\$BACKUP_FILE" > "\$DB_RAM_PATH"
else
  echo "[\$TS] No backup found at \$BACKUP_FILE — creating empty database." | tee -a "\$LOG"
  touch "\$DB_RAM_PATH"
fi

chown "\${RUN_USER}:\${RUN_USER}" "\$DB_RAM_PATH"
chmod 644 "\$DB_RAM_PATH"

# Use DELETE journal mode (SQLite's default), NOT WAL. WAL mode creates
# -shm/-wal sidecar files that get owned by whichever process opens the DB
# FIRST — if that's PHP (www-data) and later the logger script (RUN_USER)
# tries to write, it hits "attempt to write a readonly database" because it
# can't write the OTHER process's sidecar files, and vice versa. DELETE mode
# has no persistent sidecar files: each write uses a temporary rollback
# journal created and removed within the same transaction by whichever
# process is writing. We only ever have one writer (the logger) and
# read-only access from PHP, so WAL's concurrency benefit doesn't apply here.
sudo -u "\$RUN_USER" sqlite3 "\$DB_RAM_PATH" "PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL;" >/dev/null

echo "[\$TS] Restore complete: \$(du -sh "\$DB_RAM_PATH" | awk '{print \$1}')" | tee -a "\$LOG"
echo "[\$TS] Database ready at \$DB_RAM_PATH" | tee -a "\$LOG"
EOF
  chmod +x "$RESTORE_SCRIPT"
  success "Restore script written"
}

# ── Run restore once now, so DB exists immediately after setup ───────────────
run_initial_restore() {
  info "Running initial restore/init…"
  "$RESTORE_SCRIPT"
  success "Database initialized at ${DB_RAM_PATH}"
}

# ── Systemd unit for boot restore ─────────────────────────────────────────────
write_systemd_restore_unit() {
  info "Writing systemd unit: sqlite-ram-restore.service"
  cat > /etc/systemd/system/sqlite-ram-restore.service << EOF
[Unit]
Description=Restore SQLite database from SD card into RAM disk
After=local-fs.target
RequiresMountsFor=${RAMDISK_MOUNT}

[Service]
Type=oneshot
ExecStart=${RESTORE_SCRIPT}
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sqlite-ram-restore.service
  success "sqlite-ram-restore.service enabled (runs on every boot)"
}

# ── Systemd unit for shutdown flush ───────────────────────────────────────────
write_systemd_shutdown_unit() {
  info "Writing systemd unit: sqlite-flush-on-shutdown.service"
  cat > /etc/systemd/system/sqlite-flush-on-shutdown.service << EOF
[Unit]
Description=Flush SQLite RAM database to SD card on shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=${FLUSH_SCRIPT}
TimeoutStartSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=shutdown.target reboot.target halt.target
EOF

  systemctl daemon-reload
  systemctl enable sqlite-flush-on-shutdown.service
  success "sqlite-flush-on-shutdown.service enabled (flushes on graceful shutdown/reboot)"
}

# ── Daily cron job ────────────────────────────────────────────────────────────
setup_cron() {
  info "Setting up daily cron flush at ${CRON_HOUR}:$(printf '%02d' ${CRON_MINUTE})…"
  CRON_LINE="${CRON_MINUTE} ${CRON_HOUR} * * * root ${FLUSH_SCRIPT} >> ${FLUSH_LOG} 2>&1"
  echo "$CRON_LINE" > /etc/cron.d/sqlite_flush
  chmod 644 /etc/cron.d/sqlite_flush
  success "Cron job installed: /etc/cron.d/sqlite_flush"
}

# ── Size guard (warn before tmpfs fills up) ───────────────────────────────────
write_size_guard_script() {
  info "Writing size guard script: /usr/local/bin/sqlite_size_guard"
  cat > /usr/local/bin/sqlite_size_guard << EOF
#!/usr/bin/env bash
# sqlite_size_guard — warns when the RAM disk approaches its size cap.
# A full tmpfs causes SQLite writes to fail with "database or disk is full" —
# better to catch it early via cron and prune old data.

set -euo pipefail
RAMDISK_MOUNT="${RAMDISK_MOUNT}"
DB_RAM_PATH="${DB_RAM_PATH}"
LOG="/var/log/sqlite_size_guard.log"
TS="\$(date '+%Y-%m-%d %H:%M:%S')"
WARN_PCT=80

USED_PCT=\$(df --output=pcent "\$RAMDISK_MOUNT" | tail -1 | tr -dc '0-9')
USED_MB=\$(df -BM --output=used "\$RAMDISK_MOUNT" | tail -1 | tr -dc '0-9')
SIZE_MB=\$(df -BM --output=size "\$RAMDISK_MOUNT" | tail -1 | tr -dc '0-9')
DB_MB=\$(du -sm "\$DB_RAM_PATH" 2>/dev/null | awk '{print \$1}' || echo "0")

if (( USED_PCT >= WARN_PCT )); then
  echo "[\$TS] WARNING: RAM disk at \${USED_PCT}% (\${USED_MB}MB / \${SIZE_MB}MB). DB file: \${DB_MB}MB. Consider pruning old rows or running VACUUM." | tee -a "\$LOG"
  logger -t sqlite_size_guard "SQLite RAM disk at \${USED_PCT}% capacity"
else
  echo "[\$TS] OK: RAM disk at \${USED_PCT}% (\${USED_MB}MB / \${SIZE_MB}MB), DB: \${DB_MB}MB" >> "\$LOG"
fi
EOF
  chmod +x /usr/local/bin/sqlite_size_guard
  echo "0 * * * * root /usr/local/bin/sqlite_size_guard" > /etc/cron.d/sqlite_size_guard
  chmod 644 /etc/cron.d/sqlite_size_guard
  success "Size guard installed — checks hourly, logs to /var/log/sqlite_size_guard.log"
}

# ── Pragmas are now applied inside the restore script (as RUN_USER) ──────────
# Kept as a no-op function call site for clarity / future extension.
apply_pragmas() {
  info "Pragmas already applied as ${RUN_USER} during restore — skipping duplicate root-owned open"
}

# ── Example schema for temperature readings ───────────────────────────────────
create_example_table() {
  info "Creating example 'readings' table (safe to skip/edit if you already have a schema)…"
  sudo -u "$RUN_USER" sqlite3 "$DB_RAM_PATH" <<SQL
CREATE TABLE IF NOT EXISTS readings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  recorded_at TEXT NOT NULL,
  sensor TEXT NOT NULL,
  temperature_c REAL NOT NULL,
  humidity_pct REAL NOT NULL,
  sample_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_readings_recorded_at ON readings(recorded_at);
SQL
  success "Example table 'readings' ready"
}

# ── Restart PHP-FPM so new group membership takes effect ─────────────────────
restart_php_fpm_if_needed() {
  if [[ "${NEED_PHP_FPM_RESTART:-0}" != "1" ]]; then
    return
  fi

  # Find whichever phpX.Y-fpm service is installed
  FPM_SERVICE=$(systemctl list-units --type=service --all 2>/dev/null \
    | grep -oP 'php[0-9]+\.[0-9]+-fpm\.service' | head -1)

  if [[ -z "$FPM_SERVICE" ]]; then
    warn "Could not detect a php*-fpm service to restart. If you're using PHP-FPM,"
    warn "restart it manually so www-data's new group membership takes effect:"
    warn "  sudo systemctl restart php<version>-fpm"
    return
  fi

  info "Restarting ${FPM_SERVICE} so www-data picks up its new group membership…"
  systemctl restart "$FPM_SERVICE"
  success "${FPM_SERVICE} restarted"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  echo
  echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  SQLite RAM disk setup complete! 🎉${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
  echo
  echo -e "  ${CYAN}Connect / query:${NC}"
  echo -e "    sqlite3 ${DB_RAM_PATH}"
  echo
  echo -e "  ${CYAN}Architecture:${NC}"
  echo -e "    Boot     → sqlite-ram-restore.service restores SD backup into RAM"
  echo -e "    Daily    → cron flushes RAM → ${BACKUP_FILE}"
  echo -e "    Shutdown → sqlite-flush-on-shutdown.service flushes before power-off"
  echo
  echo -e "  ${CYAN}Manual flush (any time):${NC}"
  echo -e "    sudo ${FLUSH_SCRIPT}"
  echo
  echo -e "  ${CYAN}Logs:${NC}"
  echo -e "    tail -f ${FLUSH_LOG}"
  echo -e "    tail -f ${RESTORE_LOG}"
  echo -e "    tail -f /var/log/sqlite_size_guard.log"
  echo
  echo -e "  ${CYAN}RAM disk usage:${NC}"
  echo -e "    df -h ${RAMDISK_MOUNT}"
  echo
  echo -e "  ${CYAN}Verify PHP/nginx can read the database:${NC}"
  echo -e "    sudo -u www-data sqlite3 ${DB_RAM_PATH} \"SELECT COUNT(*) FROM readings;\""
  echo
  echo -e "  ${CYAN}Example insert (from your sensor script):${NC}"
  echo -e "    sqlite3 ${DB_RAM_PATH} \"INSERT INTO readings (sensor, value_c) VALUES ('cpu', 42.5);\""
  echo
  echo -e "  ${YELLOW}⚠  Data loss risk:${NC}"
  echo -e "     Unexpected power loss = up to 24h of data lost. Graceful"
  echo -e "     shutdown/reboot always flushes first. Consider a UPS if"
  echo -e "     this matters for your use case."
  echo
  echo -e "  ${YELLOW}⚠  ${RAMDISK_SIZE} budget is a hard cap:${NC}"
  echo -e "     Add a retention policy so old readings don't fill the disk, e.g.:"
  echo -e "       DELETE FROM readings WHERE recorded_at < datetime('now', '-30 days');"
  echo -e "       VACUUM;"
  echo -e "     Consider adding this as a daily cron job alongside the flush."
  echo
}

# =============================================================================
main() {
  banner
  check_root
  check_user_exists
  check_free_ram

  install_sqlite
  grant_web_user_access
  setup_tmpfs_mount
  setup_backup_dir
  wipe_sd_backup_if_reset

  write_flush_script
  write_restore_script
  run_initial_restore

  apply_pragmas
  create_example_table

  write_systemd_restore_unit
  write_systemd_shutdown_unit
  setup_cron
  write_size_guard_script

  restart_php_fpm_if_needed

  print_summary
}

main "$@"