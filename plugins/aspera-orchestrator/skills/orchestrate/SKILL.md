---
name: orchestrate
description: |
  Explicitly invoked orchestration for repository implementation work using
  Direct, Express, or Standard mode. Do not use for reviews, explanations,
  status requests, setup, doctor, installation, or uninstall work.
---

# Native Orchestrator

Use this skill only after the user explicitly chooses orchestration for a concrete repository
implementation task and provides or accepts a packet. A managed Aspera policy in `AGENTS.md`
can apply the same contract directly without loading this skill.

## Invocation

- Use `/skills` or select `$aspera-orchestrator:orchestrate` for one task.
- Treat setup/install/doctor/uninstall as non-orchestrate flows handled by the `setup` skill or parent.

## Operating modes

- Direct: parent-only execution lifecycle (plan, edit, verify), no delegated roles.
- Express: one `aspera_worker`; add `aspera_verifier` only for behavioral, multi-file, public-contract, or failed-worker work.
- Standard: up to 3 parallel `aspera_explorer` readers, then disjoint `aspera_worker` edit batches with verification waves.

## Roles (model-neutral)

- `aspera_explorer` (read-only investigation)
- `aspera_worker` (bounded edits)
- `aspera_verifier` (bounded validation and evidence)
- `aspera_researcher` (docs/spec check, evidence-first)
- `aspera_reviewer` (risk gate, read-only)

## Required packet shape

- Direct: no role packet required.
- Explorer and researcher packet:
  - TASK_ID
  - QUESTION
  - READ_ONLY_CONTEXT
  - CONSTRAINTS
  - EVIDENCE_REQUIRED
  - STOP_CONDITIONS
- Worker packet:
  - TASK_ID
  - OBJECTIVE
  - OWNED_PATHS
  - READ_ONLY_CONTEXT
  - INTERFACE_CONTRACTS
  - CONSTRAINTS
  - NON_GOALS
  - IMPLEMENTATION_STEPS
  - VERIFICATION
  - STOP_CONDITIONS
  - HANDOFF_FORMAT
- Verifier packet:
  - TASK_ID
  - OWNED_PATHS
  - VERIFICATION
  - EXPECTED_RESULTS
  - CONSTRAINTS
  - HANDOFF_FORMAT

- Reviewer packet:
  - TASK_ID
  - RISK_SCOPE
  - READ_ONLY_CONTEXT
  - INVARIANTS
  - EVIDENCE_REQUIRED
  - HANDOFF_FORMAT

## Escalation triggers

- auth/secrets/data exposure
- concurrency or persistent state changes
- public API or schema changes
- unclear invariants
- repeated verification failures
- unexpectedly broad scope
- unclear contract interpretation

## Contract rules

- Parent is the architecture owner and final authority.
- No recursive delegation.
- No silent fallback to unspecified models or roles.
- Isolated context / one writer per disjoint path.
- Shared-state edits are serialized by parent.
- Parent reruns explicit checks before accepting output.

## Canonical handoff format

Use this schema as every required `HANDOFF_FORMAT` value. Explorer and researcher roles use it directly and set `CHANGED FILES: None`.

- `STATUS: done | blocked | failed`
- `TASK_ID:`
- `CHANGED FILES:`
- `VERIFICATION COMMANDS AND RESULTS:`
- `ASSUMPTIONS:`
- `REMAINING RISKS:`
- `BLOCKER OR REQUIRED DECISION:`
