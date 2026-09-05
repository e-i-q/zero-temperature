#!/usr/bin/env bash
# =============================================================================
# setup_deploy_trigger.sh — Provisions web/deploy_trigger.php's shared secret
# on this Pi Zero, so the Hive can relay a "pull + redeploy" trigger here
# after GitHub's push webhook fires — see rpi5/web/api/deploy_webhook.php
# and rpi5/setup/setup_deploy_webhook.sh (run that FIRST; it prints the
# DEPLOY_TOKEN value this script needs).
#
# Writes /etc/git-deploy/token (chmod 640, root:www-data) — the SAME value
# as the Hive's own /etc/git-deploy/token. This is a fleet-wide secret, one
# token for every Pi Zero plus the Hive, like /etc/dht22-sync/token — but a
# SEPARATE value from it, since deploy and sync are different privileges.
#
# Also installs a narrow NOPASSWD sudo rule so www-data (running
# deploy_trigger.php) can run exactly setup/git_deploy.sh as root — needed
# because deploy_web.sh's own `sudo cp`/`sudo chown` calls need root, and
# there's no interactive terminal to type a password into from a web
# request.
#
# USAGE:
#   sudo DEPLOY_TOKEN=<value printed by setup_deploy_webhook.sh on the Hive> \
#     bash setup/setup_deploy_trigger.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

CONF_DIR="/etc/git-deploy"
TOKEN_FILE="${CONF_DIR}/token"
LOG_FILE="${LOG_FILE:-/var/log/git-deploy.log}"
WEB_USER="${WEB_USER:-www-data}"    # runs deploy_trigger.php (PHP-FPM pool user)
WEB_GROUP="${WEB_GROUP:-www-data}"  # group allowed to read the token file
SUDOERS_FILE="/etc/sudoers.d/git-deploy-rpi-zero"
GIT_DEPLOY_SCRIPT="${SCRIPT_DIR}/git_deploy.sh"
DEPLOY_TOKEN="${DEPLOY_TOKEN:-}"

check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_token_given() {
  [[ -n "$DEPLOY_TOKEN" ]] \
    || error "DEPLOY_TOKEN is required — copy the value printed by the Hive's setup_deploy_webhook.sh and pass it: sudo DEPLOY_TOKEN=<value> bash $0"
}

write_token() {
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$DEPLOY_TOKEN" > "$TOKEN_FILE"
  chown "root:${WEB_GROUP}" "$TOKEN_FILE"
  chmod 640 "$TOKEN_FILE"
  success "Token written: ${TOKEN_FILE} (root:${WEB_GROUP}, 640)"
}

setup_log_file() {
  touch "$LOG_FILE"
  chown "${WEB_USER}:${WEB_GROUP}" "$LOG_FILE"
  success "Log file ready: ${LOG_FILE}"
}

setup_sudoers() {
  [[ -f "$GIT_DEPLOY_SCRIPT" ]] || error "git_deploy.sh not found at ${GIT_DEPLOY_SCRIPT}."
  # realpath, not the cd+pwd path above — deploy_trigger.php resolves this
  # same file via PHP's realpath() (always physical, symlinks resolved)
  # before exec()'ing it, and sudo matches this rule by exact argv string.
  # bash's own `pwd` is logical by default, so if any ancestor directory is
  # a symlink the two could disagree; realpath here keeps them identical.
  GIT_DEPLOY_SCRIPT="$(realpath "$GIT_DEPLOY_SCRIPT")"

  local rule="${WEB_USER} ALL=(root) NOPASSWD: /usr/bin/bash ${GIT_DEPLOY_SCRIPT}"
  echo "$rule" > "${SUDOERS_FILE}.tmp"
  chmod 440 "${SUDOERS_FILE}.tmp"

  if ! visudo -c -f "${SUDOERS_FILE}.tmp" &>/dev/null; then
    rm -f "${SUDOERS_FILE}.tmp"
    error "Generated sudoers rule failed validation — not installed. Check ${GIT_DEPLOY_SCRIPT} contains no spaces/odd characters."
  fi

  mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
  success "Sudo rule installed: ${SUDOERS_FILE} (${WEB_USER} may run git_deploy.sh as root, no password)"
}

print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  Deploy trigger configured on this Pi Zero!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}web/deploy_trigger.php${NC} is deployed automatically the next time"
  echo -e "  ${CYAN}deploy_web.sh${NC} runs (it's just another file under web/)."
  echo
  echo -e "  A push to the repo's main branch now redeploys this Pi Zero within a"
  echo -e "  few seconds of the Hive receiving GitHub's webhook — nothing else to"
  echo -e "  do here. Make sure this sensor's row in the Hive database has the"
  echo -e "  right ip_address (dht22_logger.py keeps that current on its own; see"
  echo -e "  rpi5/web/api/deploy_webhook.php's docstring), or it falls back to"
  echo -e "  mDNS (<name>.local)."
  echo
  echo -e "  ${CYAN}Tail deploy activity:${NC}"
  echo -e "    tail -f ${LOG_FILE}"
  echo
  echo -e "  ${CYAN}Test without waiting for a push:${NC}"
  echo -e "    bash ${GIT_DEPLOY_SCRIPT}"
  echo
  echo -e "  ${CYAN}Test the trigger endpoint itself:${NC}"
  echo -e "    curl -X POST -H \"X-Deploy-Token: ${DEPLOY_TOKEN}\" http://127.0.0.1/deploy_trigger.php"
  echo
}

main() {
  check_root
  check_token_given

  write_token
  setup_log_file
  setup_sudoers

  print_summary
}

main "$@"
