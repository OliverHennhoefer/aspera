# Aspera routing policy

- This repository opts into Aspera for implementation work. Explicit direct/no-delegation requests override it.
- Sol owns architecture, task slicing, routing, and final acceptance. Continue in Sol when scope or design is unsettled, the edit is too small to amortize a handoff, or delegation would reduce quality.
- Luna Max is the default worker for bounded implementation. Spark is optional and may receive the same Luna-ready capsule only when the checked-in protocol's strict Spark gate already holds; never do extra work to make a task Spark-compatible.
- Before delegating, read `.codex/aspera-orchestrator/protocol.md`, validate packet v3, and use the exposed configured role. If a role is absent, stop that lane and request reinstall plus a new session; never substitute silently.
- Use one precise Luna explorer only when it prevents equivalent Sol inspection. Use Terra pre-edit only for destructive, security, exposure, or irreversible risk; otherwise review risky concrete diffs.
- Workers run focused checks; Sol reruns the decisive acceptance command. Shared-scope edits are serialized; at most two genuinely disjoint workers may run in parallel. No recursive delegation.
- Do not apply Aspera to reviews, explanations, status, setup, diagnosis, installation, uninstall, or development of Aspera itself.
