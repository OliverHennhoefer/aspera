# Native Codex Orchestrator Policy (v1)

This repository uses a **planner-worker-verifier** model.

Source of truth:
- `AGENTS.md` for enforcement rules and operating policy.
- `.codex/config.toml` and `.codex/agents/*.toml` for runtime role routing.
- `plugins/orchestrator/skills/*` for execution and setup workflows.

## 1) Operating modes

Use **Express mode** for low-risk, bounded edits:

- One worker owns the file set end-to-end.
- One verifier validates explicit checks.
- Parent inspects diff and verifies manually.

Use **Standard mode** for ambiguous or high-risk work:

- Spawn 2–4 explorers in parallel to map read-only evidence.
- Parent converts evidence into a bounded implementation plan.
- Spawn implementation workers with disjoint paths.
- Run verification after each implementation wave.
- Escalate to `terra-reviewer` for risk gates.

## 2) Deterministic task packet (required format)

Every worker request must include, verbatim:

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

## 3) Agent roles

- `spark_explorer` (read-only investigation)
- `spark_worker` (bounded edits)
- `spark_verifier` (evidence-based verification)
- `terra-reviewer` (risk-gated Terra-style read-only review)

## 4) Rules

1. Parent is the architecture owner and final authority.
2. No recursive delegation (`agent -> agent`).
3. Workers edit only `OWNED_PATHS`.
4. No silent fallback to unexpected models; spawn values are explicit.
5. Every worker report must use its required handoff format.
6. Shared files are never edited in parallel by multiple workers.
7. Shared-scope/shared-state edits must be serial.
8. Parent re-runs explicit verification commands before accepting any output.

## 5) Escalation

Use `terra-reviewer` (or parent) for:

- auth/secrets/data exposure
- concurrency or persistent state changes
- public/API or schema changes
- unclear invariants
- repeated verification failures
- unexpectedly broad diff

Use `spark`-based roles first; escalate only after retries are exhausted.

## 6) Risk and scope controls

- Every change must be mechanically testable.
- No behavior redesign without a matching ticketed packet.
- If ambiguity exists, workers must stop with `BLOCKER OR REQUIRED DECISION`.
