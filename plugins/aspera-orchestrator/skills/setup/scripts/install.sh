#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The runtime-computed absolute path cannot be resolved by static analysis.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

TARGET="$(pwd)"
PROFILE="spark"
INSTALL_POLICY=0
DRY_RUN=0
FORCE=0

usage() {
  cat <<'USAGE'
Usage: install.sh [--profile spark|luna] [--install-policy] [--dry-run] [--force] [TARGET]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --install-policy)
      INSTALL_POLICY=1
      shift
      ;;
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
ASPERA_POLICY_FILE="$ASPERA_TARGET/AGENTS.md"
asp_state_file="$(aspera_state_file "$ASPERA_TARGET")"

aspera_validate_profile "$PROFILE"
aspera_check_managed_ancestry "$ASPERA_TARGET"
asp_preflight_models "$PROFILE"

if [ -f "$asp_state_file" ]; then
  asp_state_validate "$asp_state_file"
  HAS_STATE=1
  STATE_PROFILE="$(asp_state_get "$asp_state_file" profile)"
  STATE_POLICY="$(asp_state_get "$asp_state_file" policy_installed)"
else
  HAS_STATE=0
  STATE_PROFILE=""
  STATE_POLICY=0
fi

DESIRED_POLICY="$STATE_POLICY"
if [ "$INSTALL_POLICY" -eq 1 ]; then
  DESIRED_POLICY=1
fi

if [ -f "$ASPERA_POLICY_FILE" ]; then
  POLICY_SCAN="$(asp_policy_scan "$ASPERA_POLICY_FILE")"
  if [ "$POLICY_SCAN" = "invalid" ]; then
    aspera_err "policy markers invalid in $ASPERA_POLICY_FILE"
  fi
else
  POLICY_SCAN="missing"
fi

POLICY_APPEND=0
if [ "$DESIRED_POLICY" -eq 1 ] && [ "$POLICY_SCAN" = "missing" ] && [ -f "$ASPERA_POLICY_FILE" ]; then
  POLICY_APPEND=1
fi

if [ "$DESIRED_POLICY" -eq 1 ] && [ ! -f "$ASPERA_POLICY_SRC" ]; then
  aspera_err "policy source missing at $ASPERA_POLICY_SRC"
fi

EXPLORER_HASH="$(asp_validate_asset_file "$PROFILE" explorer "$ASPERA_MODEL_PRIMARY")"
WORKER_HASH="$(asp_validate_asset_file "$PROFILE" worker "$ASPERA_MODEL_PRIMARY")"
VERIFIER_HASH="$(asp_validate_asset_file "$PROFILE" verifier "$ASPERA_MODEL_PRIMARY")"
RESEARCHER_HASH="$(asp_validate_asset_file "$PROFILE" researcher "$ASPERA_MODEL_RESEARCHER")"
REVIEWER_HASH="$(asp_validate_asset_file "$PROFILE" reviewer "$ASPERA_MODEL_REVIEWER")"

EXPLORER_SRC="$(asp_profile_asset_path "$PROFILE" explorer)"
WORKER_SRC="$(asp_profile_asset_path "$PROFILE" worker)"
VERIFIER_SRC="$(asp_profile_asset_path "$PROFILE" verifier)"
RESEARCHER_SRC="$(asp_profile_asset_path "$PROFILE" researcher)"
REVIEWER_SRC="$(asp_profile_asset_path "$PROFILE" reviewer)"

if [ "$HAS_STATE" -eq 1 ]; then
  DRIFT=0
  STATE_CLEAN=1

  for f in \
    ".codex/agents/aspera-explorer.toml:$EXPLORER_HASH" \
    ".codex/agents/aspera-worker.toml:$WORKER_HASH" \
    ".codex/agents/aspera-verifier.toml:$VERIFIER_HASH" \
    ".codex/agents/aspera-researcher.toml:$RESEARCHER_HASH" \
    ".codex/agents/aspera-reviewer.toml:$REVIEWER_HASH";
  do
    file="${f%%:*}"
    desired_hash="${f#*:}"
    state_hash="$(asp_state_get_hash "$asp_state_file" "$file")"
    if [ "$state_hash" != "$desired_hash" ]; then
      DRIFT=1
    fi

    cur="$ASPERA_TARGET/$file"
    if [ ! -f "$cur" ] || [ -L "$cur" ]; then
      STATE_CLEAN=0
      continue
    fi
    cur_hash="$(aspera_hash_file "$cur")"
    if [ "$state_hash" != "$cur_hash" ]; then
      STATE_CLEAN=0
    fi
  done

  if [ "$STATE_POLICY" -eq 1 ]; then
    if [ "$POLICY_SCAN" != "ok" ]; then
      DRIFT=1
      STATE_CLEAN=0
    else
      STATE_POLICY_HASH="$(asp_state_get "$asp_state_file" policy_hash)"
      POLICY_HASH="$(asp_policy_hash "$ASPERA_POLICY_FILE")"
      if [ "$STATE_POLICY_HASH" != "$POLICY_HASH" ]; then
        DRIFT=1
        STATE_CLEAN=0
      fi
    fi
  else
    if [ "$POLICY_SCAN" = "ok" ]; then
      DRIFT=1
      STATE_CLEAN=0
    fi
  fi

  if [ "$STATE_CLEAN" -eq 0 ]; then
    DRIFT=1
  fi
else
  STATE_CLEAN=0
  DRIFT=0
  for f in ".codex/agents/aspera-explorer.toml" ".codex/agents/aspera-worker.toml" ".codex/agents/aspera-verifier.toml" ".codex/agents/aspera-researcher.toml" ".codex/agents/aspera-reviewer.toml"; do
    if [ -e "$ASPERA_TARGET/$f" ]; then
      DRIFT=1
    fi
  done
  if [ "$POLICY_SCAN" = "ok" ]; then
    DRIFT=1
  fi
fi

if [ "$HAS_STATE" -eq 1 ] && [ "$PROFILE" != "$STATE_PROFILE" ] && [ "$STATE_CLEAN" -eq 1 ]; then
  DRIFT=0
fi

if [ "$HAS_STATE" -eq 1 ] && [ "$PROFILE" = "$STATE_PROFILE" ] && [ "$STATE_POLICY" -eq "$DESIRED_POLICY" ] && [ "$DRIFT" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  aspera_info "install: no changes"
  exit 0
fi

if [ "$DRIFT" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  aspera_err "drift detected; use --force"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$FORCE" -eq 1 ] && [ "$DRIFT" -eq 1 ] || [ "$POLICY_APPEND" -eq 1 ]; then
    BACKUP_ROOT="$(aspera_backup_root "$ASPERA_TARGET")"
    aspera_info "DRY-RUN: would create backup at $BACKUP_ROOT"
  fi
  aspera_info "DRY-RUN: would rewrite managed files"
  if [ "$POLICY_APPEND" -eq 1 ]; then
    aspera_info "DRY-RUN: would append managed policy block to existing AGENTS.md"
  elif [ "$DESIRED_POLICY" -eq 1 ] && [ "$POLICY_SCAN" = "missing" ]; then
    aspera_info "DRY-RUN: would create AGENTS.md with managed policy block"
  elif [ "$STATE_POLICY" -eq 1 ] || [ "$DESIRED_POLICY" -eq 0 ]; then
    aspera_info "DRY-RUN: no AGENTS.md policy change"
  fi
  aspera_info "DRY-RUN: no files written"
  exit 0
fi

if [ "$FORCE" -eq 1 ] && [ "$DRIFT" -eq 1 ]; then
  BACKUP_ROOT="$(aspera_prepare_backup_root "$ASPERA_TARGET")"
  aspera_info "backup created: $BACKUP_ROOT"
  for f in "${ASPERA_MANAGED_FILES[@]}" "AGENTS.md" "$ASPERA_STATE_FILE_REL"; do
    asp_backup "$ASPERA_TARGET" "$BACKUP_ROOT" "$f"
  done
fi

if [ "$POLICY_APPEND" -eq 1 ]; then
  if [ -z "${BACKUP_ROOT:-}" ]; then
    BACKUP_ROOT="$(aspera_prepare_backup_root "$ASPERA_TARGET")"
    aspera_info "backup created: $BACKUP_ROOT"
    for f in "${ASPERA_MANAGED_FILES[@]}" "AGENTS.md" "$ASPERA_STATE_FILE_REL"; do
      asp_backup "$ASPERA_TARGET" "$BACKUP_ROOT" "$f"
    done
  fi
fi

if [ "$DESIRED_POLICY" -eq 1 ]; then
  asp_policy_insert_or_replace "$ASPERA_POLICY_FILE" "$ASPERA_POLICY_SRC"
  POLICY_STATE_HASH="$(asp_policy_hash "$ASPERA_POLICY_FILE")"
else
  POLICY_STATE_HASH=""
fi

aspera_check_managed_ancestry "$ASPERA_TARGET"
mkdir -p "$(dirname "$asp_state_file")"
aspera_atomic_write "$ASPERA_TARGET/.codex/agents/aspera-explorer.toml" < "$EXPLORER_SRC"
aspera_atomic_write "$ASPERA_TARGET/.codex/agents/aspera-worker.toml" < "$WORKER_SRC"
aspera_atomic_write "$ASPERA_TARGET/.codex/agents/aspera-verifier.toml" < "$VERIFIER_SRC"
aspera_atomic_write "$ASPERA_TARGET/.codex/agents/aspera-researcher.toml" < "$RESEARCHER_SRC"
aspera_atomic_write "$ASPERA_TARGET/.codex/agents/aspera-reviewer.toml" < "$REVIEWER_SRC"

state_tmp="${asp_state_file}.tmp.$$"
python3 - "$state_tmp" "$PROFILE" "$ASPERA_MODEL_PRIMARY" "$ASPERA_EFFORT_PRIMARY" "$ASPERA_MODEL_RESEARCHER" "$ASPERA_EFFORT_RESEARCHER" "$ASPERA_MODEL_REVIEWER" "$ASPERA_EFFORT_REVIEWER" "$EXPLORER_HASH" "$WORKER_HASH" "$VERIFIER_HASH" "$RESEARCHER_HASH" "$REVIEWER_HASH" "$DESIRED_POLICY" "$POLICY_STATE_HASH" <<'PY'
import json
import pathlib
import sys

state_file = sys.argv[1]
payload = {
    'schema_version': 1,
    'plugin': 'aspera-orchestrator',
    'plugin_version': '0.1.0',
    'profile': sys.argv[2],
    'models': {
        'primary': sys.argv[3],
        'researcher': sys.argv[5],
        'reviewer': sys.argv[7],
    },
    'efforts': {
        'primary': sys.argv[4],
        'researcher': sys.argv[6],
        'reviewer': sys.argv[8],
    },
    'managed_files': {
        '.codex/agents/aspera-explorer.toml': sys.argv[9],
        '.codex/agents/aspera-worker.toml': sys.argv[10],
        '.codex/agents/aspera-verifier.toml': sys.argv[11],
        '.codex/agents/aspera-researcher.toml': sys.argv[12],
        '.codex/agents/aspera-reviewer.toml': sys.argv[13],
    },
    'policy_installed': bool(int(sys.argv[14])),
    'policy_hash': sys.argv[15] if bool(int(sys.argv[14])) else '',
}
pathlib.Path(state_file).write_text(json.dumps(payload, indent=2) + '\n')
PY
mv "$state_tmp" "$asp_state_file"

aspera_info "install complete"
