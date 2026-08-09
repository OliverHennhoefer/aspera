#!/usr/bin/env python3
"""Validate Aspera packet v3 and enforce bounded worker lifecycles."""

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


PACKET_VERSION = "3"
STATE_TTL_SECONDS = 24 * 60 * 60
TARGETS = {
    "luna": {
        "model": "gpt-5.6-luna",
        "max_packet_bytes": 6000,
        "max_owned_paths": 12,
        "max_anchors": 8,
        "max_inspections": 8,
        "evidence_deadline_seconds": 180.0,
    },
    "spark": {
        "model": "gpt-5.3-codex-spark",
        "max_packet_bytes": 2500,
        "max_owned_paths": 4,
        "max_anchors": 2,
        "max_inspections": 2,
        "evidence_deadline_seconds": 90.0,
    },
}
REQUIRED_FIELDS = (
    "PACKET_VERSION",
    "TASK_ID",
    "WORKER_TARGET",
    "OBJECTIVE",
    "OWNED_PATHS",
    "CONTEXT_ANCHORS",
    "CONTRACT",
    "ACCEPTANCE",
    "VERIFICATION",
    "STOP_CONDITIONS",
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
VERIFY_EXIT_RE = re.compile(r"(?m)^\s*EXPECTED_EXIT:\s*(-?\d+)\s*$")
SHELL_MUTATION_RE = re.compile(
    r"(?:^|[^<])>{1,2}|\bsed\b[^\n]*\s-i\b|\b(?:tee|rm|mv|cp|mkdir|touch|chmod|chown|install)\b"
)
SPARK_FORBIDDEN_RE = re.compile(
    r"\b(?:auth(?:entication|orization)?|secret|credential|exposure|concurren(?:cy|t)|race condition|"
    r"persist(?:ence|ent)|database|schema|migration|public api|destructive|external side effect)\b",
    re.IGNORECASE,
)


class PacketError(ValueError):
    pass


def _json_output(payload: dict[str, Any] | list[Any]) -> None:
    print(json.dumps(payload, separators=(",", ":")))


def _hook_stop(classification: str, reason: str) -> dict[str, Any]:
    message = f"ASPERA_GUARD {classification}: {reason}"
    return {"continue": False, "stopReason": classification, "systemMessage": message}


def _hook_block(classification: str, reason: str) -> dict[str, Any]:
    message = f"ASPERA_GUARD {classification}: {reason}"
    return {"decision": "block", "reason": message, "systemMessage": message}


def _additional_context(event_name: str, text: str) -> dict[str, Any]:
    return {"hookSpecificOutput": {"hookEventName": event_name, "additionalContext": text}}


def _parse_fields(prompt: str) -> dict[str, str]:
    matches: list[tuple[str, re.Match[str]]] = []
    cursor = 0
    for key in REQUIRED_FIELDS:
        match = re.compile(rf"(?m)^{re.escape(key)}:(?:[ \t]*(.*))?$").search(prompt, cursor)
        if match is None:
            raise PacketError(f"packet v3 required; missing field: {key}")
        matches.append((key, match))
        cursor = match.end()
    fields: dict[str, str] = {}
    for index, (key, match) in enumerate(matches):
        end = matches[index + 1][1].start() if index + 1 < len(matches) else len(prompt)
        inline = (match.group(1) or "").strip()
        tail = prompt[match.end() : end].strip()
        fields[key] = "\n".join(part for part in (inline, tail) if part).strip()
    missing = [key for key, value in fields.items() if not value]
    if missing:
        raise PacketError(f"missing or empty fields: {', '.join(missing)}")
    return fields


def _list_items(value: str) -> list[str]:
    items: list[str] = []
    for line in value.splitlines():
        item = re.sub(r"^\s*(?:[-*]|\d+[.)])\s*", "", line).strip()
        if item:
            items.append(item)
    return items


def _normalize_path(root: Path, raw: str) -> tuple[str, Path]:
    if GLOB_RE.search(raw):
        raise PacketError(f"path contains a glob: {raw}")
    pure = PurePosixPath(raw)
    if pure.is_absolute() or ".." in pure.parts or not pure.parts:
        raise PacketError(f"unsafe repository path: {raw}")
    normalized = pure.as_posix()
    candidate = (root / normalized).resolve(strict=False)
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise PacketError(f"path escapes the repository: {raw}") from exc
    if candidate.exists() and not candidate.is_file():
        raise PacketError(f"path must identify a file: {raw}")
    return normalized, candidate


def _validate_owned_paths(root: Path, value: str, limit: int) -> list[str]:
    owned: list[str] = []
    resolved: list[Path] = []
    for raw in _list_items(value):
        normalized, candidate = _normalize_path(root, raw)
        if normalized in owned:
            raise PacketError(f"duplicate OWNED_PATHS entry: {normalized}")
        for prior in resolved:
            if candidate in prior.parents or prior in candidate.parents:
                raise PacketError(f"overlapping OWNED_PATHS entry: {normalized}")
        owned.append(normalized)
        resolved.append(candidate)
    if not owned:
        raise PacketError("OWNED_PATHS has no exact file entries")
    if len(owned) > limit:
        raise PacketError(f"WORKER_TARGET permits at most {limit} OWNED_PATHS entries")
    return owned


def _validate_anchors(root: Path, value: str, owned: list[str], limit: int) -> list[str]:
    anchors = _list_items(value)
    if len(anchors) == 1 and anchors[0].upper() == "NONE":
        if any((root / path).exists() for path in owned):
            raise PacketError("CONTEXT_ANCHORS may be NONE only when every owned path is new")
        return []
    if not anchors:
        raise PacketError("CONTEXT_ANCHORS has no anchors")
    if len(anchors) > limit:
        raise PacketError(f"WORKER_TARGET permits at most {limit} CONTEXT_ANCHORS entries")
    for anchor in anchors:
        if "::" not in anchor:
            raise PacketError(f"anchor must use path::symbol: {anchor}")
        path_text, symbol = (part.strip() for part in anchor.split("::", 1))
        normalized, path = _normalize_path(root, path_text)
        if not path.is_file():
            raise PacketError(f"anchor path does not exist: {normalized}")
        if not symbol:
            raise PacketError(f"anchor symbol is empty: {anchor}")
        text = path.read_text(encoding="utf-8", errors="ignore")
        if symbol not in text:
            raise PacketError(f"anchor symbol is stale: {anchor}")
    return anchors


def _validate_verification(value: str) -> list[dict[str, Any]]:
    commands = [match.group(1).strip() for match in VERIFY_COMMAND_RE.finditer(value)]
    exits = [int(match.group(1)) for match in VERIFY_EXIT_RE.finditer(value)]
    if not commands or len(commands) != len(exits):
        raise PacketError("VERIFICATION requires paired '- COMMAND:' and 'EXPECTED_EXIT:' entries")
    if len(set(commands)) != len(commands):
        raise PacketError("VERIFICATION contains a duplicate command")
    for command in commands:
        if PLACEHOLDER_RE.search(command) or SHELL_MUTATION_RE.search(command):
            raise PacketError("VERIFICATION contains unresolved or mutating syntax")
    return [{"command": command, "expected_exit": expected} for command, expected in zip(commands, exits)]


def validate_packet(prompt: str, root: Path) -> dict[str, Any]:
    root = root.resolve()
    fields = _parse_fields(prompt)
    if fields["PACKET_VERSION"].strip() != PACKET_VERSION:
        raise PacketError("packet v3 required; reinstall Aspera and start a new session")
    target = fields["WORKER_TARGET"].strip().lower()
    if target not in TARGETS:
        raise PacketError("WORKER_TARGET must be luna or spark")
    limits = TARGETS[target]
    packet_bytes = len(prompt.encode("utf-8"))
    if packet_bytes > limits["max_packet_bytes"]:
        raise PacketError(f"{target} packet exceeds {limits['max_packet_bytes']} bytes")
    task_id = fields["TASK_ID"].strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", task_id):
        raise PacketError("TASK_ID must be a stable identifier without whitespace")
    for key, value in fields.items():
        if PLACEHOLDER_RE.search(value):
            raise PacketError(f"{key} contains an unresolved placeholder")
    if target == "spark":
        risk_text = "\n".join(fields[key] for key in ("OBJECTIVE", "CONTRACT", "ACCEPTANCE"))
        match = SPARK_FORBIDDEN_RE.search(risk_text)
        if match:
            raise PacketError(f"Spark packet contains excluded risk scope: {match.group(0)}")
    owned = _validate_owned_paths(root, fields["OWNED_PATHS"], int(limits["max_owned_paths"]))
    anchors = _validate_anchors(root, fields["CONTEXT_ANCHORS"], owned, int(limits["max_anchors"]))
    verification = _validate_verification(fields["VERIFICATION"])
    return {
        "task_id": task_id,
        "target": target,
        "owned_paths": owned,
        "anchors": anchors,
        "verification": verification,
        "packet_bytes": packet_bytes,
    }


def _state_root() -> Path:
    override = os.environ.get("ASPERA_GUARD_STATE_DIR")
    return Path(override) if override else Path(tempfile.gettempdir()) / "aspera-worker-guard-v3"


def _receipt_root() -> Path:
    return _state_root() / "receipts"


def _state_key(event: dict[str, Any]) -> str:
    material = "\0".join(
        str(event.get(key) or "")
        for key in ("session_id", "turn_id", "transcript_path", "cwd", "model")
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _state_path(event: dict[str, Any]) -> Path:
    return _state_root() / f"{_state_key(event)}.json"


def _cleanup_stale(now: float) -> None:
    for root in (_state_root(), _receipt_root()):
        if not root.is_dir():
            continue
        for path in root.glob("*.json"):
            try:
                if now - path.stat().st_mtime > STATE_TTL_SECONDS:
                    path.unlink()
            except FileNotFoundError:
                pass


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_suffix(f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def _read_state(event: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    path = _state_path(event)
    try:
        return path, json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        raise PacketError("worker guard is not armed for this turn") from exc


def _hash_owned(root: Path, owned: list[str]) -> dict[str, str | None]:
    return {
        relative: hashlib.sha256((root / relative).read_bytes()).hexdigest()
        if (root / relative).is_file()
        else None
        for relative in owned
    }


def _changed_paths(state: dict[str, Any]) -> list[str]:
    current = _hash_owned(Path(state["repository_root"]), state["owned_paths"])
    return sorted(path for path, digest in current.items() if digest != state["baseline_hashes"].get(path))


def _tool_command(event: dict[str, Any]) -> str:
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return ""
    return str(tool_input.get("command") or tool_input.get("cmd") or tool_input.get("patch") or "").strip()


def _patch_paths(command: str) -> list[str]:
    return [match.group(1).strip() for match in PATCH_PATH_RE.finditer(command)]


def _is_shell_tool(name: str) -> bool:
    return name in {"Bash", "exec_command"}


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


def _response_exit_code(response: Any) -> int | None:
    if isinstance(response, dict):
        value = response.get("exit_code")
        if isinstance(value, int):
            return value
        for nested in response.values():
            result = _response_exit_code(nested)
            if result is not None:
                return result
    if isinstance(response, list):
        for nested in response:
            result = _response_exit_code(nested)
            if result is not None:
                return result
    return None


def _deadline_reason(state: dict[str, Any], now: float) -> str | None:
    if state.get("decisive_at") is None and now >= float(state["evidence_deadline_at"]):
        return "no edit, decisive verification, or blocked handoff before the evidence deadline"
    edit_deadline = state.get("edit_deadline_at")
    if edit_deadline is not None and state.get("first_edit_at") is None and now >= float(edit_deadline):
        return "pre-edit verification completed but no edit followed within the additional edit window"
    return None


def _handle_prompt(event: dict[str, Any], now: float) -> dict[str, Any]:
    prompt = str(event.get("prompt") or "")
    root = Path(str(event.get("cwd") or os.getcwd())).resolve()
    try:
        packet = validate_packet(prompt, root)
    except PacketError as exc:
        return _hook_block("PACKET_REJECTED", str(exc))
    expected_model = TARGETS[packet["target"]]["model"]
    actual_model = str(event.get("model") or "")
    if actual_model and actual_model != expected_model:
        return _hook_block(
            "WORKER_MODEL_MISMATCH",
            f"WORKER_TARGET {packet['target']} requires {expected_model}, got {actual_model}",
        )
    limits = TARGETS[packet["target"]]
    _cleanup_stale(now)
    verification = {
        item["command"]: {"expected_exit": item["expected_exit"], "observed_exit": None, "runs": 0}
        for item in packet["verification"]
    }
    baseline = _hash_owned(root, packet["owned_paths"])
    state = {
        "accepted_at": now,
        "baseline_hashes": baseline,
        "current_hashes": baseline,
        "decisive_at": None,
        "edit_deadline_at": None,
        "evidence_deadline_at": now + float(limits["evidence_deadline_seconds"]),
        "first_edit_at": None,
        "inspection_count": 0,
        "inspection_total": 0,
        "last_classification": "PACKET_ACCEPTED",
        "max_inspections": int(limits["max_inspections"]),
        "owned_paths": packet["owned_paths"],
        "packet_bytes": packet["packet_bytes"],
        "repository_root": str(root),
        "task_id": packet["task_id"],
        "target": packet["target"],
        "verification": verification,
        "violations": 0,
    }
    _write_json(_state_path(event), state)
    return _additional_context(
        "UserPromptSubmit",
        f"ASPERA_GUARD_ARMED TARGET={packet['target']} DEADLINE_SECONDS={int(limits['evidence_deadline_seconds'])} MAX_INSPECTIONS={limits['max_inspections']}",
    )


def _handle_pre_tool(event: dict[str, Any], now: float) -> dict[str, Any]:
    try:
        path, state = _read_state(event)
    except PacketError as exc:
        return _hook_block("PACKET_REJECTED", str(exc))
    reason = _deadline_reason(state, now)
    if reason:
        state["last_classification"] = "PROGRESS_DEADLINE"
        _write_json(path, state)
        return _hook_block("PROGRESS_DEADLINE", reason)
    tool_name = str(event.get("tool_name") or "")
    command = _tool_command(event)
    if tool_name == "apply_patch":
        patch_paths = _patch_paths(command)
        if not patch_paths:
            return _hook_block("OWNERSHIP_VIOLATION", "apply_patch did not expose an exact target path")
        invalid = [item for item in patch_paths if PurePosixPath(item).as_posix() not in set(state["owned_paths"])]
        if invalid:
            state["violations"] += 1
            state["last_classification"] = "OWNERSHIP_VIOLATION"
            _write_json(path, state)
            return _hook_block("OWNERSHIP_VIOLATION", f"patch targets outside OWNED_PATHS: {', '.join(invalid)}")
        return {}
    if _is_shell_tool(tool_name):
        if command in state["verification"]:
            return {}
        if _read_only_shell(command):
            if int(state["inspection_count"]) >= int(state["max_inspections"]):
                state["violations"] += 1
                state["last_classification"] = "NO_PROGRESS_BUDGET_EXHAUSTED"
                _write_json(path, state)
                return _hook_block("NO_PROGRESS_BUDGET_EXHAUSTED", "return a blocked handoff or make decisive progress")
            return {}
        state["violations"] += 1
        state["last_classification"] = "SHELL_MUTATION_BLOCKED"
        _write_json(path, state)
        return _hook_block("SHELL_MUTATION_BLOCKED", "only read-only inspection or exact verification commands are allowed")
    if int(state["inspection_count"]) >= int(state["max_inspections"]):
        state["violations"] += 1
        state["last_classification"] = "NO_PROGRESS_BUDGET_EXHAUSTED"
        _write_json(path, state)
        return _hook_block("NO_PROGRESS_BUDGET_EXHAUSTED", "return a blocked handoff or make decisive progress")
    return {}


def _handle_post_tool(event: dict[str, Any], now: float) -> dict[str, Any]:
    try:
        path, state = _read_state(event)
    except PacketError:
        return {}
    tool_name = str(event.get("tool_name") or "")
    command = _tool_command(event)
    if tool_name == "apply_patch":
        current = _hash_owned(Path(state["repository_root"]), state["owned_paths"])
        if current != state["current_hashes"]:
            state["current_hashes"] = current
            state["first_edit_at"] = state["first_edit_at"] or now
            state["decisive_at"] = state["decisive_at"] or now
            state["edit_deadline_at"] = None
            state["inspection_count"] = 0
            state["last_classification"] = "PROGRESS_EDIT"
            _write_json(path, state)
            return _additional_context("PostToolUse", "ASPERA_GUARD PROGRESS_EDIT")
    elif _is_shell_tool(tool_name) and command in state["verification"]:
        observed = _response_exit_code(event.get("tool_response"))
        record = state["verification"][command]
        record["runs"] = int(record["runs"]) + 1
        record["observed_exit"] = observed
        state["decisive_at"] = state["decisive_at"] or now
        if state["first_edit_at"] is None:
            window = float(TARGETS[state["target"]]["evidence_deadline_seconds"])
            state["edit_deadline_at"] = now + window
        state["inspection_count"] = 0
        passed = observed == int(record["expected_exit"])
        state["last_classification"] = "VERIFICATION_PASSED" if passed else "VERIFICATION_FAILED"
        _write_json(path, state)
        return _additional_context(
            "PostToolUse",
            f"ASPERA_GUARD {state['last_classification']} EXPECTED={record['expected_exit']} OBSERVED={observed}",
        )
    state["inspection_count"] = int(state["inspection_count"]) + 1
    state["inspection_total"] = int(state["inspection_total"]) + 1
    state["last_classification"] = "INSPECTION"
    _write_json(path, state)
    if state["inspection_count"] == state["max_inspections"]:
        return _additional_context("PostToolUse", "ASPERA_GUARD INSPECTION_LIMIT: next action must be decisive or return blocked")
    return {}


def _handle_pre_compact(event: dict[str, Any]) -> dict[str, Any]:
    try:
        path, state = _read_state(event)
    except PacketError:
        return {}
    if str(event.get("trigger") or "") == "auto" and state.get("decisive_at") is None:
        state["last_classification"] = "PRE_EVIDENCE_COMPACTION"
        _write_json(path, state)
        return _hook_stop("PRE_EVIDENCE_COMPACTION", "automatic compaction before decisive evidence is forbidden")
    return {}


def _handoff_value(message: str, field: str) -> str:
    headings = "|".join(re.escape(item) for item in HANDOFF_FIELDS)
    match = re.search(rf"(?ms)^{re.escape(field)}\s*(.*?)(?=^(?:{headings})|\Z)", message)
    return match.group(1).strip() if match else ""


def _valid_handoff_shape(message: str, task_id: str) -> tuple[bool, str]:
    if not all(field in message for field in HANDOFF_FIELDS):
        return False, "canonical handoff fields are missing"
    status = _handoff_value(message, "STATUS:")
    if status not in {"done", "blocked", "failed"}:
        return False, "STATUS must be done, blocked, or failed"
    if _handoff_value(message, "TASK_ID:") != task_id:
        return False, "TASK_ID does not match the packet"
    return True, status


def _handoff_changed_files(message: str) -> list[str]:
    value = _handoff_value(message, "CHANGED FILES:")
    if value.lower() in {"none", "none."}:
        return []
    return sorted(_list_items(value))


def _write_receipt(state: dict[str, Any], status: str, now: float) -> None:
    verification_exits = [
        {"expected": record["expected_exit"], "observed": record["observed_exit"]}
        for record in state["verification"].values()
    ]
    payload = {
        "accepted_at": state["accepted_at"],
        "changed_path_count": len(_changed_paths(state)),
        "completed_at": now,
        "decisive_seconds": None if state["decisive_at"] is None else state["decisive_at"] - state["accepted_at"],
        "final_classification": state["last_classification"],
        "first_edit_seconds": None if state["first_edit_at"] is None else state["first_edit_at"] - state["accepted_at"],
        "inspection_count": state["inspection_total"],
        "packet_bytes": state["packet_bytes"],
        "status": status,
        "target": state["target"],
        "verification_exits": verification_exits,
        "violations": state["violations"],
    }
    key = hashlib.sha256(f"{state['accepted_at']}:{state['task_id']}".encode()).hexdigest()
    _write_json(_receipt_root() / f"{key}.json", payload)


def _handle_stop(event: dict[str, Any], now: float) -> dict[str, Any]:
    try:
        path, state = _read_state(event)
    except PacketError:
        return {}
    message = str(event.get("last_assistant_message") or "")
    valid, status_or_reason = _valid_handoff_shape(message, state["task_id"])
    if not valid:
        state["last_classification"] = "INVALID_HANDOFF"
        _write_json(path, state)
        return _hook_block("INVALID_HANDOFF", status_or_reason)
    status = status_or_reason
    actual_changed = _changed_paths(state)
    reported_changed = _handoff_changed_files(message)
    if reported_changed != actual_changed:
        state["last_classification"] = "UNTRUTHFUL_CHANGED_FILES"
        _write_json(path, state)
        return _hook_block(
            "UNTRUTHFUL_CHANGED_FILES",
            f"reported {reported_changed or ['None']}, observed {actual_changed or ['None']}",
        )
    if status == "done":
        incomplete = [
            command
            for command, record in state["verification"].items()
            if record["observed_exit"] != record["expected_exit"]
        ]
        if incomplete:
            state["last_classification"] = "VERIFICATION_INCOMPLETE"
            _write_json(path, state)
            return _hook_block("VERIFICATION_INCOMPLETE", "done requires every verification command to pass")
    state["last_classification"] = f"HANDOFF_{status.upper()}"
    _write_receipt(state, status, now)
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
        return _handle_stop(event, current)
    return {}


def _list_receipts() -> list[dict[str, Any]]:
    receipts: list[dict[str, Any]] = []
    if _receipt_root().is_dir():
        for path in sorted(_receipt_root().glob("*.json")):
            try:
                receipts.append(json.loads(path.read_text(encoding="utf-8")))
            except json.JSONDecodeError:
                continue
    return receipts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--validate-packet", action="store_true")
    parser.add_argument("--list-receipts", action="store_true")
    parser.add_argument("--root", default=os.getcwd())
    args = parser.parse_args()
    if args.validate_packet:
        try:
            packet = validate_packet(sys.stdin.read(), Path(args.root))
        except PacketError as exc:
            print(f"PACKET_REJECTED: {exc}", file=sys.stderr)
            return 1
        print(f"PACKET_ACCEPTED TASK_ID={packet['task_id']} TARGET={packet['target']}")
        return 0
    if args.list_receipts:
        _json_output(_list_receipts())
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
