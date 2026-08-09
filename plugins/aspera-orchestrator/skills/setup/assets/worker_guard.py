#!/usr/bin/env python3
"""Aspera worker packet validator and lifecycle hook.

The hook stores only lifecycle metadata in the OS temporary directory. It never
stores the task prompt or tool output.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import sys
import tempfile
import time
from typing import Any


PACKET_VERSION = "2"
READY_STATE = "IMPLEMENTATION_READY"
FIRST_EDIT_DEADLINE_SECONDS = 90.0
MAX_INSPECTIONS = 4
STATE_TTL_SECONDS = 24 * 60 * 60
REQUIRED_FIELDS = (
    "PACKET_VERSION",
    "TASK_ID",
    "OBJECTIVE",
    "READY_STATE",
    "OWNED_PATHS",
    "EVIDENCE_ANCHORS",
    "INTERFACE_CONTRACTS",
    "INVARIANTS",
    "NON_GOALS",
    "IMPLEMENTATION_STEPS",
    "ACCEPTANCE_CRITERIA",
    "VERIFICATION",
    "STOP_CONDITIONS",
    "HANDOFF_FORMAT",
)
HANDOFF_FIELDS = (
    "STATUS:",
    "TASK_ID:",
    "CHANGED FILES:",
    "VERIFICATION COMMANDS AND RESULTS:",
    "ASSUMPTIONS:",
    "REMAINING RISKS:",
    "BLOCKER OR REQUIRED DECISION:",
)
PLACEHOLDER_RE = re.compile(r"<[^>]+>|\b(?:TBD|TO BE DECIDED|UNRESOLVED)\b", re.IGNORECASE)
GLOB_RE = re.compile(r"[*?\[\]{}]")
PATCH_PATH_RE = re.compile(r"^\*\*\* (?:Add|Update|Delete) File: (.+)$", re.MULTILINE)
VERIFY_COMMAND_RE = re.compile(r"(?m)^\s*-\s*COMMAND:\s*(\S.*)$")
VERIFY_EXPECTED_RE = re.compile(r"(?m)^\s*EXPECTED:\s*(\S.*)$")
STEP_RE = re.compile(r"(?m)^\s*(?:\d+[.)]|-)\s+\S")
SHELL_MUTATION_RE = re.compile(
    r"(?:^|[^<])>{1,2}|\bsed\b[^\n]*\s-i\b|\b(?:tee|rm|mv|cp|mkdir|touch|chmod|chown|install)\b"
)


class PacketError(ValueError):
    pass


def _json_output(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, separators=(",", ":")))


def _hook_stop(classification: str, reason: str) -> dict[str, Any]:
    message = f"ASPERA_GUARD {classification}: {reason}"
    return {"continue": False, "stopReason": classification, "systemMessage": message}


def _hook_block(classification: str, reason: str) -> dict[str, Any]:
    return {
        "decision": "block",
        "reason": f"ASPERA_GUARD {classification}: {reason}",
        "systemMessage": f"ASPERA_GUARD {classification}",
    }


def _additional_context(event_name: str, text: str) -> dict[str, Any]:
    return {
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": text,
        }
    }


def _parse_fields(prompt: str) -> dict[str, str]:
    matches: list[tuple[str, re.Match[str]]] = []
    cursor = 0
    for key in REQUIRED_FIELDS:
        pattern = re.compile(rf"(?m)^{re.escape(key)}:(?:[ \t]*(.*))?$")
        match = pattern.search(prompt, cursor)
        if match is None:
            raise PacketError(f"missing or empty fields: {key}")
        matches.append((key, match))
        cursor = match.end()
    fields: dict[str, str] = {}
    for index, (key, match) in enumerate(matches):
        end = matches[index + 1][1].start() if index + 1 < len(matches) else len(prompt)
        inline = (match.group(1) or "").strip()
        tail = prompt[match.end() : end].strip()
        value = "\n".join(part for part in (inline, tail) if part).strip()
        fields[key] = value
    missing = [field for field in REQUIRED_FIELDS if not fields.get(field, "").strip()]
    if missing:
        raise PacketError(f"missing or empty fields: {', '.join(missing)}")
    return fields


def _list_items(value: str) -> list[str]:
    items: list[str] = []
    for line in value.splitlines():
        item = re.sub(r"^\s*(?:[-*]|\d+[.)])\s*", "", line).strip()
        if item:
            items.append(item)
    if len(items) == 1 and "," in items[0]:
        items = [part.strip() for part in items[0].split(",") if part.strip()]
    return items


def _normalize_owned_path(root: Path, raw: str) -> tuple[str, Path]:
    if GLOB_RE.search(raw):
        raise PacketError(f"OWNED_PATHS contains a glob: {raw}")
    pure = PurePosixPath(raw)
    if pure.is_absolute() or ".." in pure.parts or not pure.parts:
        raise PacketError(f"OWNED_PATHS contains an unsafe path: {raw}")
    normalized = pure.as_posix()
    candidate = (root / normalized).resolve(strict=False)
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise PacketError(f"OWNED_PATHS escapes the repository: {raw}") from exc
    if candidate.exists() and not candidate.is_file():
        raise PacketError(f"OWNED_PATHS must list exact files, not directories: {raw}")
    return normalized, candidate


def _validate_owned_paths(root: Path, value: str) -> list[str]:
    owned: list[str] = []
    resolved: list[Path] = []
    for raw in _list_items(value):
        normalized, candidate = _normalize_owned_path(root, raw)
        if normalized in owned:
            raise PacketError(f"duplicate OWNED_PATHS entry: {normalized}")
        for prior in resolved:
            if candidate in prior.parents or prior in candidate.parents:
                raise PacketError(f"overlapping OWNED_PATHS entries: {normalized}")
        owned.append(normalized)
        resolved.append(candidate)
    if not owned:
        raise PacketError("OWNED_PATHS has no exact file entries")
    return owned


def _validate_anchors(root: Path, value: str) -> list[str]:
    anchors = _list_items(value)
    if not anchors:
        raise PacketError("EVIDENCE_ANCHORS has no anchors")
    for anchor in anchors:
        if "::" not in anchor:
            raise PacketError(f"anchor must use path::symbol: {anchor}")
        path_text, symbol = (part.strip() for part in anchor.split("::", 1))
        normalized, path = _normalize_owned_path(root, path_text)
        if not path.is_file():
            raise PacketError(f"anchor path does not exist: {normalized}")
        if not symbol:
            raise PacketError(f"anchor symbol is empty: {anchor}")
        text = path.read_text(encoding="utf-8", errors="ignore")
        if symbol not in text:
            raise PacketError(f"anchor symbol is stale: {anchor}")
    return anchors


def _validate_verification(value: str) -> list[str]:
    commands = [match.group(1).strip() for match in VERIFY_COMMAND_RE.finditer(value)]
    expected = [match.group(1).strip() for match in VERIFY_EXPECTED_RE.finditer(value)]
    if not commands or len(commands) != len(expected):
        raise PacketError("VERIFICATION requires paired '- COMMAND:' and 'EXPECTED:' entries")
    if any(not command or PLACEHOLDER_RE.search(command) for command in commands):
        raise PacketError("VERIFICATION contains an empty or unresolved command")
    if any(SHELL_MUTATION_RE.search(command) for command in commands):
        raise PacketError("VERIFICATION contains shell mutation syntax")
    return commands


def validate_packet(prompt: str, root: Path) -> dict[str, Any]:
    root = root.resolve()
    fields = _parse_fields(prompt)
    if fields["PACKET_VERSION"].strip() != PACKET_VERSION:
        raise PacketError(f"PACKET_VERSION must be {PACKET_VERSION}")
    if fields["READY_STATE"].strip() != READY_STATE:
        raise PacketError(f"READY_STATE must be {READY_STATE}")
    task_id = fields["TASK_ID"].strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", task_id):
        raise PacketError("TASK_ID must be a stable identifier without whitespace")
    for key, value in fields.items():
        if key != "HANDOFF_FORMAT" and PLACEHOLDER_RE.search(value):
            raise PacketError(f"{key} contains an unresolved placeholder")
    owned = _validate_owned_paths(root, fields["OWNED_PATHS"])
    anchors = _validate_anchors(root, fields["EVIDENCE_ANCHORS"])
    steps = STEP_RE.findall(fields["IMPLEMENTATION_STEPS"])
    if not 3 <= len(steps) <= 7:
        raise PacketError("IMPLEMENTATION_STEPS must contain 3-7 ordered steps")
    commands = _validate_verification(fields["VERIFICATION"])
    missing_handoff = [field for field in HANDOFF_FIELDS if field not in fields["HANDOFF_FORMAT"]]
    if missing_handoff:
        raise PacketError(f"HANDOFF_FORMAT missing fields: {', '.join(missing_handoff)}")
    return {
        "task_id": task_id,
        "owned_paths": owned,
        "anchors": anchors,
        "verification_commands": commands,
    }


def _state_root() -> Path:
    override = os.environ.get("ASPERA_GUARD_STATE_DIR")
    return Path(override) if override else Path(tempfile.gettempdir()) / "aspera-worker-guard-v2"


def _state_key(event: dict[str, Any]) -> str:
    material = "\0".join(
        str(event.get(key) or "")
        for key in ("session_id", "turn_id", "transcript_path", "cwd", "model")
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _state_path(event: dict[str, Any]) -> Path:
    return _state_root() / f"{_state_key(event)}.json"


def _cleanup_stale_state(now: float) -> None:
    root = _state_root()
    if not root.is_dir():
        return
    for path in root.glob("*.json"):
        try:
            if now - path.stat().st_mtime > STATE_TTL_SECONDS:
                path.unlink()
        except FileNotFoundError:
            continue


def _write_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_suffix(f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def _read_state(event: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    path = _state_path(event)
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        raise PacketError("worker guard is not armed for this turn") from exc
    return path, state


def _hash_owned(root: Path, owned: list[str]) -> dict[str, str | None]:
    hashes: dict[str, str | None] = {}
    for relative in owned:
        path = root / relative
        hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    return hashes


def _tool_command(event: dict[str, Any]) -> str:
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return ""
    return str(tool_input.get("command") or tool_input.get("cmd") or "").strip()


def _patch_paths(command: str) -> list[str]:
    return [match.group(1).strip() for match in PATCH_PATH_RE.finditer(command)]


def _read_only_shell(command: str) -> bool:
    if not command or SHELL_MUTATION_RE.search(command):
        return False
    segments = re.split(r"\n|&&|\|\||;|\|", command)
    allowed = {"cat", "find", "grep", "head", "ls", "pwd", "rg", "sed", "stat", "tail", "test", "wc"}
    allowed_git = {"diff", "grep", "log", "ls-files", "rev-parse", "show", "status"}
    for segment in segments:
        segment = segment.strip()
        if not segment:
            continue
        try:
            words = shlex.split(segment)
        except ValueError:
            return False
        while words and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0]):
            words.pop(0)
        if not words:
            continue
        executable = Path(words[0]).name
        if executable == "git":
            subcommand = next((word for word in words[1:] if not word.startswith("-")), "")
            if subcommand not in allowed_git:
                return False
        elif executable not in allowed:
            return False
    return True


def _deadline_expired(state: dict[str, Any], now: float) -> bool:
    return state.get("first_edit_at") is None and now - float(state["accepted_at"]) >= FIRST_EDIT_DEADLINE_SECONDS


def _handle_prompt(event: dict[str, Any], now: float) -> dict[str, Any]:
    prompt = str(event.get("prompt") or "")
    root = Path(str(event.get("cwd") or os.getcwd())).resolve()
    try:
        packet = validate_packet(prompt, root)
    except PacketError as exc:
        return _hook_block("PACKET_REJECTED", str(exc))
    _cleanup_stale_state(now)
    state = {
        "accepted_at": now,
        "first_edit_at": None,
        "inspection_count": 0,
        "last_classification": "PACKET_ACCEPTED",
        "owned_hashes": _hash_owned(root, packet["owned_paths"]),
        "owned_paths": packet["owned_paths"],
        "phase": "ORIENTING",
        "repository_root": str(root),
        "task_id": packet["task_id"],
        "verification_commands": packet["verification_commands"],
        "violations": 0,
    }
    _write_state(_state_path(event), state)
    return _additional_context(
        "UserPromptSubmit",
        f"ASPERA_GUARD_ARMED TASK_ID={packet['task_id']} FIRST_EDIT_DEADLINE_SECONDS=90 MAX_INSPECTIONS=4",
    )


def _handle_pre_tool(event: dict[str, Any], now: float) -> dict[str, Any]:
    try:
        path, state = _read_state(event)
    except PacketError as exc:
        return _hook_block("PACKET_REJECTED", str(exc))
    if _deadline_expired(state, now):
        state["last_classification"] = "FIRST_EDIT_DEADLINE"
        _write_state(path, state)
        return _hook_block("FIRST_EDIT_DEADLINE", "no successful owned-file edit within 90 seconds")
    tool_name = str(event.get("tool_name") or "")
    command = _tool_command(event)
    owned = set(state["owned_paths"])
    if tool_name == "apply_patch":
        patch_paths = _patch_paths(command)
        if not patch_paths:
            return _hook_block("OWNERSHIP_VIOLATION", "apply_patch did not expose an exact target path")
        invalid = [item for item in patch_paths if PurePosixPath(item).as_posix() not in owned]
        if invalid:
            state["violations"] += 1
            state["last_classification"] = "OWNERSHIP_VIOLATION"
            _write_state(path, state)
            return _hook_block("OWNERSHIP_VIOLATION", f"patch targets outside OWNED_PATHS: {', '.join(invalid)}")
        return {}
    if tool_name == "Bash":
        if state["phase"] == "IMPLEMENTING" and command in state["verification_commands"]:
            return {}
        if not _read_only_shell(command):
            state["violations"] += 1
            state["last_classification"] = "SHELL_MUTATION_BLOCKED"
            _write_state(path, state)
            return _hook_block("SHELL_MUTATION_BLOCKED", "tracked-file changes must use apply_patch; only exact verification commands may execute after the first edit")
    if int(state["inspection_count"]) >= MAX_INSPECTIONS:
        state["violations"] += 1
        state["last_classification"] = "NO_PROGRESS_BUDGET_EXHAUSTED"
        _write_state(path, state)
        return _hook_block("NO_PROGRESS_BUDGET_EXHAUSTED", "four inspection calls completed without a progress action; return a blocked handoff")
    return {}


def _handle_post_tool(event: dict[str, Any], now: float) -> dict[str, Any]:
    try:
        path, state = _read_state(event)
    except PacketError:
        return {}
    tool_name = str(event.get("tool_name") or "")
    command = _tool_command(event)
    root = Path(state["repository_root"])
    if tool_name == "apply_patch":
        current = _hash_owned(root, state["owned_paths"])
        if current != state["owned_hashes"]:
            state["owned_hashes"] = current
            if state["first_edit_at"] is None:
                state["first_edit_at"] = now
            state["phase"] = "IMPLEMENTING"
            state["inspection_count"] = 0
            state["last_classification"] = "PROGRESS_EDIT"
            _write_state(path, state)
            return _additional_context("PostToolUse", "ASPERA_GUARD PROGRESS_EDIT: owned-file content changed; no-progress budget reset")
    elif tool_name == "Bash" and state["phase"] == "IMPLEMENTING" and command in state["verification_commands"]:
        state["inspection_count"] = 0
        state["last_classification"] = "PROGRESS_VERIFICATION"
        _write_state(path, state)
        return _additional_context("PostToolUse", "ASPERA_GUARD PROGRESS_VERIFICATION: exact verification command completed; no-progress budget reset")
    state["inspection_count"] = int(state["inspection_count"]) + 1
    state["last_classification"] = "INSPECTION"
    _write_state(path, state)
    if state["inspection_count"] == MAX_INSPECTIONS:
        return _additional_context("PostToolUse", "ASPERA_GUARD INSPECTION_LIMIT: the next tool must be an owned apply_patch or an exact verification command; otherwise return blocked")
    return {}


def _handle_pre_compact(event: dict[str, Any]) -> dict[str, Any]:
    try:
        path, state = _read_state(event)
    except PacketError:
        return {}
    if str(event.get("trigger") or "") == "auto" and state.get("first_edit_at") is None:
        state["last_classification"] = "PRE_EDIT_COMPACTION"
        _write_state(path, state)
        return _hook_stop("PRE_EDIT_COMPACTION", "automatic compaction before the first successful edit is forbidden")
    return {}


def _valid_handoff(message: str, task_id: str) -> bool:
    if not all(field in message for field in HANDOFF_FIELDS):
        return False
    return f"TASK_ID: {task_id}" in message and re.search(r"(?m)^STATUS:\s*(?:done|blocked|failed)\s*$", message) is not None


def _handle_stop(event: dict[str, Any]) -> dict[str, Any]:
    try:
        path, state = _read_state(event)
    except PacketError:
        return {}
    message = str(event.get("last_assistant_message") or "")
    if not _valid_handoff(message, state["task_id"]):
        state["last_classification"] = "INVALID_HANDOFF"
        _write_state(path, state)
        return _hook_block("INVALID_HANDOFF", "return the canonical handoff with the packet TASK_ID")
    path.unlink(missing_ok=True)
    return {}


def handle_hook(event: dict[str, Any], now: float | None = None) -> dict[str, Any]:
    current = time.time() if now is None else now
    name = str(event.get("hook_event_name") or "")
    if name == "UserPromptSubmit":
        return _handle_prompt(event, current)
    if name == "PreToolUse":
        return _handle_pre_tool(event, current)
    if name == "PostToolUse":
        return _handle_post_tool(event, current)
    if name == "PreCompact":
        return _handle_pre_compact(event)
    if name == "Stop":
        return _handle_stop(event)
    return {}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validate-packet", action="store_true")
    parser.add_argument("--root", default=os.getcwd())
    args = parser.parse_args()
    if args.validate_packet:
        try:
            packet = validate_packet(sys.stdin.read(), Path(args.root))
        except PacketError as exc:
            print(f"PACKET_REJECTED: {exc}", file=sys.stderr)
            return 1
        print(f"PACKET_ACCEPTED TASK_ID={packet['task_id']}")
        return 0
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, TypeError) as exc:
        _json_output(_hook_stop("GUARD_INPUT_INVALID", str(exc)))
        return 0
    _json_output(handle_hook(event))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
