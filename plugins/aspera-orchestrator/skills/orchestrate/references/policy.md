# Aspera Orchestrator Policy (clean public contract)

## Source of truth

- This file (`AGENTS.md`), parent task packet, and current request.
- Canonical policy: `plugins/aspera-orchestrator/skills/orchestrate/references/policy.md`.
- Managed role contracts in `plugins/aspera-orchestrator/skills/setup/assets/`.
- Setup scripts in `plugins/aspera-orchestrator/skills/setup/scripts/`.

## Operating model

- Parent is architecture owner and final authority.
- No recursive delegation.
- No silent fallback to unstated models or roles.
- If contract ambiguity remains, stop and set `BLOCKER OR REQUIRED DECISION`.
- Shared-state or shared-scope edits are serialized.

## Modes

- Direct: parent-only execution lifecycle (plan, edit, verify), no delegated roles.
- Express: one `aspera_worker`; add `aspera_verifier` only for behavioral, multi-file, public-contract, or failed-worker cases; parent is final rerun authority.
- Standard: up to 3 parallel `aspera_explorer` readers, then disjoint `aspera_worker` edit batches with verification waves.

## Roles (model-neutral)

- `aspera_explorer` (read-only investigation)
- `aspera_worker` (bounded edits)
- `aspera_verifier` (bounded validation and evidence)
- `aspera_researcher` (docs/spec check, evidence-first)
- `aspera_reviewer` (risk gate, read-only)

## Role-specific packet shape

- Direct: no role packet required.
- Explorer packet:
  - `TASK_ID`, `QUESTION`, `READ_ONLY_CONTEXT`, `CONSTRAINTS`, `EVIDENCE_REQUIRED`, `STOP_CONDITIONS`.
- Researcher packet:
  - `TASK_ID`, `QUESTION`, `READ_ONLY_CONTEXT`, `CONSTRAINTS`, `EVIDENCE_REQUIRED`, `STOP_CONDITIONS`.
- Worker packet:
  - `TASK_ID`, `OBJECTIVE`, `OWNED_PATHS`, `READ_ONLY_CONTEXT`, `INTERFACE_CONTRACTS`, `CONSTRAINTS`, `NON_GOALS`, `IMPLEMENTATION_STEPS`, `VERIFICATION`, `STOP_CONDITIONS`, `HANDOFF_FORMAT`.
- Verifier packet:
  - `TASK_ID`, `OWNED_PATHS`, `VERIFICATION`, `EXPECTED_RESULTS`, `CONSTRAINTS`, `HANDOFF_FORMAT`.
- Reviewer packet:
  - `TASK_ID`, `RISK_SCOPE`, `READ_ONLY_CONTEXT`, `INVARIANTS`, `EVIDENCE_REQUIRED`, `HANDOFF_FORMAT`.

## Escalation triggers

- auth/secrets/data exposure
- concurrency or persistent state changes
- public API or schema changes
- unclear invariants
- repeated verification failures
- unexpectedly broad scope

Use `aspera_reviewer` (or parent) for the triggers above.

## Canonical handoff format

The value of every required `HANDOFF_FORMAT` field is the schema below. Explorer and researcher roles use it directly because their packets do not carry that field. Read-only roles report `CHANGED FILES: None`.

- `STATUS: done | blocked | failed`
- `TASK_ID:`
- `CHANGED FILES:`
- `VERIFICATION COMMANDS AND RESULTS:`
- `ASSUMPTIONS:`
- `REMAINING RISKS:`
- `BLOCKER OR REQUIRED DECISION:`
