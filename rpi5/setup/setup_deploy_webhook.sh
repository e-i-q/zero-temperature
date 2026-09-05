#!/usr/bin/env bash
# =============================================================================
# setup_deploy_webhook.sh — Provisions push-to-deploy on the Hive: GitHub
# calls web/api/deploy_webhook.php on every push, which pulls + redeploys
# this Pi, then relays a deploy trigger to every registered Pi Zero (see
# rpi-zero/setup/setup_deploy_trigger.sh, which must be run on each of
# them with the DEPLOY_TOKEN this script prints).
#
# The Hive is the only Pi meant to be reachable from the internet (one
# forwarded port on your router, pointed at this Pi's HTTP port) — GitHub
# can only ever reach it, never a Pi Zero directly, which is why the fan-out
# to Pi Zeros happens as a relay from here over the LAN instead.
#
# Writes three files, all under /etc/git-deploy/ (chmod 640, root:www-data
# — outside the web root, so deploy_web.sh re-syncing web/ can never touch
# or expose them):
#   webhook_secret     known only to GitHub and this Pi — verifies the
#                      X-Hub-Signature-256 GitHub sends on every webhook
#                      call. Never leaves this Pi except into GitHub's
#                      webhook config.
#   token              the fleet-wide deploy-trigger secret shared with
#                      every Pi Zero (like /etc/dht22-sync/token, but a
#                      separate value — deploy and sync are different
#                      privileges).
#   git_deploy_script  not a secret — the resolved absolute path to this
#                      checkout's setup/git_deploy.sh, for deploy_webhook.php
#                      to read at request time (it runs from a copy of
#                      web/ under the nginx web root, so it can't find this
#                      script by walking up from its own location).
#
# Also installs a narrow NOPASSWD sudo rule so www-data (running
# deploy_webhook.php) can run exactly setup/git_deploy.sh as root — needed
# because deploy_web.sh's own `sudo cp`/`sudo chown` calls need root, and
# there's no interactive terminal to type a password into from a webhook.
#
# USAGE:
#   sudo bash setup/setup_deploy_webhook.sh
#   sudo WEBHOOK_SECRET=<value> DEPLOY_TOKEN=<value> bash setup/setup_deploy_webhook.sh
#     (reuse existing secrets, e.g. when re-running after moving the
#     checkout — both are auto-generated if not given AND not already
#     provisioned; an existing secret is otherwise left untouched so a
#     routine re-run can't silently break GitHub's webhook config or the
#     Pi Zero fleet's tokens out from under you)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONF_DIR="/etc/git-deploy"
WEBHOOK_SECRET_FILE="${CONF_DIR}/webhook_secret"
TOKEN_FILE="${CONF_DIR}/token"
GIT_DEPLOY_SCRIPT_PATH_FILE="${CONF_DIR}/git_deploy_script"
LOG_FILE="${LOG_FILE:-/var/log/git-deploy.log}"
WEB_USER="${WEB_USER:-www-data}"    # runs deploy_webhook.php (PHP-FPM pool user)
WEB_GROUP="${WEB_GROUP:-www-data}"  # group allowed to read the secrets below
SUDOERS_FILE="/etc/sudoers.d/git-deploy-rpi5"
GIT_DEPLOY_SCRIPT="${SCRIPT_DIR}/git_deploy.sh"
RUN_USER="${RUN_USER:-$(stat -c '%U' "${REPO_DIR}/.git")}"  # owns the checkout — see git_deploy.sh

WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
DEPLOY_TOKEN="${DEPLOY_TOKEN:-}"

# =============================================================================
banner() {
  echo -e "${CYAN}"
  echo "+------------------------------------------------------+"
  echo "|   Push-to-Deploy Webhook Setup — Raspberry Pi 5      |"
  echo "+------------------------------------------------------+"
  echo -e "${NC}"
  info "Repo directory : ${REPO_DIR}"
  info "Config dir     : ${CONF_DIR}"
  echo
}

check_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run as root:  sudo bash $0"
}

check_sudo_available() {
  command -v sudo &>/dev/null || error "sudo not found — required so www-data can run git_deploy.sh as root."
}

# write_secret <file> <value-from-env> <label>
# Echoes the value that ends up in the file (existing, given, or freshly
# generated) so callers can print it in the summary.
write_secret() {
  local file="$1" given="$2" label="$3" value

  mkdir -p "$CONF_DIR"

  if [[ -n "$given" ]]; then
    value="$given"
    info "Using provided ${label}."
  elif [[ -f "$file" ]]; then
    value="$(trim_file "$file")"
    info "${label} already provisioned — leaving it as-is (pass it explicitly to change it)."
  else
    value="$(openssl rand -hex 32)"
    info "Generated a new random ${label}."
  fi

  printf '%s\n' "$value" > "$file"
  chown "root:${WEB_GROUP}" "$file"
  chmod 640 "$file"
  echo "$value"
}

trim_file() {
  local content
  content="$(cat "$1")"
  printf '%s' "${content//$'\n'/}"
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
# regardless of the script file's own permissions. deploy_webhook.php's
# is_file() check then fails exactly as if git_deploy.sh didn't exist.
# Discovered the hard way: fixed manually once, then it recurred on every
# new checkout, so it belongs here instead of a one-off `chmod`.
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
  # realpath, not the cd+pwd path above — deploy_webhook.php exec()'s this
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

  # deploy_webhook.php runs from a *copy* of web/ under the nginx web root
  # (see deploy_web.sh), not from this checkout — so it can't find
  # git_deploy.sh by walking up from its own __DIR__ at request time. Record
  # the resolved path here instead, next to the secrets above, so it reads
  # the same canonical string this sudoers rule was written for.
  printf '%s\n' "$GIT_DEPLOY_SCRIPT" > "$GIT_DEPLOY_SCRIPT_PATH_FILE"
  chown "root:${WEB_GROUP}" "$GIT_DEPLOY_SCRIPT_PATH_FILE"
  chmod 640 "$GIT_DEPLOY_SCRIPT_PATH_FILE"
  success "Recorded git_deploy.sh path for deploy_webhook.php: ${GIT_DEPLOY_SCRIPT_PATH_FILE}"
}

print_summary() {
  echo
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo -e "${GREEN}  Push-to-deploy webhook configured on the Hive!${NC}"
  echo -e "${GREEN}--------------------------------------------------------${NC}"
  echo
  echo -e "  ${CYAN}1. Forward one port on your router to this Pi's HTTP port (80),${NC}"
  echo -e "  ${CYAN}   then add a webhook in GitHub — repo Settings > Webhooks > Add webhook:${NC}"
  echo
  echo -e "      Payload URL : http://<your-public-ip-or-ddns-name>/api/deploy_webhook.php"
  echo -e "      Content type: application/json"
  echo -e "      Secret      : ${WEBHOOK_SECRET_OUT}"
  echo -e "      Events      : Just the push event"
  echo
  echo -e "  GitHub will send a 'ping' first — deploy_webhook.php answers that"
  echo -e "  with 200 OK without deploying anything, so you can confirm delivery"
  echo -e "  works before the first real push."
  echo
  echo -e "  ${YELLOW}2. Provision this SAME deploy token on EVERY Pi Zero${NC}"
  echo -e "  (this is a DIFFERENT secret from the webhook secret above — it's"
  echo -e "  what lets the Hive relay a deploy trigger to each Pi Zero):"
  echo
  echo -e "      sudo DEPLOY_TOKEN=${DEPLOY_TOKEN_OUT} bash setup/setup_deploy_trigger.sh   # on each Pi Zero"
  echo
  echo -e "  ${CYAN}Tail deploy activity:${NC}"
  echo -e "    tail -f ${LOG_FILE}"
  echo
  echo -e "  ${CYAN}Test without waiting for a push:${NC}"
  echo -e "    bash ${GIT_DEPLOY_SCRIPT}"
  echo
}

# =============================================================================
main() {
  banner
  check_root
  check_sudo_available

  WEBHOOK_SECRET_OUT="$(write_secret "$WEBHOOK_SECRET_FILE" "$WEBHOOK_SECRET" "webhook secret")"
  DEPLOY_TOKEN_OUT="$(write_secret "$TOKEN_FILE" "$DEPLOY_TOKEN" "deploy token")"
  setup_log_file
  setup_sudoers

  print_summary
}

main "$@"
