# Aspera Orchestrator

Aspera is an experimental Codex plugin. It delegates small, clearly defined tasks to less expensive models while keeping the main Sol agent responsible for planning and final acceptance.

Version: `0.1.0` alpha. Cost and quality results are still pending; no savings claim is made yet.

## Requirements

- Codex `0.147.0-alpha.6.5` or newer. Older versions are unsupported. Last tested: `0.147.0-alpha.6.5` on 2026-08-08.
- Bash 3.2 or newer and Python 3.11 or newer.
- A ChatGPT account signed in to Codex:
  - **Luna profile:** ChatGPT Plus, Pro, or another plan whose Codex model list includes Luna `max` and Terra `high`.
  - **Spark profile:** ChatGPT Pro. Spark is a research preview with a separate usage limit and may be temporarily unavailable.

Spark is not generally available through API-key access during the research preview. See [ChatGPT plans](https://chatgpt.com/pricing) and the [Spark announcement](https://openai.com/index/introducing-gpt-5-3-codex-spark/).

Check which Codex your terminal uses:

```bash
codex --version
```

Aspera checks the signed-in account's current model list before writing files. Missing models or reasoning levels stop setup; Aspera never substitutes another model or lowers effort.

## Install the plugin

Clone or download this repository. In a terminal, run:

```bash
codex plugin marketplace add <path-to-aspera>
codex plugin add aspera-orchestrator@aspera
```

Then open the project where you want to use Aspera and start a **new Codex conversation**.

## Set up a project

For the Spark profile, ask Codex:

```text
Use $aspera-orchestrator:setup to install the Spark profile in this repository, then run doctor.
```

For the Luna profile:

```text
Use $aspera-orchestrator:setup to install the Luna profile in this repository, then run doctor.
```

Setup creates:

```text
.codex/agents/aspera-explorer.toml
.codex/agents/aspera-worker.toml
.codex/agents/aspera-verifier.toml
.codex/agents/aspera-researcher.toml
.codex/agents/aspera-reviewer.toml
.codex/aspera-orchestrator/state.json
```

Successful setup ends with:

```text
doctor: state and managed files are valid
doctor: ok
```

These files may appear as untracked in Git. That is expected. Review and commit them if the whole team should use Aspera, or ignore them locally for a personal test. Do not commit `.codex/aspera-orchestrator/backups/`.

The project `AGENTS.md` is unchanged by default. To install the optional managed policy block, ask:

```text
Use $aspera-orchestrator:setup to install the Spark profile and the managed AGENTS.md policy, then run doctor.
```

Aspera never creates, edits, or validates `.codex/config.toml`.

## Try it

Use a small task with a clear test:

```text
Use $aspera-orchestrator:orchestrate in Express mode for this task.
Report the selected role, model, effort, verification result, and delegation count.
```

## Profiles

| Profile | Exploration, implementation, verification | Research | Risk review |
|---|---|---|---|
| Spark | Spark `xhigh` | Luna `max` | Terra `high` |
| Luna | Luna `max` | Luna `max` | Terra `high` |

Spark prioritizes speed and uses its separate preview allowance. Luna is the broadly available alternative for clear, repeatable work. Terra is reserved for declared correctness and risk checks.

## Modes

- **Direct:** the parent handles a trivial task without delegation.
- **Express:** one worker handles a bounded task; verification is added when needed.
- **Standard:** up to three independent explorers, disjoint workers, verification after each wave, and Terra only for declared risk triggers.

The parent remains responsible for architecture, decisive checks, and final acceptance. Delegation is non-recursive and each path has one writer.

## Check or remove setup

Ask Codex:

```text
Use $aspera-orchestrator:setup to run doctor in this repository.
```

```text
Use $aspera-orchestrator:setup to uninstall Aspera from this repository.
```

Uninstall removes only artifacts recorded in Aspera's state file. Drift is refused unless you explicitly approve `--force`; forced operations create a backup first.

## Source fallback

If marketplace installation is unavailable, run the bundled scripts from the Aspera checkout:

```bash
bash "<path-to-aspera>/plugins/aspera-orchestrator/skills/setup/scripts/install.sh" --profile spark "<path-to-project>"
bash "<path-to-aspera>/plugins/aspera-orchestrator/skills/setup/scripts/doctor.sh" --profile spark "<path-to-project>"
bash "<path-to-aspera>/plugins/aspera-orchestrator/skills/setup/scripts/uninstall.sh" "<path-to-project>"
```

Use `--profile luna` for Luna. Add `--install-policy` only when you want the managed `AGENTS.md` block. Use `--dry-run` to preview setup or uninstall without changing files.

If several Codex versions are installed, point setup at the supported binary:

```bash
ASPERA_CODEX_BIN="<path-to-codex>" bash "<path-to-aspera>/plugins/aspera-orchestrator/skills/setup/scripts/install.sh" --profile spark "<path-to-project>"
```

## Troubleshooting

- **Configuration fails before installation:** `codex --version` probably points to an older Codex. Update it or use the supported binary explicitly.
- **Spark is unavailable:** confirm ChatGPT Pro access and try the Luna profile. A newer client alone does not grant Spark access.
- **An updated plugin is not visible:** reinstall the plugin and start a new conversation.
- **Drift detected:** review the changed managed files before using `--force`.

## Evaluation status

The hypothesis is that Aspera can approach Sol `high` correctness at lower cost. The fixed comparison records success, tests, tokens, credits, duration, delegation, retries, and parent intervention. Release targets include at least 9/10 bounded tasks passing, median cost no greater than 70% of Sol-only, and at least 40% lower parent-token usage on delegated tasks.

Results are pending. The protocol is in [`tests/evals/manual-eval-spec.json`](tests/evals/manual-eval-spec.json).
