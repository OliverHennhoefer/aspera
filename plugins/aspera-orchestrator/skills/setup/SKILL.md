---
name: setup
description: |
  Install, update, doctor-check, and uninstall project-scoped orchestrator
  profiles from the bundled setup scripts.
---

# Setup skill

Resolves and executes its bundled scripts directory.

Run one of:

- Install:
  - `bash ./scripts/install.sh [--profile spark|luna] [--install-policy] [--dry-run] [--force] [TARGET]`
- Health check:
  - `bash ./scripts/doctor.sh [--profile spark|luna] [--runtime-smoke explorer|worker] [TARGET]`
- Uninstall:
  - `bash ./scripts/uninstall.sh [--dry-run] [--force] [TARGET]`

### Executed behavior

- Writes managed role files into `.codex/agents/`.
- Writes the worker packet/progress guard to `.codex/aspera-orchestrator/worker_guard.py`.
- Optionally installs managed policy block into root `AGENTS.md` when using `--install-policy`.
- Requires state schema 2; version 0.1 state is a hard break and is not upgraded or uninstalled automatically.
- Preserves managed/serialized behavior defined by installer state and scripts.

## Non-goals

- Do not alter plugin manifests.
- Do not change managed files outside the orchestrator profile contract.
