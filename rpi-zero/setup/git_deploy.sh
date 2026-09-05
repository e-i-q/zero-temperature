#!/usr/bin/env bash
# =============================================================================
# git_deploy.sh — pulls the latest ${BRANCH} and re-runs deploy_web.sh.
#
# Sibling of rpi5/setup/git_deploy.sh. Run here by web/deploy_trigger.php
# (as root, via a narrow NOPASSWD sudo rule for www-data — see
# setup/setup_deploy_trigger.sh) when the Hive relays a deploy trigger after
# GitHub's push webhook fires — see rpi5/web/api/deploy_webhook.php for the
# overall flow. Also fine to run by hand, e.g. over SSH.
#
# Only ever fast-forwards (--ff-only) — if this checkout has diverged from
# origin (e.g. someone committed locally on this Pi), this fails loudly
# rather than rewriting history out from under you. git commands run as
# whichever user owns the checkout's .git directory (normally whoever
# cloned it), not as root, so ownership never shifts to root just because
# this got invoked that way.
#
# Only web/ needs redeploying here — python/dht22_logger.py and friends are
# already run straight out of this checkout by cron (see
# setup_dht22_logger.sh), so a plain git pull is all they ever need; there's
# nothing to restart.
#
# USAGE:
#   bash setup/git_deploy.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BRANCH="${BRANCH:-main}"
RUN_USER="${RUN_USER:-$(stat -c '%U' "${REPO_DIR}/.git")}"
# Only drop privileges via sudo -u when actually needed (invoked as root by
# deploy_trigger.php) — run directly when it's already RUN_USER, e.g. a
# manual `bash git_deploy.sh` by whoever owns the checkout, so that case
# never hits an unrelated self-sudo password prompt.
git_as() {
  if [[ "$(whoami)" == "$RUN_USER" ]]; then
    git -C "$REPO_DIR" "$@"
  else
    sudo -u "$RUN_USER" git -C "$REPO_DIR" "$@"
  fi
}

check_branch() {
  local current
  current="$(git_as rev-parse --abbrev-ref HEAD)"
  [[ "$current" == "$BRANCH" ]] \
    || error "${REPO_DIR} has '${current}' checked out, not '${BRANCH}'. Check it out by hand first: sudo -u ${RUN_USER} git -C ${REPO_DIR} checkout ${BRANCH}"
}

main() {
  check_branch

  info "Fetching ${BRANCH} into ${REPO_DIR} (as ${RUN_USER})…"
  git_as fetch origin "$BRANCH"

  local local_sha remote_sha
  local_sha="$(git_as rev-parse HEAD)"
  remote_sha="$(git_as rev-parse "origin/${BRANCH}")"

  if [[ "$local_sha" == "$remote_sha" ]]; then
    success "Already up to date (${local_sha:0:8})."
    exit 0
  fi

  info "Updating ${local_sha:0:8} -> ${remote_sha:0:8}…"
  git_as merge --ff-only "origin/${BRANCH}"

  bash "${SCRIPT_DIR}/deploy_web.sh"
  success "Deployed ${remote_sha:0:8}."
}

main "$@"
