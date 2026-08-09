# Aspera Orchestrator Policy (clean public contract)

## Source of truth

- This managed `AGENTS.md` block, parent task packet, and current request.
- Installed role contracts in project `.codex/agents/aspera-*.toml`.
- Setup metadata in `.codex/aspera-orchestrator/state.json`; it is not task policy.

## Activation

- This managed block opts the repository into Aspera for implementation work; it does not depend on the `orchestrate` skill being attached to each task.
- Direct mode remains parent-only and performs no delegation.
- Do not apply Aspera orchestration to reviews, explanations, status requests, setup, doctor, installation, or uninstall work; use the applicable workflow or skill instead.

## Worker lifecycle protocol

- A clean worktree or quota change alone does not prove worker success or failure.
- Validate every worker packet with `.codex/aspera-orchestrator/worker_guard.py --validate-packet --root <repository>` before spawn.
- Use the exposed configured worker directly; the first real delegation is the runtime exercise.
- If the expected role is absent, stop that lane with one actionable instruction to run `./aspera install --workspace <repository>` from the configured checkout and start a new session. Do not load setup, run doctor, spawn a synthetic worker, or retry the failed bootstrap inside the task.
- Spawn the worker with the repository root as its working directory; a different working directory is a pre-spawn blocker because the agent-scoped guard path is root-relative.
- Permit at most four inspection calls without a successful owned edit or exact verification command.
- Require the first successful owned-file edit within 90 seconds of packet acceptance; there is no total task timeout while progress continues.
- Automatic pre-edit compaction, exhausted inspection budget, approval block, or missed first-edit deadline ends the worker turn.
- Inspect the active thread, effective sandbox/approval state, working directory, and latest tool event before interruption.
- Do not steer a pre-edit failed worker. Correct the packet or routing and use one fresh worker; parent takeover is a failed delegation with parent intervention.

## Operating model

- Parent is architecture owner and final authority.
- No recursive delegation.
- No silent fallback to unstated models or roles.
- If contract ambiguity remains, stop and set `BLOCKER OR REQUIRED DECISION`.
- Shared-state or shared-scope edits are serialized.

## Modes

- Direct: parent-only execution lifecycle (plan, edit, verify), no delegated roles.
- Express: one `aspera_worker` only when packet v2 is implementation-ready and no escalation trigger exists; add `aspera_verifier` for behavioral or multi-file work.
- Standard: required for an escalation trigger; use up to 3 parallel `aspera_explorer` readers, parent resolution, then serialized or disjoint worker batches with verification waves.

## Roles (model-neutral)

- `aspera_explorer` (read-only investigation)
- `aspera_worker` (bounded edits)
- `aspera_verifier` (bounded validation and evidence)
- `aspera_researcher` (docs/spec check, evidence-first)
- `aspera_reviewer` (risk gate, read-only)

## Role-specific packet shape

- Direct: no role packet required.
- Explorer packet:
  - `PACKET_VERSION: 2`, `TASK_ID`, `QUESTION`, `READ_ONLY_CONTEXT`, `CONSTRAINTS`, `EVIDENCE_REQUIRED`, `STOP_CONDITIONS`.
- Researcher packet:
  - Explorer schema with a documentation/spec `QUESTION`.
- Worker packet:
  - `PACKET_VERSION: 2`, `TASK_ID`, `OBJECTIVE`, `READY_STATE: IMPLEMENTATION_READY`, `OWNED_PATHS`, `EVIDENCE_ANCHORS`, `INTERFACE_CONTRACTS`, `INVARIANTS`, `NON_GOALS`, `IMPLEMENTATION_STEPS`, `ACCEPTANCE_CRITERIA`, `VERIFICATION`, `STOP_CONDITIONS`, `HANDOFF_FORMAT`.
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

## Read-only handoff format

Explorer and researcher roles return `STATUS`, `TASK_ID`, `FINDINGS`, `EVIDENCE_ANCHORS`, `UNRESOLVED_DECISIONS`, `RISKS`, and `BLOCKER OR REQUIRED DECISION`. The parent resolves all open decisions before compiling a worker packet.

## Canonical handoff format

The value of every worker, verifier, or reviewer `HANDOFF_FORMAT` field is:

- `STATUS: done | blocked | failed`
- `TASK_ID:`
- `CHANGED FILES:`
- `VERIFICATION COMMANDS AND RESULTS:`
- `ASSUMPTIONS:`
- `REMAINING RISKS:`
- `BLOCKER OR REQUIRED DECISION:`
