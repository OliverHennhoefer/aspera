#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${ASPERA_TMP_ROOT:-$(mktemp -d)}"
OWN_TMP=0
[ -n "${ASPERA_TMP_ROOT:-}" ] || OWN_TMP=1
trap '[ "$OWN_TMP" -eq 0 ] || rm -rf "$TMP_ROOT"' EXIT

CLI="$ROOT/aspera"
INSTALL="$ROOT/plugins/aspera-orchestrator/skills/setup/scripts/install.sh"
ASSETS="$ROOT/plugins/aspera-orchestrator/skills/setup/assets"
STUB="${ASPERA_CODEX_BIN:-$ROOT/tests/fixtures/stub/bin/codex}"
STATE_REL='.codex/aspera-orchestrator/state.json'
COMMAND_LOG="$TMP_ROOT/codex-commands.log"
export ASPERA_CODEX_BIN="$STUB"
export ASPERA_STUB_COMMAND_LOG="$COMMAND_LOG"
export ASPERA_STUB_MARKETPLACE_ROOT="$ROOT"

MANAGED=(
  '.codex/agents/aspera-explorer.toml'
  '.codex/agents/aspera-worker.toml'
  '.codex/agents/aspera-verifier.toml'
  '.codex/agents/aspera-researcher.toml'
  '.codex/agents/aspera-reviewer.toml'
  '.codex/aspera-orchestrator/worker_guard.py'
)

passes=0
failures=0

pass() { printf '[PASS] %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf '[FAIL] %s\n' "$1" >&2; failures=$((failures + 1)); }

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" = "$expected" ]; then pass "$message"; else fail "$message (expected=$expected actual=$actual)"; fi
}

assert_file() {
  if [ -f "$1" ]; then pass "$2"; else fail "$2"; fi
}

assert_absent() {
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then pass "$2"; else fail "$2"; fi
}

assert_contains() {
  if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}

assert_not_contains() {
  if ! grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}

capture() {
  local output="$1"
  shift
  set +e
  "$@" > "$output" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc"
}

hash_file() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

state_value() {
  python3 - "$1" "$2" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')).get(sys.argv[2], '')
if isinstance(value, bool):
    print('1' if value else '0')
elif isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True))
else:
    print(value)
PY
}

managed_signature() {
  local target="$1"
  python3 - "$target" "${MANAGED[@]}" "$STATE_REL" 'AGENTS.md' <<'PY'
import hashlib
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
for rel in sys.argv[2:]:
    path = root / rel
    value = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else 'missing'
    print(f'{rel}\t{value}')
PY
}

assert_schema3() {
  local state="$1" expected_profile="$2" expected_policy="$3"
  if python3 - "$state" "$expected_profile" "$expected_policy" <<'PY'
import json
import pathlib
import re
import sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
expected_keys = {'schema_version','plugin','plugin_version','profile','managed_files','guard_hash','policy_installed','policy_hash'}
if set(data) != expected_keys or data['schema_version'] != 3 or data['plugin'] != 'aspera-orchestrator' or data['plugin_version'] != '0.3.0':
    raise SystemExit(1)
if data['profile'] != sys.argv[2] or data['policy_installed'] is not bool(int(sys.argv[3])):
    raise SystemExit(1)
managed = data['managed_files']
if len(managed) != 6 or any(re.fullmatch(r'[0-9a-f]{64}', value) is None for value in managed.values()):
    raise SystemExit(1)
if data['guard_hash'] != managed['.codex/aspera-orchestrator/worker_guard.py']:
    raise SystemExit(1)
if data['policy_installed'] and re.fullmatch(r'[0-9a-f]{64}', data['policy_hash']) is None:
    raise SystemExit(1)
if not data['policy_installed'] and data['policy_hash'] != '':
    raise SystemExit(1)
PY
  then pass "schema-3 receipt is exact ($expected_profile policy=$expected_policy)"; else fail 'schema-3 receipt is invalid'; fi
}

asset_for() {
  local profile="$1" rel="$2" role
  case "$rel" in
    .codex/aspera-orchestrator/worker_guard.py) printf '%s/worker_guard.py\n' "$ASSETS" ;;
    *)
      role="${rel##*/aspera-}"
      role="${role%.toml}"
      case "$role" in
        researcher|reviewer) printf '%s/profiles/shared/%s.toml\n' "$ASSETS" "$role" ;;
        *) printf '%s/profiles/%s/%s.toml\n' "$ASSETS" "$profile" "$role" ;;
      esac
      ;;
  esac
}

assert_exact_install() {
  local target="$1" profile="$2" rel source recorded
  for rel in "${MANAGED[@]}"; do
    source="$(asset_for "$profile" "$rel")"
    if cmp -s "$source" "$target/$rel"; then pass "$rel matches $profile asset"; else fail "$rel differs from $profile asset"; fi
    recorded="$(python3 - "$target/$STATE_REL" "$rel" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())['managed_files'][sys.argv[2]])
PY
)"
    assert_eq "$recorded" "$(hash_file "$target/$rel")" "$rel hash is recorded"
  done
}

install_direct() {
  local output="$1" target="$2"
  shift 2
  capture "$output" bash "$INSTALL" --workspace "$target" "$@"
}

seed_legacy_state() {
  local target="$1" schema="$2"
  local state="$target/$STATE_REL"
  python3 - "$state" "$schema" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
schema = int(sys.argv[2])
current = json.loads(path.read_text(encoding='utf-8'))
profile = current['profile']
models = {
    'primary': 'gpt-5.3-codex-spark' if profile == 'spark' else 'gpt-5.6-luna',
    'researcher': 'gpt-5.6-luna',
    'reviewer': 'gpt-5.6-terra',
}
efforts = {'primary': 'xhigh' if profile == 'spark' else 'max', 'researcher': 'max', 'reviewer': 'high'}
managed = dict(current['managed_files'])
payload = {
    'schema_version': schema,
    'plugin': 'aspera-orchestrator',
    'plugin_version': '0.1.0' if schema == 1 else '0.2.0',
    'profile': profile,
    'models': models,
    'efforts': efforts,
    'managed_files': managed,
    'policy_installed': current['policy_installed'],
    'policy_hash': current['policy_hash'],
}
if schema == 1:
    managed.pop('.codex/aspera-orchestrator/worker_guard.py')
else:
    payload['guard'] = {
        'required': True,
        'verified': False,
        'profile': '',
        'asset_hash': managed['.codex/aspera-orchestrator/worker_guard.py'],
        'verified_at': '',
    }
path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
PY
  if [ "$schema" = '1' ]; then
    rm -f "$target/.codex/aspera-orchestrator/worker_guard.py"
  fi
}

test_root_install() {
  local target="$TMP_ROOT/fresh project" output="$TMP_ROOT/fresh.out" rc
  mkdir -p "$target/.codex"
  printf 'keep = true\n' > "$target/.codex/config.toml"
  local config_hash
  config_hash="$(hash_file "$target/.codex/config.toml")"
  : > "$COMMAND_LOG"
  rc="$(capture "$output" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '0' 'one-command fresh install succeeds'
  assert_schema3 "$target/$STATE_REL" spark 1
  assert_exact_install "$target" spark
  assert_contains "$target/AGENTS.md" '<!-- aspera-orchestrator:policy:start -->' 'managed policy is installed by default'
  assert_eq "$(hash_file "$target/.codex/config.toml")" "$config_hash" '.codex/config.toml is untouched'
  assert_contains "$COMMAND_LOG" 'plugin marketplace list --json' 'root command inspects marketplace'
  assert_contains "$COMMAND_LOG" 'plugin add aspera-orchestrator@aspera' 'root command refreshes plugin'
  assert_not_contains "$COMMAND_LOG" 'debug models' 'install does not query model catalog'
  assert_not_contains "$COMMAND_LOG" 'exec' 'install does not run nested Codex'
  assert_not_contains "$output" 'runtime' 'successful installation has no runtime ceremony'

  local before after
  before="$(managed_signature "$target")"
  : > "$COMMAND_LOG"
  rc="$(capture "$TMP_ROOT/idempotent.out" bash "$CLI" install --workspace "$target")"
  after="$(managed_signature "$target")"
  assert_eq "$rc" '0' 'idempotent one-command update succeeds'
  assert_eq "$after" "$before" 'idempotent update performs no project writes'
}

test_profiles_and_policy() {
  local target="$TMP_ROOT/luna" rc
  mkdir -p "$target"
  rc="$(install_direct "$TMP_ROOT/luna.out" "$target" --profile luna --no-policy)"
  assert_eq "$rc" '0' 'explicit Luna install succeeds'
  assert_schema3 "$target/$STATE_REL" luna 0
  assert_absent "$target/AGENTS.md" 'policy-free fresh install leaves AGENTS.md absent'
  rc="$(install_direct "$TMP_ROOT/luna-repeat.out" "$target")"
  assert_eq "$rc" '0' 'update without flags preserves Luna profile and no-policy choice'
  assert_schema3 "$target/$STATE_REL" luna 0
}

test_legacy_migrations() {
  local schema target rc
  for schema in 1 2; do
    target="$TMP_ROOT/schema-$schema"
    mkdir -p "$target"
    install_direct "$TMP_ROOT/schema-$schema-seed.out" "$target" >/dev/null
    seed_legacy_state "$target" "$schema"
    rc="$(install_direct "$TMP_ROOT/schema-$schema-migrate.out" "$target")"
    assert_eq "$rc" '0' "schema $schema migrates in one install"
    assert_schema3 "$target/$STATE_REL" spark 1
    assert_exact_install "$target" spark
  done
}

test_drift_and_transactions() {
  local target="$TMP_ROOT/drift" rc before after
  mkdir -p "$target"
  install_direct "$TMP_ROOT/drift-seed.out" "$target" >/dev/null
  printf '# user change\n' >> "$target/.codex/agents/aspera-worker.toml"
  before="$(hash_file "$target/.codex/agents/aspera-worker.toml")"
  rc="$(install_direct "$TMP_ROOT/drift-refuse.out" "$target")"
  assert_eq "$rc" '1' 'drift is refused without force'
  assert_eq "$(hash_file "$target/.codex/agents/aspera-worker.toml")" "$before" 'refused drift is untouched'
  rc="$(install_direct "$TMP_ROOT/drift-force.out" "$target" --force)"
  assert_eq "$rc" '0' 'force reconciles approved drift'
  assert_exact_install "$target" spark
  if find "$target/.codex/aspera-orchestrator/backups" -type f -print -quit | grep -q .; then pass 'forced reconciliation creates a backup'; else fail 'forced reconciliation did not create a backup'; fi

  before="$(managed_signature "$target")"
  rc="$(ASPERA_INSTALL_FAIL_AFTER=2 install_direct "$TMP_ROOT/rollback.out" "$target" --profile luna)"
  after="$(managed_signature "$target")"
  assert_eq "$rc" '1' 'injected partial commit fails'
  assert_eq "$after" "$before" 'failed transaction restores every managed destination'
}

test_unsafe_paths() {
  local target="$TMP_ROOT/symlink" outside="$TMP_ROOT/outside" rc
  mkdir -p "$target/.codex" "$outside"
  ln -s "$outside" "$target/.codex/agents"
  rc="$(install_direct "$TMP_ROOT/symlink.out" "$target")"
  assert_eq "$rc" '1' 'symlinked managed ancestry is refused'
  assert_absent "$target/$STATE_REL" 'unsafe install writes no state'
}

test_diagnose_and_uninstall() {
  local target="$TMP_ROOT/lifecycle" rc before after
  mkdir -p "$target"
  install_direct "$TMP_ROOT/lifecycle-seed.out" "$target" >/dev/null
  before="$(managed_signature "$target")"
  : > "$COMMAND_LOG"
  rc="$(capture "$TMP_ROOT/diagnose.out" bash "$CLI" diagnose --workspace "$target")"
  after="$(managed_signature "$target")"
  assert_eq "$rc" '0' 'optional diagnosis succeeds'
  assert_eq "$after" "$before" 'diagnosis is read-only'
  assert_eq "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" '0' 'diagnosis never invokes Codex'

  rc="$(capture "$TMP_ROOT/uninstall.out" bash "$CLI" uninstall --workspace "$target")"
  assert_eq "$rc" '0' 'root uninstall succeeds'
  for rel in "${MANAGED[@]}" "$STATE_REL"; do
    assert_absent "$target/$rel" "uninstall removes $rel"
  done
  assert_absent "$target/AGENTS.md" 'uninstall removes policy-only AGENTS.md'
}

test_plugin_refresh_failures() {
  local target="$TMP_ROOT/plugin-failure" rc
  mkdir -p "$target"
  export ASPERA_STUB_MARKETPLACE_ROOT="$TMP_ROOT/another-aspera"
  mkdir -p "$ASPERA_STUB_MARKETPLACE_ROOT"
  rc="$(capture "$TMP_ROOT/marketplace-mismatch.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '1' 'mismatched Aspera marketplace is refused'
  assert_absent "$target/$STATE_REL" 'marketplace failure occurs before project writes'

  export ASPERA_STUB_MARKETPLACE_ROOT=''
  : > "$COMMAND_LOG"
  rc="$(capture "$TMP_ROOT/marketplace-add.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '0' 'missing marketplace is added by the one-command installer'
  assert_contains "$COMMAND_LOG" "plugin marketplace add $ROOT" 'root command adds the checkout marketplace'
  export ASPERA_STUB_MARKETPLACE_ROOT="$ROOT"
}

test_first_session_contract() {
  local policy
  for policy in \
    "$ROOT/AGENTS.md" \
    "$ROOT/plugins/aspera-orchestrator/skills/orchestrate/SKILL.md" \
    "$ROOT/plugins/aspera-orchestrator/skills/orchestrate/references/policy.md"; do
    assert_not_contains "$policy" 'guard.verified' "$(basename "$policy") has no persisted guard gate"
    assert_not_contains "$policy" '--runtime-smoke' "$(basename "$policy") has no runtime-smoke instruction"
  done
  assert_contains "$ROOT/plugins/aspera-orchestrator/skills/orchestrate/SKILL.md" 'Do not load setup, run doctor, spawn a synthetic worker, or retry' 'first-session orchestration forbids setup and synthetic retries'
}

test_root_install
test_profiles_and_policy
test_legacy_migrations
test_drift_and_transactions
test_unsafe_paths
test_diagnose_and_uninstall
test_plugin_refresh_failures
test_first_session_contract

printf '[SUMMARY] passes=%s failures=%s\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
