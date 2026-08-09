from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from shutil import which
from typing import Any, Dict, List, Optional

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore


FORBIDDEN_STRINGS = [
    ".codex/config.toml",
]


@dataclass
class ValidationResult:
    path: str
    status: str
    message: str


def fail(results: List[ValidationResult], path: str, message: str) -> None:
    results.append(ValidationResult(path, "fail", message))


def ok(results: List[ValidationResult], path: str, message: str) -> None:
    results.append(ValidationResult(path, "ok", message))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=os.getcwd())
    parser.add_argument("--plugin-root", default=None)
    return parser.parse_args()


def _load_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def _extract_section(lines: List[str], heading: str) -> str:
    target = heading.lower()
    start = None
    end = len(lines)
    for idx, raw_line in enumerate(lines):
        line = raw_line.strip()
        if not line.startswith("## "):
            continue
        if line[3:].strip().lower() == target:
            start = idx + 1
            break

    if start is None:
        return ""

    for idx in range(start, len(lines)):
        if lines[idx].startswith("## "):
            end = idx
            break
    return "\n".join(lines[start:end]).lower()


def _read_json(path: Path) -> Any:
    with path.open("rb") as handle:
        return json.load(handle)


def _check_json(path: Path, results: List[ValidationResult]) -> None:
    try:
        _read_json(path)
        ok(results, str(path), "valid JSON")
    except json.JSONDecodeError as exc:
        fail(results, str(path), f"invalid JSON: {exc}")
    except OSError as exc:
        fail(results, str(path), f"failed to read JSON: {exc}")


def _check_toml(path: Path, results: List[ValidationResult]) -> None:
    try:
        with path.open("rb") as handle:
            tomllib.load(handle)
        ok(results, str(path), "valid TOML")
    except (tomllib.TOMLDecodeError, ValueError) as exc:
        fail(results, str(path), f"invalid TOML: {exc}")
    except OSError as exc:
        fail(results, str(path), f"failed to read TOML file: {exc}")


def _check_shell_file(path: Path, results: List[ValidationResult]) -> None:
    code = subprocess.call(
        ["bash", "-n", str(path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if code == 0:
        ok(results, str(path), "shell syntax valid")
    else:
        fail(results, str(path), "shell syntax invalid")


def _check_shellcheck(path: Path, results: List[ValidationResult]) -> None:
    binary = which("shellcheck")
    if binary is None:
        ok(results, str(path), "shellcheck not installed (skipped)")
        return
    code = subprocess.call([binary, "-s", "bash", str(path)])
    if code == 0:
        ok(results, str(path), "shellcheck passed")
    else:
        fail(results, str(path), "shellcheck failed")


def _parse_yaml_nested(text: str) -> Dict[str, Any]:
    stack: List[tuple[int, Dict[str, Any]]] = []
    root: Dict[str, Any] = {}
    current = root
    for raw_line in text.splitlines():
        line = raw_line.rstrip("\n")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "---":
            continue
        if stripped.startswith("policy:") or stripped.startswith("openai:") or stripped.startswith("interface:"):
            pass
        match = re.match(r"^(\s*)([^:#][^:]*?)\s*:\s*(.*)\s*$", line)
        if not match:
            continue
        indent = len(match.group(1))
        key = match.group(2).strip()
        value = match.group(3).strip()

        while stack and indent <= stack[-1][0]:
            stack.pop()
        if stack:
            current = stack[-1][1]
        else:
            current = root

        if not value:
            container: Dict[str, Any] = {}
            current[key] = container
            stack.append((indent, container))
            continue

        if value.lower() in {"true", "false"}:
            current[key] = value.lower() == "true"
        elif (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            current[key] = value[1:-1]
        else:
            current[key] = value

    return root


def _check_skill_frontmatter(path: Path, results: List[ValidationResult]) -> None:
    content = _load_text(path)
    lines = content.splitlines()
    start = 0
    while start < len(lines) and not lines[start].strip():
        start += 1
    if start >= len(lines) or lines[start].strip() != "---":
        fail(results, str(path), "SKILL.md missing opening --- frontmatter")
        return

    marker = start + 1
    while marker < len(lines) and lines[marker].strip() != "---":
        marker += 1
    if marker >= len(lines):
        fail(results, str(path), "SKILL.md missing closing --- frontmatter")
        return

    raw = lines[start + 1 : marker]
    frontmatter: Dict[str, Any] = {}
    i = 0
    while i < len(raw):
        line = raw[i].rstrip()
        if not line or line.lstrip().startswith("#"):
            i += 1
            continue
        match = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not match:
            i += 1
            continue

        key = match.group(1).strip()
        value = match.group(2).rstrip()
        if not value:
            frontmatter[key] = ""
            i += 1
            continue

        if value in {"|", "|-","|+"}:
            block_lines = []
            i += 1
            while i < len(raw):
                candidate = raw[i]
                if not candidate:
                    block_lines.append("")
                    i += 1
                    continue
                if re.match(r"^\s", candidate):
                    block_lines.append(candidate.lstrip())
                    i += 1
                    continue
                break
            frontmatter[key] = "\n".join(block_lines).strip()
            continue
        if value.startswith('"') and value.endswith('"'):
            frontmatter[key] = value[1:-1]
        elif value.startswith("'") and value.endswith("'"):
            frontmatter[key] = value[1:-1]
        else:
            frontmatter[key] = value
        i += 1

    if not frontmatter.get("name"):
        fail(results, str(path), "SKILL.md frontmatter missing name")
        return
    if not frontmatter.get("description"):
        fail(results, str(path), "SKILL.md frontmatter missing description")
        return
    if not isinstance(frontmatter["name"], str) or not frontmatter["name"].strip():
        fail(results, str(path), "SKILL.md frontmatter name must be non-empty string")
        return
    if not isinstance(frontmatter["description"], str) or not frontmatter["description"].strip():
        fail(results, str(path), "SKILL.md frontmatter description must be non-empty")
        return
    ok(results, str(path), "SKILL.md has valid name/description frontmatter")


def _check_orchestrate_activation_rules(repo_root: Path, plugin_dir: Path, results: List[ValidationResult]) -> None:
    root_policy = repo_root / "AGENTS.md"
    managed_policy = plugin_dir / "skills" / "orchestrate" / "references" / "policy.md"
    protocol = plugin_dir / "skills" / "orchestrate" / "references" / "protocol.md"
    for path in (root_policy, managed_policy, protocol):
        if not path.is_file():
            fail(results, str(path), "missing routing contract")
            return

    root_text = _load_text(root_policy).lower()
    managed_text = _load_text(managed_policy).lower()
    protocol_text = _load_text(protocol).lower()
    if "always implement aspera itself parent-direct" not in root_text:
        fail(results, str(root_policy), "Aspera development is not explicitly parent-direct")
    else:
        ok(results, str(root_policy), "Aspera development bypasses its downstream orchestrator")

    installation_contract = (
        "./aspera install --workspace",
        "preserve the installed profile and policy",
        "classify every known current and legacy destination",
        "commit the receipt last",
        "supported codex plugin commands",
        "never run doctor automatically",
        "never edit codex cache or configuration files directly",
    )
    missing = [term for term in installation_contract if term not in root_text]
    if missing:
        fail(results, str(root_policy), f"stable installation contract missing: {', '.join(missing)}")
    else:
        ok(results, str(root_policy), "one-command installation invariants are explicit")

    required_policy = (
        "luna max is the default worker",
        "spark is optional",
        "explicit direct/no-delegation",
        ".codex/aspera-orchestrator/protocol.md",
        "no recursive delegation",
        "development of aspera itself",
    )
    missing = [term for term in required_policy if term not in managed_text]
    if missing:
        fail(results, str(managed_policy), f"managed router missing: {', '.join(missing)}")
    elif len(managed_policy.read_bytes()) > 2048:
        fail(results, str(managed_policy), "always-loaded managed router exceeds 2 KB")
    else:
        ok(results, str(managed_policy), "portable Luna-first router fits the 2 KB quota budget")

    forbidden_modes = ("direct:", "express:", "standard:")
    present = [term for term in forbidden_modes if term in managed_text or term in protocol_text]
    if present:
        fail(results, str(managed_policy), f"public mode taxonomy remains: {', '.join(present)}")
    else:
        ok(results, str(managed_policy), "public mode taxonomy removed")

    required_protocol = (
        "packet_version: 3",
        "worker_target: luna | spark",
        "unchanged luna-ready capsule",
        "do not retry spark",
        "never use spark",
        "expected_exit",
    )
    missing = [term for term in required_protocol if term not in protocol_text]
    if missing:
        fail(results, str(protocol), f"lazy protocol missing: {', '.join(missing)}")
    else:
        ok(results, str(protocol), "lazy packet-v3 and Spark boundary contract is complete")


def _check_worker_runtime_contract(repo_root: Path, plugin_dir: Path, results: List[ValidationResult]) -> None:
    assets = plugin_dir / "skills" / "setup" / "assets"
    workers = (
        assets / "profiles" / "shared" / "luna-worker.toml",
        assets / "profiles" / "adaptive" / "spark-worker.toml",
    )
    required_hooks = {"UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact", "Stop"}
    for path in workers:
        text = _load_text(path).lower()
        required = ("packet_version 3", "apply_patch", "verification", "blocked", "no recursive delegation")
        missing = [term for term in required if term not in text]
        if missing:
            fail(results, str(path), f"worker action contract missing: {', '.join(missing)}")
            continue
        data = _load_toml(path)
        hooks = data.get("hooks", {})
        if set(hooks) != required_hooks:
            fail(results, str(path), "worker hook set is incomplete or unexpected")
        elif any(
            entry.get("hooks", [{}])[0].get("command") != "python3 .codex/aspera-orchestrator/worker_guard.py"
            for event in required_hooks
            for entry in hooks[event]
        ):
            fail(results, str(path), "worker hooks do not use the managed guard")
        else:
            ok(results, str(path), "packet-v3 worker and managed hooks are complete")

    guard_path = assets / "worker_guard.py"
    guard_text = _load_text(guard_path)
    try:
        compile(guard_text, str(guard_path), "exec")
    except SyntaxError as exc:
        fail(results, str(guard_path), f"worker guard syntax invalid: {exc}")
    else:
        guard_terms = (
            'PACKET_VERSION = "3"',
            '"max_owned_paths": 12',
            '"max_owned_paths": 4',
            '"max_anchors": 8',
            '"max_anchors": 2',
            '"evidence_deadline_seconds": 180.0',
            '"evidence_deadline_seconds": 90.0',
            "WORKER_MODEL_MISMATCH",
            "NO_PROGRESS_BUDGET_EXHAUSTED",
            "PRE_EVIDENCE_COMPACTION",
            "OWNERSHIP_VIOLATION",
            "UNTRUTHFUL_CHANGED_FILES",
            "VERIFICATION_INCOMPLETE",
            "receipts",
        )
        missing_guard = [term for term in guard_terms if term not in guard_text]
        if missing_guard:
            fail(results, str(guard_path), f"worker guard contract missing: {', '.join(missing_guard)}")
        else:
            ok(results, str(guard_path), "Luna/Spark packet-v3 state machine is complete")

    doctor_path = plugin_dir / "skills" / "setup" / "scripts" / "doctor.sh"
    common_path = plugin_dir / "skills" / "setup" / "scripts" / "common.sh"
    install_path = plugin_dir / "skills" / "setup" / "scripts" / "install.sh"
    lifecycle_text = (_load_text(doctor_path) + _load_text(common_path) + _load_text(install_path)).lower()
    forbidden_runtime = (
        "--runtime-smoke",
        "asp_run_smoke",
        "aspera_guard_armed",
        "codex exec",
        "debug models",
    )
    present = [term for term in forbidden_runtime if term in lifecycle_text]
    if present:
        fail(results, str(common_path), f"task-time runtime ceremony remains: {', '.join(present)}")
    else:
        ok(results, str(common_path), "install and diagnosis contain no runtime smoke or model probe")

    install_terms = (
        "schema_version': 4",
        "adaptive",
        "aspera-luna-worker.toml",
        "aspera-spark-worker.toml",
        "protocol.md",
        "asp_state_validate_supported",
        "snapshot-before",
        "snapshot-after",
        "rollback_install",
        "asp_verify_installation",
    )
    missing = [term for term in install_terms if term not in lifecycle_text]
    if missing:
        fail(results, str(install_path), f"reconcile transaction contract missing: {', '.join(missing)}")
    else:
        ok(results, str(install_path), "schema migration and transactional reconcile contract is complete")

    root_cli = repo_root / "aspera"
    if not root_cli.is_file():
        fail(results, str(root_cli), "missing root lifecycle command")
    else:
        cli_text = _load_text(root_cli).lower()
        cli_terms = (
            "install)",
            "diagnose)",
            "uninstall)",
            "--install-policy|--no-policy",
            "plugin marketplace list --json",
            "plugin list --json",
            "plugin remove",
            "plugin add",
            "inspect_plugin_list",
        )
        missing = [term for term in cli_terms if term not in cli_text]
        if missing:
            fail(results, str(root_cli), f"root lifecycle command missing: {', '.join(missing)}")
        else:
            ok(results, str(root_cli), "root command owns plugin refresh and project lifecycle")
        _check_shell_file(root_cli, results)
        _check_shellcheck(root_cli, results)

    eval_path = repo_root / "tests" / "evals" / "manual-eval-spec.json"
    eval_data = _read_json(eval_path)
    metrics = eval_data.get("recorded_metrics", {}).get("luna_route", {})
    telemetry = {
        "packet_bytes",
        "decisive_seconds",
        "first_edit_seconds",
        "inspection_count",
        "changed_path_count",
        "verification_exits",
        "guard_classification",
    }
    missing_metrics = sorted(telemetry.difference(metrics))
    if missing_metrics:
        fail(results, str(eval_path), f"worker telemetry missing: {', '.join(missing_metrics)}")
    else:
        ok(results, str(eval_path), "worker lifecycle telemetry is complete")


def _check_skill_openai_yaml(path: Path, results: List[ValidationResult]) -> None:
    data = _parse_yaml_nested(_load_text(path))
    interface = data.get("interface")
    if not isinstance(interface, dict):
        fail(results, str(path), "openai.yaml missing interface block")
        return

    for key in ("display_name", "short_description", "default_prompt"):
        if key not in interface:
            fail(results, str(path), f"openai.yaml missing interface.{key}")
            return
        if not isinstance(interface[key], str) or not interface[key].strip():
            fail(results, str(path), f"openai.yaml interface.{key} must be non-empty string")
            return

    if len(interface["short_description"]) < 25:
        fail(results, str(path), "openai.yaml short_description below minimum length")
        return

    for key in ("display_name", "short_description", "default_prompt"):
        if not re.search(
            rf"(?m)^\s*{re.escape(key)}\s*:\s+['\"].*['\"]\s*$",
            _load_text(path),
        ):
            fail(results, str(path), f"openai.yaml requires quoted string for interface.{key}")
            return

    policy = data.get("policy")
    if not isinstance(policy, dict) or "allow_implicit_invocation" not in policy:
        fail(results, str(path), "openai.yaml missing policy.allow_implicit_invocation")
        return
    if not isinstance(policy.get("allow_implicit_invocation"), bool):
        fail(results, str(path), "openai.yaml policy.allow_implicit_invocation must be boolean")
        return

    role = path.parent.parent.name
    if role == "orchestrate" and policy.get("allow_implicit_invocation") is not False:
        fail(results, str(path), "orchestrate must set allow_implicit_invocation: false")
        return

    ok(results, str(path), "openai.yaml has valid policy/interface contract")


def _check_policy_source(repo_root: Path, results: List[ValidationResult]) -> None:
    policy_path = repo_root / "plugins" / "aspera-orchestrator" / "skills" / "orchestrate" / "references" / "policy.md"
    if not policy_path.is_file():
        fail(results, str(policy_path), "missing orchestrator policy.md")
        return
    try:
        if not policy_path.read_text(encoding="utf-8").strip():
            fail(results, str(policy_path), "policy.md is empty")
        else:
            ok(results, str(policy_path), "orchestrator policy.md exists")
    except OSError as exc:
        fail(results, str(policy_path), f"unable to read policy.md: {exc}")


def _check_manual_eval_activation_records(repo_root: Path, results: List[ValidationResult]) -> None:
    eval_path = repo_root / "tests" / "evals" / "manual-eval-spec.json"
    data = None
    try:
        data = _read_json(eval_path)
    except (json.JSONDecodeError, OSError) as exc:
        fail(results, str(eval_path), f"invalid manual eval spec JSON: {exc}")
        return

    fixture_counts = data.get("fixture_counts", {})
    records = data.get("activation_records")
    if not isinstance(records, list):
        fail(results, str(eval_path), "manual eval spec missing activation_records list")
        return

    positive_expected = fixture_counts.get("positive_activation_records")
    negative_expected = fixture_counts.get("negative_activation_records")
    if not isinstance(positive_expected, int) or not isinstance(negative_expected, int):
        fail(results, str(eval_path), "manual eval spec missing activation record counts")
        return

    positive_records = [record for record in records if isinstance(record, dict) and record.get("category") == "positive"]
    negative_records = [record for record in records if isinstance(record, dict) and record.get("category") == "negative"]
    if len(positive_records) != positive_expected:
        fail(
            results,
            str(eval_path),
            f"positive activation record count mismatch: expected {positive_expected}, got {len(positive_records)}",
        )
    else:
        ok(results, str(eval_path), "positive activation record count matches fixture")
    if len(negative_records) != negative_expected:
        fail(
            results,
            str(eval_path),
            f"negative activation record count mismatch: expected {negative_expected}, got {len(negative_records)}",
        )
    else:
        ok(results, str(eval_path), "negative activation record count matches fixture")

    required_common_keys = ["id", "category", "route", "delegation", "task_type", "expected_activation", "scenario"]
    required_positive_keys = required_common_keys
    required_negative_keys = required_common_keys
    for record in records:
        if not isinstance(record, dict):
            fail(results, str(eval_path), "manual eval activation record must be an object")
            continue
        category = record.get("category")
        if category not in {"positive", "negative"}:
            fail(results, str(eval_path), f"manual eval activation record {record.get('id')} has invalid category {category!r}")
            continue
        for required in (required_positive_keys if category == "positive" else required_negative_keys):
            if required not in record:
                fail(results, str(eval_path), f"manual eval activation record {record.get('id')} missing {required}")
        route = record.get("route")
        if category == "positive":
            if route not in {"sol", "luna", "spark", "luna_with_post_review", "sol_with_pre_review_then_luna"}:
                fail(results, str(eval_path), f"manual eval record {record.get('id')} has invalid route {route!r}")
            delegation = record.get("delegation")
            if not isinstance(delegation, list):
                fail(results, str(eval_path), f"manual eval record {record.get('id')} delegation must be a list")
            elif route == "sol" and delegation:
                fail(results, str(eval_path), f"manual eval record {record.get('id')} Sol route must have zero delegation")
            elif route != "sol" and not delegation:
                fail(results, str(eval_path), f"manual eval record {record.get('id')} delegated route requires a role")
            if record.get("expected_activation") is not True:
                fail(results, str(eval_path), f"manual eval record {record.get('id')} should be positive expected_activation=True")
        else:
            if route != "excluded":
                fail(results, str(eval_path), f"manual eval record {record.get('id')} has invalid excluded route {route!r}")
            delegation = record.get("delegation")
            if delegation not in ([], None):
                fail(results, str(eval_path), f"manual eval record {record.get('id')} should not expect delegation")
            if record.get("expected_activation") is not False:
                fail(results, str(eval_path), f"manual eval record {record.get('id')} should be expected_activation=False")

    ok(results, str(eval_path), "manual activation records include category and delegation semantics")

    thresholds = data.get("thresholds", {})
    expected_thresholds = {
        ("quality", "max_pass_deficit_vs_sol"): 0,
        ("luna_core", "max_median_total_quota_ratio_vs_sol"): 0.6,
        ("luna_core", "max_median_sol_parent_quota_ratio"): 0.6,
        ("luna_core", "max_median_latency_ratio_vs_sol"): 2.0,
        ("spark_incremental", "max_median_total_quota_ratio_vs_sol"): 0.6,
        ("spark_incremental", "max_median_total_quota_ratio_vs_luna"): 0.8,
        ("spark_incremental", "max_parent_packet_quota_ratio_vs_luna"): 1.05,
        ("spark_incremental", "max_median_latency_ratio_vs_luna"): 1.25,
        ("spark_incremental", "max_extra_context_construction_rate"): 0.0,
        ("spark_incremental", "tuning_iterations_before_removal"): 1,
        ("no_fit", "max_quota_ratio_vs_direct_sol"): 1.05,
    }
    bad = [
        f"{section}.{key}"
        for (section, key), expected in expected_thresholds.items()
        if thresholds.get(section, {}).get(key) != expected
    ]
    if bad:
        fail(results, str(eval_path), f"quota/quality release gates changed or missing: {', '.join(bad)}")
    else:
        ok(results, str(eval_path), "Luna and Spark go/no-go gates match the release contract")

    instructions = data.get("instructions", {})
    required_instructions = {
        "use_identical_frozen_repository_state": True,
        "use_identical_capsule_for_luna_and_spark": True,
        "include_parent_packet_construction": True,
    }
    if any(instructions.get(key) is not value for key, value in required_instructions.items()):
        fail(results, str(eval_path), "paired evaluation does not hold repository state, capsule, and parent construction constant")
    else:
        ok(results, str(eval_path), "paired evaluation controls are explicit")


def _load_toml(path: Path) -> Dict[str, Any]:
    with path.open("rb") as handle:
        return tomllib.loads(handle.read().decode("utf-8"))


def _check_setup_assets(plugin_dir: Path, results: List[ValidationResult]) -> None:
    base = plugin_dir / "skills" / "setup" / "assets" / "profiles"
    expected = {
        base / "shared" / "explorer.toml": ("aspera_explorer", "gpt-5.6-luna", "read-only", "max"),
        base / "shared" / "luna-worker.toml": ("aspera_luna_worker", "gpt-5.6-luna", "workspace-write", "max"),
        base / "adaptive" / "spark-worker.toml": ("aspera_spark_worker", "gpt-5.3-codex-spark", "workspace-write", "xhigh"),
        base / "shared" / "researcher.toml": ("aspera_researcher", "gpt-5.6-luna", "read-only", "max"),
        base / "shared" / "reviewer.toml": ("aspera_reviewer", "gpt-5.6-terra", "read-only", "high"),
    }
    for path, values in expected.items():
        if not path.is_file():
            fail(results, str(path), "missing role asset TOML")
            continue
        try:
            data = _load_toml(path)
        except (tomllib.TOMLDecodeError, ValueError, OSError) as exc:
            fail(results, str(path), f"invalid TOML: {exc}")
            continue
        keys = ("name", "model", "sandbox_mode", "model_reasoning_effort")
        observed = tuple(data.get(key) for key in keys)
        if observed != values:
            fail(results, str(path), f"role mapping mismatch: expected {values}, got {observed}")
        else:
            ok(results, str(path), "role mapping matches Luna-first contract")

    verifier_assets = list(base.glob("**/*verifier*.toml"))
    if verifier_assets:
        fail(results, str(base), "default verifier role assets remain")
    else:
        ok(results, str(base), "default verifier role removed")


def _check_manifest_and_marketplace(plugin_dir: Path, repo_root: Path, results: List[ValidationResult]) -> None:
    manifest_path = plugin_dir / ".codex-plugin" / "plugin.json"
    if not manifest_path.is_file():
        fail(results, str(manifest_path), "missing .codex-plugin/plugin.json")
        return

    try:
        manifest = _read_json(manifest_path)
    except (json.JSONDecodeError, OSError) as exc:
        fail(results, str(manifest_path), f"invalid .codex-plugin/plugin.json: {exc}")
        return

    plugin_name = manifest.get("name")
    if not plugin_name:
        fail(results, str(manifest_path), "manifest missing plugin name")
        return
    if plugin_name != plugin_dir.name:
        fail(results, str(manifest_path), "manifest name does not match plugin folder")
    else:
        ok(results, str(manifest_path), "manifest name matches plugin folder")

    if manifest.get("version") != "0.4.0":
        fail(results, str(manifest_path), "manifest version must be 0.4.0")

    marketplace_path = repo_root / ".agents" / "plugins" / "marketplace.json"
    if not marketplace_path.is_file():
        fail(results, str(marketplace_path), "missing marketplace file")
        return

    try:
        payload = _read_json(marketplace_path)
    except (json.JSONDecodeError, OSError) as exc:
        fail(results, str(marketplace_path), f"invalid marketplace JSON: {exc}")
        return

    plugins = payload.get("plugins", [])
    if not isinstance(plugins, list):
        fail(results, str(marketplace_path), "marketplace plugins field must be an array")
        return

    match: Optional[Dict[str, Any]] = None
    for entry in plugins:
        if isinstance(entry, dict) and entry.get("name") == plugin_name:
            match = entry
            break
    if match is None:
        fail(results, str(marketplace_path), f"marketplace missing entry for {plugin_name}")
        return
    source_path = match.get("source", {}).get("path", "")
    expected_source = f"./plugins/{plugin_name}"
    if source_path != expected_source:
        fail(
            results,
            str(marketplace_path),
            f"marketplace source path {source_path} does not match {expected_source}",
        )
    else:
        ok(results, str(marketplace_path), "marketplace references plugin path consistently")


def _check_forbidden(plugin_dir: Path, results: List[ValidationResult]) -> None:
    for candidate in plugin_dir.glob("**/*"):
        if not candidate.is_file():
            continue
        try:
            text = candidate.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for token in FORBIDDEN_STRINGS:
            if token in text:
                fail(results, str(candidate), f"forbidden token present: {token}")


def validate_package(plugin_dir: Path, repo_root: Path, results: List[ValidationResult]) -> None:
    if not plugin_dir.exists():
        fail(results, str(plugin_dir), "plugin root missing")
        return

    _check_policy_source(repo_root, results)
    _check_orchestrate_activation_rules(repo_root, plugin_dir, results)
    _check_worker_runtime_contract(repo_root, plugin_dir, results)
    _check_manual_eval_activation_records(repo_root, results)

    for shell_path in plugin_dir.glob("**/*.sh"):
        if shell_path.is_file():
            _check_shell_file(shell_path, results)
            _check_shellcheck(shell_path, results)

    for json_path in plugin_dir.glob("**/*.json"):
        if json_path.is_file():
            _check_json(json_path, results)

    for toml_path in plugin_dir.glob("**/*.toml"):
        if toml_path.is_file():
            _check_toml(toml_path, results)

    for skill in plugin_dir.glob("**/SKILL.md"):
        if skill.is_file():
            _check_skill_frontmatter(skill, results)

    for openai in plugin_dir.glob("**/openai.yaml"):
        if openai.is_file():
            _check_skill_openai_yaml(openai, results)

    _check_setup_assets(plugin_dir, results)
    _check_manifest_and_marketplace(plugin_dir, repo_root, results)
    _check_forbidden(plugin_dir, results)


def summarize(results: List[ValidationResult]) -> int:
    fails = [r for r in results if r.status == "fail"]
    for result in results:
        prefix = "FAIL" if result.status == "fail" else "OK"
        print(f"[{prefix}] {result.path} :: {result.message}")
    print(f"[SUMMARY] checks={len(results)} fails={len(fails)}")
    return len(fails)


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    if args.plugin_root:
        plugin_candidates = [Path(args.plugin_root).resolve()]
    else:
        plugin_candidates = [repo_root / "plugins" / "aspera-orchestrator"]

    results: List[ValidationResult] = []
    for plugin in plugin_candidates:
        validate_package(plugin, repo_root, results)

    failures = summarize(results)
    if failures:
        print("[RESULT] static validator failed")
        return 1
    print("[RESULT] static validator passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
