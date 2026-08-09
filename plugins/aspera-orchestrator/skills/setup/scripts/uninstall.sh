#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

TARGET="$(pwd)"
TARGET_SET=0
DRY_RUN=0
FORCE=0

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--workspace PATH] [--dry-run] [--force] [PATH]
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
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
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
if [ ! -e "$state_file" ] && [ ! -L "$state_file" ]; then
  aspera_info "Aspera is not installed in $ASPERA_TARGET."
  exit 0
fi

aspera_check_managed_ancestry "$ASPERA_TARGET"
if [ ! -f "$state_file" ] || [ -L "$state_file" ]; then
  aspera_err "state path is unsafe: $state_file"
fi
asp_state_validate_supported "$state_file" || aspera_err "unsupported or corrupt Aspera state: $state_file"

STATE_POLICY="$(asp_state_get "$state_file" policy_installed)"
ASPERA_POLICY_FILE="$ASPERA_TARGET/$ASPERA_AGENTS_FILE_REL"
POLICY_SCAN="$(asp_policy_scan "$ASPERA_POLICY_FILE")"
DRIFT=0
while IFS= read -r rel; do
  recorded="$(asp_state_get_hash "$state_file" "$rel")"
  current="$ASPERA_TARGET/$rel"
  if [ ! -f "$current" ] || [ -L "$current" ] || [ "$(aspera_hash_file "$current")" != "$recorded" ]; then
    DRIFT=1
  fi
done < <(asp_state_managed_files "$state_file")
if [ "$STATE_POLICY" -eq 1 ]; then
  if [ "$POLICY_SCAN" != 'ok' ] || [ "$(asp_policy_hash "$ASPERA_POLICY_FILE")" != "$(asp_state_get "$state_file" policy_hash)" ]; then
    DRIFT=1
  fi
elif [ "$POLICY_SCAN" = 'ok' ]; then
  DRIFT=1
fi

if [ "$DRIFT" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  aspera_err 'managed-file drift was detected; inspect it before rerunning with --force'
fi
if [ "$DRY_RUN" -eq 1 ]; then
  aspera_info "DRY-RUN: would uninstall Aspera from $ASPERA_TARGET"
  [ "$DRIFT" -eq 0 ] || aspera_info 'DRY-RUN: would back up approved drift first'
  aspera_info 'DRY-RUN: no files written'
  exit 0
fi

BACKUP_ROOT="$(aspera_prepare_backup_root "$ASPERA_TARGET")"
while IFS= read -r rel; do
  asp_backup "$ASPERA_TARGET" "$BACKUP_ROOT" "$rel"
done < <(asp_state_managed_files "$state_file")
asp_backup "$ASPERA_TARGET" "$BACKUP_ROOT" "$ASPERA_AGENTS_FILE_REL"
asp_backup "$ASPERA_TARGET" "$BACKUP_ROOT" "$ASPERA_STATE_FILE_REL"
aspera_info "backup created: $BACKUP_ROOT"

STAGE_ROOT="$ASPERA_TARGET/.codex/aspera-orchestrator/.uninstall-stage.$$.$RANDOM"
mkdir -p "$STAGE_ROOT"
if [ "$STATE_POLICY" -eq 1 ] && [ "$POLICY_SCAN" = 'ok' ]; then
  asp_render_policy_without_block "$ASPERA_POLICY_FILE" "$STAGE_ROOT/AGENTS.md"
fi

ROLLBACK_ACTIVE=1
rollback_uninstall() {
  local rel
  [ "$ROLLBACK_ACTIVE" -eq 1 ] || return 0
  while IFS= read -r rel; do
    if [ -f "$BACKUP_ROOT/$rel" ]; then
      mkdir -p "$(dirname "$ASPERA_TARGET/$rel")"
      cp -p "$BACKUP_ROOT/$rel" "$ASPERA_TARGET/$rel"
    fi
  done < <(asp_state_managed_files "$BACKUP_ROOT/$ASPERA_STATE_FILE_REL")
  [ ! -f "$BACKUP_ROOT/$ASPERA_AGENTS_FILE_REL" ] || cp -p "$BACKUP_ROOT/$ASPERA_AGENTS_FILE_REL" "$ASPERA_POLICY_FILE"
  cp -p "$BACKUP_ROOT/$ASPERA_STATE_FILE_REL" "$state_file"
}
cleanup_uninstall() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rollback_uninstall || true
    aspera_info 'uninstall rolled back after failure'
  fi
  rm -rf "$STAGE_ROOT"
  exit "$rc"
}
trap cleanup_uninstall EXIT INT TERM

while IFS= read -r rel; do
  rm -f "$ASPERA_TARGET/$rel"
done < <(asp_state_managed_files "$state_file")
if [ "$STATE_POLICY" -eq 1 ] && [ "$POLICY_SCAN" = 'ok' ]; then
  if [ -s "$STAGE_ROOT/AGENTS.md" ]; then
    mv -f "$STAGE_ROOT/AGENTS.md" "$ASPERA_POLICY_FILE"
  else
    rm -f "$ASPERA_POLICY_FILE"
  fi
fi
rm -f "$state_file"
ROLLBACK_ACTIVE=0
trap - EXIT INT TERM
rm -rf "$STAGE_ROOT"
aspera_info "Uninstalled Aspera from $ASPERA_TARGET. Backup retained at $BACKUP_ROOT"
