#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

TARGET="$(pwd)"
TARGET_SET=0
PROFILE=''
POLICY_MODE='preserve'
DRY_RUN=0
FORCE=0

usage() {
  cat <<'USAGE'
Usage: install.sh [--workspace PATH] [--profile spark|luna] [--no-policy] [--dry-run] [--force] [PATH]

Installs or updates an Aspera project in one idempotent operation. Fresh installs
default to the Spark profile with managed project policy. Existing installs keep
their profile and policy unless an explicit option changes them.
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
    --profile)
      [ "$#" -ge 2 ] || aspera_err '--profile requires spark or luna'
      PROFILE="$2"
      shift 2
      ;;
    --install-policy)
      POLICY_MODE='install'
      shift
      ;;
    --no-policy)
      POLICY_MODE='remove'
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
ASPERA_POLICY_FILE="$ASPERA_TARGET/$ASPERA_AGENTS_FILE_REL"
asp_state_file="$(aspera_state_file "$ASPERA_TARGET")"
aspera_check_managed_ancestry "$ASPERA_TARGET"

HAS_STATE=0
STATE_SCHEMA=''
STATE_PROFILE=''
STATE_POLICY=0
if [ -e "$asp_state_file" ] || [ -L "$asp_state_file" ]; then
  [ -f "$asp_state_file" ] && [ ! -L "$asp_state_file" ] || aspera_err "state path is unsafe: $asp_state_file"
  asp_state_validate_supported "$asp_state_file" || aspera_err "unsupported or corrupt Aspera state: $asp_state_file"
  HAS_STATE=1
  STATE_SCHEMA="$(asp_state_schema "$asp_state_file")"
  STATE_PROFILE="$(asp_state_get "$asp_state_file" profile)"
  STATE_POLICY="$(asp_state_get "$asp_state_file" policy_installed)"
fi

if [ -z "$PROFILE" ]; then
  if [ "$HAS_STATE" -eq 1 ]; then
    PROFILE="$STATE_PROFILE"
  else
    PROFILE='spark'
  fi
fi
aspera_validate_profile "$PROFILE"
asp_set_profile_contract "$PROFILE"

if [ "$HAS_STATE" -eq 1 ]; then
  DESIRED_POLICY="$STATE_POLICY"
else
  DESIRED_POLICY=1
fi
case "$POLICY_MODE" in
  install) DESIRED_POLICY=1 ;;
  remove) DESIRED_POLICY=0 ;;
esac

POLICY_SCAN="$(asp_policy_scan "$ASPERA_POLICY_FILE")"
[ "$POLICY_SCAN" != 'invalid' ] || aspera_err "policy markers are invalid in $ASPERA_POLICY_FILE"
if [ "$DESIRED_POLICY" -eq 1 ]; then
  [ -f "$ASPERA_POLICY_SRC" ] && [ ! -L "$ASPERA_POLICY_SRC" ] || aspera_err "policy source is missing or unsafe: $ASPERA_POLICY_SRC"
fi

EXPLORER_SRC="$(asp_profile_asset_path "$PROFILE" explorer)"
WORKER_SRC="$(asp_profile_asset_path "$PROFILE" worker)"
VERIFIER_SRC="$(asp_profile_asset_path "$PROFILE" verifier)"
RESEARCHER_SRC="$(asp_profile_asset_path "$PROFILE" researcher)"
REVIEWER_SRC="$(asp_profile_asset_path "$PROFILE" reviewer)"
EXPLORER_HASH="$(asp_validate_asset_file "$PROFILE" explorer "$ASPERA_MODEL_PRIMARY")"
WORKER_HASH="$(asp_validate_asset_file "$PROFILE" worker "$ASPERA_MODEL_PRIMARY")"
VERIFIER_HASH="$(asp_validate_asset_file "$PROFILE" verifier "$ASPERA_MODEL_PRIMARY")"
RESEARCHER_HASH="$(asp_validate_asset_file "$PROFILE" researcher "$ASPERA_MODEL_RESEARCHER")"
REVIEWER_HASH="$(asp_validate_asset_file "$PROFILE" reviewer "$ASPERA_MODEL_REVIEWER")"
GUARD_HASH="$(asp_validate_guard_asset)"

DRIFT=0
if [ "$HAS_STATE" -eq 1 ]; then
  while IFS= read -r rel; do
    recorded="$(asp_state_get_hash "$asp_state_file" "$rel")"
    current_path="$ASPERA_TARGET/$rel"
    if [ ! -f "$current_path" ] || [ -L "$current_path" ] || [ "$(aspera_hash_file "$current_path")" != "$recorded" ]; then
      DRIFT=1
    fi
  done < <(asp_state_managed_files "$asp_state_file")

  if [ "$STATE_SCHEMA" = '1' ] && [ -e "$ASPERA_TARGET/.codex/aspera-orchestrator/worker_guard.py" ]; then
    DRIFT=1
  fi
  if [ "$STATE_POLICY" -eq 1 ]; then
    if [ "$POLICY_SCAN" != 'ok' ] || [ "$(asp_policy_hash "$ASPERA_POLICY_FILE")" != "$(asp_state_get "$asp_state_file" policy_hash)" ]; then
      DRIFT=1
    fi
  elif [ "$POLICY_SCAN" = 'ok' ]; then
    DRIFT=1
  fi
else
  for rel in "${ASPERA_MANAGED_FILES[@]}"; do
    if [ -e "$ASPERA_TARGET/$rel" ] || [ -L "$ASPERA_TARGET/$rel" ]; then
      DRIFT=1
    fi
  done
  [ "$POLICY_SCAN" != 'ok' ] || DRIFT=1
fi

if [ "$DRIFT" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  aspera_err 'managed-file drift or an unmanaged conflict was detected; inspect it before rerunning with --force'
fi

DESIRED_POLICY_HASH=''
if [ "$DESIRED_POLICY" -eq 1 ]; then
  DESIRED_POLICY_HASH="$(asp_policy_source_hash "$ASPERA_POLICY_SRC")"
fi

UPDATE_NEEDED=0
if [ "$HAS_STATE" -eq 0 ] || [ "$STATE_SCHEMA" != "$ASPERA_STATE_SCHEMA" ] || [ "$STATE_PROFILE" != "$PROFILE" ] || [ "$STATE_POLICY" -ne "$DESIRED_POLICY" ]; then
  UPDATE_NEEDED=1
fi
for pair in \
  ".codex/agents/aspera-explorer.toml:$EXPLORER_HASH" \
  ".codex/agents/aspera-worker.toml:$WORKER_HASH" \
  ".codex/agents/aspera-verifier.toml:$VERIFIER_HASH" \
  ".codex/agents/aspera-researcher.toml:$RESEARCHER_HASH" \
  ".codex/agents/aspera-reviewer.toml:$REVIEWER_HASH" \
  ".codex/aspera-orchestrator/worker_guard.py:$GUARD_HASH"; do
  rel="${pair%%:*}"
  desired_hash="${pair#*:}"
  if [ "$HAS_STATE" -eq 0 ] || [ "$(asp_state_get_hash "$asp_state_file" "$rel")" != "$desired_hash" ]; then
    UPDATE_NEEDED=1
  fi
done
if [ "$DESIRED_POLICY" -eq 1 ] && { [ "$POLICY_SCAN" != 'ok' ] || [ "$(asp_policy_hash "$ASPERA_POLICY_FILE")" != "$DESIRED_POLICY_HASH" ]; }; then
  UPDATE_NEEDED=1
fi
if [ "$DESIRED_POLICY" -eq 0 ] && [ "$POLICY_SCAN" = 'ok' ]; then
  UPDATE_NEEDED=1
fi
if [ "$DRIFT" -eq 1 ]; then
  UPDATE_NEEDED=1
fi

if [ "$UPDATE_NEEDED" -eq 0 ]; then
  asp_verify_installation "$ASPERA_TARGET" || aspera_err 'post-install verification failed for the existing installation'
  aspera_info "Aspera $ASPERA_PLUGIN_VERSION is already current for $ASPERA_TARGET ($PROFILE)."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  aspera_info "DRY-RUN: would reconcile Aspera $ASPERA_PLUGIN_VERSION for $ASPERA_TARGET ($PROFILE, policy=$DESIRED_POLICY)"
  [ "$STATE_SCHEMA" != '' ] && [ "$STATE_SCHEMA" != "$ASPERA_STATE_SCHEMA" ] && aspera_info "DRY-RUN: would migrate state schema $STATE_SCHEMA to $ASPERA_STATE_SCHEMA"
  [ "$DRIFT" -eq 0 ] || aspera_info 'DRY-RUN: would back up and replace approved drift'
  aspera_info 'DRY-RUN: no files written'
  exit 0
fi

STAGE_PARENT="$ASPERA_TARGET/.codex/aspera-orchestrator"
mkdir -p "$STAGE_PARENT"
aspera_check_managed_ancestry "$ASPERA_TARGET"
STAGE_ROOT="$STAGE_PARENT/.install-stage.$$.$RANDOM"
[ ! -e "$STAGE_ROOT" ] || aspera_err "staging path already exists: $STAGE_ROOT"
umask 077
mkdir -p "$STAGE_ROOT/files" "$STAGE_ROOT/rollback"

TRANSACTION_ACTIVE=0
rollback_install() {
  local rel
  [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0
  while IFS= read -r rel; do
    if [ -f "$STAGE_ROOT/rollback/$rel" ]; then
      mkdir -p "$(dirname "$ASPERA_TARGET/$rel")"
      cp -p "$STAGE_ROOT/rollback/$rel" "$ASPERA_TARGET/$rel"
    else
      rm -f "$ASPERA_TARGET/$rel"
    fi
  done < "$STAGE_ROOT/rollback-paths"
  aspera_info 'install rolled back after failure'
}
cleanup_install() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rollback_install || true
  fi
  rm -rf "$STAGE_ROOT"
  exit "$rc"
}
trap cleanup_install EXIT INT TERM

for rel in "${ASPERA_MANAGED_FILES[@]}" "$ASPERA_AGENTS_FILE_REL" "$ASPERA_STATE_FILE_REL"; do
  printf '%s\n' "$rel" >> "$STAGE_ROOT/rollback-paths"
  if [ -e "$ASPERA_TARGET/$rel" ]; then
    [ -f "$ASPERA_TARGET/$rel" ] && [ ! -L "$ASPERA_TARGET/$rel" ] || aspera_err "managed destination is unsafe: $ASPERA_TARGET/$rel"
    mkdir -p "$(dirname "$STAGE_ROOT/rollback/$rel")"
    cp -p "$ASPERA_TARGET/$rel" "$STAGE_ROOT/rollback/$rel"
  fi
done

aspera_capture_destination_snapshot "$ASPERA_TARGET" "$STAGE_ROOT/snapshot-before"

stage_copy() {
  local source="$1"
  local rel="$2"
  mkdir -p "$(dirname "$STAGE_ROOT/files/$rel")"
  cp "$source" "$STAGE_ROOT/files/$rel"
}
stage_copy "$EXPLORER_SRC" '.codex/agents/aspera-explorer.toml'
stage_copy "$WORKER_SRC" '.codex/agents/aspera-worker.toml'
stage_copy "$VERIFIER_SRC" '.codex/agents/aspera-verifier.toml'
stage_copy "$RESEARCHER_SRC" '.codex/agents/aspera-researcher.toml'
stage_copy "$REVIEWER_SRC" '.codex/agents/aspera-reviewer.toml'
stage_copy "$ASPERA_GUARD_SRC" '.codex/aspera-orchestrator/worker_guard.py'

if [ "$DESIRED_POLICY" -eq 1 ]; then
  asp_render_policy "$ASPERA_POLICY_FILE" "$ASPERA_POLICY_SRC" "$STAGE_ROOT/files/$ASPERA_AGENTS_FILE_REL"
  POLICY_STATE_HASH="$(asp_policy_hash "$STAGE_ROOT/files/$ASPERA_AGENTS_FILE_REL")"
else
  POLICY_STATE_HASH=''
  asp_render_policy_without_block "$ASPERA_POLICY_FILE" "$STAGE_ROOT/files/$ASPERA_AGENTS_FILE_REL"
fi

mkdir -p "$(dirname "$STAGE_ROOT/files/$ASPERA_STATE_FILE_REL")"
python3 - "$STAGE_ROOT/files/$ASPERA_STATE_FILE_REL" "$PROFILE" "$EXPLORER_HASH" "$WORKER_HASH" "$VERIFIER_HASH" "$RESEARCHER_HASH" "$REVIEWER_HASH" "$GUARD_HASH" "$DESIRED_POLICY" "$POLICY_STATE_HASH" <<'PY'
import json
import pathlib
import sys
target = pathlib.Path(sys.argv[1])
payload = {
    'schema_version': 3,
    'plugin': 'aspera-orchestrator',
    'plugin_version': '0.3.0',
    'profile': sys.argv[2],
    'managed_files': {
        '.codex/agents/aspera-explorer.toml': sys.argv[3],
        '.codex/agents/aspera-worker.toml': sys.argv[4],
        '.codex/agents/aspera-verifier.toml': sys.argv[5],
        '.codex/agents/aspera-researcher.toml': sys.argv[6],
        '.codex/agents/aspera-reviewer.toml': sys.argv[7],
        '.codex/aspera-orchestrator/worker_guard.py': sys.argv[8],
    },
    'guard_hash': sys.argv[8],
    'policy_installed': bool(int(sys.argv[9])),
    'policy_hash': sys.argv[10] if bool(int(sys.argv[9])) else '',
}
target.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
PY
asp_state_validate "$STAGE_ROOT/files/$ASPERA_STATE_FILE_REL" || aspera_err 'staged state failed schema validation'

if [ "$HAS_STATE" -eq 1 ] || [ "$DRIFT" -eq 1 ] || [ -e "$ASPERA_POLICY_FILE" ]; then
  BACKUP_ROOT="$(aspera_prepare_backup_root "$ASPERA_TARGET")"
  for rel in "${ASPERA_MANAGED_FILES[@]}" "$ASPERA_AGENTS_FILE_REL" "$ASPERA_STATE_FILE_REL"; do
    asp_backup "$ASPERA_TARGET" "$BACKUP_ROOT" "$rel"
  done
  aspera_info "backup created: $BACKUP_ROOT"
fi

aspera_check_managed_ancestry "$ASPERA_TARGET"
aspera_capture_destination_snapshot "$ASPERA_TARGET" "$STAGE_ROOT/snapshot-after"
cmp -s "$STAGE_ROOT/snapshot-before" "$STAGE_ROOT/snapshot-after" || aspera_err 'managed destinations changed during preflight; no files were committed'

TRANSACTION_ACTIVE=1
COMMIT_COUNT=0
commit_file() {
  local rel="$1"
  mkdir -p "$(dirname "$ASPERA_TARGET/$rel")"
  mv -f "$STAGE_ROOT/files/$rel" "$ASPERA_TARGET/$rel"
  COMMIT_COUNT=$((COMMIT_COUNT + 1))
  if [ -n "${ASPERA_INSTALL_FAIL_AFTER:-}" ] && [ "$COMMIT_COUNT" -eq "$ASPERA_INSTALL_FAIL_AFTER" ]; then
    aspera_err "injected install failure after commit $COMMIT_COUNT"
  fi
}

for rel in "${ASPERA_MANAGED_FILES[@]}"; do
  commit_file "$rel"
done
if [ -s "$STAGE_ROOT/files/$ASPERA_AGENTS_FILE_REL" ]; then
  commit_file "$ASPERA_AGENTS_FILE_REL"
else
  rm -f "$ASPERA_TARGET/$ASPERA_AGENTS_FILE_REL"
  COMMIT_COUNT=$((COMMIT_COUNT + 1))
fi
commit_file "$ASPERA_STATE_FILE_REL"

asp_verify_installation "$ASPERA_TARGET" || aspera_err 'post-install exactness verification failed'
TRANSACTION_ACTIVE=0
trap - EXIT INT TERM
rm -rf "$STAGE_ROOT"
aspera_info "Installed Aspera $ASPERA_PLUGIN_VERSION for $ASPERA_TARGET ($PROFILE). Start a new Codex session."
