#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_CFG="${PLUGIN_ROOT}/templates/config.toml"
SESSION_TEMPLATE_CFG="${PLUGIN_ROOT}/templates/session-config.toml.example"

USE_SESSION_TEMPLATE=0
ROOT="${1:-$(pwd)}"

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --with-session-template)
      USE_SESSION_TEMPLATE=1
      shift
      ;;
    --help|-h)
      cat <<EOF
Usage:
  bash install-agents.sh [target-root]
  bash install-agents.sh --with-session-template [target-root]

Options:
  --with-session-template  Install and overwrite .codex/config.toml from
                           plugins/orchestrator/templates/session-config.toml.example.
EOF
      exit 0
      ;;
    --*)
      echo "Unknown option: ${1}" >&2
      exit 1
      ;;
    *)
      ROOT="${1}"
      shift
      ;;
  esac
done

TARGET_ROOT="${ROOT}"
TARGET_CFG="${TARGET_ROOT}/.codex/config.toml"
TARGET_AGENTS_DIR="${TARGET_ROOT}/.codex/agents"

mkdir -p "${TARGET_AGENTS_DIR}"
mkdir -p "${TARGET_ROOT}/.codex"

if [[ ${USE_SESSION_TEMPLATE} -eq 1 ]]; then
  if [[ ! -f "${SESSION_TEMPLATE_CFG}" ]]; then
    echo "ERROR: missing ${SESSION_TEMPLATE_CFG}" >&2
    exit 1
  fi
  cp "${SESSION_TEMPLATE_CFG}" "${TARGET_CFG}"
  echo "Installed session-template config to ${TARGET_CFG}"
else
  if [[ -f "${TARGET_CFG}" ]]; then
    echo "Keeping existing orchestrator config at ${TARGET_CFG}"
  else
    cp "${TEMPLATE_CFG}" "${TARGET_CFG}"
    echo "Installed orchestrator config to ${TARGET_CFG} from template"
  fi
fi

for f in spark-explorer.toml spark-worker.toml spark-verifier.toml terra-reviewer.toml luna-researcher.toml
 do
  cp "${PLUGIN_ROOT}/agents/${f}" "${TARGET_AGENTS_DIR}/${f}"
done

if [[ -f "${TARGET_AGENTS_DIR}/strong-reviewer.toml" ]]; then
  rm -f "${TARGET_AGENTS_DIR}/strong-reviewer.toml"
fi

if [[ ! -f "${TARGET_CFG}" ]]; then
  echo "WARN: missing ${TARGET_CFG} after install" >&2
fi
echo "Installed orchestrator agents to ${TARGET_AGENTS_DIR}"
