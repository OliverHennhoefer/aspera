#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

TARGET="$(pwd)"
TARGET_SET=0

usage() {
  cat <<'USAGE'
Usage: doctor.sh [--workspace PATH] [PATH]

Runs read-only local diagnostics. It never starts Codex, spawns an agent, writes
state, or changes installation readiness.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      [ "$#" -ge 2 ] || aspera_err '--workspace requires a path'
      TARGET="$2"
      TARGET_SET=1
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    --*) aspera_err "unknown option: $1" ;;
    *)
      [ "$TARGET_SET" -eq 0 ] || aspera_err 'workspace supplied more than once'
      TARGET="$1"
      TARGET_SET=1
      shift
      ;;
  esac
done

ASPERA_TARGET="$(aspera_normalize_target "$TARGET")"
state_file="$(aspera_state_file "$ASPERA_TARGET")"
aspera_check_managed_ancestry "$ASPERA_TARGET"
if [ ! -f "$state_file" ] || [ -L "$state_file" ]; then
  aspera_err "state not found or unsafe: $state_file"
fi
asp_state_validate_supported "$state_file" || aspera_err "unsupported or corrupt Aspera state: $state_file"

schema="$(asp_state_schema "$state_file")"
if [ "$schema" != "$ASPERA_STATE_SCHEMA" ] || ! asp_state_validate "$state_file"; then
  aspera_err "state schema $schema is valid but requires migration; run 'aspera install'"
fi

asp_verify_installation "$ASPERA_TARGET" || aspera_err 'managed-file or policy verification failed'

aspera_info "Aspera $ASPERA_PLUGIN_VERSION diagnostic passed for $ASPERA_TARGET (Luna Max)."
