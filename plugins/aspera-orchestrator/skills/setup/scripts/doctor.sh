#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The runtime-computed absolute path cannot be resolved by static analysis.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

TARGET="$(pwd)"
PROFILE=""
RUNTIME_SMOKE=""

usage() {
  cat <<'USAGE'
Usage: doctor.sh [--profile spark|luna] [--runtime-smoke explorer|worker] [TARGET]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --runtime-smoke)
      if [[ $# -lt 2 ]]; then
        aspera_err "--runtime-smoke requires explorer or worker"
      fi
      RUNTIME_SMOKE="$2"
      case "$RUNTIME_SMOKE" in
        explorer|worker) ;;
        *) aspera_err "invalid runtime smoke '$RUNTIME_SMOKE' (expected explorer or worker)" ;;
      esac
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      aspera_err "unknown option: $1"
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

ASPERA_TARGET="$(aspera_normalize_target "$TARGET")"
asp_state_file="$(aspera_state_file "$ASPERA_TARGET")"
ASPERA_POLICY_FILE="$ASPERA_TARGET/AGENTS.md"

if [ ! -f "$asp_state_file" ]; then
  aspera_err "state not found at $asp_state_file"
fi

aspera_check_managed_ancestry "$ASPERA_TARGET"
asp_state_validate "$asp_state_file"
STATE_PROFILE="$(asp_state_get "$asp_state_file" profile)"
STATE_POLICY="$(asp_state_get "$asp_state_file" policy_installed)"

if [ -n "$PROFILE" ]; then
  aspera_validate_profile "$PROFILE"
  if [ "$STATE_PROFILE" != "$PROFILE" ]; then
    aspera_err "state profile '$STATE_PROFILE' does not match requested '$PROFILE'"
  fi
else
  PROFILE="$STATE_PROFILE"
fi

if [ "$STATE_POLICY" -eq 1 ] && [ ! -f "$ASPERA_POLICY_FILE" ]; then
  aspera_err "missing AGENTS.md for state-managed policy"
fi

FAIL=0
SCAN="$(asp_policy_scan "$ASPERA_POLICY_FILE")"
if [ "$SCAN" = "invalid" ]; then
  echo "[INVALID] policy marker layout in $ASPERA_POLICY_FILE"
  FAIL=1
fi

for f in ".codex/agents/aspera-explorer.toml" ".codex/agents/aspera-worker.toml" ".codex/agents/aspera-verifier.toml" ".codex/agents/aspera-researcher.toml" ".codex/agents/aspera-reviewer.toml"; do
  rel="$ASPERA_TARGET/$f"
  if [ ! -f "$rel" ]; then
    echo "[MISSING] $rel"
    FAIL=1
    continue
  fi
  if [ -L "$rel" ]; then
    echo "[INVALID] managed path is symlink: $rel"
    FAIL=1
    continue
  fi
  recorded="$(asp_state_get_hash "$asp_state_file" "$f")"
  current="$(aspera_hash_file "$rel")"
  if [ "$recorded" != "$current" ]; then
    echo "[DRIFT] $rel"
    FAIL=1
  fi
done

if [ "$STATE_POLICY" -eq 1 ]; then
  if [ "$SCAN" != "ok" ]; then
    echo "[MISSING] AGENTS.md policy block required by state"
    FAIL=1
  else
    state_policy_hash="$(asp_state_get "$asp_state_file" policy_hash)"
    current_policy_hash="$(asp_policy_hash "$ASPERA_POLICY_FILE")"
    if [ "$state_policy_hash" != "$current_policy_hash" ]; then
      echo "[DRIFT] AGENTS policy block"
      FAIL=1
    fi
  fi
elif [ "$SCAN" = "ok" ]; then
  echo "[WARN] AGENTS.md contains an unmanaged policy block"
fi

if [ "$FAIL" -ne 0 ]; then
  aspera_err "doctor failed"
fi

echo "doctor: state and managed files are valid"

if [ -n "$RUNTIME_SMOKE" ]; then
  if ! (asp_preflight_models "$PROFILE"); then
    echo "classification=MODEL_CATALOG_FAILURE"
    exit 1
  fi
  out_file="$(mktemp)"
  status_file="$(mktemp)"
  if asp_run_smoke "$RUNTIME_SMOKE" "$ASPERA_TARGET" "$out_file" "$status_file"; then
    aspera_info "runtime-smoke kind: $RUNTIME_SMOKE"
    cat "$status_file"
    asp_report_smoke_usage "$out_file"
    echo "runtime-smoke output:"
    cat "$out_file"
    rm -f "$out_file" "$status_file"
  else
    rc=$?
    aspera_info "runtime-smoke kind: $RUNTIME_SMOKE"
    cat "$status_file" || true
    asp_report_smoke_usage "$out_file"
    aspera_info "runtime-smoke failed with $rc"
    echo "runtime-smoke output:"
    cat "$out_file" || true
    rm -f "$out_file" "$status_file"
    exit "$rc"
  fi
fi

echo "doctor: ok"
