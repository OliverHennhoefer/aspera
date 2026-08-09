#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
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


def packet(target: str = "luna", version: str = "3", owned: list[str] | None = None) -> str:
    paths = owned or ["owned.txt"]
    return f"""PACKET_VERSION: {version}
TASK_ID: TEST_TASK
WORKER_TARGET: {target}
OBJECTIVE: Apply the exact requested text transformation.
OWNED_PATHS:
{chr(10).join(f'- {path}' for path in paths)}
CONTEXT_ANCHORS:
- anchor.py::target
CONTRACT: Preserve the existing text interface and change only the owned files.
ACCEPTANCE: Every owned file contains changed followed by one newline.
VERIFICATION:
- COMMAND: python3 -m unittest tests.test_worker_guard
  EXPECTED_EXIT: 0
STOP_CONDITIONS: Return blocked if an anchor, ownership boundary, or contract is false.
"""


def handoff(status: str, changed: list[str] | None = None) -> str:
    changed_text = "None" if not changed else "\n".join(f"- {path}" for path in changed)
    return f"""STATUS: {status}
TASK_ID: TEST_TASK
CHANGED FILES:
{changed_text}
VERIFICATION COMMANDS AND RESULTS: Recorded by the guard.
ASSUMPTIONS: None
REMAINING RISKS: None
BLOCKER OR REQUIRED DECISION: None
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
            "model": "gpt-5.6-luna",
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

    def arm(self, target: str = "luna", now: float = 1000.0) -> dict[str, object]:
        self.base["model"] = guard.TARGETS[target]["model"]
        return guard.handle_hook(self.event("UserPromptSubmit", prompt=packet(target)), now=now)

    def inspect_once(self, now: float) -> dict[str, object]:
        return guard.handle_hook(
            self.event(
                "PostToolUse",
                tool_name="Bash",
                tool_input={"command": "sed -n '1,20p' anchor.py"},
                tool_response={"output": "def target"},
            ),
            now=now,
        )

    def edit_once(self, now: float = 1001.0) -> None:
        pre = guard.handle_hook(
            self.event(
                "PreToolUse",
                tool_name="apply_patch",
                tool_input={"command": "*** Begin Patch\n*** Update File: owned.txt\n*** End Patch"},
            ),
            now=now,
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
            now=now + 1,
        )
        self.assertIn("PROGRESS_EDIT", post["hookSpecificOutput"]["additionalContext"])

    def verify_once(self, exit_code: int = 0, now: float = 1003.0) -> dict[str, object]:
        command = "python3 -m unittest tests.test_worker_guard"
        return guard.handle_hook(
            self.event(
                "PostToolUse",
                tool_name="Bash",
                tool_input={"command": command},
                tool_response={"exit_code": exit_code, "output": "result"},
            ),
            now=now,
        )

    def test_valid_luna_and_spark_packets(self) -> None:
        luna = guard.validate_packet(packet("luna"), self.root)
        spark = guard.validate_packet(packet("spark"), self.root)
        self.assertEqual(luna["target"], "luna")
        self.assertEqual(spark["target"], "spark")

    def test_v2_is_rejected_with_migration_instruction(self) -> None:
        with self.assertRaisesRegex(guard.PacketError, "packet v3 required"):
            guard.validate_packet(packet(version="2"), self.root)

    def test_worker_model_mismatch_is_blocked(self) -> None:
        self.base["model"] = "gpt-5.3-codex-spark"
        result = guard.handle_hook(self.event("UserPromptSubmit", prompt=packet("luna")), now=1000.0)
        self.assertIn("WORKER_MODEL_MISMATCH", result["reason"])

    def test_spark_caps_and_excluded_risk(self) -> None:
        paths = []
        for index in range(5):
            name = f"owned-{index}.txt"
            (self.root / name).write_text("original\n", encoding="utf-8")
            paths.append(name)
        with self.assertRaisesRegex(guard.PacketError, "at most 4"):
            guard.validate_packet(packet("spark", owned=paths), self.root)
        risky = packet("spark").replace("exact requested text transformation", "database schema migration")
        with self.assertRaisesRegex(guard.PacketError, "excluded risk scope"):
            guard.validate_packet(risky, self.root)

        oversized = packet("spark").replace(
            "Preserve the existing text interface",
            "Preserve " + ("mechanical behavior " * 180),
        )
        with self.assertRaisesRegex(guard.PacketError, "exceeds 2500 bytes"):
            guard.validate_packet(oversized, self.root)

    def test_context_none_is_only_for_all_new_files(self) -> None:
        invalid = packet().replace("- anchor.py::target", "NONE")
        with self.assertRaisesRegex(guard.PacketError, "every owned path is new"):
            guard.validate_packet(invalid, self.root)
        new_packet = packet(owned=["new.txt"]).replace("- anchor.py::target", "NONE")
        self.assertEqual(guard.validate_packet(new_packet, self.root)["anchors"], [])

    def test_target_specific_inspection_budgets(self) -> None:
        self.arm("spark")
        self.inspect_once(1001.0)
        self.inspect_once(1002.0)
        blocked = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "rg target anchor.py"}),
            now=1003.0,
        )
        self.assertIn("NO_PROGRESS_BUDGET_EXHAUSTED", blocked["reason"])

        self.state.cleanup()
        self.state = tempfile.TemporaryDirectory()
        os.environ["ASPERA_GUARD_STATE_DIR"] = self.state.name
        self.arm("luna", now=2000.0)
        for offset in range(1, 9):
            self.inspect_once(2000.0 + offset)
        blocked = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "rg target anchor.py"}),
            now=2009.0,
        )
        self.assertIn("NO_PROGRESS_BUDGET_EXHAUSTED", blocked["reason"])

    def test_pre_edit_verification_grants_one_edit_window(self) -> None:
        self.arm("spark", now=1000.0)
        result = self.verify_once(now=1080.0)
        self.assertIn("VERIFICATION_PASSED", result["hookSpecificOutput"]["additionalContext"])
        allowed = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "rg target anchor.py"}),
            now=1169.0,
        )
        self.assertEqual(allowed, {})
        blocked = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "rg target anchor.py"}),
            now=1170.0,
        )
        self.assertIn("PROGRESS_DEADLINE", blocked["reason"])

    def test_initial_evidence_deadline_is_target_specific(self) -> None:
        self.arm("spark", now=1000.0)
        blocked = guard.handle_hook(
            self.event("PreToolUse", tool_name="Bash", tool_input={"command": "rg target anchor.py"}),
            now=1090.0,
        )
        self.assertIn("PROGRESS_DEADLINE", blocked["reason"])

    def test_ownership_and_shell_mutation_are_blocked(self) -> None:
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

    def test_done_requires_real_verification_and_truthful_changed_files(self) -> None:
        self.arm()
        self.edit_once()
        incomplete = guard.handle_hook(
            self.event("Stop", last_assistant_message=handoff("done", ["owned.txt"])), now=1003.0
        )
        self.assertIn("VERIFICATION_INCOMPLETE", incomplete["reason"])
        self.verify_once(now=1004.0)
        untruthful = guard.handle_hook(
            self.event("Stop", last_assistant_message=handoff("done", [])), now=1005.0
        )
        self.assertIn("UNTRUTHFUL_CHANGED_FILES", untruthful["reason"])
        valid = guard.handle_hook(
            self.event("Stop", last_assistant_message=handoff("done", ["owned.txt"])), now=1006.0
        )
        self.assertEqual(valid, {})

    def test_failed_verification_can_return_failed_and_writes_safe_receipt(self) -> None:
        self.arm()
        self.edit_once()
        self.verify_once(exit_code=1)
        result = guard.handle_hook(
            self.event("Stop", last_assistant_message=handoff("failed", ["owned.txt"])), now=1005.0
        )
        self.assertEqual(result, {})
        receipts = guard._list_receipts()
        self.assertEqual(len(receipts), 1)
        receipt = receipts[0]
        self.assertEqual(receipt["target"], "luna")
        self.assertEqual(receipt["verification_exits"], [{"expected": 0, "observed": 1}])
        serialized = json.dumps(receipt)
        self.assertNotIn("TEST_TASK", serialized)
        self.assertNotIn("owned.txt", serialized)

    def test_pre_evidence_compaction_stops(self) -> None:
        self.arm()
        result = guard.handle_hook(self.event("PreCompact", trigger="auto"), now=1001.0)
        self.assertFalse(result["continue"])
        self.assertEqual(result["stopReason"], "PRE_EVIDENCE_COMPACTION")


if __name__ == "__main__":
    unittest.main()
