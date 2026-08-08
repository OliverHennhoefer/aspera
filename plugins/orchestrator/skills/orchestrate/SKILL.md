name: orchestrate
description: |-
  Apply the planner-worker-verifier process with bounded, evidence-first tasks and
  explicit verification.

# Native Orchestrator

Use this skill when implementing repository work in Codex.

## Required packet shape

Send this exact sequence to workers:

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

## Operating modes

- Express: one `spark_worker`, one `spark_verifier`, parent re-runs decisive checks.
- Standard: 2-4 `spark_explorer` roles in parallel first, then disjoint worker waves.

## Role routing

- `spark_explorer`: read-only mapping and evidence.
- `spark_worker`: bounded implementation in owned files.
- `spark_verifier`: scoped validation and failing evidence.
- `terra-reviewer`: risk gate (auth, migration, public contract, repeated failure).
- `luna_researcher`: fast pass for doc/spec-pattern checks.

## Non-goals

Do not alter this workflow with recursive delegation. No new interface redesign unless
requested in the parent packet.
