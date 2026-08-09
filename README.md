# Aspera Orchestrator

Aspera reduces premium parent-model quota without trading away correctness. Sol settles architecture and acceptance, Luna Max performs most bounded implementation, and Spark is available only for naturally mechanical work that already fits the same compact capsule.

## Requirements

- A current Codex CLI or IDE with plugins, custom agents, subagents, and hooks.
- Bash 3.2+, Python 3.11+, and access to the models selected by the installed profile.

## Install or update

```bash
./aspera install --workspace /absolute/path/to/project
```

Fresh installs use the `adaptive` profile:

| Responsibility | Model |
|---|---|
| Architecture, routing, acceptance | Session parent (normally Sol-high) |
| Primary implementation and repository exploration | Luna Max |
| Conditional mechanical implementation | Spark `xhigh` |
| High-risk review | Terra `high` |

Use Luna without the conditional Spark role:

```bash
./aspera install --workspace /absolute/path/to/project --profile luna
```

The legacy `--profile spark` name is accepted for one release as an alias for `adaptive`. Existing valid 0.1–0.3 installations migrate transactionally. Start a new Codex session after install or update.

The installer manages role files, packet-v3 guard, lazy protocol, compact project policy, and state receipt. It refuses unmanaged conflicts, drift, and unsafe symlinks; `--force` backs up approved drift before complete reconciliation. It also refreshes the checkout plugin through supported Codex commands and verifies its version, source, and enabled state.

Updates preserve the installed profile and policy when their flags are omitted. Use `--no-policy` to remove automatic repository activation and `--install-policy` to restore it. These options are mutually exclusive.

There is no setup interview, automatic doctor, model probe, nested Codex process, runtime smoke, or other activation step.

## Runtime routing

There are no public orchestration modes. With policy installed, Sol performs targeted orientation and chooses:

- continue in Sol when delegation has negative value or quality risk;
- Luna Max for normal bounded implementation;
- Spark only when the unchanged Luna-ready capsule passes every strict mechanical-work gate.

Spark is never a reason to add planning, context, or another handoff. It gets one attempt; a concrete failure may be upgraded once to Luna. Workers run focused checks, and Sol inspects the diff and reruns the decisive command.

Detailed routing, packet v3, limits, handoff, and failure rules are installed lazily at:

```text
.codex/aspera-orchestrator/protocol.md
```

If an expected role is absent, reinstall and start a new session. Aspera never silently substitutes a model.

## Managed project files

Adaptive installs create:

```text
.codex/agents/aspera-explorer.toml
.codex/agents/aspera-luna-worker.toml
.codex/agents/aspera-spark-worker.toml
.codex/agents/aspera-researcher.toml
.codex/agents/aspera-reviewer.toml
.codex/aspera-orchestrator/worker_guard.py
.codex/aspera-orchestrator/protocol.md
.codex/aspera-orchestrator/state.json
```

The Luna profile omits `aspera-spark-worker.toml`. Managed files may be committed or ignored. Do not commit `.codex/aspera-orchestrator/backups/`.

## Lifecycle

Read-only diagnosis:

```bash
./aspera diagnose --workspace /absolute/path/to/project
```

Recoverable uninstall with retained backup:

```bash
./aspera uninstall --workspace /absolute/path/to/project
```

Both support `--dry-run` where applicable. Forced drift handling requires `--force`.

## Evaluation and development

Spark remains a conditional lane until paired Sol/Luna/Spark evaluations meet the checked-in quota, quality, latency, and retry gates. Evaluation records include complete parent and worker consumption; production receipts contain lifecycle metadata only, never prompts, code, or tool output.

Aspera itself is always developed parent-direct:

```bash
bash tests/run.sh
git diff --check
```
