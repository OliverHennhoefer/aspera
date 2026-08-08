# Native Codex Orchestrator

Open-source plugin implementation for the Codex ecosystem, usable directly from this repository.

Lightweight Codex orchestrator plugin for a deterministic, structured task flow using an explicit task format:
`spark`-backed `spark_explorer`, `spark_worker`, and `spark_verifier`, `luna_researcher` for docs/spec checks, and `terra-reviewer` for risk gates.

## Install into another project

```bash
bash plugins/orchestrator/scripts/install-agents.sh /path/to/other-project
bash plugins/orchestrator/scripts/install-agents.sh --with-session-template /path/to/other-project
bash plugins/orchestrator/scripts/doctor.sh /path/to/other-project
```

Deterministic session-template bootstrap (single command):

```bash
PLUGIN_REPO=/path/to/this-plugin-repo
TARGET_REPO=/path/to/other-project
bash "$PLUGIN_REPO/plugins/orchestrator/scripts/install-agents.sh" --with-session-template "$TARGET_REPO"
```

Run `doctor.sh` afterward to verify health:

```bash
bash "$PLUGIN_REPO/plugins/orchestrator/scripts/doctor.sh" "$TARGET_REPO"
```

## Install modes

- Default mode (lightweight, plugin runtime):
  - Installs `.codex/agents/*.toml`.
  - Creates `.codex/config.toml` only if missing.
  - Keeps existing `.codex/config.toml` in place.

- Session-template mode:
  - `bash plugins/orchestrator/scripts/install-agents.sh --with-session-template /path/to/other-project`
  - Installs role files and overwrites `.codex/config.toml` from
    `plugins/orchestrator/templates/session-config.toml.example`.
  - In this mode, the README `AGENTS.md` addition for this project is optional.

## Installed runtime files

- `.codex/config.toml`
- `.codex/agents/spark-explorer.toml`
- `.codex/agents/spark-worker.toml`
- `.codex/agents/spark-verifier.toml`
- `.codex/agents/terra-reviewer.toml`
- `.codex/agents/luna-researcher.toml`

## Minimal `AGENTS.md` hint for target project

By default, add this (or equivalent) to the target project’s `AGENTS.md` so the policy is discoverable to the main session:

```md
Use a fixed explicit task format for implementation work.
Required task packet keys:
TASK_ID, OBJECTIVE, OWNED_PATHS, READ_ONLY_CONTEXT, INTERFACE_CONTRACTS, CONSTRAINTS, NON_GOALS, IMPLEMENTATION_STEPS, VERIFICATION, STOP_CONDITIONS, HANDOFF_FORMAT.

Roles: spark_explorer, spark_worker, spark_verifier, luna_researcher, terra-reviewer.
Escalate risk-sensitive work to `terra-reviewer`.
```

## Optional: skip AGENTS.md if you use session-template mode

If you installed with `--with-session-template`, you can use `plugins/orchestrator/templates/session-config.toml.example` as `.codex/config.toml` in the target workspace (or merge equivalent fields into an existing `.codex/config.toml`).
In that case, main-session policy is carried by the session config and the `AGENTS.md` snippet is optional.

Notes:
- Use only this template if your target project allows changing its main Codex session config.
- Ensure the template’s keys remain valid for your Codex/runtime version (`model_reasoning_effort`/features/agent blocks vary by version).
