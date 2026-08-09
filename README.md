# Aspera Orchestrator

Aspera is a Codex plugin for bounded planner-worker-verifier execution. The parent remains responsible for architecture, verification, and final acceptance.

## Requirements

- A current Codex CLI or Codex IDE installation with plugins, custom agents, subagents, and hooks.
- Bash 3.2 or newer and Python 3.11 or newer.
- Access to the models selected by the chosen profile.

Aspera does not query the authenticated model catalog during installation. Codex reports model or routing availability when a real task uses a configured role.

## Install or update

Clone or update this repository, then run one command from the Aspera checkout:

```bash
./aspera install --workspace /absolute/path/to/project
```

The command:

- adds or verifies the local Aspera marketplace and refreshes the plugin from this checkout;
- installs the project role files, worker guard, managed `AGENTS.md` policy, and state receipt;
- migrates valid Aspera 0.1 and 0.2 state;
- refuses unmanaged conflicts, drift, and symlinked managed paths;
- stages the complete target state, rechecks destinations, commits it, and verifies exact hashes;
- preserves the installed profile and policy on updates.

Fresh installs use the Spark profile and managed policy. Choose Luna explicitly:

```bash
./aspera install --workspace /absolute/path/to/project --profile luna
```

Use `--no-policy` only when every task will attach `$aspera-orchestrator:orchestrate` explicitly. Use `--force` only after inspecting reported managed-file drift; Aspera creates a backup before replacing it.

After success, start a new Codex session so role and policy discovery use the installed files. There is no setup conversation, doctor command, runtime smoke, or other activation step.

Setup creates:

```text
.codex/agents/aspera-explorer.toml
.codex/agents/aspera-worker.toml
.codex/agents/aspera-verifier.toml
.codex/agents/aspera-researcher.toml
.codex/agents/aspera-reviewer.toml
.codex/aspera-orchestrator/worker_guard.py
.codex/aspera-orchestrator/state.json
```

These files may be committed for team use or ignored for a personal installation. Do not commit `.codex/aspera-orchestrator/backups/`.

## Use

With managed policy installed, ask for implementation work normally. Aspera uses the roles exposed when the session starts. The first real delegation is the runtime exercise; no synthetic worker is spawned first.

If an expected role is absent, Aspera stops that lane once and asks for a reinstall plus a new session. It does not run setup, retry delegation, or reinterpret a collaboration bootstrap error as an installation failure.

Without managed policy, explicitly select **Aspera Orchestrator: Orchestrate** from `/skills` or `$` for the task.

### Profiles

| Profile | Exploration, implementation, verification | Research | Risk review |
|---|---|---|---|
| Spark | Spark `xhigh` | Luna `max` | Terra `high` |
| Luna | Luna `max` | Luna `max` | Terra `high` |

### Modes

- **Direct:** parent-only, no delegation.
- **Express:** one bounded worker, plus a verifier when needed.
- **Standard:** independent exploration, resolved architecture, serialized or disjoint workers, and verification waves.

Workers receive packet v2 with exact owned paths, evidence anchors, settled interfaces, invariants, implementation steps, verification commands, stop conditions, and the canonical handoff. The managed hook is defense-in-depth for packet, ownership, progress, and handoff enforcement.

## Optional lifecycle support

Local diagnosis is read-only and never starts Codex or changes readiness:

```bash
./aspera diagnose --workspace /absolute/path/to/project
```

Uninstall removes only files recorded by a supported state receipt and retains a backup:

```bash
./aspera uninstall --workspace /absolute/path/to/project
```

Both commands support `--dry-run` where applicable. Forced drift handling requires `--force`.

## Troubleshooting

- **Marketplace points elsewhere:** use the checkout already configured as marketplace `aspera`, or remove the conflicting marketplace deliberately before retrying.
- **Role missing in a fresh session:** rerun the one install command and confirm it exits successfully.
- **Drift detected:** inspect the named managed files before approving `--force`.
- **Model unavailable during a real task:** choose a profile supported by the current account; Aspera never substitutes a model or reasoning level.
- **Collaboration bootstrap failure:** treat it as a host/runtime failure. It does not invalidate the installed receipt.

## Development

```bash
bash tests/run.sh
git diff --check
```

The optional authenticated runtime evaluation is a release activity and never changes project installation state. The evaluation protocol remains in [`tests/evals/manual-eval-spec.json`](tests/evals/manual-eval-spec.json).
