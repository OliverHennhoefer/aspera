#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TARGET="$(pwd)"
DRY_RUN=0
FORCE=0

usage() {
  cat <<'USAGE'
Usage: uninstall.sh [--dry-run] [--force] [TARGET]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      aspera_err "unknown option: $1"
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

ASPERA_TARGET="$(aspera_normalize_target "$TARGET")"
asp_state_file="$(aspera_state_file "$ASPERA_TARGET")"

if [ ! -f "$asp_state_file" ]; then
  aspera_info "uninstall: no state, clean no-op"
  exit 0
fi

ASPERA_POLICY_FILE="$ASPERA_TARGET/AGENTS.md"
aspera_check_managed_ancestry "$ASPERA_TARGET"
asp_state_validate "$asp_state_file"
STATE_POLICY="$(asp_state_get "$asp_state_file" policy_installed)"

DRIFT=0
for f in ".codex/agents/aspera-explorer.toml" ".codex/agents/aspera-worker.toml" ".codex/agents/aspera-verifier.toml" ".codex/agents/aspera-researcher.toml" ".codex/agents/aspera-reviewer.toml"; do
  rec="$(asp_state_get_hash "$asp_state_file" "$f")"
  cur_path="$ASPERA_TARGET/$f"
  if [ -n "$rec" ]; then
    if [ ! -f "$cur_path" ]; then
      DRIFT=1
      continue
    fi
    if [ -L "$cur_path" ]; then
      DRIFT=1
      continue
    fi
    cur="$(aspera_hash_file "$cur_path")"
    [ "$rec" = "$cur" ] || DRIFT=1
  fi
done

if [ -f "$ASPERA_POLICY_FILE" ]; then
  SCAN="$(asp_policy_scan "$ASPERA_POLICY_FILE")"
  if [ "$SCAN" = "invalid" ]; then
    DRIFT=1
    echo "[INVALID] malformed policy block in $ASPERA_POLICY_FILE"
    aspera_err "invalid policy markers in $ASPERA_POLICY_FILE"
  elif [ "$STATE_POLICY" -eq 1 ]; then
    if [ "$SCAN" != "ok" ]; then
      DRIFT=1
    else
      state_hash="$(asp_state_get "$asp_state_file" policy_hash)"
      cur_hash="$(asp_policy_hash "$ASPERA_POLICY_FILE")"
      [ "$state_hash" = "$cur_hash" ] || DRIFT=1
    fi
  elif [ "$SCAN" = "ok" ]; then
    DRIFT=1
  fi
else
  if [ "$STATE_POLICY" -eq 1 ]; then
    DRIFT=1
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$DRIFT" -eq 1 ]; then
    if [ "$FORCE" -eq 1 ]; then
      aspera_info "DRY-RUN: would create backup"
    else
      aspera_info "DRY-RUN: drift detected; force required for destructive changes"
    fi
  else
    aspera_info "DRY-RUN: no drift"
  fi
  aspera_info "DRY-RUN: no files written"
  exit 0
fi

if [ "$DRIFT" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  aspera_err "drift detected; use --force"
fi

if [ "$FORCE" -eq 1 ] && [ "$DRIFT" -eq 1 ]; then
  BACKUP_ROOT="$(aspera_prepare_backup_root "$ASPERA_TARGET")"
  aspera_info "backup created: $BACKUP_ROOT"
  for f in "${ASPERA_MANAGED_FILES[@]}" "AGENTS.md" "$ASPERA_STATE_FILE_REL"; do
    asp_backup "$ASPERA_TARGET" "$BACKUP_ROOT" "$f"
  done
fi

for f in "${ASPERA_MANAGED_FILES[@]}"; do
  rm -f "$ASPERA_TARGET/$f"
done

if [ "$STATE_POLICY" -eq 1 ] && [ -f "$ASPERA_POLICY_FILE" ] && [ "$(asp_policy_scan "$ASPERA_POLICY_FILE")" = "ok" ]; then
  asp_policy_remove_block "$ASPERA_POLICY_FILE"
fi

rm -f "$asp_state_file"
aspera_info "uninstall complete"
