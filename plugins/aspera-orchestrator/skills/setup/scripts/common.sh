#!/usr/bin/env bash
# Shared setup helpers. Keep this file compatible with macOS Bash 3.2.
# shellcheck disable=SC2034
set -euo pipefail

ASPERA_PLUGIN_NAME='aspera-orchestrator'
ASPERA_PLUGIN_VERSION='0.4.1'
ASPERA_STATE_SCHEMA='4'
ASPERA_POLICY_MARKER_START='<!-- aspera-orchestrator:policy:start -->'
ASPERA_POLICY_MARKER_END='<!-- aspera-orchestrator:policy:end -->'
ASPERA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASPERA_POLICY_SRC="${ASPERA_SCRIPT_DIR}/../../orchestrate/references/policy.md"
ASPERA_PROTOCOL_SRC="${ASPERA_SCRIPT_DIR}/../../orchestrate/references/protocol.md"
ASPERA_SETUP_ASSETS_DIR="${ASPERA_SCRIPT_DIR}/../assets"
ASPERA_ASSETS_DIR="${ASPERA_SETUP_ASSETS_DIR}/profiles"
ASPERA_GUARD_SRC="${ASPERA_SETUP_ASSETS_DIR}/worker_guard.py"
ASPERA_STATE_FILE_REL='.codex/aspera-orchestrator/state.json'
ASPERA_PROTOCOL_FILE_REL='.codex/aspera-orchestrator/protocol.md'
ASPERA_STATE_BACKUP_DIR_REL='.codex/aspera-orchestrator/backups'
ASPERA_AGENTS_FILE_REL='AGENTS.md'
ASPERA_COMMON_MANAGED_FILES=(
  '.codex/agents/aspera-explorer.toml'
  '.codex/agents/aspera-luna-worker.toml'
  '.codex/agents/aspera-researcher.toml'
  '.codex/agents/aspera-reviewer.toml'
  '.codex/aspera-orchestrator/worker_guard.py'
  '.codex/aspera-orchestrator/protocol.md'
)
ASPERA_ADAPTIVE_MANAGED_FILES=(
  '.codex/agents/aspera-spark-worker.toml'
)
ASPERA_LEGACY_MANAGED_FILES=(
  '.codex/agents/aspera-worker.toml'
  '.codex/agents/aspera-verifier.toml'
)
ASPERA_ALL_MANAGED_FILES=(
  "${ASPERA_COMMON_MANAGED_FILES[@]}"
  "${ASPERA_ADAPTIVE_MANAGED_FILES[@]}"
  "${ASPERA_LEGACY_MANAGED_FILES[@]}"
)
ASPERA_MANAGED_FILES=("${ASPERA_COMMON_MANAGED_FILES[@]}")

aspera_err() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

aspera_info() {
  printf '%s\n' "$*"
}

aspera_require_python3() {
  command -v python3 >/dev/null 2>&1 || aspera_err 'python3 is required'
}

aspera_normalize_target() {
  local target="${1:-$(pwd)}"
  target="${target%/}"
  [ -n "$target" ] || target="$(pwd)"
  case "$target" in
    /*) ;;
    *) target="$(pwd)/$target" ;;
  esac
  [ -e "$target" ] || aspera_err "workspace does not exist: $target"
  [ -d "$target" ] || aspera_err "workspace is not a directory: $target"
  [ ! -L "$target" ] || aspera_err "refusing symlink workspace: $target"
  (cd -P "$target" >/dev/null 2>&1) || aspera_err "workspace is not accessible: $target"
  (cd -P "$target" && pwd)
}

aspera_validate_profile() {
  case "$1" in
    adaptive|luna) ;;
    *) aspera_err "invalid profile '$1' (expected adaptive or luna; spark is a deprecated install alias)" ;;
  esac
}

aspera_normalize_profile() {
  case "$1" in
    spark) printf 'adaptive\n' ;;
    adaptive|luna) printf '%s\n' "$1" ;;
    *) aspera_err "invalid profile '$1' (expected adaptive, luna, or deprecated alias spark)" ;;
  esac
}

aspera_check_path_not_symlink() {
  local path="$1"
  [ ! -L "$path" ] || aspera_err "refusing symlink path: $path"
}

aspera_check_managed_ancestry() {
  local root="$1"
  local rel path
  aspera_check_path_not_symlink "$root"
  for path in \
    "$root/.codex" \
    "$root/.codex/agents" \
    "$root/.codex/aspera-orchestrator" \
    "$root/$ASPERA_STATE_BACKUP_DIR_REL"; do
    aspera_check_path_not_symlink "$path"
    if [ -e "$path" ] && [ ! -d "$path" ]; then
      aspera_err "managed ancestor is not a directory: $path"
    fi
  done
  aspera_check_path_not_symlink "$root/$ASPERA_STATE_FILE_REL"
  aspera_check_path_not_symlink "$root/$ASPERA_AGENTS_FILE_REL"
  for rel in "${ASPERA_ALL_MANAGED_FILES[@]}"; do
    aspera_check_path_not_symlink "$root/$rel"
  done
}

aspera_state_file() {
  printf '%s/%s\n' "$1" "$ASPERA_STATE_FILE_REL"
}

aspera_hash_file() {
  aspera_require_python3
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

aspera_entry_fingerprint() {
  local path="$1"
  if [ -L "$path" ]; then
    printf 'symlink\n'
  elif [ -f "$path" ]; then
    printf 'file:%s\n' "$(aspera_hash_file "$path")"
  elif [ -e "$path" ]; then
    printf 'other\n'
  else
    printf 'missing\n'
  fi
}

aspera_capture_destination_snapshot() {
  local root="$1"
  local output="$2"
  local rel
  : > "$output"
  for rel in "${ASPERA_ALL_MANAGED_FILES[@]}" "$ASPERA_STATE_FILE_REL" "$ASPERA_AGENTS_FILE_REL"; do
    printf '%s\t%s\n' "$rel" "$(aspera_entry_fingerprint "$root/$rel")" >> "$output"
  done
}

aspera_atomic_write() {
  local target="$1"
  local tmp="${target}.tmp.$$.$RANDOM"
  mkdir -p "$(dirname "$target")"
  cat > "$tmp"
  mv -f "$tmp" "$target"
}

asp_state_schema() {
  aspera_require_python3
  python3 - "$1" <<'PY'
import json
import pathlib
import sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')).get('schema_version', '')
except Exception:
    value = ''
print(value)
PY
}

asp_state_validate_supported() {
  aspera_require_python3
  python3 - "$1" <<'PY'
import json
import pathlib
import re
import sys

try:
    data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
except Exception:
    raise SystemExit(1)

if not isinstance(data, dict) or data.get('plugin') != 'aspera-orchestrator':
    raise SystemExit(1)
schema = data.get('schema_version')
versions = {1: {'0.1.0'}, 2: {'0.2.0'}, 3: {'0.3.0'}, 4: {'0.4.0', '0.4.1'}}
if schema not in versions or data.get('plugin_version') not in versions[schema]:
    raise SystemExit(1)
profile = data.get('profile')
if profile not in ({'spark', 'luna'} if schema < 4 else {'adaptive', 'luna'}):
    raise SystemExit(1)

legacy_role_files = {
    '.codex/agents/aspera-explorer.toml',
    '.codex/agents/aspera-worker.toml',
    '.codex/agents/aspera-verifier.toml',
    '.codex/agents/aspera-researcher.toml',
    '.codex/agents/aspera-reviewer.toml',
}
current_role_files = {
    '.codex/agents/aspera-explorer.toml',
    '.codex/agents/aspera-luna-worker.toml',
    '.codex/agents/aspera-researcher.toml',
    '.codex/agents/aspera-reviewer.toml',
    '.codex/aspera-orchestrator/worker_guard.py',
    '.codex/aspera-orchestrator/protocol.md',
}
if profile == 'adaptive':
    current_role_files.add('.codex/agents/aspera-spark-worker.toml')
managed = data.get('managed_files')
if not isinstance(managed, dict):
    raise SystemExit(1)
if schema < 4:
    expected_managed = set(legacy_role_files)
    if schema >= 2:
        expected_managed.add('.codex/aspera-orchestrator/worker_guard.py')
else:
    expected_managed = current_role_files
if set(managed) != expected_managed:
    raise SystemExit(1)
if any(not isinstance(value, str) or re.fullmatch(r'[0-9a-f]{64}', value) is None for value in managed.values()):
    raise SystemExit(1)

policy_installed = data.get('policy_installed')
policy_hash = data.get('policy_hash')
if not isinstance(policy_installed, bool) or not isinstance(policy_hash, str):
    raise SystemExit(1)
if policy_installed and re.fullmatch(r'[0-9a-f]{64}', policy_hash) is None:
    raise SystemExit(1)
if not policy_installed and policy_hash != '':
    raise SystemExit(1)

if schema in {1, 2}:
    models = data.get('models')
    efforts = data.get('efforts')
    if not isinstance(models, dict) or not isinstance(efforts, dict):
        raise SystemExit(1)
    primary_model = 'gpt-5.3-codex-spark' if profile == 'spark' else 'gpt-5.6-luna'
    primary_effort = 'xhigh' if profile == 'spark' else 'max'
    if models != {'primary': primary_model, 'researcher': 'gpt-5.6-luna', 'reviewer': 'gpt-5.6-terra'}:
        raise SystemExit(1)
    if efforts != {'primary': primary_effort, 'researcher': 'max', 'reviewer': 'high'}:
        raise SystemExit(1)

if schema == 2:
    guard = data.get('guard')
    if not isinstance(guard, dict):
        raise SystemExit(1)
    if guard.get('required') is not True or not isinstance(guard.get('verified'), bool):
        raise SystemExit(1)
    if guard.get('asset_hash') != managed['.codex/aspera-orchestrator/worker_guard.py']:
        raise SystemExit(1)
    if guard.get('verified'):
        if guard.get('profile') != profile or not isinstance(guard.get('verified_at'), str) or not guard.get('verified_at'):
            raise SystemExit(1)
    elif guard.get('profile') != '' or guard.get('verified_at') != '':
        raise SystemExit(1)

if schema in {3, 4}:
    expected_keys = {
        'schema_version', 'plugin', 'plugin_version', 'profile', 'managed_files',
        'guard_hash', 'policy_installed', 'policy_hash',
    }
    if set(data) != expected_keys:
        raise SystemExit(1)
    if data.get('guard_hash') != managed['.codex/aspera-orchestrator/worker_guard.py']:
        raise SystemExit(1)
PY
}

asp_state_validate() {
  asp_state_validate_supported "$1" || return 1
  [ "$(asp_state_schema "$1")" = "$ASPERA_STATE_SCHEMA" ]
}

asp_state_get() {
  python3 - "$1" "$2" <<'PY'
import json
import pathlib
import sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
value = data.get(sys.argv[2], '')
if isinstance(value, bool):
    print('1' if value else '0')
elif isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True))
else:
    print(value)
PY
}

asp_state_get_hash() {
  python3 - "$1" "$2" <<'PY'
import json
import pathlib
import sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
print(data.get('managed_files', {}).get(sys.argv[2], ''))
PY
}

asp_state_managed_files() {
  python3 - "$1" <<'PY'
import json
import pathlib
import sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
for path in sorted(data.get('managed_files', {})):
    print(path)
PY
}

asp_set_profile_contract() {
  local profile="$1"
  aspera_validate_profile "$profile"
  ASPERA_MODEL_LUNA='gpt-5.6-luna'
  ASPERA_EFFORT_LUNA='max'
  ASPERA_MODEL_SPARK='gpt-5.3-codex-spark'
  ASPERA_EFFORT_SPARK='xhigh'
  ASPERA_MODEL_RESEARCHER='gpt-5.6-luna'
  ASPERA_EFFORT_RESEARCHER='max'
  ASPERA_MODEL_REVIEWER='gpt-5.6-terra'
  ASPERA_EFFORT_REVIEWER='high'
  ASPERA_MANAGED_FILES=("${ASPERA_COMMON_MANAGED_FILES[@]}")
  if [ "$profile" = 'adaptive' ]; then
    ASPERA_MANAGED_FILES+=("${ASPERA_ADAPTIVE_MANAGED_FILES[@]}")
  fi
}

asp_profile_asset_path() {
  local role="$2"
  case "$role" in
    explorer|researcher|reviewer) printf '%s/shared/%s.toml\n' "$ASPERA_ASSETS_DIR" "$role" ;;
    luna-worker) printf '%s/shared/luna-worker.toml\n' "$ASPERA_ASSETS_DIR" ;;
    spark-worker) printf '%s/adaptive/spark-worker.toml\n' "$ASPERA_ASSETS_DIR" ;;
    *) aspera_err "invalid role '$role'" ;;
  esac
}

asp_validate_asset_file() {
  local profile="$1"
  local role="$2"
  local expected_model="$3"
  local path
  path="$(asp_profile_asset_path "$profile" "$role")"
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    aspera_err "missing or unsafe profile asset: $path"
  fi
  python3 - "$path" "$profile" "$role" "$expected_model" <<'PY'
import hashlib
import pathlib
import sys
import tomllib

path, profile, role, expected_model = sys.argv[1:5]
data = tomllib.loads(pathlib.Path(path).read_text(encoding='utf-8'))
expected_names = {
    'explorer': 'aspera_explorer',
    'luna-worker': 'aspera_luna_worker',
    'spark-worker': 'aspera_spark_worker',
    'researcher': 'aspera_researcher',
    'reviewer': 'aspera_reviewer',
}
expected_name = expected_names[role]
expected_sandbox = 'workspace-write' if role in {'luna-worker', 'spark-worker'} else 'read-only'
if role == 'researcher':
    expected_effort = 'max'
elif role == 'reviewer':
    expected_effort = 'high'
elif role == 'spark-worker':
    expected_effort = 'xhigh'
else:
    expected_effort = 'max'
if data.get('name') != expected_name or data.get('model') != expected_model:
    raise SystemExit(1)
if data.get('sandbox_mode') != expected_sandbox or data.get('model_reasoning_effort') != expected_effort:
    raise SystemExit(1)
print(hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest())
PY
}

asp_validate_guard_asset() {
  if [ ! -f "$ASPERA_GUARD_SRC" ] || [ -L "$ASPERA_GUARD_SRC" ]; then
    aspera_err "missing or unsafe worker guard asset: $ASPERA_GUARD_SRC"
  fi
  python3 - "$ASPERA_GUARD_SRC" <<'PY'
import hashlib
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
required = ('PACKET_VERSION = "3"', 'WORKER_MODEL_MISMATCH', 'UNTRUTHFUL_CHANGED_FILES', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PreCompact', 'Stop')
if any(term not in text for term in required):
    raise SystemExit(1)
compile(text, str(path), 'exec')
print(hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

asp_policy_scan() {
  local file="$1"
  [ -f "$file" ] || { printf 'missing\n'; return 0; }
  [ ! -L "$file" ] || { printf 'invalid\n'; return 0; }
  python3 - "$file" "$ASPERA_POLICY_MARKER_START" "$ASPERA_POLICY_MARKER_END" <<'PY'
import pathlib
import sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
start, end = sys.argv[2:4]
if text.count(start) == 0 and text.count(end) == 0:
    print('missing')
elif text.count(start) != 1 or text.count(end) != 1 or text.find(start) > text.find(end):
    print('invalid')
else:
    print('ok')
PY
}

asp_policy_hash() {
  python3 - "$1" "$ASPERA_POLICY_MARKER_START" "$ASPERA_POLICY_MARKER_END" <<'PY'
import hashlib
import pathlib
import sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
start_marker, end_marker = sys.argv[2:4]
start = text.find(start_marker)
end = text.find(end_marker)
if start < 0 or end < 0 or start >= end:
    print('')
    raise SystemExit(0)
start = text.find('\n', start)
start = len(text) if start < 0 else start + 1
block = text[start:end].strip('\n')
print(hashlib.sha256(block.encode()).hexdigest())
PY
}

asp_policy_source_hash() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys
block = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').strip('\n')
print(hashlib.sha256(block.encode()).hexdigest())
PY
}

asp_validate_policy_assets() {
  if [ ! -f "$ASPERA_POLICY_SRC" ] || [ -L "$ASPERA_POLICY_SRC" ]; then
    aspera_err "policy source is missing or unsafe: $ASPERA_POLICY_SRC"
  fi
  if [ ! -f "$ASPERA_PROTOCOL_SRC" ] || [ -L "$ASPERA_PROTOCOL_SRC" ]; then
    aspera_err "protocol source is missing or unsafe: $ASPERA_PROTOCOL_SRC"
  fi
  local policy_bytes
  policy_bytes="$(wc -c < "$ASPERA_POLICY_SRC" | tr -d ' ')"
  [ "$policy_bytes" -le 2048 ] || aspera_err "managed routing policy exceeds 2048 bytes: $policy_bytes"
}

asp_render_policy() {
  local source_file="$1"
  local policy_file="$2"
  local output_file="$3"
  python3 - "$source_file" "$policy_file" "$ASPERA_POLICY_MARKER_START" "$ASPERA_POLICY_MARKER_END" "$output_file" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1])
policy = pathlib.Path(sys.argv[2])
start_marker = sys.argv[3]
end_marker = sys.argv[4]
output = pathlib.Path(sys.argv[5])
text = source.read_text(encoding='utf-8') if source.exists() else ''
policy_text = policy.read_text(encoding='utf-8').strip('\n')
start_at = text.find(start_marker)
end_at = text.find(end_marker)
if start_at == -1:
    if text and not text.endswith('\n'):
        text += '\n'
    if text:
        text += '\n'
    text += f'{start_marker}\n{policy_text}\n{end_marker}\n'
else:
    if end_at == -1 or start_at >= end_at:
        raise SystemExit(2)
    endline = text.find('\n', end_at)
    endline = len(text) if endline == -1 else endline + 1
    text = text[:start_at] + f'{start_marker}\n{policy_text}\n{end_marker}\n' + text[endline:]
pathlib.Path(output).write_text(text, encoding='utf-8')
PY
}

asp_render_policy_without_block() {
  local source_file="$1"
  local output_file="$2"
  python3 - "$source_file" "$ASPERA_POLICY_MARKER_START" "$ASPERA_POLICY_MARKER_END" "$output_file" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1])
text = source.read_text(encoding='utf-8') if source.exists() else ''
start_marker, end_marker = sys.argv[2:4]
start = text.find(start_marker)
if start >= 0:
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(2)
    endline = text.find('\n', end)
    endline = len(text) if endline < 0 else endline + 1
    text = text[:start] + text[endline:]
pathlib.Path(sys.argv[4]).write_text(text, encoding='utf-8')
PY
}

aspera_backup_root() {
  printf '%s/%s/%s-%s\n' "$1" "$ASPERA_STATE_BACKUP_DIR_REL" "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

aspera_prepare_backup_root() {
  local root="$1"
  local backup_root physical_root physical_backup
  backup_root="$(aspera_backup_root "$root")"
  aspera_check_managed_ancestry "$root"
  if [ -e "$backup_root" ] || [ -L "$backup_root" ]; then
    aspera_err "backup path already exists: $backup_root"
  fi
  umask 077
  mkdir -p "$backup_root"
  aspera_check_managed_ancestry "$root"
  physical_root="$(cd -P "$root" && pwd)"
  physical_backup="$(cd -P "$backup_root" && pwd)"
  case "$physical_backup" in
    "$physical_root/$ASPERA_STATE_BACKUP_DIR_REL"/*) ;;
    *) aspera_err "backup path escaped the workspace: $physical_backup" ;;
  esac
  printf '%s\n' "$backup_root"
}

asp_backup() {
  local root="$1"
  local backup_root="$2"
  local rel="$3"
  local source="$root/$rel"
  [ -e "$source" ] || [ -L "$source" ] || return 0
  [ ! -L "$source" ] || aspera_err "refusing to back up symlink: $source"
  mkdir -p "$(dirname "$backup_root/$rel")"
  cp -p "$source" "$backup_root/$rel"
}

asp_verify_installation() {
  local root="$1"
  local state_file="$root/$ASPERA_STATE_FILE_REL"
  local rel recorded current policy_scan policy_hash
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  asp_state_validate "$state_file" || return 1
  while IFS= read -r rel; do
    [ -f "$root/$rel" ] && [ ! -L "$root/$rel" ] || return 1
    recorded="$(asp_state_get_hash "$state_file" "$rel")"
    current="$(aspera_hash_file "$root/$rel")"
    [ "$recorded" = "$current" ] || return 1
  done < <(asp_state_managed_files "$state_file")
  for rel in "${ASPERA_ALL_MANAGED_FILES[@]}"; do
    recorded="$(asp_state_get_hash "$state_file" "$rel")"
    if [ -z "$recorded" ] && { [ -e "$root/$rel" ] || [ -L "$root/$rel" ]; }; then
      return 1
    fi
  done
  [ "$(asp_state_get "$state_file" guard_hash)" = "$(asp_state_get_hash "$state_file" '.codex/aspera-orchestrator/worker_guard.py')" ] || return 1
  if [ "$(asp_state_get "$state_file" policy_installed)" = '1' ]; then
    policy_scan="$(asp_policy_scan "$root/$ASPERA_AGENTS_FILE_REL")"
    [ "$policy_scan" = 'ok' ] || return 1
    policy_hash="$(asp_policy_hash "$root/$ASPERA_AGENTS_FILE_REL")"
    [ "$policy_hash" = "$(asp_state_get "$state_file" policy_hash)" ] || return 1
  else
    [ "$(asp_policy_scan "$root/$ASPERA_AGENTS_FILE_REL")" = 'missing' ] || return 1
  fi
}
