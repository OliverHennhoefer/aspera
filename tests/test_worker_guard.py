#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GUARD_PATH = ROOT / "plugins/aspera-orchestrator/skills/setup/assets/worker_guard.py"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("aspera_worker_guard", GUARD_PATH)
assert SPEC is not None and SPEC.loader is not None
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


HANDOFF = "STATUS: done | blocked | failed; TASK_ID:; CHANGED FILES:; VERIFICATION COMMANDS AND RESULTS:; ASSUMPTIONS:; REMAINING RISKS:; BLOCKER OR REQUIRED DECISION:"


def packet(anchor: str = "anchor.py::target", version: str = "2") -> str:
    return f"""PACKET_VERSION: {version}
TASK_ID: TEST_TASK
OBJECTIVE: Change owned.txt to the requested value and prove it.
READY_STATE: IMPLEMENTATION_READY
OWNED_PATHS:
- owned.txt
EVIDENCE_ANCHORS:
- {anchor}
INTERFACE_CONTRACTS: Keep the owned text file interface stable.
INVARIANTS: Modify no path except owned.txt.
NON_GOALS: Do not redesign adjacent behavior.
IMPLEMENTATION_STEPS:
1. Confirm the supplied target anchor.
2. Edit owned.txt with apply_patch.
3. Run the exact verification command and return the handoff.
ACCEPTANCE_CRITERIA: owned.txt contains changed followed by one newline.
VERIFICATION:
- COMMAND: python3 -m unittest tests.test_worker_guard
  EXPECTED: Exit status 0.
STOP_CONDITIONS: Return blocked when an anchor or invariant is false.
HANDOFF_FORMAT: {HANDOFF}
"""


class WorkerGuardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = tempfile.TemporaryDirectory()
        self.state = tempfile.TemporaryDirectory()
        self.root = Path(self.workspace.name)
        (self.root / "anchor.py").write_text("def target():\n    pass\n", encoding="utf-8")
        (self.root / "owned.txt").write_text("original\n", encoding="utf-8")
        self.previous_state_dir = os.environ.get("ASPERA_GUARD_STATE_DIR")
        os.environ["ASPERA_GUARD_STATE_DIR"] = self.state.name
        self.base = {
            "session_id": "session",
            "turn_id": "turn",
            "transcript_path": "/tmp/transcript",
            "cwd": str(self.root),
            "model": "test-model",
        }

    def tearDown(self) -> None:
        if self.previous_state_dir is None:
            os.environ.pop("ASPERA_GUARD_STATE_DIR", None)
        else:
            os.environ["ASPERA_GUARD_STATE_DIR"] = self.previous_state_dir
        self.state.cleanup()
        self.workspace.cleanup()

    def event(self, name: str, **values: object) -> dict[str, object]:
        return {**self.base, "hook_event_name": name, **values}

    def arm(self, now: float = 1000.0) -> dict[str, object]:
        return guard.handle_hook(self.event("UserPromptSubmit", prompt=packet()), now=now)

    def inspect_once(self, now: float) -> dict[str, object]:
        event = self.event(
            "PostToolUse",
            tool_name="Bash",
            tool_input={"command": "sed -n '1,20p' anchor.py"},
            tool_response={"output": "def target"},
        )
        return guard.handle_hook(event, now=now)

    def test_valid_packet_arms_guard(self) -> None:
        result = self.arm()
        self.assertIn("ASPERA_GUARD_ARMED", result["hookSpecificOutput"]["additionalContext"])

    def test_multiline_handoff_schema_is_packet_data(self) -> None:
        multiline = packet().replace(
            f"HANDOFF_FORMAT: {HANDOFF}",
            """HANDOFF_FORMAT:
STATUS: done | blocked | failed
TASK_ID:
CHANGED FILES:
VERIFICATION COMMANDS AND RESULTS:
ASSUMPTIONS:
REMAINING RISKS:
BLOCKER OR REQUIRED DECISION:""",
        )
        result = guard.handle_hook(self.event("UserPromptSubmit", prompt=multiline), now=1000.0)
        self.assertIn("ASPERA_GUARD_ARMED", result["hookSpecificOutput"]["additionalContext"])

    def test_v1_and_incomplete_packets_fail_closed(self) -> None:
        result = guard.handle_hook(self.event("UserPromptSubmit", prompt=packet(version="1")), now=1000.0)
        self.assertEqual(result["decision"], "block")
        self.assertIn("PACKET_REJECTED", result["reason"])
        incomplete = packet().replace("ACCEPTANCE_CRITERIA: owned.txt contains changed followed by one newline.\n", "")
        result = guard.handle_hook(self.event("UserPromptSubmit", prompt=incomplete), now=1000.0)
        self.assertEqual(result["decision"], "block")

    def test_stale_anchor_is_rejected(self) -> None:
        result = guard.handle_hook(
            self.event("UserPromptSubmit", prompt=packet(anchor="anchor.py::missing_symbol")),
            now=1000.0,
        )
        self.assertEqual(result["decision"], "block")
        self.assertIn("stale", result["reason"])

    def test_mutating_verification_is_rejected(self) -> None:
        mutating = packet().replace(
            "python3 -m unittest tests.test_worker_guard",
            "sed -i '' owned.txt",
        )
        result = guard.handle_hook(self.event("UserPromptSubmit", prompt=mutating), now=1000.0)
        self.assertEqual(result["decision"], "block")
        self.assertIn("shell mutation", result["reason"])

    def test_fifth_inspection_is_blocked(self) -> None:
        self.arm()
        for offset in range(1, 5):
            self.inspect_once(1000.0 + offset)
        result = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "rg target anchor.py"}),
            now=1005.0,
        )
        self.assertEqual(result["decision"], "block")
        self.assertIn("NO_PROGRESS_BUDGET_EXHAUSTED", result["reason"])

    def test_pre_edit_auto_compaction_stops(self) -> None:
        self.arm()
        result = guard.handle_hook(self.event("PreCompact", trigger="auto"), now=1001.0)
        self.assertFalse(result["continue"])
        self.assertEqual(result["stopReason"], "PRE_EDIT_COMPACTION")

    def test_out_of_scope_patch_and_shell_mutation_are_blocked(self) -> None:
        self.arm()
        patch_result = guard.handle_hook(
            self.event(
                "PreToolUse",
                tool_name="apply_patch",
                tool_input={"command": "*** Begin Patch\n*** Update File: other.txt\n*** End Patch"},
            ),
            now=1001.0,
        )
        self.assertIn("OWNERSHIP_VIOLATION", patch_result["reason"])
        shell_result = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "printf changed > owned.txt"}),
            now=1002.0,
        )
        self.assertIn("SHELL_MUTATION_BLOCKED", shell_result["reason"])

    def test_edit_and_verification_reset_progress_budget(self) -> None:
        self.arm()
        self.inspect_once(1001.0)
        pre = guard.handle_hook(
            self.event(
                "PreToolUse",
                tool_name="apply_patch",
                tool_input={"command": "*** Begin Patch\n*** Update File: owned.txt\n*** End Patch"},
            ),
            now=1002.0,
        )
        self.assertEqual(pre, {})
        (self.root / "owned.txt").write_text("changed\n", encoding="utf-8")
        post = guard.handle_hook(
            self.event(
                "PostToolUse",
                tool_name="apply_patch",
                tool_input={"command": "*** Begin Patch\n*** Update File: owned.txt\n*** End Patch"},
                tool_response={"output": "Done"},
            ),
            now=1003.0,
        )
        self.assertIn("PROGRESS_EDIT", post["hookSpecificOutput"]["additionalContext"])
        for offset in range(4, 8):
            self.inspect_once(1000.0 + offset)
        verify = guard.handle_hook(
            self.event(
                "PostToolUse",
                tool_name="Bash",
                tool_input={"command": "python3 -m unittest tests.test_worker_guard"},
                tool_response={"exit_code": 0},
            ),
            now=1008.0,
        )
        self.assertIn("PROGRESS_VERIFICATION", verify["hookSpecificOutput"]["additionalContext"])
        allowed = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "git diff -- owned.txt"}),
            now=1009.0,
        )
        self.assertEqual(allowed, {})

    def test_deadline_only_applies_before_first_edit(self) -> None:
        self.arm(now=1000.0)
        expired = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "rg target anchor.py"}),
            now=1090.0,
        )
        self.assertIn("FIRST_EDIT_DEADLINE", expired["reason"])

        self.state.cleanup()
        self.state = tempfile.TemporaryDirectory()
        os.environ["ASPERA_GUARD_STATE_DIR"] = self.state.name
        self.arm(now=2000.0)
        (self.root / "owned.txt").write_text("changed again\n", encoding="utf-8")
        guard.handle_hook(
            self.event(
                "PostToolUse",
                tool_name="apply_patch",
                tool_input={"command": "*** Begin Patch\n*** Update File: owned.txt\n*** End Patch"},
            ),
            now=2001.0,
        )
        allowed = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "git diff -- owned.txt"}),
            now=2500.0,
        )
        self.assertEqual(allowed, {})

    def test_stop_requires_canonical_handoff(self) -> None:
        self.arm()
        invalid = guard.handle_hook(self.event("Stop", last_assistant_message="done"), now=1001.0)
        self.assertEqual(invalid["stopReason"], "INVALID_HANDOFF")
        valid_message = """STATUS: blocked
TASK_ID: TEST_TASK
CHANGED FILES: None
VERIFICATION COMMANDS AND RESULTS: Not run
ASSUMPTIONS: None
REMAINING RISKS: None
BLOCKER OR REQUIRED DECISION: Anchor changed
"""
        valid = guard.handle_hook(self.event("Stop", last_assistant_message=valid_message), now=1002.0)
        self.assertEqual(valid, {})


if __name__ == "__main__":
    unittest.main()
