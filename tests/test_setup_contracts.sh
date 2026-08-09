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
POLICY="$ROOT/plugins/aspera-orchestrator/skills/orchestrate/references/policy.md"
PROTOCOL="$ROOT/plugins/aspera-orchestrator/skills/orchestrate/references/protocol.md"
STUB="${ASPERA_CODEX_BIN:-$ROOT/tests/fixtures/stub/bin/codex}"
STATE_REL='.codex/aspera-orchestrator/state.json'
COMMAND_LOG="$TMP_ROOT/codex-commands.log"
STUB_STATE_DIR="$TMP_ROOT/codex-stub-state"
export ASPERA_CODEX_BIN="$STUB"
export ASPERA_STUB_COMMAND_LOG="$COMMAND_LOG"
export ASPERA_STUB_MARKETPLACE_ROOT="$ROOT"
export ASPERA_STUB_STATE_DIR="$STUB_STATE_DIR"
mkdir -p "$STUB_STATE_DIR"

MANAGED_LUNA=(
  '.codex/agents/aspera-explorer.toml'
  '.codex/agents/aspera-luna-worker.toml'
  '.codex/agents/aspera-researcher.toml'
  '.codex/agents/aspera-reviewer.toml'
  '.codex/aspera-orchestrator/worker_guard.py'
  '.codex/aspera-orchestrator/protocol.md'
)
MANAGED_ADAPTIVE=("${MANAGED_LUNA[@]}" '.codex/agents/aspera-spark-worker.toml')
LEGACY_MANAGED=(
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
payload = {
    'pluginId': f'aspera-orchestrator@{marketplace}',
    'name': 'aspera-orchestrator',
    'marketplaceName': marketplace,
    'version': version,
    'installed': True,
    'enabled': True,
    'source': {'source': 'local', 'path': f'{source}/plugins/aspera-orchestrator'},
    'marketplaceSource': {'sourceType': 'local', 'source': source},
}
path.write_text(json.dumps(payload), encoding='utf-8')
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
  python3 - "$target" "${MANAGED_ADAPTIVE[@]}" "${LEGACY_MANAGED[@]}" "$STATE_REL" 'AGENTS.md' <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
for rel in dict.fromkeys(sys.argv[2:]):
    path = root / rel
    value = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else 'missing'
    print(f'{rel}\t{value}')
PY
}

assert_schema4() {
  local state="$1" expected_profile="$2" expected_policy="$3"
  if python3 - "$state" "$expected_profile" "$expected_policy" <<'PY'
import json, pathlib, re, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
expected_keys = {'schema_version','plugin','plugin_version','profile','managed_files','guard_hash','policy_installed','policy_hash'}
if set(data) != expected_keys or data['schema_version'] != 4 or data['plugin_version'] != '0.4.0':
    raise SystemExit(1)
profile = sys.argv[2]
if data['profile'] != profile or data['policy_installed'] is not bool(int(sys.argv[3])):
    raise SystemExit(1)
expected = {
    '.codex/agents/aspera-explorer.toml',
    '.codex/agents/aspera-luna-worker.toml',
    '.codex/agents/aspera-researcher.toml',
    '.codex/agents/aspera-reviewer.toml',
    '.codex/aspera-orchestrator/worker_guard.py',
    '.codex/aspera-orchestrator/protocol.md',
}
if profile == 'adaptive':
    expected.add('.codex/agents/aspera-spark-worker.toml')
if set(data['managed_files']) != expected:
    raise SystemExit(1)
if any(re.fullmatch(r'[0-9a-f]{64}', value) is None for value in data['managed_files'].values()):
    raise SystemExit(1)
if data['guard_hash'] != data['managed_files']['.codex/aspera-orchestrator/worker_guard.py']:
    raise SystemExit(1)
if data['policy_installed'] != bool(data['policy_hash']):
    raise SystemExit(1)
PY
  then pass "schema-4 receipt is exact ($expected_profile policy=$expected_policy)"; else fail 'schema-4 receipt is invalid'; fi
}

asset_for() {
  local rel="$1"
  case "$rel" in
    .codex/agents/aspera-explorer.toml) printf '%s/profiles/shared/explorer.toml\n' "$ASSETS" ;;
    .codex/agents/aspera-luna-worker.toml) printf '%s/profiles/shared/luna-worker.toml\n' "$ASSETS" ;;
    .codex/agents/aspera-spark-worker.toml) printf '%s/profiles/adaptive/spark-worker.toml\n' "$ASSETS" ;;
    .codex/agents/aspera-researcher.toml) printf '%s/profiles/shared/researcher.toml\n' "$ASSETS" ;;
    .codex/agents/aspera-reviewer.toml) printf '%s/profiles/shared/reviewer.toml\n' "$ASSETS" ;;
    .codex/aspera-orchestrator/worker_guard.py) printf '%s/worker_guard.py\n' "$ASSETS" ;;
    .codex/aspera-orchestrator/protocol.md) printf '%s\n' "$PROTOCOL" ;;
  esac
}

assert_exact_install() {
  local target="$1" profile="$2" rel source recorded
  local managed=("${MANAGED_LUNA[@]}")
  [ "$profile" != 'adaptive' ] || managed+=( '.codex/agents/aspera-spark-worker.toml' )
  for rel in "${managed[@]}"; do
    source="$(asset_for "$rel")"
    if cmp -s "$source" "$target/$rel"; then pass "$rel matches source asset"; else fail "$rel differs from source asset"; fi
    recorded="$(python3 - "$target/$STATE_REL" "$rel" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())['managed_files'][sys.argv[2]])
PY
)"
    assert_eq "$recorded" "$(hash_file "$target/$rel")" "$rel hash is recorded"
  done
  if [ "$profile" = 'luna' ]; then
    assert_absent "$target/.codex/agents/aspera-spark-worker.toml" 'Luna profile omits Spark worker'
  fi
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
import hashlib, json, pathlib, shutil, sys
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

test_root_install() {
  local target="$TMP_ROOT/fresh project" output="$TMP_ROOT/fresh.out" rc before after
  mkdir -p "$target/.codex"
  printf 'keep = true\n' > "$target/.codex/config.toml"
  local config_hash
  config_hash="$(hash_file "$target/.codex/config.toml")"
  reset_stub
  rc="$(capture "$output" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '0' 'one-command fresh install succeeds'
  assert_schema4 "$target/$STATE_REL" adaptive 1
  assert_exact_install "$target" adaptive
  assert_contains "$target/AGENTS.md" '<!-- aspera-orchestrator:policy:start -->' 'managed router is installed by default'
  assert_eq "$(wc -c < "$POLICY" | tr -d ' ')" "$(python3 -c "print(len(open('$POLICY','rb').read()))")" 'policy byte measurement is stable'
  if [ "$(wc -c < "$POLICY" | tr -d ' ')" -le 2048 ]; then pass 'always-loaded policy is capped at 2 KB'; else fail 'always-loaded policy exceeds 2 KB'; fi
  assert_eq "$(hash_file "$target/.codex/config.toml")" "$config_hash" '.codex/config.toml is untouched'
  assert_contains "$COMMAND_LOG" 'plugin marketplace list --json' 'root command inspects marketplace'
  assert_contains "$COMMAND_LOG" 'plugin add aspera-orchestrator@aspera' 'root command refreshes plugin'
  assert_contains "$COMMAND_LOG" 'plugin list --json' 'root command verifies installed plugin metadata'
  assert_not_contains "$COMMAND_LOG" 'debug models' 'install does not query model catalog'
  assert_not_contains "$COMMAND_LOG" 'exec' 'install does not run nested Codex'
  assert_not_contains "$output" 'doctor' 'install does not require doctor'
  assert_not_contains "$output" 'runtime smoke' 'install does not run runtime smoke'

  before="$(managed_signature "$target")"
  : > "$COMMAND_LOG"
  rc="$(capture "$TMP_ROOT/idempotent.out" bash "$CLI" install --workspace "$target")"
  after="$(managed_signature "$target")"
  assert_eq "$rc" '0' 'idempotent update succeeds'
  assert_eq "$after" "$before" 'idempotent update performs no project writes'
  assert_contains "$COMMAND_LOG" 'plugin remove aspera-orchestrator@aspera --json' 'same-version update clears the installed plugin cache through Codex'
  assert_contains "$COMMAND_LOG" 'plugin add aspera-orchestrator@aspera --json' 'same-version update reinstalls the plugin through Codex'
}

test_profiles_and_alias() {
  local target="$TMP_ROOT/luna" alias_target="$TMP_ROOT/alias" rc before after
  mkdir -p "$target" "$alias_target"
  rc="$(install_direct "$TMP_ROOT/luna.out" "$target" --profile luna --no-policy)"
  assert_eq "$rc" '0' 'explicit Luna install succeeds'
  assert_schema4 "$target/$STATE_REL" luna 0
  assert_exact_install "$target" luna
  assert_absent "$target/AGENTS.md" 'policy-free install leaves AGENTS.md absent'

  before="$(managed_signature "$target")"
  rc="$(install_direct "$TMP_ROOT/luna-repeat.out" "$target")"
  after="$(managed_signature "$target")"
  assert_eq "$rc" '0' 'update without flags preserves Luna and no-policy choices'
  assert_eq "$after" "$before" 'preserved Luna installation performs no writes'
  assert_schema4 "$target/$STATE_REL" luna 0

  rc="$(install_direct "$TMP_ROOT/policy-enable.out" "$target" --install-policy)"
  assert_eq "$rc" '0' 'managed policy can be re-enabled explicitly'
  assert_schema4 "$target/$STATE_REL" luna 1
  assert_contains "$target/AGENTS.md" '<!-- aspera-orchestrator:policy:start -->' 're-enabled policy is installed'

  before="$(managed_signature "$target")"
  rc="$(install_direct "$TMP_ROOT/policy-conflict.out" "$target" --install-policy --no-policy)"
  after="$(managed_signature "$target")"
  assert_eq "$rc" '1' 'contradictory policy flags are rejected'
  assert_eq "$after" "$before" 'contradictory policy flags write nothing'

  rc="$(install_direct "$TMP_ROOT/alias.out" "$alias_target" --profile spark)"
  assert_eq "$rc" '0' 'legacy Spark profile alias succeeds'
  assert_schema4 "$alias_target/$STATE_REL" adaptive 1
}

test_legacy_migrations() {
  local schema target rc
  for schema in 1 2 3; do
    target="$TMP_ROOT/schema-$schema"
    mkdir -p "$target"
    seed_legacy_state "$target" "$schema"
    rc="$(install_direct "$TMP_ROOT/schema-$schema-migrate.out" "$target")"
    assert_eq "$rc" '0' "schema $schema migrates in one install"
    assert_schema4 "$target/$STATE_REL" adaptive 1
    assert_exact_install "$target" adaptive
    assert_absent "$target/.codex/agents/aspera-worker.toml" 'migration removes legacy worker file'
    assert_absent "$target/.codex/agents/aspera-verifier.toml" 'migration removes legacy verifier file'
  done
}

test_drift_and_transactions() {
  local target="$TMP_ROOT/drift" rc before after
  mkdir -p "$target"
  install_direct "$TMP_ROOT/drift-seed.out" "$target" >/dev/null
  printf '# user change\n' >> "$target/.codex/agents/aspera-luna-worker.toml"
  before="$(hash_file "$target/.codex/agents/aspera-luna-worker.toml")"
  rc="$(install_direct "$TMP_ROOT/drift-refuse.out" "$target")"
  assert_eq "$rc" '1' 'drift is refused without force'
  assert_eq "$(hash_file "$target/.codex/agents/aspera-luna-worker.toml")" "$before" 'refused drift is untouched'
  rc="$(install_direct "$TMP_ROOT/drift-force.out" "$target" --force)"
  assert_eq "$rc" '0' 'force reconciles approved drift'
  assert_exact_install "$target" adaptive
  if find "$target/.codex/aspera-orchestrator/backups" -type f -print -quit | grep -q .; then pass 'forced reconciliation creates a backup'; else fail 'forced reconciliation did not create a backup'; fi

  before="$(managed_signature "$target")"
  rc="$(ASPERA_INSTALL_FAIL_AFTER=2 install_direct "$TMP_ROOT/rollback.out" "$target" --profile luna)"
  after="$(managed_signature "$target")"
  assert_eq "$rc" '1' 'injected partial commit fails'
  assert_eq "$after" "$before" 'failed transaction restores every managed destination'

  before="$(managed_signature "$target")"
  rc="$(ASPERA_INSTALL_FAIL_AFTER=7 install_direct "$TMP_ROOT/rollback-after-removal.out" "$target" --profile luna)"
  after="$(managed_signature "$target")"
  assert_eq "$rc" '1' 'injected failure after profile-excluded removal fails'
  assert_eq "$after" "$before" 'rollback restores a removed profile-excluded role'

  rc="$(install_direct "$TMP_ROOT/switch.out" "$target" --profile luna)"
  assert_eq "$rc" '0' 'adaptive profile can switch to Luna'
  assert_absent "$target/.codex/agents/aspera-spark-worker.toml" 'profile switch removes Spark worker'
}

test_profile_excluded_conflicts() {
  local fresh_luna="$TMP_ROOT/fresh-luna-conflict" current_luna="$TMP_ROOT/current-luna-conflict"
  local fresh_adaptive="$TMP_ROOT/fresh-adaptive-conflict" rc original

  mkdir -p "$fresh_luna/.codex/agents"
  printf 'unmanaged spark role\n' > "$fresh_luna/.codex/agents/aspera-spark-worker.toml"
  original="$(hash_file "$fresh_luna/.codex/agents/aspera-spark-worker.toml")"
  rc="$(install_direct "$TMP_ROOT/fresh-luna-refuse.out" "$fresh_luna" --profile luna)"
  assert_eq "$rc" '1' 'fresh Luna install refuses an unmanaged Spark role'
  assert_eq "$(hash_file "$fresh_luna/.codex/agents/aspera-spark-worker.toml")" "$original" 'refused Spark conflict is untouched'
  rc="$(install_direct "$TMP_ROOT/fresh-luna-force.out" "$fresh_luna" --profile luna --force)"
  assert_eq "$rc" '0' 'forced fresh Luna install reconciles a Spark conflict'
  assert_absent "$fresh_luna/.codex/agents/aspera-spark-worker.toml" 'forced Luna install removes the excluded Spark role'
  if find "$fresh_luna/.codex/aspera-orchestrator/backups" -path '*/.codex/agents/aspera-spark-worker.toml' -type f -print -quit | grep -q .; then
    pass 'forced Luna install backs up the excluded Spark role'
  else
    fail 'forced Luna install did not back up the excluded Spark role'
  fi

  mkdir -p "$fresh_adaptive/.codex/agents"
  printf 'legacy worker\n' > "$fresh_adaptive/.codex/agents/aspera-worker.toml"
  printf 'legacy verifier\n' > "$fresh_adaptive/.codex/agents/aspera-verifier.toml"
  rc="$(install_direct "$TMP_ROOT/fresh-adaptive-refuse.out" "$fresh_adaptive")"
  assert_eq "$rc" '1' 'fresh adaptive install refuses unmanaged legacy roles'
  rc="$(install_direct "$TMP_ROOT/fresh-adaptive-force.out" "$fresh_adaptive" --force)"
  assert_eq "$rc" '0' 'forced adaptive install reconciles unmanaged legacy roles'
  assert_absent "$fresh_adaptive/.codex/agents/aspera-worker.toml" 'forced adaptive install removes legacy worker'
  assert_absent "$fresh_adaptive/.codex/agents/aspera-verifier.toml" 'forced adaptive install removes legacy verifier'

  mkdir -p "$current_luna"
  install_direct "$TMP_ROOT/current-luna-seed.out" "$current_luna" --profile luna >/dev/null
  printf 'late spark role\n' > "$current_luna/.codex/agents/aspera-spark-worker.toml"
  rc="$(install_direct "$TMP_ROOT/current-luna-refuse.out" "$current_luna")"
  assert_eq "$rc" '1' 'current Luna install detects an unrecorded Spark role'
  rc="$(capture "$TMP_ROOT/current-luna-diagnose.out" bash "$CLI" diagnose --workspace "$current_luna")"
  assert_eq "$rc" '1' 'exact diagnosis rejects a role absent from the receipt'
  rc="$(install_direct "$TMP_ROOT/current-luna-force.out" "$current_luna" --force)"
  assert_eq "$rc" '0' 'forced Luna update removes an unrecorded Spark role'
  assert_absent "$current_luna/.codex/agents/aspera-spark-worker.toml" 'updated Luna profile contains no Spark role'
}

test_concurrent_change_refusal() {
  local target="$TMP_ROOT/concurrent-change" wrapper="$TMP_ROOT/concurrent-bin" rc real_python
  mkdir -p "$target" "$wrapper"
  install_direct "$TMP_ROOT/concurrent-seed.out" "$target" >/dev/null
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
    ASPERA_CONCURRENT_TARGET="$target/.codex/agents/aspera-luna-worker.toml" \
    ASPERA_CONCURRENT_MARKER="$TMP_ROOT/concurrent-triggered" \
    ASPERA_CONCURRENT_SNAPSHOT_LINES=11 \
    bash "$INSTALL" --workspace "$target" --profile luna)"
  assert_eq "$rc" '1' 'concurrent managed-file change aborts installation'
  assert_contains "$target/.codex/agents/aspera-luna-worker.toml" '# concurrent user edit' 'concurrent user change is preserved'
  assert_schema4 "$target/$STATE_REL" adaptive 1
  assert_file "$target/.codex/agents/aspera-spark-worker.toml" 'aborted profile switch leaves the prior profile intact'
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
  for rel in "${MANAGED_ADAPTIVE[@]}" "$STATE_REL"; do
    assert_absent "$target/$rel" "uninstall removes $rel"
  done
  assert_absent "$target/AGENTS.md" 'uninstall removes policy-only AGENTS.md'
}

test_plugin_refresh_failures() {
  local target rc

  reset_stub
  target="$TMP_ROOT/plugin-marketplace-mismatch"
  mkdir -p "$target"
  export ASPERA_STUB_MARKETPLACE_ROOT="$TMP_ROOT/another-aspera"
  mkdir -p "$ASPERA_STUB_MARKETPLACE_ROOT"
  rc="$(capture "$TMP_ROOT/marketplace-mismatch.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '1' 'mismatched Aspera marketplace is refused'
  assert_absent "$target/$STATE_REL" 'marketplace failure occurs before project writes'

  reset_stub
  target="$TMP_ROOT/plugin-marketplace-add"
  mkdir -p "$target"
  export ASPERA_STUB_MARKETPLACE_ROOT=''
  rc="$(capture "$TMP_ROOT/marketplace-add.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '0' 'missing marketplace is added'
  assert_contains "$COMMAND_LOG" "plugin marketplace add $ROOT --json" 'root command adds the checkout marketplace'
  assert_eq "$(stub_plugin_version)" '0.4.0' 'first plugin install matches the checkout version'

  reset_stub
  target="$TMP_ROOT/plugin-version-update"
  mkdir -p "$target"
  seed_stub_plugin '0.3.0'
  rc="$(capture "$TMP_ROOT/plugin-version-update.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '0' 'different-version plugin update succeeds directly'
  assert_not_contains "$COMMAND_LOG" 'plugin remove aspera-orchestrator@aspera' 'different-version update does not remove the prior plugin first'
  assert_eq "$(stub_plugin_version)" '0.4.0' 'different-version update verifies the checkout version'

  reset_stub
  target="$TMP_ROOT/plugin-wrong-source"
  mkdir -p "$target"
  seed_stub_plugin '0.4.0' 'other-marketplace' "$TMP_ROOT/other-marketplace"
  rc="$(capture "$TMP_ROOT/plugin-wrong-source.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '1' 'installed Aspera plugin from an unexpected marketplace is refused'
  assert_absent "$target/$STATE_REL" 'unexpected plugin source leaves project untouched'

  reset_stub
  target="$TMP_ROOT/plugin-remove-failure"
  mkdir -p "$target"
  seed_stub_plugin '0.4.0'
  export ASPERA_STUB_PLUGIN_REMOVE_STATUS=7
  rc="$(capture "$TMP_ROOT/plugin-remove-failure.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '1' 'same-version plugin removal failure is reported'
  assert_file "$STUB_STATE_DIR/plugin.json" 'failed removal preserves the installed plugin record'
  assert_absent "$target/$STATE_REL" 'plugin removal failure leaves project untouched'

  reset_stub
  target="$TMP_ROOT/plugin-reinstall-failure"
  mkdir -p "$target"
  seed_stub_plugin '0.4.0'
  export ASPERA_STUB_PLUGIN_ADD_STATUS=8
  rc="$(capture "$TMP_ROOT/plugin-reinstall-failure.out" bash "$CLI" install --workspace "$target")"
  assert_eq "$rc" '1' 'same-version plugin reinstall failure is reported'
  assert_absent "$STUB_STATE_DIR/plugin.json" 'failed same-version reinstall reports the removed prior plugin state'
  assert_absent "$target/$STATE_REL" 'plugin reinstall failure leaves project untouched'
  assert_contains "$TMP_ROOT/plugin-reinstall-failure.out" 'prior same-version plugin was removed' 'reinstall failure is actionable'

  reset_stub
  target="$TMP_ROOT/plugin-readback-failure"
  mkdir -p "$target"
  export ASPERA_STUB_PLUGIN_ADD_VERSION='0.3.0'
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
  assert_not_contains "$POLICY" 'Direct:' 'managed policy has no Direct mode'
  assert_not_contains "$POLICY" 'Express:' 'managed policy has no Express mode'
  assert_not_contains "$POLICY" 'Standard:' 'managed policy has no Standard mode'
  assert_contains "$POLICY" 'Luna Max is the default worker' 'managed policy is Luna-first'
  assert_contains "$PROTOCOL" 'Never use Spark' 'lazy protocol contains strict Spark exclusions'
  assert_contains "$ROOT/AGENTS.md" 'Always implement Aspera itself parent-direct' 'Aspera development is parent-direct'
  assert_contains "$ROOT/AGENTS.md" './aspera install --workspace' 'repository policy pins the one-command lifecycle'
  assert_contains "$ROOT/AGENTS.md" 'Preserve the installed profile and policy' 'repository policy pins update preservation'
  assert_contains "$ROOT/AGENTS.md" 'commit the receipt last' 'repository policy pins transactional ordering'
  assert_contains "$ROOT/AGENTS.md" 'never run doctor automatically' 'repository policy forbids installation ceremony'
  assert_contains "$ROOT/README.md" '--install-policy' 'public documentation exposes policy re-enablement'
  assert_contains "$ROOT/aspera" '--install-policy|--no-policy' 'root help exposes both policy controls'
}

test_root_install
test_profiles_and_alias
test_legacy_migrations
test_drift_and_transactions
test_profile_excluded_conflicts
test_concurrent_change_refusal
test_unsafe_paths
test_diagnose_and_uninstall
test_plugin_refresh_failures
test_contract_text

printf '[SUMMARY] passes=%s failures=%s\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
