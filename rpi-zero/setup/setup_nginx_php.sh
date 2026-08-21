#!/usr/bin/env bash
# =============================================================================
# nginx + PHP-FPM Installer — Raspberry Pi Zero (ARM 32-bit / armhf)
#
# Installs nginx + PHP-FPM with SQLite3 (pdo_sqlite) support, and wires them
# together so .php files under the web root are executed by PHP, not just
# served as plain text.
#
# USAGE:
#   sudo bash install_nginx_php.sh
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
  echo "¦   nginx + PHP-FPM Installer — Raspberry Pi Zero     ¦"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
}

# -- Preflight -----------------------------------------------------------------
check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_disk_space() {
  AVAIL_MB=$(df /var --output=avail -BM | tail -1 | tr -d 'M')
  (( AVAIL_MB >= 200 )) || error "Not enough disk space (${AVAIL_MB} MB free, need = 200 MB)."
  info "Available disk space: ${AVAIL_MB} MB — OK"
}

check_internet() {
  info "Checking internet connectivity…"
  ping -c1 -W3 8.8.8.8 &>/dev/null || error "No internet connection detected. Please connect and retry."
  success "Internet OK"
}

detect_php_version() {
  # Find whatever PHP version is available in the distro repos (Debian/Raspbian
  # ships one default version per release — e.g. PHP 8.2 on Bookworm)
  apt-cache search '^php[0-9]\.[0-9]-fpm$' 2>/dev/null | head -1 | grep -oP 'php\K[0-9]\.[0-9]' || true
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
    php-sqlite3 \
    php-cli

  PHP_VERSION=$(php -v | head -1 | grep -oP 'PHP \K[0-9]+\.[0-9]+')
  PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
  PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

  info "Detected PHP version: ${PHP_VERSION}"
  info "PHP-FPM socket: ${PHP_FPM_SOCK}"

  success "PHP-FPM installed with pdo_sqlite support"
}

verify_sqlite_extension() {
  info "Verifying SQLite3 PHP extension…"
  if php -m | grep -qi sqlite3 && php -m | grep -qi pdo_sqlite; then
    success "sqlite3 and pdo_sqlite extensions confirmed active"
  else
    error "SQLite PHP extensions not found. Check: php -m | grep -i sqlite"
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

    # Explicitly declare UTF-8 so the browser doesn't have to guess or fall
    # back to a locale-dependent default. This applies to text/html responses
    # (and other 'charset' MIME types nginx recognizes) for both static files
    # and PHP responses served from this site.
    charset utf-8;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Hand .php requests to PHP-FPM over its unix socket
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

  # Remove the stock default site if it's still symlinked and different from ours
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

# -- Sanity test: PHP + SQLite info page ---------------------------------------
write_test_page() {
  info "Writing a quick PHP+SQLite test page…"
  cat > "${WEB_ROOT}/phptest.php" << 'EOF'
<?php
header('Content-Type: text/plain');
echo "PHP version: " . phpversion() . "\n";
echo "SQLite3 extension loaded: " . (extension_loaded('sqlite3') ? 'yes' : 'no') . "\n";
echo "PDO SQLite driver available: " . (in_array('sqlite', PDO::getAvailableDrivers()) ? 'yes' : 'no') . "\n";

try {
    $db = new PDO('sqlite::memory:');
    $db->exec("CREATE TABLE t (id INTEGER)");
    $db->exec("INSERT INTO t (id) VALUES (1)");
    $count = $db->query("SELECT COUNT(*) FROM t")->fetchColumn();
    echo "In-memory SQLite test query: OK (count=$count)\n";
} catch (Exception $e) {
    echo "In-memory SQLite test query: FAILED - " . $e->getMessage() . "\n";
}
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
  echo -e "${GREEN}  nginx + PHP-FPM installed successfully! ??${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}PHP version:${NC}        ${PHP_VERSION}"
  echo -e "  ${CYAN}PHP-FPM service:${NC}    ${PHP_FPM_SERVICE}"
  echo -e "  ${CYAN}PHP-FPM socket:${NC}     ${PHP_FPM_SOCK}"
  echo -e "  ${CYAN}Web root:${NC}           ${WEB_ROOT}"
  echo -e "  ${CYAN}nginx site config:${NC}  /etc/nginx/sites-available/${SITE_NAME}"
  echo
  echo -e "  ${CYAN}Test page:${NC}"
  echo -e "    curl http://127.0.0.1/phptest.php"
  echo -e "    (remove this file once you've confirmed everything works:"
  echo -e "     sudo rm ${WEB_ROOT}/phptest.php)"
  echo
  echo -e "  ${CYAN}Service management:${NC}"
  echo -e "    sudo systemctl {start|stop|restart|status} nginx"
  echo -e "    sudo systemctl {start|stop|restart|status} ${PHP_FPM_SERVICE}"
  echo
  echo -e "  ${CYAN}Logs:${NC}"
  echo -e "    /var/log/nginx/${SITE_NAME}.access.log"
  echo -e "    /var/log/nginx/${SITE_NAME}.error.log"
  echo -e "    journalctl -u ${PHP_FPM_SERVICE}"
  echo
  echo -e "  ${YELLOW}Next step:${NC} write a PHP endpoint (e.g. readings.php) that opens"
  echo -e "  your SQLite database with PDO and returns JSON for the dashboard —"
  echo -e "  happy to write that for you on request."
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
  verify_sqlite_extension

  setup_web_root
  configure_nginx_site
  test_nginx_config
  enable_services

  write_test_page
  run_smoke_test

  print_summary
}

main "$@"