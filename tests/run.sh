#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${ROOT}/tests"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export ASPERA_CODEX_BIN="${ROOT}/tests/fixtures/stub/bin/codex"
export ASPERA_STUB_CATALOG="${ROOT}/tests/fixtures/stub/models.json"
export ASPERA_TMP_ROOT="${TMP_DIR}"
export ASPERA_TEST_ROOT="${TMP_DIR}/workspace"
mkdir -p "${ASPERA_TEST_ROOT}"

failed=0
summary=()

run_step() {
  local label="$1"
  shift
  echo "[RUN] ${label}"
  if "$@"; then
    summary+=("${label}: OK")
  else
    summary+=("${label}: FAIL")
    failed=1
  fi
}

run_step "shell-behavior-contracts" bash "${TESTS_DIR}/test_setup_contracts.sh"
run_step "worker-guard" python3 "${TESTS_DIR}/test_worker_guard.py"
run_step "static-validator" python3 "${TESTS_DIR}/static_validator.py"

for entry in "${summary[@]}"; do
  echo "${entry}"
done

if [[ ${failed} -ne 0 ]]; then
  exit 1
fi
