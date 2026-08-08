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
- Before spawn, validate the complete worker packet with the managed worker guard.
- Delegation requires schema-2 state with `guard.verified: true` for the installed profile and guard hash.
- Spawn workers with the repository root as their working directory so the managed agent-scoped hook path resolves exactly.
- The worker receives settled architecture and exact evidence anchors; it confirms them but does not rediscover architecture.
- Permit at most four inspection calls without a successful owned edit or exact verification command.
- Require the first successful owned-file edit within 90 seconds of packet acceptance. This is not a total task timeout.
- Automatic compaction before the first edit, exhausted inspection budget, approval block, or missed first-edit deadline ends the worker turn.
- Inspect the active thread, effective sandbox/approval state, working directory, and latest tool event before interruption.
- Do not steer a pre-edit failed worker. Correct the packet or routing and use one fresh worker.
- Parent intervention after interruption is a failed delegation and is reported as parent intervention.

## Modes

- Direct: parent-only, no delegated roles.
- Express: one `aspera_worker` only for an implementation-ready packet with no escalation trigger; add `aspera_verifier` for behavioral or multi-file work. Parent is final rerun authority.
- Standard: required for every escalation trigger; use up to three parallel `aspera_explorer` readers, parent resolution, then serialized or disjoint `aspera_worker` edit batches with verification waves.

## Roles

- `aspera_explorer` (read-only investigation)
- `aspera_worker` (bounded edits)
- `aspera_verifier` (bounded validation and evidence)
- `aspera_researcher` (docs/spec checks, evidence-first)
- `aspera_reviewer` (risk gate, read-only)

## Exact packet schemas

Explorer:

- `PACKET_VERSION: 2`
- `TASK_ID`
- `QUESTION`
- `READ_ONLY_CONTEXT`
- `CONSTRAINTS`
- `EVIDENCE_REQUIRED`
- `STOP_CONDITIONS`

Worker (full):

- `PACKET_VERSION: 2`
- `TASK_ID`
- `OBJECTIVE`
- `READY_STATE: IMPLEMENTATION_READY`
- `OWNED_PATHS`
- `EVIDENCE_ANCHORS`
- `INTERFACE_CONTRACTS`
- `INVARIANTS`
- `NON_GOALS`
- `IMPLEMENTATION_STEPS`
- `ACCEPTANCE_CRITERIA`
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

## Read-only handoff format

Explorer and researcher roles return:

- `STATUS: done | blocked | failed`
- `TASK_ID:`
- `FINDINGS:`
- `EVIDENCE_ANCHORS:`
- `UNRESOLVED_DECISIONS:`
- `RISKS:`
- `BLOCKER OR REQUIRED DECISION:`

The parent resolves every `UNRESOLVED_DECISIONS` entry before setting `READY_STATE: IMPLEMENTATION_READY`.

## Escalation triggers

- auth/secrets/data exposure
- concurrency or persistent state changes
- public API or schema changes
- unclear invariants
- repeated verification failures
- unexpectedly broad scope

## Canonical handoff format

The value of every worker, verifier, or reviewer `HANDOFF_FORMAT` field is:

- `STATUS: done | blocked | failed`
- `TASK_ID:`
- `CHANGED FILES:`
- `VERIFICATION COMMANDS AND RESULTS:`
- `ASSUMPTIONS:`
- `REMAINING RISKS:`
- `BLOCKER OR REQUIRED DECISION:`
