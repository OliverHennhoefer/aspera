# aspera-orchestrator

Lightweight, deterministic Codex orchestration with bounded role packets.

- Status: initial `0.1.0` release candidate; capability and cost gates are pending.
- Compatibility assumption: the newest Codex generation only.
- Last validated baseline: Codex `0.147.0-alpha.6.5` on 2026-08-08.
- Requirements: Bash 3.2+, Python 3.11+, and the required Codex model entitlements.

The goal is comparable correctness at lower total cost than asking Sol `high` to perform the whole task. Sol remains the architecture and acceptance parent; Spark, Luna, and Terra handle bounded work.

## Install commands

Marketplace:

```bash
codex plugin marketplace add <repo-root>
codex plugin add aspera-orchestrator@aspera
```

Source:

```bash
bash plugins/aspera-orchestrator/skills/setup/scripts/install.sh --profile spark <target-root>
bash plugins/aspera-orchestrator/skills/setup/scripts/install.sh --profile spark --install-policy <target-root>
```

Replace `--profile spark` with `--profile luna` for Luna mode.

`--install-policy` adds or updates a marked block in the target's root `AGENTS.md`. Use `--dry-run` to preview and `--force` only after reviewing a reported drift conflict.

Doctor:

```bash
bash plugins/aspera-orchestrator/skills/setup/scripts/doctor.sh <target-root>
bash plugins/aspera-orchestrator/skills/setup/scripts/doctor.sh --profile spark <target-root>
bash plugins/aspera-orchestrator/skills/setup/scripts/doctor.sh --runtime-smoke --profile spark <target-root>
```

Uninstall:

```bash
bash plugins/aspera-orchestrator/skills/setup/scripts/uninstall.sh <target-root>
bash plugins/aspera-orchestrator/skills/setup/scripts/uninstall.sh --dry-run <target-root>
bash plugins/aspera-orchestrator/skills/setup/scripts/uninstall.sh --force <target-root>
```

## Runtime entrypoint

`$aspera-orchestrator:orchestrate`

Use exact schema from `AGENTS.md` for role packets.

## Modes

- Direct: parent-only, no delegation.
- Express: one `aspera_worker`; add `aspera_verifier` for behavioral, multi-file, public-contract, or failed-worker cases.
- Standard: up to 3 `aspera_explorer` packets in parallel, then disjoint `aspera_worker` batches.

## Roles and models

- Spark profile:
  - `aspera_explorer`, `aspera_worker`, `aspera_verifier`: `gpt-5.3-codex-spark`, `xhigh`
  - `aspera_researcher`: `gpt-5.6-luna`, `max`
  - `aspera_reviewer`: `gpt-5.6-terra`, `high`
- Luna profile:
  - `aspera_explorer`, `aspera_worker`, `aspera_verifier`: `gpt-5.6-luna`, `max`
  - `aspera_researcher`: `gpt-5.6-luna`, `max`
  - `aspera_reviewer`: `gpt-5.6-terra`, `high`

Spark is a Pro research preview with separate usage limits. Missing models or effort levels block installation; there is no silent substitution or downgrade.

## Safety boundary

- Never edits `.codex/config.toml`.
- Runtime-owned artifacts include `.codex/agents/aspera-*.toml` and `.codex/aspera-orchestrator/state.json`.
- Optional policy markers live in root `AGENTS.md`.
- Delegated roles use isolated, task-local context; delegation is non-recursive and each path has one writer.
- The parent owns architecture, reruns decisive checks, and makes final acceptance decisions.
- `bash tests/run.sh` is part of normal CI and must run with no paid model calls.

`doctor.sh --runtime-smoke` is the only quota-consuming setup check. It is explicit, limited to 120 seconds, prints captured output/usage, and must return `ASPERA_SMOKE_OK`.

## Capability and cost evaluation

Run identical fixed tasks once with Sol `high` working alone and once with Sol `high` acting only as the Aspera parent. Record task/test success, input/cached-input/output/reasoning tokens per model, reported credits when available, current-rate-card normalized cost, wall time, delegation count, retries, and parent intervention.

The machine-readable protocol and empty result record are in `tests/evals/manual-eval-spec.json`. Published result status: pending. No efficacy or savings claim is made until every gate below passes.

## Release gates

- Direct: 5/5 zero delegation.
- 10 bounded Aspera tasks >= 9/10 quality.
- No more than one bounded Aspera task behind Sol baseline per release batch.
- Median normalized cost <= 70% of Sol.
- Zero ownership/fallback violations.
- 5 research cases with same cost target as above.
- 5 high-risk Terra routes.
- Parent token usage >= 40% lower than baseline.
- 5 positive / 3 negative activations.
