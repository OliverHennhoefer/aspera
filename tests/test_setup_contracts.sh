#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${ASPERA_TMP_ROOT:-$(mktemp -d)}"
OWN_TMP=0
[ -n "${ASPERA_TMP_ROOT:-}" ] || OWN_TMP=1
trap '[ "$OWN_TMP" -eq 0 ] || rm -rf "$TMP_ROOT"' EXIT

CLI="$ROOT/aspera"
INSTALL="$ROOT/plugins/aspera-orchestrator/skills/setup/scripts/install.sh"
POLICY="$ROOT/plugins/aspera-orchestrator/skills/orchestrate/references/policy.md"
STUB="${ASPERA_CODEX_BIN:-$ROOT/tests/fixtures/stub/bin/codex}"
STATE_REL='.codex/aspera-orchestrator/state.json'
SPARK_REL='.codex/agents/aspera-spark-worker.toml'
COMMAND_LOG="$TMP_ROOT/codex-commands.log"
STUB_STATE_DIR="$TMP_ROOT/codex-stub-state"
export ASPERA_CODEX_BIN="$STUB"
export ASPERA_STUB_COMMAND_LOG="$COMMAND_LOG"
export ASPERA_STUB_MARKETPLACE_ROOT="$ROOT"
export ASPERA_STUB_STATE_DIR="$STUB_STATE_DIR"
mkdir -p "$STUB_STATE_DIR"

OBSOLETE_MANAGED=(
  "$SPARK_REL"
  '.codex/agents/aspera-explorer.toml'
  '.codex/agents/aspera-luna-worker.toml'
  '.codex/agents/aspera-researcher.toml'
  '.codex/agents/aspera-reviewer.toml'
  '.codex/aspera-orchestrator/worker_guard.py'
  '.codex/aspera-orchestrator/protocol.md'
  '.codex/agents/aspera-worker.toml'
  '.codex/agents/aspera-verifier.toml'
)
ALL_KNOWN=("${OBSOLETE_MANAGED[@]}")

passes=0
failures=0
pass() { printf '[PASS] %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf '[FAIL] %s\n' "$1" >&2; failures=$((failures + 1)); }

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" = "$expected" ]; then pass "$message"; else fail "$message (expected=$expected actual=$actual)"; fi
}
assert_file() { if [ -f "$1" ]; then pass "$2"; else fail "$2"; fi; }
assert_absent() { if [ ! -e "$1" ] && [ ! -L "$1" ]; then pass "$2"; else fail "$2"; fi; }
assert_contains() { if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi; }
assert_not_contains() { if ! grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi; }

reset_stub() {
  rm -f "$STUB_STATE_DIR/marketplace-root" "$STUB_STATE_DIR/plugin.json"
  unset ASPERA_STUB_PLUGIN_STATUS ASPERA_STUB_PLUGIN_ADD_STATUS ASPERA_STUB_PLUGIN_REMOVE_STATUS
  unset ASPERA_STUB_PLUGIN_LIST_STATUS ASPERA_STUB_PLUGIN_ADD_VERSION
  unset ASPERA_STUB_MARKETPLACE_ADD_STATUS ASPERA_STUB_MARKETPLACE_REMOVE_STATUS
  export ASPERA_STUB_MARKETPLACE_ROOT="$ROOT"
  : > "$COMMAND_LOG"
}

seed_stub_plugin() {
  local version="$1" marketplace="${2:-aspera}" source="${3:-$ROOT}"
  python3 - "$STUB_STATE_DIR/plugin.json" "$version" "$marketplace" "$source" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
version, marketplace, source = sys.argv[2:5]
path.write_text(json.dumps({
    'pluginId': f'aspera-orchestrator@{marketplace}',
    'name': 'aspera-orchestrator',
    'marketplaceName': marketplace,
    'version': version,
    'installed': True,
    'enabled': True,
    'source': {'source': 'local', 'path': f'{source}/plugins/aspera-orchestrator'},
    'marketplaceSource': {'sourceType': 'local', 'source': source},
}), encoding='utf-8')
PY
}

stub_plugin_version() {
  python3 - "$STUB_STATE_DIR/plugin.json" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))['version'])
PY
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
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

managed_signature() {
  local target="$1"
  python3 - "$target" "${ALL_KNOWN[@]}" "$STATE_REL" 'AGENTS.md' <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
for rel in dict.fromkeys(sys.argv[2:]):
    path = root / rel
    value = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else 'missing'
    print(f'{rel}\t{value}')
PY
}

assert_schema5() {
  local state="$1" expected_policy="$2"
  if python3 - "$state" "$expected_policy" <<'PY'
import json, pathlib, re, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
expected_keys = {'schema_version','plugin','plugin_version','profile','managed_files','policy_installed','policy_hash'}
if set(data) != expected_keys or data['schema_version'] != 5 or data['plugin_version'] != '0.5.0':
    raise SystemExit(1)
if data['profile'] != 'luna' or data['policy_installed'] is not bool(int(sys.argv[2])):
    raise SystemExit(1)
if data['managed_files'] != {}:
    raise SystemExit(1)
if data['policy_installed'] and re.fullmatch(r'[0-9a-f]{64}', data['policy_hash']) is None:
    raise SystemExit(1)
if data['policy_installed'] != bool(data['policy_hash']):
    raise SystemExit(1)
PY
  then pass "schema-5 Luna-only receipt is exact (policy=$expected_policy)"; else fail 'schema-5 receipt is invalid'; fi
}

assert_exact_install() {
  local target="$1" rel
  for rel in "${OBSOLETE_MANAGED[@]}"; do
    assert_absent "$target/$rel" "obsolete runtime file is absent: $rel"
  done
}

install_direct() {
  local output="$1" target="$2"
  shift 2
  capture "$output" bash "$INSTALL" --workspace "$target" "$@"
}

seed_legacy_state() {
  local target="$1" schema="$2"
  install_direct "$TMP_ROOT/legacy-current-$schema.out" "$target" >/dev/null
  python3 - "$target" "$schema" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
schema = int(sys.argv[2])
state_path = root / '.codex/aspera-orchestrator/state.json'
current = json.loads(state_path.read_text())
policy_hash = current['policy_hash']
for rel in current['managed_files']:
    (root / rel).unlink(missing_ok=True)
legacy = [
    '.codex/agents/aspera-explorer.toml', '.codex/agents/aspera-worker.toml',
    '.codex/agents/aspera-verifier.toml', '.codex/agents/aspera-researcher.toml',
    '.codex/agents/aspera-reviewer.toml',
]
for rel in legacy:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f'legacy {rel}\n')
managed = {rel: hashlib.sha256((root / rel).read_bytes()).hexdigest() for rel in legacy}
guard_rel = '.codex/aspera-orchestrator/worker_guard.py'
if schema >= 2:
    guard = root / guard_rel
    guard.write_text('legacy guard\n')
    managed[guard_rel] = hashlib.sha256(guard.read_bytes()).hexdigest()
payload = {
    'schema_version': schema, 'plugin': 'aspera-orchestrator',
    'plugin_version': {1:'0.1.0', 2:'0.2.0', 3:'0.3.0'}[schema],
    'profile': 'spark', 'managed_files': managed,
    'policy_installed': True, 'policy_hash': policy_hash,
}
if schema in {1, 2}:
    payload['models'] = {'primary':'gpt-5.3-codex-spark','researcher':'gpt-5.6-luna','reviewer':'gpt-5.6-terra'}
    payload['efforts'] = {'primary':'xhigh','researcher':'max','reviewer':'high'}
if schema == 2:
    payload['guard'] = {'required':True,'verified':False,'profile':'','asset_hash':managed[guard_rel],'verified_at':''}
if schema == 3:
    payload['guard_hash'] = managed[guard_rel]
state_path.write_text(json.dumps(payload, indent=2) + '\n')
PY
}

seed_schema4_state() {
  local target="$1"
  install_direct "$TMP_ROOT/schema4-current.out" "$target" >/dev/null
  python3 - "$target" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
state = root / '.codex/aspera-orchestrator/state.json'
current = json.loads(state.read_text())
paths = {
    '.codex/agents/aspera-explorer.toml', '.codex/agents/aspera-luna-worker.toml',
    '.codex/agents/aspera-researcher.toml', '.codex/agents/aspera-reviewer.toml',
    '.codex/agents/aspera-spark-worker.toml', '.codex/aspera-orchestrator/worker_guard.py',
    '.codex/aspera-orchestrator/protocol.md',
}
for rel in paths:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f'v4 {rel}\n')
managed = {rel: hashlib.sha256((root / rel).read_bytes()).hexdigest() for rel in paths}
state.write_text(json.dumps({
    'schema_version': 4, 'plugin': 'aspera-orchestrator', 'plugin_version': '0.4.1',
    'profile': 'adaptive', 'managed_files': managed,
    'guard_hash': managed['.codex/aspera-orchestrator/worker_guard.py'],
    'policy_installed': True, 'policy_hash': current['policy_hash'],
}, indent=2) + '\n')
PY
}

test_fresh_and_policy() {
  local target="$TMP_ROOT/fresh" no_policy="$TMP_ROOT/no-policy" rc before after legacy_profile
  mkdir -p "$target/.codex" "$no_policy"
  printf 'keep = true\n' > "$target/.codex/config.toml"
  local config_hash
  config_hash="$(hash_file "$target/.codex/config.toml")"
  reset_stub
  rc="$(capture "$TMP_ROOT/fresh.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '0' 'one-command Luna Max install succeeds'
  assert_schema5 "$target/$STATE_REL" 1
  assert_exact_install "$target"
  assert_contains "$target/AGENTS.md" '<!-- aspera-orchestrator:policy:start -->' 'managed router is installed by default'
  if [ "$(wc -c < "$POLICY" | tr -d ' ')" -le 1536 ]; then pass 'always-loaded policy is capped at 1.5 KB'; else fail 'always-loaded policy exceeds 1.5 KB'; fi
  assert_eq "$(hash_file "$target/.codex/config.toml")" "$config_hash" '.codex/config.toml is untouched'
  assert_not_contains "$COMMAND_LOG" 'debug models' 'install does not query the model catalog'
  assert_not_contains "$COMMAND_LOG" 'exec' 'install does not run nested Codex'

  before="$(managed_signature "$target")"
  : > "$COMMAND_LOG"
  rc="$(capture "$TMP_ROOT/idempotent.out" bash "$CLI" install --workspace "$target")"
  after="$(managed_signature "$target")"
  assert_eq "$rc" '0' 'idempotent update succeeds'
  assert_eq "$after" "$before" 'idempotent update performs no project writes'
  assert_not_contains "$COMMAND_LOG" 'plugin remove aspera-orchestrator@aspera --json' 'same-version update preserves the installed plugin'
  assert_not_contains "$COMMAND_LOG" 'plugin add aspera-orchestrator@aspera --json' 'same-version update is a plugin no-op'

  rc="$(install_direct "$TMP_ROOT/no-policy.out" "$no_policy" --no-policy)"
  assert_eq "$rc" '0' 'policy-free Luna Max install succeeds'
  assert_schema5 "$no_policy/$STATE_REL" 0
  assert_exact_install "$no_policy"
  assert_absent "$no_policy/AGENTS.md" 'policy-free install leaves AGENTS.md absent'

  before="$(managed_signature "$no_policy")"
  rc="$(install_direct "$TMP_ROOT/no-policy-repeat.out" "$no_policy")"
  after="$(managed_signature "$no_policy")"
  assert_eq "$rc" '0' 'update preserves the no-policy choice'
  assert_eq "$after" "$before" 'preserved Luna-only installation performs no writes'

  rc="$(install_direct "$TMP_ROOT/policy-enable.out" "$no_policy" --install-policy)"
  assert_eq "$rc" '0' 'managed policy can be re-enabled explicitly'
  assert_schema5 "$no_policy/$STATE_REL" 1
  assert_contains "$no_policy/AGENTS.md" '<!-- aspera-orchestrator:policy:start -->' 're-enabled policy is installed'

  before="$(managed_signature "$no_policy")"
  rc="$(install_direct "$TMP_ROOT/policy-conflict.out" "$no_policy" --install-policy --no-policy)"
  after="$(managed_signature "$no_policy")"
  assert_eq "$rc" '1' 'contradictory policy flags are rejected'
  assert_eq "$after" "$before" 'contradictory policy flags write nothing'

  rc="$(install_direct "$TMP_ROOT/dry-run.out" "$no_policy" --no-policy --dry-run)"
  after="$(managed_signature "$no_policy")"
  assert_eq "$rc" '0' 'policy-change dry-run succeeds'
  assert_eq "$after" "$before" 'dry-run performs no writes'
  assert_contains "$TMP_ROOT/dry-run.out" 'DRY-RUN: no files written' 'dry-run reports its read-only result'

  before="$(managed_signature "$no_policy")"
  for legacy_profile in luna adaptive spark; do
    rc="$(install_direct "$TMP_ROOT/invalid-$legacy_profile.out" "$no_policy" --profile "$legacy_profile")"
    after="$(managed_signature "$no_policy")"
    assert_eq "$rc" '1' "removed $legacy_profile profile option is rejected"
    assert_eq "$after" "$before" "rejected $legacy_profile profile writes nothing"
  done
  capture "$TMP_ROOT/cli-help.out" bash "$CLI" --help >/dev/null
  assert_not_contains "$TMP_ROOT/cli-help.out" '--profile' 'public CLI no longer advertises profiles'
}

test_migrations() {
  local schema target rc rel
  for schema in 1 2 3; do
    target="$TMP_ROOT/schema-$schema"
    mkdir -p "$target"
    seed_legacy_state "$target" "$schema"
    rc="$(install_direct "$TMP_ROOT/schema-$schema-migrate.out" "$target")"
    assert_eq "$rc" '0' "schema $schema migrates in one install"
    assert_schema5 "$target/$STATE_REL" 1
    assert_exact_install "$target"
  done

  target="$TMP_ROOT/schema-4"
  mkdir -p "$target"
  seed_schema4_state "$target"
  rc="$(install_direct "$TMP_ROOT/schema-4-migrate.out" "$target")"
  assert_eq "$rc" '0' 'schema 4 migrates in one install'
  assert_schema5 "$target/$STATE_REL" 1
  assert_exact_install "$target"
  for rel in "${OBSOLETE_MANAGED[@]}"; do
    assert_absent "$target/$rel" "schema-4 migration removes $rel"
  done
}

test_drift_transactions_and_conflicts() {
  local target="$TMP_ROOT/drift" rollback="$TMP_ROOT/rollback" conflict="$TMP_ROOT/conflict" rc before after
  mkdir -p "$target" "$rollback" "$conflict/.codex/agents"
  seed_schema4_state "$target"
  printf '# user change\n' >> "$target/$SPARK_REL"
  before="$(hash_file "$target/$SPARK_REL")"
  rc="$(install_direct "$TMP_ROOT/drift-refuse.out" "$target")"
  assert_eq "$rc" '1' 'managed Spark drift is refused without force'
  assert_eq "$(hash_file "$target/$SPARK_REL")" "$before" 'refused drift is untouched'
  rc="$(install_direct "$TMP_ROOT/drift-force.out" "$target" --force)"
  assert_eq "$rc" '0' 'force migrates and removes approved legacy drift'
  assert_schema5 "$target/$STATE_REL" 1
  assert_exact_install "$target"
  if find "$target/.codex/aspera-orchestrator/backups" -type f -print -quit | grep -q .; then pass 'forced reconciliation creates a backup'; else fail 'forced reconciliation did not create a backup'; fi

  seed_schema4_state "$rollback"
  before="$(managed_signature "$rollback")"
  rc="$(ASPERA_INSTALL_FAIL_AFTER=2 install_direct "$TMP_ROOT/rollback.out" "$rollback")"
  after="$(managed_signature "$rollback")"
  assert_eq "$rc" '1' 'injected partial commit fails'
  assert_eq "$after" "$before" 'failed transaction restores every managed destination'

  printf 'unmanaged Spark role\n' > "$target/$SPARK_REL"
  rc="$(install_direct "$TMP_ROOT/unrecorded-spark-refuse.out" "$target")"
  assert_eq "$rc" '1' 'Luna install rejects an unrecorded Spark role'
  rc="$(capture "$TMP_ROOT/unrecorded-spark-diagnose.out" bash "$CLI" diagnose --workspace "$target")"
  assert_eq "$rc" '1' 'diagnosis rejects a role absent from the receipt'
  rc="$(install_direct "$TMP_ROOT/unrecorded-spark-force.out" "$target" --force)"
  assert_eq "$rc" '0' 'forced Luna update removes an unrecorded Spark role'
  assert_absent "$target/$SPARK_REL" 'forced Luna reconciliation restores the native-only surface'

  printf 'unmanaged old role\n' > "$conflict/.codex/agents/aspera-luna-worker.toml"
  rc="$(install_direct "$TMP_ROOT/conflict-refuse.out" "$conflict")"
  assert_eq "$rc" '1' 'fresh install refuses an unmanaged obsolete role'
  rc="$(install_direct "$TMP_ROOT/conflict-force.out" "$conflict" --force)"
  assert_eq "$rc" '0' 'forced install removes an unmanaged obsolete role'
  assert_absent "$conflict/.codex/agents/aspera-luna-worker.toml" 'forced reconciliation removes the obsolete role'
}

test_concurrent_and_unsafe_paths() {
  local target="$TMP_ROOT/concurrent" wrapper="$TMP_ROOT/concurrent-bin" rc real_python
  mkdir -p "$target" "$wrapper"
  seed_schema4_state "$target"
  cat > "$wrapper/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for snapshot in "$ASPERA_CONCURRENT_ROOT"/.codex/aspera-orchestrator/.install-stage.*/snapshot-before; do
  snapshot_lines=0
  if [ -f "$snapshot" ]; then
    while IFS= read -r _; do snapshot_lines=$((snapshot_lines + 1)); done < "$snapshot"
  fi
  if [ "$snapshot_lines" -eq "$ASPERA_CONCURRENT_SNAPSHOT_LINES" ] && [ ! -e "$ASPERA_CONCURRENT_MARKER" ]; then
    printf '# concurrent user edit\n' >> "$ASPERA_CONCURRENT_TARGET"
    : > "$ASPERA_CONCURRENT_MARKER"
    break
  fi
done
exec "$ASPERA_REAL_PYTHON3" "$@"
SH
  chmod +x "$wrapper/python3"
  real_python="$(command -v python3)"
  rc="$(capture "$TMP_ROOT/concurrent.out" env \
    PATH="$wrapper:$PATH" \
    ASPERA_REAL_PYTHON3="$real_python" \
    ASPERA_CONCURRENT_ROOT="$target" \
    ASPERA_CONCURRENT_TARGET="$target/$SPARK_REL" \
    ASPERA_CONCURRENT_MARKER="$TMP_ROOT/concurrent-triggered" \
    ASPERA_CONCURRENT_SNAPSHOT_LINES=11 \
    bash "$INSTALL" --workspace "$target")"
  assert_eq "$rc" '1' 'concurrent managed-file change aborts installation'
  assert_contains "$target/$SPARK_REL" '# concurrent user edit' 'concurrent user change is preserved'
  assert_eq "$(python3 - "$target/$STATE_REL" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(f"{data['schema_version']} {data['profile']}")
PY
)" '4 adaptive' 'aborted migration preserves the legacy receipt'

  target="$TMP_ROOT/symlink"
  mkdir -p "$target/.codex" "$TMP_ROOT/outside"
  ln -s "$TMP_ROOT/outside" "$target/.codex/agents"
  rc="$(install_direct "$TMP_ROOT/symlink.out" "$target")"
  assert_eq "$rc" '1' 'symlinked managed ancestry is refused'
  assert_absent "$target/$STATE_REL" 'unsafe install writes no state'
}

test_lifecycle() {
  local target="$TMP_ROOT/lifecycle" rc before after rel
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
  for rel in "${ALL_KNOWN[@]}" "$STATE_REL"; do
    assert_absent "$target/$rel" "uninstall leaves $rel absent"
  done
  assert_absent "$target/AGENTS.md" 'uninstall removes policy-only AGENTS.md'
}

test_plugin_refresh() {
  local target rc
  reset_stub
  target="$TMP_ROOT/plugin-marketplace-mismatch"
  mkdir -p "$target" "$TMP_ROOT/another-aspera"
  export ASPERA_STUB_MARKETPLACE_ROOT="$TMP_ROOT/another-aspera"
  rc="$(capture "$TMP_ROOT/marketplace-mismatch.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '1' 'mismatched Aspera marketplace is refused'
  assert_absent "$target/$STATE_REL" 'marketplace mismatch occurs before project writes'

  reset_stub
  target="$TMP_ROOT/plugin-marketplace-add"
  mkdir -p "$target"
  export ASPERA_STUB_MARKETPLACE_ROOT=''
  rc="$(capture "$TMP_ROOT/marketplace-add.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '0' 'missing marketplace is added'
  assert_contains "$COMMAND_LOG" "plugin marketplace add $ROOT --json" 'root command adds the checkout marketplace'
  assert_eq "$(stub_plugin_version)" '0.5.0' 'first plugin install matches the checkout version'

  reset_stub
  target="$TMP_ROOT/plugin-version-update"
  mkdir -p "$target"
  seed_stub_plugin '0.4.1'
  rc="$(capture "$TMP_ROOT/plugin-version-update.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '0' 'different-version plugin update succeeds directly'
  assert_not_contains "$COMMAND_LOG" 'plugin remove aspera-orchestrator@aspera' 'different-version update does not remove the prior plugin first'
  assert_eq "$(stub_plugin_version)" '0.5.0' 'different-version update verifies the checkout version'

  reset_stub
  target="$TMP_ROOT/plugin-wrong-source"
  mkdir -p "$target"
  seed_stub_plugin '0.5.0' 'other-marketplace' "$TMP_ROOT/other-marketplace"
  rc="$(capture "$TMP_ROOT/plugin-wrong-source.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '1' 'installed Aspera plugin from an unexpected marketplace is refused'
  assert_absent "$target/$STATE_REL" 'unexpected plugin source leaves project untouched'

  reset_stub
  target="$TMP_ROOT/plugin-same-version"
  mkdir -p "$target"
  seed_stub_plugin '0.5.0'
  export ASPERA_STUB_PLUGIN_REMOVE_STATUS=7
  export ASPERA_STUB_PLUGIN_ADD_STATUS=8
  rc="$(capture "$TMP_ROOT/plugin-same-version.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '0' 'same-version plugin install is a safe no-op'
  assert_file "$STUB_STATE_DIR/plugin.json" 'same-version no-op preserves the installed plugin record'
  assert_not_contains "$COMMAND_LOG" 'plugin remove aspera-orchestrator@aspera --json' 'same-version no-op never removes the installed plugin'
  assert_not_contains "$COMMAND_LOG" 'plugin add aspera-orchestrator@aspera --json' 'same-version no-op never reinstalls the plugin'
  assert_schema5 "$target/$STATE_REL" 1

  reset_stub
  target="$TMP_ROOT/plugin-readback-failure"
  mkdir -p "$target"
  export ASPERA_STUB_PLUGIN_ADD_VERSION='0.4.1'
  rc="$(capture "$TMP_ROOT/plugin-readback-failure.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '1' 'plugin version readback mismatch is rejected'
  assert_absent "$target/$STATE_REL" 'plugin readback failure leaves project untouched'

  reset_stub
  target="$TMP_ROOT/plugin-new-marketplace-failure"
  mkdir -p "$target"
  export ASPERA_STUB_MARKETPLACE_ROOT=''
  export ASPERA_STUB_PLUGIN_ADD_STATUS=9
  rc="$(capture "$TMP_ROOT/plugin-new-marketplace-failure.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '1' 'plugin failure after marketplace creation is reported'
  assert_absent "$STUB_STATE_DIR/marketplace-root" 'failed first install removes the newly added marketplace'
  assert_contains "$COMMAND_LOG" 'plugin marketplace remove aspera --json' 'new marketplace cleanup uses the supported Codex command'
  assert_absent "$target/$STATE_REL" 'failed first plugin install leaves project untouched'
  reset_stub
}

test_contract_text() {
  assert_contains "$POLICY" 'one focused edit-and-test cycle' 'policy has the direct-work threshold'
  assert_contains "$POLICY" 'native `gpt-5.6-luna` at `max`' 'policy targets native Luna Max'
  assert_contains "$POLICY" 'native `gpt-5.6-terra` at `high`' 'policy bounds native Terra review'
  assert_contains "$POLICY" 'Default to one worker' 'policy defaults to one worker'
  assert_not_contains "$POLICY" 'PACKET_VERSION' 'policy has no packet contract'
  assert_not_contains "$POLICY" 'Spark' 'policy has no Spark route'
  assert_absent "$ROOT/plugins/aspera-orchestrator/skills/setup/assets/profiles/adaptive/spark-worker.toml" 'Spark role asset is removed'
  assert_contains "$ROOT/AGENTS.md" 'Always implement Aspera itself parent-direct' 'Aspera development is parent-direct'
  assert_contains "$ROOT/README.md" 'native Luna Max' 'public documentation describes native Luna routing'
  assert_contains "$ROOT/README.md" 'no custom role files' 'public documentation describes the reduced install surface'
}

test_fresh_and_policy
test_migrations
test_drift_transactions_and_conflicts
test_concurrent_and_unsafe_paths
test_lifecycle
test_plugin_refresh
test_contract_text

printf '[SUMMARY] passes=%s failures=%s\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
