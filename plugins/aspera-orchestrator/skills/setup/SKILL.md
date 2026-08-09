---
name: setup
description: |
  Diagnose or remove a project-scoped Aspera installation when the user
  explicitly requests lifecycle support. Normal installation and updates use
  the checkout's root ./aspera command in a terminal.
---

# Aspera lifecycle support

Normal use is terminal-first:

```bash
./aspera install --workspace /absolute/path/to/project
```

That command installs or updates the plugin and project profile, migrates supported
state, verifies exact managed files, and prints the fresh-session boundary. Do not
invoke this skill during an implementation task and do not add a post-install doctor
or runtime smoke step.

Omitted flags preserve the installed profile and policy. Use `--no-policy` to remove
managed activation and `--install-policy` to restore it; the options are mutually
exclusive. Forced reconciliation backs up and removes every approved current,
profile-excluded, or legacy Aspera conflict.

Use the bundled scripts only for explicitly requested support:

- Read-only diagnosis: `bash ./scripts/doctor.sh [--profile adaptive|luna] [--workspace PATH]`
- Project uninstall: `bash ./scripts/uninstall.sh [--dry-run] [--force] [--workspace PATH]`

Diagnosis never starts Codex, spawns an agent, writes state, or changes readiness.
Installation state schema 4 is a compact managed-file receipt; the root installer
automatically migrates valid schema-1, schema-2, and schema-3 receipts.

## Non-goals

- No task-time setup or repair.
- No model-catalog preflight.
- No runtime-smoke or synthetic delegation.
- No direct Codex cache or project configuration mutation.
