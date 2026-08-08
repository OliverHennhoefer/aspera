#!/usr/bin/env bash
set -euo pipefail

ASPERA_POLICY_MARKER_START='<!-- aspera-orchestrator:policy:start -->'
ASPERA_POLICY_MARKER_END='<!-- aspera-orchestrator:policy:end -->'
ASPERA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASPERA_POLICY_SRC="${ASPERA_SCRIPT_DIR}/../../orchestrate/references/policy.md"
ASPERA_ASSETS_DIR="${ASPERA_SCRIPT_DIR}/../assets/profiles"
ASPERA_STATE_FILE_REL='.codex/aspera-orchestrator/state.json'
ASPERA_STATE_BACKUP_DIR_REL='.codex/aspera-orchestrator/backups'
ASPERA_AGENTS_FILE_REL='AGENTS.md'
ASPERA_PLUGIN_ID='aspera-orchestrator'
ASPERA_SCHEMA_VERSION=1
ASPERA_PLUGIN_VERSION='0.1.0'
ASPERA_MANAGED_FILES=(
  '.codex/agents/aspera-explorer.toml'
  '.codex/agents/aspera-worker.toml'
  '.codex/agents/aspera-verifier.toml'
  '.codex/agents/aspera-researcher.toml'
  '.codex/agents/aspera-reviewer.toml'
)

aspera_err() {
  echo "ERROR: $*" >&2
  exit 1
}

aspera_info() {
  echo "$*"
}

aspera_require_python3() {
  command -v python3 >/dev/null 2>&1 || aspera_err "python3 is required"
}

aspera_normalize_target() {
  local target="${1:-$(pwd)}"
  target="${target%/}"
  if [ -z "$target" ]; then
    target="$(pwd)"
  fi
  case "$target" in
    /*) ;;
    *) target="$(pwd)/$target" ;;
  esac
  if [ ! -e "$target" ]; then
    aspera_err "target does not exist: $target"
  fi
  if [ ! -d "$target" ]; then
    aspera_err "target is not a directory: $target"
  fi
  if [ -L "$target" ]; then
    aspera_err "refusing symlink target: $target"
  fi
  if ! cd -P "$target" >/dev/null 2>&1; then
    aspera_err "target is not accessible: $target"
  fi
  pwd -P
}

aspera_validate_profile() {
  case "$1" in
    spark|luna) ;;
    *) aspera_err "invalid profile '$1'" ;;
  esac
}

aspera_check_ancestry_not_symlink() {
  local path="$1"
  if [ -L "$path" ]; then
    aspera_err "refusing symlink path: $path"
  fi
}

aspera_check_managed_ancestry() {
  local root="$1"
  aspera_check_ancestry_not_symlink "$root"
  aspera_check_ancestry_not_symlink "$root/.codex"
  aspera_check_ancestry_not_symlink "$root/.codex/agents"
  aspera_check_ancestry_not_symlink "$root/.codex/aspera-orchestrator"
  aspera_check_ancestry_not_symlink "$root/$ASPERA_STATE_BACKUP_DIR_REL"
  aspera_check_ancestry_not_symlink "$root/$ASPERA_STATE_FILE_REL"
  aspera_check_ancestry_not_symlink "$root/$ASPERA_AGENTS_FILE_REL"

  local rel=
  for rel in "${ASPERA_MANAGED_FILES[@]}"; do
    aspera_check_ancestry_not_symlink "$root/$rel"
  done
}

aspera_state_file() {
  echo "$1/$ASPERA_STATE_FILE_REL"
}

aspera_backup_root() {
  echo "$1/$ASPERA_STATE_BACKUP_DIR_REL/$(date -u +%Y%m%dT%H%M%SZ)-$$"
}

aspera_prepare_backup_root() {
  local root="$1"
  local backup_parent="$root/$ASPERA_STATE_BACKUP_DIR_REL"
  local backup_root

  aspera_check_managed_ancestry "$root"
  if [ -e "$backup_parent" ] && [ ! -d "$backup_parent" ]; then
    aspera_err "backup path is not a directory: $backup_parent"
  fi

  backup_root="$(aspera_backup_root "$root")"
  if [ -e "$backup_root" ] || [ -L "$backup_root" ]; then
    aspera_err "backup path already exists: $backup_root"
  fi

  umask 077
  mkdir -p "$backup_root"
  aspera_check_managed_ancestry "$root"
  aspera_check_ancestry_not_symlink "$backup_root"

  local physical_root physical_backup
  physical_root="$(cd -P "$root" && pwd)"
  physical_backup="$(cd -P "$backup_root" && pwd)"
  case "$physical_backup" in
    "$physical_root/$ASPERA_STATE_BACKUP_DIR_REL"/*) ;;
    *) aspera_err "backup path escaped target: $physical_backup" ;;
  esac

  echo "$backup_root"
}

aspera_validate_backup_root() {
  local root="$1"
  local backup_root="$2"
  local expected_parent="$root/$ASPERA_STATE_BACKUP_DIR_REL"

  aspera_check_managed_ancestry "$root"
  aspera_check_ancestry_not_symlink "$backup_root"
  if [ ! -d "$backup_root" ]; then
    aspera_err "backup directory missing: $backup_root"
  fi
  case "$backup_root" in
    "$expected_parent"/*) ;;
    *) aspera_err "invalid backup destination: $backup_root" ;;
  esac
}

aspera_hash_file() {
  local file="$1"
  python3 - "$file" <<'PY2'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY2
}

aspera_atomic_write() {
  local target="$1"
  local tmp="${target}.tmp.$$.$RANDOM"
  mkdir -p "$(dirname "$target")"
  cat > "$tmp"
  mv "$tmp" "$target"
}

asp_state_validate() {
  aspera_require_python3
  python3 - "$1" <<'PY2'
import json
import re
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    d = json.load(f)

if d.get('schema_version') != 1:
    raise SystemExit(1)
if d.get('plugin') != 'aspera-orchestrator':
    raise SystemExit(1)
if d.get('plugin_version') != '0.1.0':
    raise SystemExit(1)

profile = d.get('profile')
if profile not in ('spark', 'luna'):
    raise SystemExit(1)

models = d.get('models')
efforts = d.get('efforts')
managed = d.get('managed_files')
if not isinstance(models, dict) or not isinstance(efforts, dict) or not isinstance(managed, dict):
    raise SystemExit(1)

required = {'primary', 'researcher', 'reviewer'}
if set(models.keys()) != required:
    raise SystemExit(1)
if set(efforts.keys()) != required:
    raise SystemExit(1)

for key in required:
    if not isinstance(models.get(key), str) or not models[key]:
        raise SystemExit(1)
    if not isinstance(efforts.get(key), str) or not efforts[key]:
        raise SystemExit(1)

profile = d.get('profile')
if profile == 'spark':
    expected_primary_model = 'gpt-5.3-codex-spark'
    expected_primary_effort = 'xhigh'
else:
    expected_primary_model = 'gpt-5.6-luna'
    expected_primary_effort = 'max'

if models['primary'] != expected_primary_model:
    raise SystemExit(1)
if efforts['primary'] != expected_primary_effort:
    raise SystemExit(1)

if models['researcher'] != 'gpt-5.6-luna':
    raise SystemExit(1)
if efforts['researcher'] != 'max':
    raise SystemExit(1)

if models['reviewer'] != 'gpt-5.6-terra':
    raise SystemExit(1)
if efforts['reviewer'] != 'high':
    raise SystemExit(1)

required_managed = {
    '.codex/agents/aspera-explorer.toml',
    '.codex/agents/aspera-worker.toml',
    '.codex/agents/aspera-verifier.toml',
    '.codex/agents/aspera-researcher.toml',
    '.codex/agents/aspera-reviewer.toml',
}
if set(managed.keys()) != required_managed:
    raise SystemExit(1)
for key in required_managed:
    value = managed.get(key)
    if not isinstance(value, str) or re.fullmatch(r'[0-9a-f]{64}', value) is None:
        raise SystemExit(1)

policy_installed = d.get('policy_installed')
if not isinstance(policy_installed, bool):
    raise SystemExit(1)
policy_hash = d.get('policy_hash', '')
if not isinstance(policy_hash, str):
    raise SystemExit(1)
if policy_installed and re.fullmatch(r'[0-9a-f]{64}', policy_hash) is None:
    raise SystemExit(1)
if not policy_installed and policy_hash != '':
    raise SystemExit(1)
PY2
}

asp_state_get() {
  python3 - "$1" "$2" <<'PY2'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    d = json.load(f)

value = d.get(sys.argv[2], '')
if isinstance(value, bool):
  print('1' if value else '0')
elif isinstance(value, (dict, list)):
  import json as _json
  print(_json.dumps(value))
else:
  print(value)
PY2
}

asp_state_get_hash() {
  python3 - "$1" "$2" <<'PY2'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    d = json.load(f)
print(d.get('managed_files', {}).get(sys.argv[2], ''))
PY2
}

asp_preflight_models() {
  aspera_require_python3
  local profile="$1"
  local codex_bin="${ASPERA_CODEX_BIN:-codex}"
  command -v "$codex_bin" >/dev/null 2>&1 || aspera_err "$codex_bin is required"

  local catalog
  catalog="$(mktemp)"
  if ! "$codex_bin" debug models >"$catalog"; then
    rm -f "$catalog"
    aspera_err "failed to refresh the authenticated model catalog with '$codex_bin debug models'"
  fi

  local parsed
  if ! parsed="$(python3 - "$catalog" "$profile" <<'PY2'
import json
import sys

path, profile = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)

if not isinstance(data, dict) or not isinstance(data.get('models'), list):
    raise SystemExit(1)

required = [
    ('LUNA', 'gpt-5.6-luna', 'max'),
    ('TERRA', 'gpt-5.6-terra', 'high'),
]
if profile == 'spark':
    required.append(('SPARK', 'gpt-5.3-codex-spark', 'xhigh'))

found = {}
for entry in data['models']:
    if not isinstance(entry, dict):
        continue
    slug = str(entry.get('slug', '') or '').strip()
    if not slug:
        continue
    levels = entry.get('supported_reasoning_levels', [])
    if not isinstance(levels, list):
        continue
    normalized_levels = []
    for level in levels:
        if isinstance(level, dict):
            effort = str(level.get('effort', '')).strip().lower()
            if effort:
                normalized_levels.append(effort)
    for token, slug_check, effort_check in required:
        if slug == slug_check:
            if effort_check not in normalized_levels:
                raise SystemExit(1)
            found[token] = (slug, effort_check)

for token, slug_check, effort_check in required:
    if token not in found:
        raise SystemExit(1)
    print(f"{token}_MODEL={found[token][0]}")
    print(f"{token}_EFFORT={found[token][1]}")
print("OK=1")
PY2
)"; then
    rm -f "$catalog"
    aspera_err "model catalog did not satisfy preflight"
  fi
  rm -f "$catalog"

  ASPERA_MODEL_SPARK=""
  ASPERA_EFFORT_SPARK=""
  ASPERA_MODEL_LUNA=""
  ASPERA_EFFORT_LUNA=""
  ASPERA_MODEL_TERRA=""
  ASPERA_EFFORT_TERRA=""

  while IFS='=' read -r key value; do
    case "$key" in
      SPARK_MODEL) ASPERA_MODEL_SPARK="$value" ;;
      SPARK_EFFORT) ASPERA_EFFORT_SPARK="$value" ;;
      LUNA_MODEL) ASPERA_MODEL_LUNA="$value" ;;
      LUNA_EFFORT) ASPERA_EFFORT_LUNA="$value" ;;
      TERRA_MODEL) ASPERA_MODEL_TERRA="$value" ;;
      TERRA_EFFORT) ASPERA_EFFORT_TERRA="$value" ;;
      OK) : ;;
      *) : ;;
    esac
  done <<< "$parsed"

  if [ "$profile" = 'spark' ] && [ -z "$ASPERA_MODEL_SPARK" ]; then
    aspera_err "preflight missing spark model"
  fi
  [ -n "$ASPERA_MODEL_LUNA" ] || aspera_err "preflight missing luna model"
  [ -n "$ASPERA_MODEL_TERRA" ] || aspera_err "preflight missing terra model"
  if [ "$profile" = 'spark' ] && [ "$ASPERA_EFFORT_SPARK" != 'xhigh' ]; then
    aspera_err "spark effort must be xhigh"
  fi
  if [ "$ASPERA_EFFORT_LUNA" != 'max' ]; then
    aspera_err "luna effort must be max"
  fi
  if [ "$ASPERA_EFFORT_TERRA" != 'high' ]; then
    aspera_err "terra effort must be high"
  fi

  ASPERA_MODEL_PRIMARY="$ASPERA_MODEL_LUNA"
  ASPERA_EFFORT_PRIMARY="$ASPERA_EFFORT_LUNA"
  ASPERA_MODEL_RESEARCHER="$ASPERA_MODEL_LUNA"
  ASPERA_EFFORT_RESEARCHER="$ASPERA_EFFORT_LUNA"
  ASPERA_MODEL_REVIEWER="$ASPERA_MODEL_TERRA"
  ASPERA_EFFORT_REVIEWER="$ASPERA_EFFORT_TERRA"

  if [ "$profile" = 'spark' ]; then
    ASPERA_MODEL_PRIMARY="$ASPERA_MODEL_SPARK"
    ASPERA_EFFORT_PRIMARY="$ASPERA_EFFORT_SPARK"
  fi
}

asp_profile_asset_path() {
  local profile="$1"
  local role="$2"

  case "$role" in
    explorer|worker|verifier)
      echo "$ASPERA_ASSETS_DIR/$profile/$role.toml"
      ;;
    researcher|reviewer)
      echo "$ASPERA_ASSETS_DIR/shared/$role.toml"
      ;;
    *) aspera_err "invalid role '$role'" ;;
  esac
}

asp_expected_asset_contract() {
  local role="$1"
  case "$role" in
    explorer|worker|verifier)
      case "$role" in
        explorer) echo 'aspera_explorer' ;;
        worker) echo 'aspera_worker' ;;
        verifier) echo 'aspera_verifier' ;;
      esac
      ;;
    researcher)
      echo 'aspera_researcher'
      ;;
    reviewer)
      echo 'aspera_reviewer'
      ;;
    *) echo '' ;;
  esac
}

asp_expected_asset_sandbox() {
  local role="$1"
  case "$role" in
    worker|verifier) echo 'workspace-write' ;;
    explorer|researcher|reviewer) echo 'read-only' ;;
    *) echo '' ;;
  esac
}

asp_expected_asset_effort() {
  local profile="$1" role="$2"
  case "$role" in
    explorer|worker|verifier)
      if [ "$profile" = 'spark' ]; then
        echo 'xhigh'
      else
        echo 'max'
      fi
      ;;
    researcher) echo 'max' ;;
    reviewer) echo 'high' ;;
    *) echo '' ;;
  esac
}

asp_validate_asset_file() {
  local profile="$1" role="$2" expected_model="$3"
  local path
  path="$(asp_profile_asset_path "$profile" "$role")"
  if [ ! -f "$path" ]; then
    aspera_err "missing profile asset $path"
  fi

  local expected_name expected_sandbox expected_effort
  expected_name="$(asp_expected_asset_contract "$role")"
  expected_sandbox="$(asp_expected_asset_sandbox "$role")"
  expected_effort="$(asp_expected_asset_effort "$profile" "$role")"

  python3 - "$path" "$expected_name" "$expected_sandbox" "$expected_effort" "$expected_model" "$role" <<'PY2'
import hashlib
import pathlib
import sys

try:
  import tomllib
except Exception:
  tomllib = None
if tomllib is None:
  raise SystemExit(1)

path, expected_name, expected_sandbox, expected_effort, expected_model, role = sys.argv[1:7]
data = tomllib.loads(pathlib.Path(path).read_text(encoding='utf-8'))
if not isinstance(data, dict):
  raise SystemExit(1)

name = str(data.get('name', '')).strip()
model = str(data.get('model', '')).strip()
effort = str(data.get('model_reasoning_effort', '')).strip()
sandbox = str(data.get('sandbox_mode', '')).strip()
if name != expected_name:
  raise SystemExit(1)
if model != expected_model:
  raise SystemExit(1)
if effort != expected_effort:
  raise SystemExit(1)
if sandbox != expected_sandbox:
  raise SystemExit(1)

if not model or not expected_model:
  raise SystemExit(1)

print(hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest())
PY2
}

asp_policy_scan() {
  local file="$1"
  [ -f "$file" ] || { echo missing; return 0; }
  python3 - "$file" "$ASPERA_POLICY_MARKER_START" "$ASPERA_POLICY_MARKER_END" <<'PY2'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
start = text.count(sys.argv[2])
end = text.count(sys.argv[3])
if start == 0 and end == 0:
    print('missing')
    raise SystemExit(0)
if start != 1 or end != 1:
    print('invalid')
    raise SystemExit(0)
if text.find(sys.argv[2]) > text.find(sys.argv[3]):
    print('invalid')
else:
    print('ok')
PY2
}

asp_policy_hash() {
  local file="$1"
  python3 - "$file" "$ASPERA_POLICY_MARKER_START" "$ASPERA_POLICY_MARKER_END" <<'PY2'
import hashlib
import pathlib
import sys
text = pathlib.Path(sys.argv[1]).read_text()
start = text.find(sys.argv[2])
end = text.find(sys.argv[3])
if start == -1 or end == -1 or start >= end:
    print('')
    raise SystemExit(0)
start = text.find('\n', start)
if start == -1:
    start = len(text)
else:
    start = start + 1
block = text[start:end].strip('\n')
print(hashlib.sha256(block.encode('utf-8')).hexdigest())
PY2
}

asp_policy_insert_or_replace() {
  local file="$1" policy_file="$2"
  local rendered="${file}.tmp.$$.$RANDOM"
  python3 - "$file" "$policy_file" "$ASPERA_POLICY_MARKER_START" "$ASPERA_POLICY_MARKER_END" <<'PY2' > "$rendered"
import pathlib
import sys
agents = pathlib.Path(sys.argv[1])
policy = pathlib.Path(sys.argv[2]).read_text()
start_marker = sys.argv[3]
end_marker = sys.argv[4]
if agents.exists():
    text = agents.read_text()
    start = text.find(start_marker)
    end = text.find(end_marker)
    if start == -1:
        if text and not text.endswith('\n'):
            text += '\n'
        text += start_marker + '\n' + policy + '\n' + end_marker + '\n'
    else:
        if end == -1 or start >= end:
            raise SystemExit(2)
        endline = text.find('\n', end)
        if endline == -1:
            endline = len(text)
        else:
            endline = endline + 1
        before = text[:start]
        after = text[endline:]
        if before and not before.endswith('\n'):
            before += '\n'
        text = before + start_marker + '\n' + policy + '\n' + end_marker + '\n' + after
else:
    text = start_marker + '\n' + policy + '\n' + end_marker + '\n'
print(text, end='')
PY2
  aspera_atomic_write "$file" < "$rendered"
  rm -f "$rendered"
}

asp_policy_remove_block() {
  local file="$1"
  local rendered="${file}.tmp.$$.$RANDOM"
  python3 - "$file" "$ASPERA_POLICY_MARKER_START" "$ASPERA_POLICY_MARKER_END" <<'PY2' > "$rendered"
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
start = text.find(sys.argv[2])
end = text.find(sys.argv[3])
if start == -1:
    print(text, end='')
    raise SystemExit(0)
endline = text.find('\n', end)
if endline == -1:
    endline = len(text)
else:
    endline = endline + 1
before = text[:start]
after = text[endline:]
if before.endswith('\n') and after.startswith('\n'):
    after = after[1:]
print(before + after, end='')
PY2
  aspera_atomic_write "$file" < "$rendered"
  rm -f "$rendered"
}

asp_backup() {
  local root="$1"
  local backup_root="$2"
  local rel="$3"
  local src="$root/$rel"
  aspera_validate_backup_root "$root" "$backup_root"
  if [ ! -e "$src" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$backup_root/$rel")"
  cp "$src" "$backup_root/$rel"
}

asp_run_smoke() {
  local target="$1"
  local out_file="$2"
  local codex_bin="${ASPERA_CODEX_BIN:-codex}"
  command -v "$codex_bin" >/dev/null 2>&1 || aspera_err "$codex_bin required for smoke"

  python3 - "$codex_bin" "$target" "$out_file" <<'PY2'
import subprocess
import sys

bin_path, target, out_file = sys.argv[1:4]
prompt = (
  "You are the scoped smoke checker. "
  "Spawn aspera_explorer in an isolated context only. "
  "Respond with exactly: ASPERA_SMOKE_OK"
)
cmd = [
  bin_path,
  'exec',
  '--cd',
  target,
  '--skip-git-repo-check',
  '--ephemeral',
  '--sandbox',
  'read-only',
  prompt,
]
with open(out_file, 'w') as out:
  try:
    proc = subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT, timeout=120)
  except subprocess.TimeoutExpired:
    out.write('ASPERA_SMOKE_TIMEOUT')
    raise SystemExit(124)
raise SystemExit(proc.returncode)
PY2
}
