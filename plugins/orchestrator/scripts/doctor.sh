#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)}"
CFG="${ROOT}/.codex/config.toml"
FAIL=0

check_file() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "[MISSING] ${path}"
    FAIL=1
  else
    echo "[OK] ${path}"
  fi
}

check_key() {
  local path="$1"
  local key="$2"
  if ! grep -Fq -- "${key}" "${path}"; then
    echo "[INVALID] ${path} missing key: ${key}"
    FAIL=1
  else
    echo "[OK] ${path}: ${key}"
  fi
}

check_file "${CFG}"
check_key "${CFG}" "[agents]"
check_key "${CFG}" "enabled"
check_key "${CFG}" "max_concurrent_threads_per_session"

if grep -Fq '[agents.spark]' "${CFG}" && \
   grep -Fq '[agents.luna]' "${CFG}" && \
   grep -Fq '[agents.reviewer]' "${CFG}" && \
   grep -Fq 'default_subagent_model = "gpt-5.6-luna"' "${CFG}" && \
   grep -Fq 'default_subagent_reasoning_effort = "xhigh"' "${CFG}"; then
  echo "doctor: session-template mode enabled (AGENTS.md policy snippet optional)"
fi

for role in spark-explorer.toml spark-worker.toml spark-verifier.toml terra-reviewer.toml luna-researcher.toml; do
  FILE="${ROOT}/.codex/agents/${role}"

  if [[ "${role}" == "terra-reviewer.toml" ]]; then
    LEGACY_FILE="${ROOT}/.codex/agents/strong-reviewer.toml"
    if [[ ! -f "${FILE}" && -f "${LEGACY_FILE}" ]]; then
      echo "[DEPRECATED] ${LEGACY_FILE} is present but no longer accepted. Install required config: ${FILE}."
      FAIL=1
      continue
    fi
  fi

  check_file "$FILE"
  check_key "$FILE" "name"
  check_key "$FILE" "model"
  check_key "$FILE" "sandbox_mode"
  check_key "$FILE" "developer_instructions"
done

if [[ $FAIL -ne 0 ]]; then
  echo "doctor: failed"
  exit 1
fi

echo "doctor: ok"
