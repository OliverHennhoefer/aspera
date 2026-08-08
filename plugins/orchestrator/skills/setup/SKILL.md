name: setup
description: |
  Install and validate the local orchestrator plugin profiles used by Codex.

# Setup skill

Run one of:

- Install roles into workspace:
  `bash plugins/orchestrator/scripts/install-agents.sh`
- Run health checks:
  `bash plugins/orchestrator/scripts/doctor.sh`

## What install does

Creates/updates:

- `.codex/config.toml`
- `.codex/agents/spark-explorer.toml`
- `.codex/agents/spark-worker.toml`
- `.codex/agents/spark-verifier.toml`
- `.codex/agents/terra-reviewer.toml`
- `.codex/agents/luna-researcher.toml`
