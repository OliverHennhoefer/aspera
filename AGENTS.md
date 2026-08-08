# Aspera Orchestrator Policy (clean public contract)

## Source of truth

- This file (`AGENTS.md`), parent task packet, and current request.
- `plugins/aspera-orchestrator/skills/orchestrate/references/policy.md`.
- `plugins/aspera-orchestrator/skills/setup/assets/*` for role defaults.
- `plugins/aspera-orchestrator/skills/setup/scripts/*` for setup/doctor/uninstall command behavior.

Do not derive policy from `.codex/config.toml`.

## Operating model

- Parent is architecture owner and final authority.
- Direct mode is parent-only.
- No recursive delegation.
- No silent fallback to unstated models or roles.
- If contract ambiguity remains, stop with `BLOCKER OR REQUIRED DECISION`.
- Shared-state edits are serialized.

## Activation

- This repository opts into Aspera for implementation work.
- Direct mode remains parent-only and performs no delegation.
- Do not apply Aspera orchestration to reviews, explanations, status requests, setup, doctor, installation, or uninstall work; use the applicable workflow or skill instead.

## Worker lifecycle protocol

- A clean worktree or quota change alone does not prove worker success or failure.
- On first signs of worker stall or uncertainty, inspect the active thread, effective sandbox/approval state, working directory, and latest tool event before intervening.
- Permit at most one corrective steer during a single task unless state has changed materially.
- Use the packet deadline when present; otherwise use 120 seconds as a conservative fallback before classifying non-progress. This is not an expected latency or root-cause diagnosis.
- Interrupt only when there is confirmed failure, explicit approval block, task timeout, or sustained non-progress.
- Parent intervention in interrupted worker cases is treated as a failed delegation and parent intervention.

## Modes

- Direct: parent-only, no delegated roles.
- Express: one `aspera_worker`; add `aspera_verifier` only for behavioral, multi-file, public-contract, or failed-worker cases. Parent is final rerun authority.
- Standard: up to three parallel `aspera_explorer` readers, then disjoint `aspera_worker` edit batches with verification waves.

## Roles

- `aspera_explorer` (read-only investigation)
- `aspera_worker` (bounded edits)
- `aspera_verifier` (bounded validation and evidence)
- `aspera_researcher` (docs/spec checks, evidence-first)
- `aspera_reviewer` (risk gate, read-only)

## Exact packet schemas

Explorer:

- `TASK_ID`
- `QUESTION`
- `READ_ONLY_CONTEXT`
- `CONSTRAINTS`
- `EVIDENCE_REQUIRED`
- `STOP_CONDITIONS`

Worker (full):

- `TASK_ID`
- `OBJECTIVE`
- `OWNED_PATHS`
- `READ_ONLY_CONTEXT`
- `INTERFACE_CONTRACTS`
- `CONSTRAINTS`
- `NON_GOALS`
- `IMPLEMENTATION_STEPS`
- `VERIFICATION`
- `STOP_CONDITIONS`
- `HANDOFF_FORMAT`

Verifier:

- `TASK_ID`
- `OWNED_PATHS`
- `VERIFICATION`
- `EXPECTED_RESULTS`
- `CONSTRAINTS`
- `HANDOFF_FORMAT`

Reviewer:

- `TASK_ID`
- `RISK_SCOPE`
- `READ_ONLY_CONTEXT`
- `INVARIANTS`
- `EVIDENCE_REQUIRED`
- `HANDOFF_FORMAT`

Researcher:

- Explorer schema with documentation/spec `QUESTION`.

## Escalation triggers

- auth/secrets/data exposure
- concurrency or persistent state changes
- public API or schema changes
- unclear invariants
- repeated verification failures
- unexpectedly broad scope

## Canonical handoff format

The value of every required `HANDOFF_FORMAT` field is the schema below. Explorer and researcher roles use it directly because their packets do not carry that field. Read-only roles report `CHANGED FILES: None`.

- `STATUS: done | blocked | failed`
- `TASK_ID:`
- `CHANGED FILES:`
- `VERIFICATION COMMANDS AND RESULTS:`
- `ASSUMPTIONS:`
- `REMAINING RISKS:`
- `BLOCKER OR REQUIRED DECISION:`
