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
#   sudo bash setup/setup_nginx_php.sh
# =============================================================================

set -euo pipefail

# -- Colours ------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# -- Config --------------------------------------------------------------------
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
SITE_NAME="${SITE_NAME:-default}"
RUN_USER="${RUN_USER:-www-data}"   # nginx/PHP-FPM run as this user

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "+------------------------------------------------------+"
  echo "|   nginx + PHP-FPM Installer — Raspberry Pi 5 (Hive)  |"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
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
  apt-get update -qq
  success "Package lists updated"
}

install_nginx() {
  info "Installing nginx…"
  apt-get install -y nginx
  success "nginx installed: $(nginx -v 2>&1)"
}

install_php() {
  info "Installing PHP-FPM and required extensions…"
  apt-get install -y \
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

# -- www-data's PostgreSQL credentials -----------------------------------------
check_pgpass() {
  local home_dir pgpass_file perms
  home_dir="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  pgpass_file="${home_dir}/.pgpass"

  if [[ ! -f "$pgpass_file" ]]; then
    warn "${pgpass_file} not found — the dashboard's API endpoints will fail to"
    warn "connect until it exists. As root (or via sudo -u ${RUN_USER}), create it with:"
    warn "  127.0.0.1:5432:sensors:web_reader:<password>"
    warn "then:  chmod 600 ${pgpass_file}; chown ${RUN_USER} ${pgpass_file}"
    return
  fi

  perms="$(stat -c '%a' "$pgpass_file")"
  if [[ "$perms" != "600" ]]; then
    warn "${pgpass_file} has permissions ${perms}, not 600 — libpq will refuse to use it."
    warn "Fix with:  chmod 600 ${pgpass_file}"
  fi
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
  echo -e "  ${YELLOW}Next step:${NC} run 'bash setup/deploy_web.sh' to copy web/ into"
  echo -e "  ${WEB_ROOT}, then make sure www-data's ~/.pgpass has a line for web_reader"
  echo -e "  (see the warning above, or rpi5/README.md)."
  echo
}

# =============================================================================
main() {
  banner
  check_root
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

  check_pgpass
  write_test_page
  run_smoke_test

  print_summary
}

main "$@"
