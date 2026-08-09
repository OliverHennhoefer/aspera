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
- Treat install/diagnose/uninstall as explicit terminal lifecycle commands, never as task-time orchestration steps.

## Operating modes

- Direct: parent-only execution lifecycle (plan, edit, verify), no delegated roles.
- Express: one `aspera_worker` only for an implementation-ready packet with no escalation trigger; add `aspera_verifier` for behavioral or multi-file work.
- Standard: required for escalation triggers; use up to 3 parallel `aspera_explorer` readers, parent resolution, then serialized or disjoint worker edit batches with verification waves.

## Roles (model-neutral)

- `aspera_explorer` (read-only investigation)
- `aspera_worker` (bounded edits)
- `aspera_verifier` (bounded validation and evidence)
- `aspera_researcher` (docs/spec check, evidence-first)
- `aspera_reviewer` (risk gate, read-only)

## Required packet shape

- Direct: no role packet required.
- Explorer and researcher packet:
  - PACKET_VERSION: 2
  - TASK_ID
  - QUESTION
  - READ_ONLY_CONTEXT
  - CONSTRAINTS
  - EVIDENCE_REQUIRED
  - STOP_CONDITIONS
- Worker packet:
  - PACKET_VERSION: 2
  - TASK_ID
  - OBJECTIVE
  - READY_STATE: IMPLEMENTATION_READY
  - OWNED_PATHS
  - EVIDENCE_ANCHORS
  - INTERFACE_CONTRACTS
  - INVARIANTS
  - NON_GOALS
  - IMPLEMENTATION_STEPS
  - ACCEPTANCE_CRITERIA
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

## Worker execution guidance

- Use the exposed configured role directly; the first real delegation is the runtime exercise.
- If an expected role is absent, stop that lane with one actionable instruction to run `./aspera install --workspace <repository>` from the configured checkout and start a new session. Do not load setup, run doctor, spawn a synthetic worker, or retry the failed bootstrap inside the task.
- Require the worker working directory to equal the repository root so the agent-scoped guard path resolves; otherwise stop before spawn.
- Before spawning, validate the packet with `.codex/aspera-orchestrator/worker_guard.py --validate-packet --root <repository>` on stdin.
- `OWNED_PATHS` contains exact repository-relative files only; no directories, globs, duplicates, overlaps, or traversal.
- `EVIDENCE_ANCHORS` contains confirmed `path::symbol` entries. The worker confirms anchors but does not rediscover architecture.
- `IMPLEMENTATION_STEPS` should be 3-7 clear steps and include:
  - concrete file paths/symbols
  - exact interface touch points
  - decisive verification command(s)
- Keep `STOP_CONDITIONS` explicit (e.g., insufficient signal, contradictory requirements, blocked action).
- The worker guard enforces:
  - at most four inspection calls without a successful owned edit or exact verification command
  - tracked-file edits through `apply_patch` and only within `OWNED_PATHS`
  - no hosted tools or automatic compaction before the first successful edit
  - canonical handoff validation
- Require the first successful edit within 90 seconds after packet acceptance. There is no total timeout after progress begins.
- If the worker misses a guard boundary:
  - inspect thread state before changing course
  - treat a clean worktree or quota change alone as insufficient evidence of success or failure
  - confirm the effective sandbox/approval state, working directory, and latest tool event
  - interrupt on approval block, first-edit deadline, pre-edit compaction, or exhausted progress budget
  - do not steer the polluted pre-edit context; correct the packet or routing and use one fresh worker
- Parent takeover after interruption is a failed delegation and must be recorded as parent intervention.

## Read-only handoff format

Explorer and researcher roles return:

- `STATUS: done | blocked | failed`
- `TASK_ID:`
- `FINDINGS:`
- `EVIDENCE_ANCHORS:`
- `UNRESOLVED_DECISIONS:`
- `RISKS:`
- `BLOCKER OR REQUIRED DECISION:`

The parent resolves every open decision before setting `READY_STATE: IMPLEMENTATION_READY`.

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

Use this schema as every worker, verifier, or reviewer `HANDOFF_FORMAT` value.

- `STATUS: done | blocked | failed`
- `TASK_ID:`
- `CHANGED FILES:`
- `VERIFICATION COMMANDS AND RESULTS:`
- `ASSUMPTIONS:`
- `REMAINING RISKS:`
- `BLOCKER OR REQUIRED DECISION:`
