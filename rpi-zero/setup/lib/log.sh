#!/usr/bin/env bash
# =============================================================================
# lib/log.sh — shared colored logging + quiet-by-default command output for
# this project's setup scripts.
#
# Source it near the top of a script (after `set -euo pipefail`):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/log.sh"
#
# Provides:
#   info/success/warn/error  — colored progress messages
#   run_quiet <command...>   — runs a command, hiding its own output unless
#                              VERBOSE=1 (set via -v/--verbose on the command
#                              line, or by exporting VERBOSE=1) or it fails
# =============================================================================

# -- Colours ------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# -- Verbosity ------------------------------------------------------------
# Default: noisy commands (apt-get, pip, ...) run silently — the caller
# prints its own one-line info() message instead. -v/--verbose lets the
# command's real output through, e.g.:
#   sudo bash setup/setup_nginx_php.sh --verbose
VERBOSE="${VERBOSE:-0}"
for _log_sh_arg in "$@"; do
  case "$_log_sh_arg" in
    -v|--verbose) VERBOSE=1 ;;
  esac
done
unset _log_sh_arg

# run_quiet <command> [args...]
# Suppresses a command's stdout/stderr unless VERBOSE=1, in which case it
# passes straight through. On failure the captured output is always shown,
# followed by error() (which exits).
run_quiet() {
  if [[ "$VERBOSE" == "1" ]]; then
    "$@"
    return
  fi

  local output
  if ! output="$("$@" 2>&1)"; then
    echo "$output" >&2
    error "Command failed: $*"
  fi
}
