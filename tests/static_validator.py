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

    ok(results, str(path), "openai.yaml required nested interface and policy fields present")


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


def _load_toml(path: Path) -> Dict[str, Any]:
    with path.open("rb") as handle:
        return tomllib.loads(handle.read().decode("utf-8"))


def _check_setup_assets(plugin_dir: Path, results: List[ValidationResult]) -> None:
    profile_expected = {
        "spark": {
            "explorer": ("aspera_explorer", "gpt-5.3-codex-spark", "read-only", "xhigh"),
            "worker": ("aspera_worker", "gpt-5.3-codex-spark", "workspace-write", "xhigh"),
            "verifier": ("aspera_verifier", "gpt-5.3-codex-spark", "workspace-write", "xhigh"),
            "researcher": ("aspera_researcher", "gpt-5.6-luna", "read-only", "max"),
            "reviewer": ("aspera_reviewer", "gpt-5.6-terra", "read-only", "high"),
        },
        "luna": {
            "explorer": ("aspera_explorer", "gpt-5.6-luna", "read-only", "max"),
            "worker": ("aspera_worker", "gpt-5.6-luna", "workspace-write", "max"),
            "verifier": ("aspera_verifier", "gpt-5.6-luna", "workspace-write", "max"),
            "researcher": ("aspera_researcher", "gpt-5.6-luna", "read-only", "max"),
            "reviewer": ("aspera_reviewer", "gpt-5.6-terra", "read-only", "high"),
        },
    }
    for profile, role_map in profile_expected.items():
        for role, values in role_map.items():
            expected_name, expected_model, expected_sandbox, expected_effort = values
            if role in {"explorer", "worker", "verifier"}:
                path = plugin_dir / "skills" / "setup" / "assets" / "profiles" / profile / f"{role}.toml"
            else:
                path = plugin_dir / "skills" / "setup" / "assets" / "profiles" / "shared" / f"{role}.toml"

            if not path.is_file():
                fail(results, str(path), "missing role asset TOML")
                continue

            try:
                data = _load_toml(path)
            except (tomllib.TOMLDecodeError, ValueError, OSError) as exc:
                fail(results, str(path), f"invalid TOML: {exc}")
                continue
            if data.get("name") != expected_name:
                fail(results, str(path), f"incorrect name for {profile}/{role}")
            if data.get("model") != expected_model:
                fail(results, str(path), f"incorrect model for {profile}/{role}")
            if data.get("sandbox_mode") != expected_sandbox:
                fail(results, str(path), f"incorrect sandbox_mode for {profile}/{role}")
            if data.get("model_reasoning_effort") != expected_effort:
                fail(results, str(path), f"incorrect effort for {profile}/{role}")
            if all(
                key in data
                for key in ("name", "model", "sandbox_mode", "model_reasoning_effort")
            ):
                ok(results, str(path), "role mapping matches strict contract")


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

    if manifest.get("version") != "0.1.0":
        fail(results, str(manifest_path), "manifest version must be 0.1.0")

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
