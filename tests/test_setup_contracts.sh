#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${ASPERA_TMP_ROOT:-$(mktemp -d)}"
TMP_ROOT_CREATED=0
if [[ -z "${ASPERA_TMP_ROOT:-}" ]]; then
  TMP_ROOT_CREATED=1
fi

cleanup_tmp() {
  if [[ ${TMP_ROOT_CREATED} -eq 1 ]]; then
    rm -rf "${TMP_ROOT}"
  fi
}
trap cleanup_tmp EXIT

STUB_BIN="${ASPERA_CODEX_BIN:-${ROOT}/tests/fixtures/stub/bin/codex}"
STATE_FILE=".codex/aspera-orchestrator/state.json"
ASSETS_DIR="${ROOT}/plugins/aspera-orchestrator/skills/setup/assets/profiles"
INSTALL_SCRIPT="${ROOT}/plugins/aspera-orchestrator/skills/setup/scripts/install.sh"
DOCTOR_SCRIPT="${ROOT}/plugins/aspera-orchestrator/skills/setup/scripts/doctor.sh"
UNINSTALL_SCRIPT="${ROOT}/plugins/aspera-orchestrator/skills/setup/scripts/uninstall.sh"
WORK_ROOT="${TMP_ROOT}/workspace"

mkdir -p "${WORK_ROOT}"
if [[ ! -x "${STUB_BIN}" || ! -x "${INSTALL_SCRIPT}" || ! -x "${DOCTOR_SCRIPT}" || ! -x "${UNINSTALL_SCRIPT}" ]]; then
  echo "required binaries/scripts are not executable" >&2
  exit 1
fi
export ASPERA_CODEX_BIN="${STUB_BIN}"

MANAGED_ROLES=(
  ".codex/agents/aspera-explorer.toml"
  ".codex/agents/aspera-worker.toml"
  ".codex/agents/aspera-verifier.toml"
  ".codex/agents/aspera-researcher.toml"
  ".codex/agents/aspera-reviewer.toml"
  ".codex/aspera-orchestrator/worker_guard.py"
)

failed=0
pass_count=0
skip_count=0

hash_file() {
  local path="$1"
  python3 - "${path}" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

snapshot_signature() {
  local path="$1"
  python3 - "$path" <<'PY'
import hashlib
import os
import sys

root = sys.argv[1]
entries = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    filenames.sort()
    for name in filenames:
        full = os.path.join(dirpath, name)
        if not os.path.isfile(full):
            continue
        with open(full, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        entries.append(f"{os.path.relpath(full, root)}\t{digest}")
print("\n".join(entries))
PY
}

capture() {
  local outfile="$1"
  shift
  set +e
  "$@" >"${outfile}" 2>&1
  local status=$?
  set -e
  echo "${status}"
}

assert_true() {
  local condition="$1"
  local message="$2"
  if bash -lc "${condition}"; then
    echo "[PASS] ${message}"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] ${message}"
    failed=1
  fi
}

assert_exit() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "[PASS] ${message}"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] ${message} expected=${expected} actual=${actual}"
    failed=1
  fi
}

assert_file() {
  local path="$1"
  local message="$2"
  assert_true "[[ -f \"${path}\" ]]" "${message}"
}

read_state_value() {
  local state_file="$1"
  local field
  field="$2"
  shift 2
  python3 - "$state_file" "$field" "$@" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
value = data.get(sys.argv[2], "")
if sys.argv[3:]:
    for key in sys.argv[3:]:
        if not isinstance(value, dict):
            print("")
            raise SystemExit(0)
        value = value.get(key, "")
if isinstance(value, bool):
    print("1" if value else "0")
elif isinstance(value, (dict, list)):
    import json as _json
    print(_json.dumps(value, sort_keys=True))
else:
    print(value if value is not None else "")
PY
}

asset_path() {
  local profile="$1"
  local role="$2"
  case "${role}" in
    explorer|worker|verifier)
      echo "${ASSETS_DIR}/${profile}/${role}.toml"
      ;;
    researcher|reviewer)
      echo "${ASSETS_DIR}/shared/${role}.toml"
      ;;
    guard)
      echo "${ROOT}/plugins/aspera-orchestrator/skills/setup/assets/worker_guard.py"
      ;;
    *) echo "" ;;
  esac
}

assert_state_contract() {
  local state_file="$1"
  local profile="$2"
  python3 - "$state_file" "$profile" <<'PY'
import json
import pathlib
import re
import sys

state_path, profile = sys.argv[1:3]
state = json.loads(pathlib.Path(state_path).read_text(encoding="utf-8"))

if state.get("schema_version") != 2:
    raise SystemExit(1)
if state.get("plugin") != "aspera-orchestrator":
    raise SystemExit(1)
if state.get("plugin_version") != "0.2.0":
    raise SystemExit(1)
if state.get("profile") != profile:
    raise SystemExit(1)

models = state.get("models", {})
efforts = state.get("efforts", {})
managed = state.get("managed_files", {})
guard = state.get("guard", {})
if set(models.keys()) != {"primary", "researcher", "reviewer"}:
    raise SystemExit(1)
if set(efforts.keys()) != {"primary", "researcher", "reviewer"}:
    raise SystemExit(1)
for key in ("primary", "researcher", "reviewer"):
    if not isinstance(models.get(key), str) or not models.get(key):
        raise SystemExit(1)
    if not isinstance(efforts.get(key), str) or not efforts.get(key):
        raise SystemExit(1)

if profile == "spark":
    if models["primary"] != "gpt-5.3-codex-spark" or efforts["primary"] != "xhigh":
        raise SystemExit(1)
else:
    if models["primary"] != "gpt-5.6-luna" or efforts["primary"] != "max":
        raise SystemExit(1)
if models["researcher"] != "gpt-5.6-luna" or efforts["researcher"] != "max":
    raise SystemExit(1)
if models["reviewer"] != "gpt-5.6-terra" or efforts["reviewer"] != "high":
    raise SystemExit(1)

if not isinstance(managed, dict):
    raise SystemExit(1)
required = {
    ".codex/agents/aspera-explorer.toml",
    ".codex/agents/aspera-worker.toml",
    ".codex/agents/aspera-verifier.toml",
    ".codex/agents/aspera-researcher.toml",
    ".codex/agents/aspera-reviewer.toml",
    ".codex/aspera-orchestrator/worker_guard.py",
}
if set(managed.keys()) != required:
    raise SystemExit(1)
for key in required:
    if not isinstance(managed[key], str) or re.fullmatch(r"[0-9a-f]{64}", managed[key]) is None:
        raise SystemExit(1)

if guard != {
    "required": True,
    "verified": False,
    "profile": "",
    "asset_hash": managed[".codex/aspera-orchestrator/worker_guard.py"],
    "verified_at": "",
}:
    raise SystemExit(1)

if state.get("policy_installed") not in (0, False, 1, True):
    raise SystemExit(1)
state_policy = bool(state.get("policy_installed"))
if not isinstance(state.get("policy_hash"), str):
    raise SystemExit(1)
if state_policy and re.fullmatch(r"[0-9a-f]{64}", state.get("policy_hash")) is None:
    raise SystemExit(1)
if not state_policy and state.get("policy_hash") != "":
    raise SystemExit(1)
PY
}

assert_managed_state_hashes() {
  local state_file="$1"
  local profile="$2"
  local role
  local managed_file
  for managed_file in "${MANAGED_ROLES[@]}"; do
    if [[ "${managed_file}" == ".codex/aspera-orchestrator/worker_guard.py" ]]; then
      role="guard"
    else
      role="${managed_file#*aspera-}"
      role="${role%.toml}"
    fi
    local source
    source="$(asset_path "${profile}" "${role}")"
    local expected
    expected="$(hash_file "${source}")"
    local actual
    actual="$(read_state_value "${state_file}" managed_files "${managed_file}")"
    assert_exit "${actual}" "${expected}" "state managed hash for ${managed_file} matches ${source}"
  done
}

assert_installed_roles() {
  local target="$1"
  local profile="$2"
  local role
  local managed_file
  for managed_file in "${MANAGED_ROLES[@]}"; do
    if [[ "${managed_file}" == ".codex/aspera-orchestrator/worker_guard.py" ]]; then
      role="guard"
    else
      role="${managed_file#*aspera-}"
      role="${role%.toml}"
    fi
    local source
    source="$(asset_path "${profile}" "${role}")"
    local installed="${target}/${managed_file}"
    assert_file "${installed}" "installed role file exists: ${managed_file}"
    if cmp -s "${source}" "${installed}"; then
      echo "[PASS] installed file ${managed_file} matches ${profile} asset"
      pass_count=$((pass_count + 1))
    else
      echo "[FAIL] installed file ${managed_file} does not match ${source}"
      failed=1
    fi

    if [[ "${role}" == "guard" ]]; then
      if python3 "${installed}" --help >/dev/null; then
        echo "[PASS] installed worker guard is executable by Python"
        pass_count=$((pass_count + 1))
      else
        echo "[FAIL] installed worker guard is not executable by Python"
        failed=1
      fi
      continue
    fi

    python3 - "$installed" "${role}" "${profile}" <<'PY'
import sys
import tomllib
from pathlib import Path

path, role, profile = sys.argv[1:4]
data = tomllib.loads(Path(path).read_text(encoding="utf-8"))
if not isinstance(data, dict):
    raise SystemExit(1)
expected_name = {
    "explorer": "aspera_explorer",
    "worker": "aspera_worker",
    "verifier": "aspera_verifier",
    "researcher": "aspera_researcher",
    "reviewer": "aspera_reviewer",
}[role]
expected_sandbox = {"explorer": "read-only", "worker": "workspace-write", "verifier": "workspace-write", "researcher": "read-only", "reviewer": "read-only"}[role]
expected_effort = "xhigh" if profile == "spark" and role in {"explorer", "worker", "verifier"} else (
    "max" if profile in {"spark", "luna"} and role in {"explorer", "worker", "verifier", "researcher"} else "high"
)
expected_model = {
    "spark": {
        "explorer": "gpt-5.3-codex-spark",
        "worker": "gpt-5.3-codex-spark",
        "verifier": "gpt-5.3-codex-spark",
        "researcher": "gpt-5.6-luna",
        "reviewer": "gpt-5.6-terra",
    },
    "luna": {
        "explorer": "gpt-5.6-luna",
        "worker": "gpt-5.6-luna",
        "verifier": "gpt-5.6-luna",
        "researcher": "gpt-5.6-luna",
        "reviewer": "gpt-5.6-terra",
    },
}[profile][role]

if data.get("name") != expected_name:
    raise SystemExit(1)
if data.get("model") != expected_model:
    raise SystemExit(1)
if data.get("model_reasoning_effort") != expected_effort:
    raise SystemExit(1)
if data.get("sandbox_mode") != expected_sandbox:
    raise SystemExit(1)
PY
  done
}

assert_no_config_mutation() {
  local baseline="$1"
  local target="$2"
  local message="$3"
  local now
  now="$(hash_file "${target}")"
  assert_exit "${now}" "${baseline}" "${message}"
}

run_install() {
  local out="$1"
  shift
  local args=("$@")
  capture "${out}" bash "${INSTALL_SCRIPT}" "${args[@]}"
}

test_stub_contract() {
  local exit_code
  set +e
  "${STUB_BIN}" --version >/dev/null
  exit_code=$?
  set -e
  assert_exit "${exit_code}" "0" "stub codex binary is executable and reports version"

  local catalog
  catalog="$("${STUB_BIN}" catalog)"
  if [[ "${catalog}" == *"gpt-5.6-luna"* ]]; then
    echo "[PASS] stub returns deterministic model catalog"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] stub model catalog does not contain deterministic contract model"
    failed=1
  fi

  local refreshed_args="${TMP_ROOT}/stub_refreshed_catalog_args.txt"
  local refreshed_target="${WORK_ROOT}/stub-refreshed-catalog"
  rm -rf "${refreshed_target}"
  mkdir -p "${refreshed_target}"
  rc="$(ASPERA_STUB_DEBUG_MODELS_ARGS_FILE="${refreshed_args}" capture "${TMP_ROOT}/stub_refreshed_install.out" bash "${INSTALL_SCRIPT}" --profile spark "${refreshed_target}")"
  assert_exit "${rc}" "0" "installer accepts the authenticated refreshed model catalog"
  assert_exit "$(cat "${refreshed_args}")" "debug models" "installer does not restrict preflight to the bundled catalog"

  local out="${TMP_ROOT}/stub_exec.out"
  local args_file="${TMP_ROOT}/stub_exec_args.txt"
  local rc
  rc="$(ASPERA_SMOKE_ARGS_FILE="${args_file}" capture "${out}" bash "${STUB_BIN}" exec --cd "${WORK_ROOT}" --skip-git-repo-check --ephemeral --ignore-user-config --sandbox read-only --json "Spawn aspera_explorer and respond with ASPERA_EXPLORER_SMOKE_OK")"
  assert_exit "${rc}" "0" "stub supports codex exec"
  if [[ -f "${args_file}" ]]; then
    if grep -q -- "--cd" "${args_file}" \
      && grep -q -- "${WORK_ROOT}" "${args_file}" \
      && grep -q -- "--skip-git-repo-check" "${args_file}" \
      && grep -q -- "--ephemeral" "${args_file}" \
      && grep -q -- "--ignore-user-config" "${args_file}" \
      && grep -q -- "--sandbox" "${args_file}" \
      && grep -q -- "read-only" "${args_file}" \
      && grep -q -- "--json" "${args_file}"; then
      echo "[PASS] stub records smoke exec arguments"
      pass_count=$((pass_count + 1))
    else
      echo "[FAIL] stub exec args not recorded as expected"
      failed=1
    fi
  else
    echo "[FAIL] stub did not write ASPERA_SMOKE_ARGS_FILE"
    failed=1
  fi

  if grep -q -- "ASPERA_EXPLORER_SMOKE_OK" "${out}"; then
    echo "[PASS] stub returns ASPERA_EXPLORER_SMOKE_OK"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] stub smoke run output did not include ASPERA_EXPLORER_SMOKE_OK"
    failed=1
  fi
}

test_profile_install_contract() {
  local target="$1"
  local profile="$2"
  local catalog
  catalog="$3"
  local out="${TMP_ROOT}/install_${profile}.out"
  local rc

  rm -rf "${target}"
  mkdir -p "${target}"
  local before
  before="$(snapshot_signature "${target}")"
  if [[ "${catalog}" != "" ]]; then
    rc="$(ASPERA_STUB_CATALOG="${catalog}" capture "${out}" bash "${INSTALL_SCRIPT}" --profile "${profile}" "${target}")"
  else
    rc="$(capture "${out}" bash "${INSTALL_SCRIPT}" --profile "${profile}" "${target}")"
  fi
  assert_exit "${rc}" "0" "install ${profile} completes"
  if [[ ${rc} -ne 0 ]]; then
    return
  fi

  assert_file "${target}/${STATE_FILE}" "install ${profile} writes state marker"
  assert_state_contract "${target}/${STATE_FILE}" "${profile}"
  assert_installed_roles "${target}" "${profile}"
  assert_managed_state_hashes "${target}/${STATE_FILE}" "${profile}"

  assert_exit "$(read_state_value "${target}/${STATE_FILE}" schema_version)" "2" "state schema_version is 2"
  local expected_profile_policy="0"
  assert_exit "$(read_state_value "${target}/${STATE_FILE}" policy_installed)" "${expected_profile_policy}" "install ${profile} defaults policy_installed=false"

  local after
  after="$(snapshot_signature "${target}")"
  assert_true "[[ \"${before}\" != \"${after}\" ]]" "install ${profile} performs actual writes"
}

test_install_contracts() {
  local spark_target="${WORK_ROOT}/install-spark"
  local luna_target="${WORK_ROOT}/install-luna"
  local malformed_target="${WORK_ROOT}/install-missing-model"
  local bad_effort_target="${WORK_ROOT}/install-bad-effort"

  test_profile_install_contract "${spark_target}" "spark" ""
  local spark_state="${spark_target}/${STATE_FILE}"
  if [[ -f "${spark_state}" ]]; then
    assert_exit "$(read_state_value "${spark_state}" profile)" "spark" "state profile is spark"
    assert_exit "$(read_state_value "${spark_state}" policy_installed)" "0" "policy flag defaults false"
    assert_exit "$(read_state_value "${spark_state}" models)" "{\"primary\": \"gpt-5.3-codex-spark\", \"researcher\": \"gpt-5.6-luna\", \"reviewer\": \"gpt-5.6-terra\"}" "state models exact for spark"
    assert_exit "$(read_state_value "${spark_state}" efforts)" "{\"primary\": \"xhigh\", \"researcher\": \"max\", \"reviewer\": \"high\"}" "state efforts exact for spark"
  else
    echo "[FAIL] spark install did not write state file"
    failed=1
  fi

  local pre_hash pre_roles
  pre_hash="$(hash_file "${spark_state}")"
  pre_roles="$(snapshot_signature "${spark_target}")"

  rc="$(capture "${TMP_ROOT}/install_idem.out" bash "${INSTALL_SCRIPT}" "${spark_target}")"
  assert_exit "${rc}" "0" "second install is idempotent"
  post_hash="$(hash_file "${spark_state}")"
  post_roles="$(snapshot_signature "${spark_target}")"
  assert_exit "${pre_hash}" "${post_hash}" "state file stable across repeated install"
  assert_exit "${pre_roles}" "${post_roles}" "managed artifacts stable across repeated install"

  local clean_upgrade_target="${WORK_ROOT}/clean-v2-upgrade"
  rm -rf "${clean_upgrade_target}"
  mkdir -p "${clean_upgrade_target}"
  capture "${TMP_ROOT}/clean_v2_seed.out" bash "${INSTALL_SCRIPT}" "${clean_upgrade_target}" >/dev/null
  printf '\n# prior managed v2 asset\n' >> "${clean_upgrade_target}/.codex/agents/aspera-worker.toml"
  local prior_managed_hash
  prior_managed_hash="$(hash_file "${clean_upgrade_target}/.codex/agents/aspera-worker.toml")"
  python3 - "${clean_upgrade_target}/${STATE_FILE}" "${prior_managed_hash}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text(encoding="utf-8"))
state["managed_files"][".codex/agents/aspera-worker.toml"] = sys.argv[2]
path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
PY
  rc="$(capture "${TMP_ROOT}/clean_v2_upgrade.out" bash "${INSTALL_SCRIPT}" "${clean_upgrade_target}")"
  assert_exit "${rc}" "0" "clean schema-v2 managed asset update succeeds without force"
  assert_exit "$(hash_file "${clean_upgrade_target}/.codex/agents/aspera-worker.toml")" "$(hash_file "${ASSETS_DIR}/spark/worker.toml")" "clean schema-v2 update installs current worker asset"

  local v1_target="${WORK_ROOT}/v1-hard-break"
  rm -rf "${v1_target}"
  mkdir -p "${v1_target}/.codex/aspera-orchestrator"
  printf '%s\n' '{"schema_version":1,"plugin":"aspera-orchestrator","plugin_version":"0.1.0"}' > "${v1_target}/${STATE_FILE}"
  rc="$(capture "${TMP_ROOT}/v1_hard_break.out" bash "${INSTALL_SCRIPT}" "${v1_target}")"
  assert_exit "${rc}" "1" "schema-v1 state is a hard break"
  if grep -q -- "does not upgrade older state" "${TMP_ROOT}/v1_hard_break.out"; then
    echo "[PASS] schema-v1 hard break reports explicit reinstall guidance"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] schema-v1 hard break guidance missing"
    failed=1
  fi

  rc="$(capture "${TMP_ROOT}/install_switch.out" bash "${INSTALL_SCRIPT}" --profile luna "${spark_target}")"
  assert_exit "${rc}" "0" "clean profile switch to luna succeeds"
  assert_exit "$(read_state_value "${spark_state}" profile)" "luna" "profile switch is recorded"

  local config_target="${WORK_ROOT}/config-identity"
  rm -rf "${config_target}"
  mkdir -p "${config_target}/.codex"
  printf "%s\n" "# test config\n" "keep=true" > "${config_target}/.codex/config.toml"
  local config_hash
  config_hash="$(hash_file "${config_target}/.codex/config.toml")"
  rc="$(capture "${TMP_ROOT}/install_config.out" bash "${INSTALL_SCRIPT}" "${config_target}")"
  assert_exit "${rc}" "0" "install preserves pre-existing .codex/config.toml"
  assert_no_config_mutation "${config_hash}" "${config_target}/.codex/config.toml" ".codex/config.toml unchanged after install"
  rc="$(capture "${TMP_ROOT}/switch_config.out" bash "${INSTALL_SCRIPT}" --profile luna "${config_target}")"
  assert_exit "${rc}" "0" "profile switch preserves pre-existing .codex/config.toml"
  assert_no_config_mutation "${config_hash}" "${config_target}/.codex/config.toml" ".codex/config.toml unchanged after profile switch"

  assert_file "${config_target}/${STATE_FILE}" "state exists after profile switch with existing config"

  test_profile_install_contract "${luna_target}" "luna" ""
  local luna_state="${luna_target}/${STATE_FILE}"
  if [[ -f "${luna_state}" ]]; then
    assert_exit "$(read_state_value "${luna_state}" profile)" "luna" "luna install defaults profile to luna"
    assert_exit "$(read_state_value "${luna_state}" models)" "{\"primary\": \"gpt-5.6-luna\", \"researcher\": \"gpt-5.6-luna\", \"reviewer\": \"gpt-5.6-terra\"}" "state models exact for luna"
    assert_exit "$(read_state_value "${luna_state}" efforts)" "{\"primary\": \"max\", \"researcher\": \"max\", \"reviewer\": \"high\"}" "state efforts exact for luna"
  else
    echo "[FAIL] luna install did not write state file"
    failed=1
  fi

  local missing_catalog="${TMP_ROOT}/missing_spark.json"
  cat > "${missing_catalog}" <<'JSON'
{
  "models": [
    {
      "slug": "gpt-5.6-luna",
      "supported_reasoning_levels": [
        {"effort": "max"}
      ]
    },
    {
      "slug": "gpt-5.6-terra",
      "supported_reasoning_levels": [
        {"effort": "high"}
      ]
    }
  ]
}
JSON
  rm -rf "${malformed_target}"
  mkdir -p "${malformed_target}"
  local bad_before
  bad_before="$(snapshot_signature "${malformed_target}")"
  rc="$(ASPERA_STUB_CATALOG="${missing_catalog}" capture "${TMP_ROOT}/install_bad_model.out" bash "${INSTALL_SCRIPT}" "${malformed_target}")"
  assert_exit "${rc}" "1" "install fails when spark catalog entry is missing"
  local bad_after
  bad_after="$(snapshot_signature "${malformed_target}")"
  assert_exit "${bad_before}" "${bad_after}" "missing-model failure leaves target unmodified"
  rm -f "${malformed_target}/${STATE_FILE}"

  local low_effort_catalog="${TMP_ROOT}/bad_effort.json"
  cat > "${low_effort_catalog}" <<'JSON'
{
  "models": [
    {
      "slug": "gpt-5.3-codex-spark",
      "supported_reasoning_levels": [
        {"effort": "high"}
      ]
    },
    {
      "slug": "gpt-5.6-luna",
      "supported_reasoning_levels": [
        {"effort": "max"}
      ]
    },
    {
      "slug": "gpt-5.6-terra",
      "supported_reasoning_levels": [
        {"effort": "high"}
      ]
    }
  ]
}
JSON
  rm -rf "${bad_effort_target}"
  mkdir -p "${bad_effort_target}"
  local bad_before2
  bad_before2="$(snapshot_signature "${bad_effort_target}")"
  rc="$(ASPERA_STUB_CATALOG="${low_effort_catalog}" capture "${TMP_ROOT}/install_bad_effort.out" bash "${INSTALL_SCRIPT}" --profile spark "${bad_effort_target}")"
  assert_exit "${rc}" "1" "install fails when spark catalog does not provide xhigh"
  local bad_after2
  bad_after2="$(snapshot_signature "${bad_effort_target}")"
  assert_exit "${bad_before2}" "${bad_after2}" "effort-fail leaves target unmodified"

  local drift_target="${WORK_ROOT}/install-drift"
  rm -rf "${drift_target}"
  mkdir -p "${drift_target}"
  capture "${TMP_ROOT}/drift_install.out" bash "${INSTALL_SCRIPT}" --profile luna "${drift_target}" >/dev/null
  printf "corrupted\n" > "${drift_target}/.codex/agents/aspera-worker.toml"
  local drift_before
  drift_before="$(snapshot_signature "${drift_target}")"
  rc="$(capture "${TMP_ROOT}/drift_install_blocked.out" bash "${INSTALL_SCRIPT}" --profile luna "${drift_target}")"
  assert_exit "${rc}" "1" "modified live role refuses install without --force"
  local drift_after
  drift_after="$(snapshot_signature "${drift_target}")"
  assert_exit "${drift_before}" "${drift_after}" "drift refusal makes no changes without --force"
  rc="$(capture "${TMP_ROOT}/drift_install_force.out" bash "${INSTALL_SCRIPT}" --profile luna --force "${drift_target}")"
  assert_exit "${rc}" "0" "modified live role replaced when --force is used"
  local backup_dir
  backup_dir="$(find "${drift_target}/.codex/aspera-orchestrator/backups" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
  if [[ -d "${backup_dir}" ]]; then
    assert_true "[[ -f \"${backup_dir}/.codex/agents/aspera-worker.toml\" ]]" "force install creates backup for drifted managed file"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] force install did not create managed backup directory"
    failed=1
  fi

  local dry_sig_before
  dry_sig_before="$(snapshot_signature "${drift_target}")"
  rc="$(capture "${TMP_ROOT}/install_dry.out" bash "${INSTALL_SCRIPT}" --dry-run --force --profile luna "${drift_target}")"
  assert_exit "${rc}" "0" "dry-run with drift and --force exits successfully"
  local dry_sig_after
  dry_sig_after="$(snapshot_signature "${drift_target}")"
  assert_exit "${dry_sig_before}" "${dry_sig_after}" "dry-run with drift and --force has no target mutation"

  local dry_target="${WORK_ROOT}/install-dry-run"
  rm -rf "${dry_target}"
  mkdir -p "${dry_target}"
  local dry_fresh_before
  dry_fresh_before="$(snapshot_signature "${dry_target}")"
  rc="$(capture "${TMP_ROOT}/install_dry_fresh.out" bash "${INSTALL_SCRIPT}" --dry-run --force --profile luna "${dry_target}")"
  assert_exit "${rc}" "0" "dry-run on fresh target succeeds"
  local dry_fresh_after
  dry_fresh_after="$(snapshot_signature "${dry_target}")"
  assert_exit "${dry_fresh_before}" "${dry_fresh_after}" "dry-run on fresh target has no target mutation"
}

test_symlink_contracts() {
  local none_target="${WORK_ROOT}/missing-target"
  rc="$(capture "${TMP_ROOT}/missing.out" bash "${INSTALL_SCRIPT}" "${none_target}")"
  if [[ "${rc}" == "0" ]]; then
    echo "[FAIL] nonexistent target unexpectedly accepted"
    failed=1
  else
    echo "[PASS] nonexistent target is rejected"
    pass_count=$((pass_count + 1))
  fi

  local symlink_target="${WORK_ROOT}/symlinked"
  rm -rf "${symlink_target}" "${symlink_target}-real"
  mkdir -p "${symlink_target}-real"
  ln -s "${symlink_target}-real" "${symlink_target}"
  rc="$(capture "${TMP_ROOT}/symlink.out" bash "${INSTALL_SCRIPT}" "${symlink_target}")"
  if [[ "${rc}" == "0" ]]; then
    echo "[FAIL] symlinked target unexpectedly accepted"
    failed=1
  else
    echo "[PASS] symlinked target is rejected"
    pass_count=$((pass_count + 1))
  fi

  local managed_parent="${WORK_ROOT}/symlink-parent"
  rm -rf "${managed_parent}"
  mkdir -p "${managed_parent}"
  mkdir -p "${managed_parent}/realcodex"
  ln -s "${managed_parent}/realcodex" "${managed_parent}/.codex"
  rc="$(capture "${TMP_ROOT}/symlink_parent.out" bash "${INSTALL_SCRIPT}" "${managed_parent}")"
  assert_exit "${rc}" "1" "symlinked managed parent is rejected"

  local state_target="${WORK_ROOT}/symlink-state"
  mkdir -p "${state_target}/.codex/aspera-orchestrator"
  ln -s /dev/null "${state_target}/.codex/aspera-orchestrator/state.json"
  rc="$(capture "${TMP_ROOT}/symlink_state.out" bash "${INSTALL_SCRIPT}" "${state_target}")"
  assert_exit "${rc}" "1" "symlinked state path is rejected"
  rm -f "${state_target}/.codex/aspera-orchestrator/state.json"

  local agents_target="${WORK_ROOT}/symlink-agents"
  mkdir -p "${agents_target}/.codex"
  ln -s "${agents_target}/.codex" "${agents_target}/.codex/agents"
  rc="$(capture "${TMP_ROOT}/symlink_agents.out" bash "${INSTALL_SCRIPT}" "${agents_target}")"
  assert_exit "${rc}" "1" "symlinked managed agents dir is rejected"

  local agents_target2="${WORK_ROOT}/symlink-agents2"
  mkdir -p "${agents_target2}/.codex/agents"
  ln -s "${agents_target2}/missing-role" "${agents_target2}/.codex/agents/aspera-worker.toml"
  rc="$(capture "${TMP_ROOT}/symlink_agents2.out" bash "${INSTALL_SCRIPT}" "${agents_target2}")"
  assert_exit "${rc}" "1" "symlinked managed role file is rejected"

  local agents_target3="${WORK_ROOT}/symlink-root-agents"
  mkdir -p "${agents_target3}/.codex"
  ln -s "${agents_target3}/.codex" "${agents_target3}/AGENTS.md"
  rc="$(capture "${TMP_ROOT}/symlink_agfile.out" bash "${INSTALL_SCRIPT}" "${agents_target3}")"
  assert_exit "${rc}" "1" "symlinked root AGENTS.md is rejected"

  local backup_target="${WORK_ROOT}/symlink-install-backups"
  local backup_external="${WORK_ROOT}/symlink-install-external"
  rm -rf "${backup_target}" "${backup_external}"
  mkdir -p "${backup_target}" "${backup_external}"
  capture "${TMP_ROOT}/symlink_backup_install_seed.out" bash "${INSTALL_SCRIPT}" --profile luna "${backup_target}" >/dev/null
  printf '%s\n' 'drift' > "${backup_target}/.codex/agents/aspera-worker.toml"
  ln -s "${backup_external}" "${backup_target}/.codex/aspera-orchestrator/backups"
  rc="$(capture "${TMP_ROOT}/symlink_backup_install.out" bash "${INSTALL_SCRIPT}" --profile luna --force "${backup_target}")"
  assert_exit "${rc}" "1" "force install rejects symlinked backup directory"
  assert_exit "$(snapshot_signature "${backup_external}")" "" "rejected install writes nothing through backup symlink"
  assert_file "${backup_target}/.codex/agents/aspera-worker.toml" "rejected install preserves drifted managed file"

  local uninstall_target="${WORK_ROOT}/symlink-uninstall-backups"
  local uninstall_external="${WORK_ROOT}/symlink-uninstall-external"
  rm -rf "${uninstall_target}" "${uninstall_external}"
  mkdir -p "${uninstall_target}" "${uninstall_external}"
  capture "${TMP_ROOT}/symlink_backup_uninstall_seed.out" bash "${INSTALL_SCRIPT}" --profile luna "${uninstall_target}" >/dev/null
  printf '%s\n' 'drift' > "${uninstall_target}/.codex/agents/aspera-worker.toml"
  ln -s "${uninstall_external}" "${uninstall_target}/.codex/aspera-orchestrator/backups"
  rc="$(capture "${TMP_ROOT}/symlink_backup_uninstall.out" bash "${UNINSTALL_SCRIPT}" --force "${uninstall_target}")"
  assert_exit "${rc}" "1" "force uninstall rejects symlinked backup directory"
  assert_exit "$(snapshot_signature "${uninstall_external}")" "" "rejected uninstall writes nothing through backup symlink"
  assert_file "${uninstall_target}/.codex/agents/aspera-worker.toml" "rejected uninstall preserves managed file"
  assert_file "${uninstall_target}/${STATE_FILE}" "rejected uninstall preserves state"
}

policy_marker_count() {
  local file="$1"
  python3 - "$file" <<'PY'
import pathlib
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore")
start = text.count("<!-- aspera-orchestrator:policy:start -->")
end = text.count("<!-- aspera-orchestrator:policy:end -->")
print(f"{start} {end}")
PY
}

test_policy_contracts() {
  local target="${WORK_ROOT}/policy"
  rm -rf "${target}"
  mkdir -p "${target}"
  capture "${TMP_ROOT}/policy_install.out" bash "${INSTALL_SCRIPT}" "${target}" >/dev/null
  printf "%s\n" "preexisting content" > "${target}/AGENTS.md"

  local rc
  rc="$(capture "${TMP_ROOT}/policy_add.out" bash "${INSTALL_SCRIPT}" --install-policy "${target}")"
  assert_exit "${rc}" "0" "policy create succeeds with preexisting AGENTS.md"
  local policy_backup
  policy_backup="$(find "${target}/.codex/aspera-orchestrator/backups" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
  assert_file "${policy_backup}/AGENTS.md" "policy append backs up preexisting AGENTS.md"
  assert_true "grep -Fq 'preexisting content' \"${policy_backup}/AGENTS.md\"" "policy backup preserves preexisting content"
  local counts
  counts="$(policy_marker_count "${target}/AGENTS.md")"
  if [[ "${counts}" == "1 1" ]]; then
    echo "[PASS] policy add creates exactly one marker pair"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] policy add did not create expected marker pair"
    failed=1
  fi
  local preappend
  preappend="$(cat "${target}/AGENTS.md")"
  rc="$(capture "${TMP_ROOT}/policy_idem.out" bash "${INSTALL_SCRIPT}" --install-policy "${target}")"
  assert_exit "${rc}" "0" "policy install idempotent with existing managed block"
  if [[ "${preappend}" == "$(cat "${target}/AGENTS.md")" ]]; then
    echo "[PASS] policy block remains stable under idempotent install-policy"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] policy idempotency changed AGENTS.md payload"
    failed=1
  fi

  python3 - "${target}/AGENTS.md" "${target}/${STATE_FILE}" <<'PY'
import hashlib
import json
import pathlib
import sys

agents = pathlib.Path(sys.argv[1])
state_path = pathlib.Path(sys.argv[2])
start = "<!-- aspera-orchestrator:policy:start -->"
end = "<!-- aspera-orchestrator:policy:end -->"
text = agents.read_text(encoding="utf-8")
before, remainder = text.split(start, 1)
_, after = remainder.split(end, 1)
prior = "prior managed schema-2 policy"
agents.write_text(before + start + "\n" + prior + "\n" + end + after, encoding="utf-8")
state = json.loads(state_path.read_text(encoding="utf-8"))
state["policy_hash"] = hashlib.sha256(prior.encode("utf-8")).hexdigest()
state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
PY
  rc="$(capture "${TMP_ROOT}/policy_clean_update.out" bash "${INSTALL_SCRIPT}" --install-policy "${target}")"
  assert_exit "${rc}" "0" "clean schema-v2 policy update succeeds without force"
  assert_true "grep -Fq 'Worker lifecycle protocol' \"${target}/AGENTS.md\"" "clean policy update installs current managed policy"

  printf "%s\n" \
    "<!-- aspera-orchestrator:policy:start -->" \
    "dup1" \
    "<!-- aspera-orchestrator:policy:end -->" \
    "<!-- aspera-orchestrator:policy:start -->" \
    "dup2" \
    "<!-- aspera-orchestrator:policy:end -->" > "${target}/AGENTS.md"
  rc="$(capture "${TMP_ROOT}/policy_dup.out" bash "${INSTALL_SCRIPT}" --install-policy "${target}")"
  assert_exit "${rc}" "1" "duplicate markers fail policy install"
  rc="$(capture "${TMP_ROOT}/policy_dup_force.out" bash "${INSTALL_SCRIPT}" --force --install-policy "${target}")"
  assert_exit "${rc}" "1" "duplicate markers still fail with --force"

  printf "%s\n" \
    "<!-- aspera-orchestrator:policy:end -->" \
    "reversed" \
    "<!-- aspera-orchestrator:policy:start -->" > "${target}/AGENTS.md"
  rc="$(capture "${TMP_ROOT}/policy_reversed.out" bash "${INSTALL_SCRIPT}" --install-policy "${target}")"
  assert_exit "${rc}" "1" "reversed markers fail policy install"
  rc="$(capture "${TMP_ROOT}/policy_reversed_force.out" bash "${INSTALL_SCRIPT}" --force --install-policy "${target}")"
  assert_exit "${rc}" "1" "reversed markers still fail with --force"

  printf "%s\n" "<!-- aspera-orchestrator:policy:start -->" "unbalanced" > "${target}/AGENTS.md"
  rc="$(capture "${TMP_ROOT}/policy_unbalanced.out" bash "${INSTALL_SCRIPT}" --install-policy "${target}")"
  assert_exit "${rc}" "1" "unbalanced start marker fails policy install"
  rc="$(capture "${TMP_ROOT}/policy_unbalanced_force.out" bash "${INSTALL_SCRIPT}" --force --install-policy "${target}")"
  assert_exit "${rc}" "1" "unbalanced markers still fail with --force"
}

test_doctor_contracts() {
  local target="${WORK_ROOT}/doctor"
  rm -rf "${target}"
  mkdir -p "${target}"
  capture "${TMP_ROOT}/doctor_install.out" bash "${INSTALL_SCRIPT}" "${target}" >/dev/null

  local out="${TMP_ROOT}/doctor.out"
  local rc
  rc="$(capture "${out}" bash "${DOCTOR_SCRIPT}" "${target}")"
  assert_exit "${rc}" "1" "doctor blocks delegation until worker guard verification"
  if grep -q -- "worker guard is unverified" "${out}"; then
    echo "[PASS] doctor reports the guard activation requirement"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] doctor guard activation guidance missing"
    failed=1
  fi
  rc="$(capture "${TMP_ROOT}/doctor_guard_activate.out" bash "${DOCTOR_SCRIPT}" --runtime-smoke worker "${target}")"
  assert_exit "${rc}" "0" "worker smoke activates guard verification"
  assert_exit "$(read_state_value "${target}/${STATE_FILE}" guard verified)" "1" "state records successful guard verification"
  rc="$(capture "${out}" bash "${DOCTOR_SCRIPT}" "${target}")"
  assert_exit "${rc}" "0" "doctor validates healthy installation"

  rc="$(capture "${out}" bash "${DOCTOR_SCRIPT}" --profile luna "${target}")"
  assert_exit "${rc}" "1" "doctor rejects profile mismatch"
  rm -f "${target}/.codex/agents/aspera-explorer.toml"
  rc="$(capture "${out}" bash "${DOCTOR_SCRIPT}" "${target}")"
  assert_exit "${rc}" "1" "doctor detects missing role file"
  rm -f "${target}/${STATE_FILE}"
  rc="$(capture "${out}" bash "${DOCTOR_SCRIPT}" "${target}")"
  assert_exit "${rc}" "1" "doctor detects missing state file"

  local target2="${WORK_ROOT}/doctor-warning"
  rm -rf "${target2}"
  mkdir -p "${target2}"
  capture "${TMP_ROOT}/doctor_install2.out" bash "${INSTALL_SCRIPT}" "${target2}" >/dev/null
  capture "${TMP_ROOT}/doctor_activate2.out" bash "${DOCTOR_SCRIPT}" --runtime-smoke worker "${target2}" >/dev/null
  printf "%s\n" \
    "<!-- aspera-orchestrator:policy:start -->" \
    "manual policy block" \
    "<!-- aspera-orchestrator:policy:end -->" > "${target2}/AGENTS.md"
  rc="$(capture "${out}" bash "${DOCTOR_SCRIPT}" "${target2}")"
  assert_exit "${rc}" "0" "doctor allows unmanaged policy marker with warning"
  if grep -Fq -- "[WARN] AGENTS.md contains an unmanaged policy block" "${out}"; then
    echo "[PASS] doctor emits unmanaged policy warning"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] doctor did not emit unmanaged policy warning"
    failed=1
  fi

  local config_target="${target2}/.codex/config.toml"
  mkdir -p "${target2}/.codex"
  printf "%s\n%s\n" "# doctor test config" "flag=true" > "${config_target}"
  local config_hash
  config_hash="$(hash_file "${config_target}")"
  rc="$(capture "${out}" bash "${DOCTOR_SCRIPT}" "${target2}")"
  assert_exit "${rc}" "0" "doctor does not alter existing .codex/config.toml"
  assert_no_config_mutation "${config_hash}" "${config_target}" ".codex/config.toml remains unchanged through doctor"

  local smoke_target="${WORK_ROOT}/doctor-smoke"
  rm -rf "${smoke_target}"
  mkdir -p "${smoke_target}"
  capture "${TMP_ROOT}/doctor_smoke_install.out" bash "${INSTALL_SCRIPT}" "${smoke_target}" >/dev/null
  local explorer_args_file="${TMP_ROOT}/doctor_explorer_smoke_args.txt"
  rc="$(ASPERA_SMOKE_ARGS_FILE="${explorer_args_file}" capture "${TMP_ROOT}/doctor_explorer_smoke.out" bash "${DOCTOR_SCRIPT}" --runtime-smoke explorer "${smoke_target}")"
  assert_exit "${rc}" "0" "explorer runtime smoke exits successfully"
  if grep -q -- "classification=EXPLORER_SUCCESS" "${TMP_ROOT}/doctor_explorer_smoke.out" \
    && grep -q -- "ASPERA_EXPLORER_SMOKE_OK" "${TMP_ROOT}/doctor_explorer_smoke.out"; then
    echo "[PASS] explorer runtime smoke reports a valid handoff"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] explorer runtime smoke does not report a valid handoff"
    failed=1
  fi
  if [[ -f "${explorer_args_file}" ]]; then
    if grep -q -- "${smoke_target}" "${explorer_args_file}" \
      && grep -q -- "--sandbox" "${explorer_args_file}" \
      && grep -q -- "read-only" "${explorer_args_file}" \
      && grep -q -- "--json" "${explorer_args_file}"; then
      echo "[PASS] explorer runtime smoke records expected exec arguments"
      pass_count=$((pass_count + 1))
    else
      echo "[FAIL] explorer runtime smoke exec arguments missing expected values"
      failed=1
    fi
  else
    echo "[FAIL] explorer runtime smoke did not record args"
    failed=1
  fi

  local worker_args_file="${TMP_ROOT}/doctor_worker_smoke_args.txt"
  rc="$(ASPERA_SMOKE_ARGS_FILE="${worker_args_file}" capture "${TMP_ROOT}/doctor_worker_smoke.out" bash "${DOCTOR_SCRIPT}" --runtime-smoke worker "${smoke_target}")"
  assert_exit "${rc}" "0" "worker runtime smoke exits successfully"
  if grep -q -- "classification=WORKER_SUCCESS" "${TMP_ROOT}/doctor_worker_smoke.out" \
    && grep -q -- "time_to_first_tool_seconds=" "${TMP_ROOT}/doctor_worker_smoke.out" \
    && grep -q -- "time_to_first_edit_seconds=" "${TMP_ROOT}/doctor_worker_smoke.out" \
    && grep -q -- "first_edit_deadline_seconds=90.000" "${TMP_ROOT}/doctor_worker_smoke.out" \
    && grep -q -- "guard_armed=1" "${TMP_ROOT}/doctor_worker_smoke.out" \
    && grep -q -- "ASPERA_WORKER_SMOKE_OK" "${TMP_ROOT}/doctor_worker_smoke.out" \
    && grep -q -- "input_tokens=100" "${TMP_ROOT}/doctor_worker_smoke.out"; then
    echo "[PASS] worker runtime smoke reports edit, handoff, timing, and usage"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] worker runtime smoke output is incomplete"
    failed=1
  fi
  if grep -q -- "PACKET_VERSION: 2" "${worker_args_file}" \
    && grep -q -- "READY_STATE: IMPLEMENTATION_READY" "${worker_args_file}" \
    && grep -q -- "EVIDENCE_ANCHORS:" "${worker_args_file}"; then
    echo "[PASS] worker runtime smoke sends packet v2"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] worker runtime smoke packet v2 fields missing"
    failed=1
  fi

  local worker_smoke_root
  worker_smoke_root="$(awk 'previous == "--cd" { print; exit } { previous = $0 }' "${worker_args_file}")"
  if [[ -n "${worker_smoke_root}" \
    && "${worker_smoke_root}" != "${smoke_target}" \
    && ! -e "${worker_smoke_root}" \
    && ! -e "${smoke_target}/aspera-worker-smoke.txt" ]] \
    && grep -q -- "workspace-write" "${worker_args_file}" \
    && grep -q -- "--ignore-user-config" "${worker_args_file}"; then
    echo "[PASS] worker runtime smoke uses and cleans an isolated workspace"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] worker runtime smoke isolation contract failed"
    failed=1
  fi

  rc="$(capture "${TMP_ROOT}/doctor_invalid_smoke.out" bash "${DOCTOR_SCRIPT}" --runtime-smoke invalid "${smoke_target}")"
  assert_exit "${rc}" "1" "doctor rejects an invalid runtime smoke kind"

  rc="$(ASPERA_STUB_CATALOG="${TMP_ROOT}/missing_spark.json" capture "${TMP_ROOT}/doctor_model_catalog_smoke.out" bash "${DOCTOR_SCRIPT}" --runtime-smoke worker "${smoke_target}")"
  assert_exit "${rc}" "1" "worker runtime smoke rejects unavailable profile models"
  if grep -q -- "classification=MODEL_CATALOG_FAILURE" "${TMP_ROOT}/doctor_model_catalog_smoke.out"; then
    echo "[PASS] worker runtime smoke classifies model catalog failure"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] worker runtime smoke does not classify model catalog failure"
    failed=1
  fi

  local smoke_case expected_classification
  for smoke_case in approval-blocked spawn-failure execution-failure silent inspection-loop post-edit-hang invalid-handoff; do
    case "${smoke_case}" in
      approval-blocked) expected_classification="APPROVAL_BLOCKED" ;;
      spawn-failure) expected_classification="SPAWN_FAILURE" ;;
      execution-failure) expected_classification="EXECUTION_FAILURE" ;;
      silent) expected_classification="FIRST_EDIT_DEADLINE" ;;
      inspection-loop) expected_classification="FIRST_EDIT_DEADLINE" ;;
      post-edit-hang) expected_classification="SMOKE_HARNESS_TIMEOUT" ;;
      invalid-handoff) expected_classification="INVALID_HANDOFF" ;;
    esac
    rc="$(ASPERA_STUB_SMOKE_RESULT="${smoke_case}" ASPERA_FIRST_EDIT_DEADLINE_SECONDS=0.1 ASPERA_SMOKE_TIMEOUT_SECONDS=0.2 capture "${TMP_ROOT}/doctor_smoke_${smoke_case}.out" bash "${DOCTOR_SCRIPT}" --runtime-smoke worker "${smoke_target}")"
    assert_exit "${rc}" "1" "worker runtime smoke rejects ${smoke_case}"
    if grep -q -- "classification=${expected_classification}" "${TMP_ROOT}/doctor_smoke_${smoke_case}.out"; then
      echo "[PASS] worker runtime smoke classifies ${smoke_case}"
      pass_count=$((pass_count + 1))
    else
      echo "[FAIL] worker runtime smoke misclassified ${smoke_case}"
      failed=1
    fi
  done
}

test_uninstall_contracts() {
  local target="${WORK_ROOT}/uninstall"
  rm -rf "${target}"
  mkdir -p "${target}"
  capture "${TMP_ROOT}/uninstall_install.out" bash "${INSTALL_SCRIPT}" "${target}" >/dev/null
  touch "${target}/.keep.txt"
  printf '%s\n' 'name = "user_agent"' > "${target}/.codex/agents/user-agent.toml"
  printf "%s\n%s\n" "# existing" "value=1" > "${target}/.codex/config.toml"
  local config_hash
  config_hash="$(hash_file "${target}/.codex/config.toml")"

  local rc
  rc="$(capture "${TMP_ROOT}/uninstall.out" bash "${UNINSTALL_SCRIPT}" "${target}")"
  assert_exit "${rc}" "0" "uninstall cleans managed files in normal state"
  assert_true "[[ ! -f \"${target}/${STATE_FILE}\" ]]" "state file removed by uninstall"
  assert_true "[[ ! -f \"${target}/.codex/agents/aspera-explorer.toml\" ]]" "managed role files removed by uninstall"
  assert_true "[[ -f \"${target}/.keep.txt\" ]]" "uninstall preserves unrelated files"
  assert_exit "$(hash_file "${target}/.codex/config.toml")" "${config_hash}" "uninstall preserves .codex/config.toml contents"
  assert_file "${target}/.codex/agents/user-agent.toml" "uninstall preserves unrelated agent files"

  rc="$(capture "${TMP_ROOT}/uninstall_nostate.out" bash "${UNINSTALL_SCRIPT}" "${target}")"
  assert_exit "${rc}" "0" "uninstall idempotent when state is absent"

  local drift_target="${WORK_ROOT}/uninstall-drift"
  rm -rf "${drift_target}"
  mkdir -p "${drift_target}"
  capture "${TMP_ROOT}/uninstall_drift_install.out" bash "${INSTALL_SCRIPT}" "${drift_target}" >/dev/null
  printf "%s\n" "drift" > "${drift_target}/.codex/agents/aspera-explorer.toml"
  rc="$(capture "${TMP_ROOT}/uninstall_drift.out" bash "${UNINSTALL_SCRIPT}" "${drift_target}")"
  assert_exit "${rc}" "1" "uninstall refuses when managed drift exists"
  rc="$(capture "${TMP_ROOT}/uninstall_drift_force.out" bash "${UNINSTALL_SCRIPT}" --force "${drift_target}")"
  assert_exit "${rc}" "0" "uninstall with --force replaces drift and cleans state"
  assert_true "[[ ! -f \"${drift_target}/.codex/agents/aspera-explorer.toml\" ]]" "force uninstall removes managed files"
  local drift_backup
  drift_backup="$(find "${drift_target}/.codex/aspera-orchestrator/backups" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
  if [[ -d "${drift_backup}" ]]; then
    assert_true "[[ -f \"${drift_backup}/.codex/agents/aspera-explorer.toml\" ]]" "force uninstall creates backup of drifted managed file"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] force uninstall did not create backup"
    failed=1
  fi
  assert_true "[[ ! -f \"${drift_target}/${STATE_FILE}\" ]]" "state removed after forced uninstall"

  local invalid_target="${WORK_ROOT}/uninstall-invalid-policy"
  rm -rf "${invalid_target}"
  mkdir -p "${invalid_target}"
  capture "${TMP_ROOT}/uninstall_invalid_install.out" bash "${INSTALL_SCRIPT}" "${invalid_target}" >/dev/null
  printf "%s\n%s\n" "<!-- aspera-orchestrator:policy:start -->" "broken" > "${invalid_target}/AGENTS.md"
  rc="$(capture "${TMP_ROOT}/uninstall_invalid_policy.out" bash "${UNINSTALL_SCRIPT}" --force "${invalid_target}")"
  assert_exit "${rc}" "1" "invalid policy markers hard-fail even with --force"

  local malformed_state_target="${WORK_ROOT}/uninstall-malformed-state"
  rm -rf "${malformed_state_target}"
  mkdir -p "${malformed_state_target}"
  capture "${TMP_ROOT}/uninstall_malformed_seed.out" bash "${INSTALL_SCRIPT}" --profile luna "${malformed_state_target}" >/dev/null
  python3 - "${malformed_state_target}/${STATE_FILE}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text(encoding="utf-8"))
state["managed_files"][".codex/agents/aspera-worker.toml"] = ""
path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
PY
  rc="$(capture "${TMP_ROOT}/uninstall_malformed_state.out" bash "${UNINSTALL_SCRIPT}" "${malformed_state_target}")"
  assert_exit "${rc}" "1" "uninstall rejects empty managed-file hash in state"
  assert_file "${malformed_state_target}/.codex/agents/aspera-worker.toml" "malformed state cannot authorize managed-file deletion"
  assert_file "${malformed_state_target}/${STATE_FILE}" "malformed state remains for manual repair"
}

test_install_contracts
test_policy_contracts
test_doctor_contracts
test_uninstall_contracts
test_symlink_contracts
test_stub_contract

echo "[SUMMARY] passed=${pass_count} skipped=${skip_count} failed=${failed}"
if [[ ${failed} -ne 0 ]]; then
  exit 1
fi
