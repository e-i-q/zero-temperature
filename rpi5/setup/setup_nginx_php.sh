#!/usr/bin/env bash
# =============================================================================
# nginx + PHP-FPM Installer — Raspberry Pi 5 (Hive dashboard host)
#
# Installs nginx + PHP-FPM with PostgreSQL (pdo_pgsql) support, and wires
# them together so .php files under the web root are executed by PHP. This
# is the sibling of rpi-zero/setup/setup_nginx_php.sh — same shape, but
# php-pgsql instead of php-sqlite3, since the Hive dashboard queries the
# central PostgreSQL database directly rather than a local SQLite file.
#
# Assumes the `db` project (../../db, "Hive") has already installed and is
# running PostgreSQL on this Pi — this script only installs the web server
# that serves rpi5/web/ on top of it.
#
# USAGE:
#   sudo bash setup/setup_nginx_php.sh [-v|--verbose]
#
#   -v, --verbose   Show full output from package installs (apt-get, etc.)
#                   instead of just a one-line progress message.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

# -- Config --------------------------------------------------------------------
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
SITE_NAME="${SITE_NAME:-default}"
RUN_USER="${RUN_USER:-www-data}"   # nginx/PHP-FPM run as this user

# Must match web/api/db.php's PG_HOST/PG_PORT/PG_DBNAME/PG_USER constants.
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_DBNAME="${PG_DBNAME:-sensors}"
PG_ROLE="${PG_ROLE:-web_reader}"
# WEB_READER_PASSWORD: set this beforehand to skip the interactive prompt
# (e.g. for unattended installs); otherwise prompt_for_password() below asks
# for it once, at the start of the run.

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "+------------------------------------------------------+"
  echo "|   nginx + PHP-FPM Installer — Raspberry Pi 5 (Hive)  |"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
}

# -- www-data's PostgreSQL credentials -----------------------------------------
# Asked up front, before any package installation, so the run isn't
# interrupted partway through waiting on input.
prompt_for_password() {
  if [[ -n "${WEB_READER_PASSWORD:-}" ]]; then
    info "Using WEB_READER_PASSWORD from the environment for '${PG_ROLE}'"
    return
  fi
  if [[ ! -t 0 ]]; then
    warn "Not running interactively and WEB_READER_PASSWORD is not set —"
    warn "~/.pgpass will not be configured automatically. Set WEB_READER_PASSWORD"
    warn "and re-run, or configure ~/.pgpass by hand afterwards (see README)."
    return
  fi

  info "The dashboard connects to the Hive database (${PG_HOST}:${PG_PORT}/${PG_DBNAME})"
  info "as the '${PG_ROLE}' role — this is the same password used when that role"
  info "was created by the db project's setup_db.py (WEB_READER_PASSWORD there)."
  read -r -s -p "Enter the PostgreSQL password for '${PG_ROLE}' (leave blank to configure ~/.pgpass manually later): " WEB_READER_PASSWORD
  echo
  export WEB_READER_PASSWORD
}

# -- Preflight -----------------------------------------------------------------
check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_disk_space() {
  AVAIL_MB=$(df /var --output=avail -BM | tail -1 | tr -d 'M')
  (( AVAIL_MB >= 200 )) || error "Not enough disk space (${AVAIL_MB} MB free, need >= 200 MB)."
  info "Available disk space: ${AVAIL_MB} MB — OK"
}

check_internet() {
  info "Checking internet connectivity…"
  ping -c1 -W3 8.8.8.8 &>/dev/null || error "No internet connection detected. Please connect and retry."
  success "Internet OK"
}

# -- Installation --------------------------------------------------------------
update_system() {
  info "Updating package lists…"
  run_quiet apt-get update
  success "Package lists updated"
}

install_nginx() {
  info "Installing nginx…"
  run_quiet apt-get install -y nginx
  success "nginx installed: $(nginx -v 2>&1)"
}

install_php() {
  info "Installing PHP-FPM and required extensions…"
  run_quiet apt-get install -y \
    php-fpm \
    php-pgsql \
    php-cli

  PHP_VERSION=$(php -v | head -1 | grep -oP 'PHP \K[0-9]+\.[0-9]+')
  PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
  PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

  info "Detected PHP version: ${PHP_VERSION}"
  info "PHP-FPM socket: ${PHP_FPM_SOCK}"

  success "PHP-FPM installed with pdo_pgsql support"
}

verify_pgsql_extension() {
  info "Verifying PostgreSQL PHP extension…"
  if php -m | grep -qi pdo_pgsql; then
    success "pdo_pgsql extension confirmed active"
  else
    error "pdo_pgsql PHP extension not found. Check: php -m | grep -i pgsql"
  fi
}

# Writes/updates RUN_USER's ~/.pgpass with the line the dashboard's API
# endpoints need to authenticate, using the password prompt_for_password()
# collected. Idempotent: re-running with a new password replaces the old
# line for this host:port:db:role rather than appending a duplicate.
setup_pgpass() {
  local home_dir pgpass_file match_prefix line

  home_dir="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  if [[ -z "$home_dir" || "$home_dir" == "/nonexistent" ]]; then
    warn "Could not find a usable home directory for '${RUN_USER}' (getent says '${home_dir:-<empty>}')."
    warn "Set one (e.g. 'usermod -d /var/www ${RUN_USER}') or create ~/.pgpass by hand — see README."
    return
  fi
  pgpass_file="${home_dir}/.pgpass"

  if [[ -z "${WEB_READER_PASSWORD:-}" ]]; then
    warn "No password collected — skipping ~/.pgpass setup."
    warn "The dashboard's API endpoints will fail to connect until ${pgpass_file} exists:"
    warn "  ${PG_HOST}:${PG_PORT}:${PG_DBNAME}:${PG_ROLE}:<password>   (chmod 600, owned by ${RUN_USER})"
    return
  fi

  mkdir -p "$home_dir"
  touch "$pgpass_file"

  match_prefix="${PG_HOST}:${PG_PORT}:${PG_DBNAME}:${PG_ROLE}:"
  line="${match_prefix}${WEB_READER_PASSWORD}"
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

enable_services() {
  info "Enabling and starting services…"
  systemctl enable nginx
  systemctl enable "${PHP_FPM_SERVICE}"
  systemctl restart "${PHP_FPM_SERVICE}"
  systemctl restart nginx
  sleep 1

  systemctl is-active --quiet nginx \
    || error "nginx failed to start. Check: journalctl -xe -u nginx"
  systemctl is-active --quiet "${PHP_FPM_SERVICE}" \
    || error "${PHP_FPM_SERVICE} failed to start. Check: journalctl -xe -u ${PHP_FPM_SERVICE}"

  success "nginx and ${PHP_FPM_SERVICE} are running"
}

# -- nginx site config wiring PHP-FPM in ---------------------------------------
configure_nginx_site() {
  info "Configuring nginx site '${SITE_NAME}' to hand .php files to PHP-FPM…"

  CONF_PATH="/etc/nginx/sites-available/${SITE_NAME}"

  if [[ -f "$CONF_PATH" ]]; then
    cp "$CONF_PATH" "${CONF_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    warn "Existing config backed up to ${CONF_PATH}.bak.*"
  fi

  cat > "$CONF_PATH" << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    root ${WEB_ROOT};
    index index.php index.html;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Hand .php requests (the dashboard's api/*.php endpoints) to PHP-FPM
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    # Deny access to dotfiles (.env, .git, etc.)
    location ~ /\. {
        deny all;
    }

    access_log /var/log/nginx/${SITE_NAME}.access.log;
    error_log  /var/log/nginx/${SITE_NAME}.error.log;
}
EOF

  ln -sf "$CONF_PATH" "/etc/nginx/sites-enabled/${SITE_NAME}"

  if [[ -L /etc/nginx/sites-enabled/default && "$SITE_NAME" != "default" ]]; then
    rm -f /etc/nginx/sites-enabled/default
    info "Removed default nginx site (replaced by '${SITE_NAME}')"
  fi

  success "nginx site configured: ${CONF_PATH}"
}

test_nginx_config() {
  info "Testing nginx configuration…"
  nginx -t || error "nginx config test failed — check the output above"
  systemctl reload nginx
  success "nginx config valid and reloaded"
}

# -- Permissions for web root --------------------------------------------------
setup_web_root() {
  info "Setting up web root at ${WEB_ROOT}…"
  mkdir -p "$WEB_ROOT"
  chown -R "${RUN_USER}:${RUN_USER}" "$WEB_ROOT"
  success "Web root ready: ${WEB_ROOT} (owned by ${RUN_USER})"
}

# -- Sanity test: PHP + pdo_pgsql info page ------------------------------------
write_test_page() {
  info "Writing a quick PHP+PostgreSQL test page…"
  cat > "${WEB_ROOT}/phptest.php" << 'EOF'
<?php
header('Content-Type: text/plain');
echo "PHP version: " . phpversion() . "\n";
echo "pdo_pgsql extension loaded: " . (extension_loaded('pdo_pgsql') ? 'yes' : 'no') . "\n";
echo "PDO pgsql driver available: " . (in_array('pgsql', PDO::getAvailableDrivers()) ? 'yes' : 'no') . "\n";
echo "\nThis only checks the PHP extension — it does not connect to the Hive\n";
echo "database. Once web_reader's ~/.pgpass entry is in place, verify the\n";
echo "actual connection via api/readings.php instead.\n";
EOF
  chown "${RUN_USER}:${RUN_USER}" "${WEB_ROOT}/phptest.php"
  success "Test page written: ${WEB_ROOT}/phptest.php"
}

run_smoke_test() {
  info "Running smoke test against http://127.0.0.1/phptest.php…"
  sleep 1
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/phptest.php || echo "000")

  if [[ "$RESPONSE" == "200" ]]; then
    success "Smoke test passed (HTTP 200)"
    info "Response body:"
    curl -s http://127.0.0.1/phptest.php | sed 's/^/    /'
  else
    warn "Smoke test returned HTTP ${RESPONSE} — check nginx/php-fpm logs if this isn't expected"
  fi
}

# -- Summary -------------------------------------------------------------------
print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  nginx + PHP-FPM installed successfully!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}PHP version:${NC}        ${PHP_VERSION}"
  echo -e "  ${CYAN}PHP-FPM service:${NC}    ${PHP_FPM_SERVICE}"
  echo -e "  ${CYAN}Web root:${NC}           ${WEB_ROOT}"
  echo -e "  ${CYAN}nginx site config:${NC}  /etc/nginx/sites-available/${SITE_NAME}"
  echo
  echo -e "  ${CYAN}Test page:${NC}"
  echo -e "    curl http://127.0.0.1/phptest.php"
  echo -e "    (remove this file once you've confirmed everything works:"
  echo -e "     sudo rm ${WEB_ROOT}/phptest.php)"
  echo
  if [[ -n "${WEB_READER_PASSWORD:-}" ]]; then
    echo -e "  ${CYAN}~/.pgpass:${NC}          configured for '${PG_ROLE}' on ${PG_HOST}:${PG_PORT}/${PG_DBNAME}"
  else
    echo -e "  ${YELLOW}~/.pgpass:${NC}          NOT configured — see the warning above"
  fi
  echo
  echo -e "  ${YELLOW}Next step:${NC} run 'bash setup/deploy_web.sh' to copy web/ into ${WEB_ROOT}."
  echo
}

# =============================================================================
main() {
  banner
  check_root
  prompt_for_password

  check_disk_space
  check_internet

  update_system
  install_nginx
  install_php
  verify_pgsql_extension

  setup_web_root
  configure_nginx_site
  test_nginx_config
  enable_services

  setup_pgpass
  write_test_page
  run_smoke_test

  print_summary
}

main "$@"
