# Aspera delegation protocol v3

## Routing

Use `aspera_luna_worker` by default after Sol settles architecture, ownership, contract, and acceptance. Luna may own at most 12 exact files and use at most 8 context anchors.

Use `aspera_spark_worker` only when the unchanged Luna-ready capsule is choice-free, mechanical, confined to one subsystem and at most 4 exact files, needs at most 2 anchors and 2 inspections, is at most 2,500 characters, has exact verification, and amortizes startup through at least 4 meaningful inspect/edit/test operations. Never use Spark for diagnosis, architecture, contract interpretation, auth/secrets/exposure, concurrency or persistence semantics, migrations, public-interface design, destructive work, or external side effects.

Do not retry Spark. After a blocked/failed Spark handoff, inspect the diff and upgrade once to Luna with the original capsule plus failure evidence. Permit one Luna repair turn when scope and architecture are unchanged; then return to Sol.

### Spark availability fallback

Spark is optional and must never block the goal. If its worker cannot start or continue because quota is exhausted, capacity or model routing is unavailable, or the Spark role is unavailable:

1. make no second Spark attempt and do not count the event as a blocked goal turn;
2. if Spark started, inspect its latest event and the shared worktree for partial edits;
3. change only `WORKER_TARGET: spark` to `WORKER_TARGET: luna` and send the same capsule to `aspera_luna_worker`;
4. report the fallback reason in the final handoff.

This availability fallback does not consume the one Luna repair turn. Only Luna unavailability may stop the implementation lane.

## Packet

```text
PACKET_VERSION: 3
TASK_ID: stable-id
WORKER_TARGET: luna | spark
OBJECTIVE: bounded outcome
OWNED_PATHS:
- exact/repository/file
CONTEXT_ANCHORS:
- path::symbol
CONTRACT: settled decisions, interfaces, invariants, and material non-goals
ACCEPTANCE: observable completion criteria
VERIFICATION:
- COMMAND: exact read-only verification command
  EXPECTED_EXIT: 0
STOP_CONDITIONS: concrete reasons to block
```

Context anchors are required when any owned path already exists; self-contained all-new-file work may use `CONTEXT_ANCHORS: NONE`.

Validate before spawn:

```bash
python3 .codex/aspera-orchestrator/worker_guard.py --validate-packet --root <repository> < packet
```

Spawn from the repository root. The worker must return:

```text
STATUS: done | blocked | failed
TASK_ID:
CHANGED FILES:
VERIFICATION COMMANDS AND RESULTS:
ASSUMPTIONS:
REMAINING RISKS:
BLOCKER OR REQUIRED DECISION:
```

`done` requires truthful changed files and every required verification command to complete with its expected exit code. Sol inspects the diff and reruns the decisive command before acceptance.
