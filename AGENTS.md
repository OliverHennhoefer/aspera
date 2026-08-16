# Aspera repository policy

## Source of truth

- This file, the current request, and any parent task packet.
- `plugins/aspera-orchestrator/skills/orchestrate/references/policy.md` for the compact downstream router.
- `plugins/aspera-orchestrator/skills/setup/assets/*` and `scripts/*` for installed contracts.

Do not derive policy from `.codex/config.toml`.

## Development rule

- Always implement Aspera itself parent-direct. Do not delegate implementation, verification, review, or exploration in this repository.
- The downstream orchestrator is tested here but activates only after installation into another repository.
- Preserve user changes and serialize shared-state edits.

## Product invariants

- Sol owns architecture, routing, and final acceptance.
- Native Luna Max is the primary downstream implementation worker.
- Routing uses one natural brief and never causes pre-reading, packet construction, or context enrichment.
- No public Direct/Express/Standard modes, recursive delegation, or silent model substitution.
- Quality gates quota savings.
- Managed installation, migration, drift handling, backup, and uninstall remain transactional and recoverable.

## Installation contract

- The checkout root `./aspera install --workspace <repository>` command is the only normal install and update path; success requires only a fresh Codex session afterward.
- Preserve the installed policy when its flags are omitted. Supported legacy profiles migrate automatically to the Luna-only contract.
- Classify every known current and legacy destination before external mutation. Refuse unsafe paths and unmanaged changes unless `--force` explicitly approves backup and complete reconciliation.
- Stage the desired project state, recheck destinations for concurrent changes, commit the receipt last, and verify desired hashes plus absence of obsolete managed paths before returning success.
- Install, update, and verify the plugin only through supported Codex plugin commands. Same-version installs are no-ops; content changes require a version bump. Never edit Codex cache or configuration files directly.
- Installation and diagnosis never run doctor automatically, query models, start nested Codex, spawn agents, run runtime smoke, or persist runtime readiness.
