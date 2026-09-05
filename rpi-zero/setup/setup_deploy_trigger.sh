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
# Also writes /etc/git-deploy/git_deploy_script (same permissions) — not a
# secret, the resolved absolute path to this checkout's setup/git_deploy.sh,
# for deploy_trigger.php to read at request time (it runs from a copy of
# web/ under the nginx web root, so it can't find this script by walking up
# from its own location).
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
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONF_DIR="/etc/git-deploy"
TOKEN_FILE="${CONF_DIR}/token"
GIT_DEPLOY_SCRIPT_PATH_FILE="${CONF_DIR}/git_deploy_script"
LOG_FILE="${LOG_FILE:-/var/log/git-deploy.log}"
WEB_USER="${WEB_USER:-www-data}"    # runs deploy_trigger.php (PHP-FPM pool user)
WEB_GROUP="${WEB_GROUP:-www-data}"  # group allowed to read the token file
SUDOERS_FILE="/etc/sudoers.d/git-deploy-rpi-zero"
GIT_DEPLOY_SCRIPT="${SCRIPT_DIR}/git_deploy.sh"
RUN_USER="${RUN_USER:-$(stat -c '%U' "${REPO_DIR}/.git")}"  # owns the checkout — see git_deploy.sh
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

# grant_checkout_traversal — let WEB_USER (www-data) reach GIT_DEPLOY_SCRIPT
# even when the checkout lives under RUN_USER's home directory.
#
# Home directories default to mode 750 on Debian/Raspberry Pi OS — owner
# rwx, group/other nothing — so www-data can't even traverse *into* it,
# regardless of the script file's own permissions. deploy_trigger.php's
# is_file() check then fails exactly as if git_deploy.sh didn't exist.
# Discovered the hard way: fixed manually once, then it recurred on every
# new Pi Zero, so it belongs here instead of a one-off `chmod`.
#
# Grants execute (traversal only — not read/listing) on every ancestor
# directory of GIT_DEPLOY_SCRIPT that RUN_USER owns, stopping the moment
# an ancestor belongs to someone else (e.g. /home, owned by root) — so
# this never reaches outside the checkout owner's own tree.
#
# Sets BOTH group and "other" bits, not just "other": if WEB_USER is ever
# a member of RUN_USER's primary group (it was, on one Pi Zero in the
# field — added for an unrelated reason), the kernel's permission check
# uses whichever bucket matches first, so granting only one of the two
# isn't reliable.
grant_checkout_traversal() {
  local dir parent
  dir="$(dirname "$GIT_DEPLOY_SCRIPT")"
  while [[ "$(stat -c '%U' "$dir")" == "$RUN_USER" ]]; do
    chmod g+x,o+x "$dir"
    parent="$(dirname "$dir")"
    [[ "$parent" == "$dir" ]] && break
    dir="$parent"
  done
  success "Ensured ${WEB_USER} can traverse to ${GIT_DEPLOY_SCRIPT}."
}

setup_sudoers() {
  [[ -f "$GIT_DEPLOY_SCRIPT" ]] || error "git_deploy.sh not found at ${GIT_DEPLOY_SCRIPT}."
  # realpath, not the cd+pwd path above — deploy_trigger.php exec()'s this
  # same path (read back from GIT_DEPLOY_SCRIPT_PATH_FILE below, not
  # recomputed from its own location — see that file's docstring for why),
  # and sudo matches this rule by exact argv string. bash's own `pwd` is
  # logical by default, so if any ancestor directory is a symlink the two
  # could disagree; realpath here keeps them identical.
  GIT_DEPLOY_SCRIPT="$(realpath "$GIT_DEPLOY_SCRIPT")"
  grant_checkout_traversal

  local rule="${WEB_USER} ALL=(root) NOPASSWD: /usr/bin/bash ${GIT_DEPLOY_SCRIPT}"
  echo "$rule" > "${SUDOERS_FILE}.tmp"
  chmod 440 "${SUDOERS_FILE}.tmp"

  if ! visudo -c -f "${SUDOERS_FILE}.tmp" &>/dev/null; then
    rm -f "${SUDOERS_FILE}.tmp"
    error "Generated sudoers rule failed validation — not installed. Check ${GIT_DEPLOY_SCRIPT} contains no spaces/odd characters."
  fi

  mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
  success "Sudo rule installed: ${SUDOERS_FILE} (${WEB_USER} may run git_deploy.sh as root, no password)"

  # deploy_trigger.php runs from a *copy* of web/ under the nginx web root
  # (see deploy_web.sh), not from this checkout — so it can't find
  # git_deploy.sh by walking up from its own __DIR__ at request time. Record
  # the resolved path here instead, next to the token above, so it reads
  # the same canonical string this sudoers rule was written for.
  printf '%s\n' "$GIT_DEPLOY_SCRIPT" > "$GIT_DEPLOY_SCRIPT_PATH_FILE"
  chown "root:${WEB_GROUP}" "$GIT_DEPLOY_SCRIPT_PATH_FILE"
  chmod 640 "$GIT_DEPLOY_SCRIPT_PATH_FILE"
  success "Recorded git_deploy.sh path for deploy_trigger.php: ${GIT_DEPLOY_SCRIPT_PATH_FILE}"
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
