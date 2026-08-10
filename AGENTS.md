# Aspera repository policy

## Source of truth

- This file, the current request, and any parent task packet.
- `plugins/aspera-orchestrator/skills/orchestrate/references/policy.md` for the compact downstream router.
- `plugins/aspera-orchestrator/skills/orchestrate/references/protocol.md` for downstream packet and lifecycle behavior.
- `plugins/aspera-orchestrator/skills/setup/assets/*` and `scripts/*` for installed contracts.

Do not derive policy from `.codex/config.toml`.

## Development rule

- Always implement Aspera itself parent-direct. Do not delegate implementation, verification, review, or exploration in this repository.
- The downstream orchestrator is tested here but activates only after installation into another repository.
- Preserve user changes and serialize shared-state edits.

## Product invariants

- Sol owns architecture, routing, and final acceptance.
- Luna Max is the primary downstream implementation worker.
- Spark is conditional, receives the unchanged Luna-ready capsule, and never causes extra planning or context construction.
- No public Direct/Express/Standard modes, recursive delegation, or silent model substitution. Spark unavailability automatically falls back to Luna with explicit reporting.
- Quality gates quota savings; failed Spark economics remove or disable the lane.
- Managed installation, migration, drift handling, backup, and uninstall remain transactional and recoverable.

## Installation contract

- The checkout root `./aspera install --workspace <repository>` command is the only normal install and update path; success requires only a fresh Codex session afterward.
- Preserve the installed profile and policy when their flags are omitted. Profile and policy changes require explicit options, and supported legacy state migrates automatically.
- Classify every known current and legacy destination before external mutation. Refuse unsafe paths and unmanaged changes unless `--force` explicitly approves backup and complete reconciliation.
- Stage the desired project state, recheck destinations for concurrent changes, commit the receipt last, and verify desired hashes plus absence of obsolete managed paths before returning success.
- Refresh and verify the plugin only through supported Codex plugin commands. Never edit Codex cache or configuration files directly.
- Installation and diagnosis never run doctor automatically, query models, start nested Codex, spawn agents, run runtime smoke, or persist runtime readiness.
