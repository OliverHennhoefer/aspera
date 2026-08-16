from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from shutil import which
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore


@dataclass
class Result:
    path: str
    status: str
    message: str


def record(results: list[Result], path: Path, passed: bool, message: str) -> None:
    results.append(Result(str(path), "ok" if passed else "fail", message))


def load_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=os.getcwd())
    parser.add_argument("--plugin-root", default=None)
    return parser.parse_args()


def check_syntax(plugin: Path, repo: Path, results: list[Result]) -> None:
    for path in plugin.rglob("*.json"):
        try:
            load_json(path)
        except (json.JSONDecodeError, OSError) as exc:
            record(results, path, False, f"invalid JSON: {exc}")
        else:
            record(results, path, True, "valid JSON")

    for path in plugin.rglob("*.toml"):
        try:
            tomllib.loads(load_text(path))
        except (tomllib.TOMLDecodeError, OSError) as exc:
            record(results, path, False, f"invalid TOML: {exc}")
        else:
            record(results, path, True, "valid TOML")

    shell_paths = [repo / "aspera", *plugin.rglob("*.sh")]
    for path in shell_paths:
        syntax = subprocess.run(["bash", "-n", str(path)], check=False, capture_output=True)
        record(results, path, syntax.returncode == 0, "shell syntax valid")
        shellcheck = which("shellcheck")
        if shellcheck:
            checked = subprocess.run([shellcheck, "-s", "bash", str(path)], check=False)
            record(results, path, checked.returncode == 0, "shellcheck passed")


def check_skills(plugin: Path, results: list[Result]) -> None:
    for skill in plugin.rglob("SKILL.md"):
        text = load_text(skill)
        match = re.match(r"\A---\n(.*?)\n---\n", text, re.DOTALL)
        valid = bool(match and re.search(r"(?m)^name:\s*\S+", match.group(1)) and re.search(r"(?m)^description:\s*(?:\||\S+)", match.group(1)))
        record(results, skill, valid, "skill has name and description frontmatter")

    for metadata in plugin.rglob("openai.yaml"):
        text = load_text(metadata)
        required = ("display_name:", "short_description:", "default_prompt:", "allow_implicit_invocation:")
        valid = all(term in text for term in required)
        record(results, metadata, valid, "skill interface metadata is complete")


def check_routing(plugin: Path, repo: Path, results: list[Result]) -> None:
    policy = plugin / "skills/orchestrate/references/policy.md"
    skill = plugin / "skills/orchestrate/SKILL.md"
    root_policy = repo / "AGENTS.md"
    policy_text = load_text(policy).lower()
    skill_text = load_text(skill).lower()
    root_text = load_text(root_policy).lower()

    required_policy = (
        "one focused edit-and-test cycle",
        "native `gpt-5.6-luna` at `max`",
        "natural brief",
        "default to one worker",
        "plainly independent, disjoint units",
        "native `gpt-5.6-terra` at `high`",
        "never delegate recursively",
    )
    missing = [term for term in required_policy if term not in policy_text]
    record(results, policy, not missing, "compact native routing heuristic is complete" if not missing else f"missing: {', '.join(missing)}")
    record(results, policy, len(policy.read_bytes()) <= 1536, "managed routing policy fits the 1.5 KB budget")

    required_skill = (
        "native `gpt-5.6-luna` subagent at `max`",
        "native `gpt-5.6-terra` subagent at `high`",
        "do not pre-read",
        "never delegate recursively",
    )
    missing = [term for term in required_skill if term not in skill_text]
    record(results, skill, not missing, "orchestration skill mirrors native routing" if not missing else f"missing: {', '.join(missing)}")

    forbidden_runtime = ("spark", "packet_version", "owned_paths", "context_anchors", "worker_guard", "inspection calls", "handoff schema")
    present = [term for term in forbidden_runtime if term in policy_text or term in skill_text]
    record(results, skill, not present, "packet and lifecycle machinery is absent" if not present else f"obsolete terms: {', '.join(present)}")

    root_terms = (
        "always implement aspera itself parent-direct",
        "native luna max is the primary downstream implementation worker",
        "one natural brief",
        "supported legacy profiles migrate automatically to the luna-only contract",
        "commit the receipt last",
    )
    missing = [term for term in root_terms if term not in root_text]
    record(results, root_policy, not missing, "repository development and lifecycle invariants remain explicit" if not missing else f"missing: {', '.join(missing)}")


def check_runtime_surface(plugin: Path, results: list[Result]) -> None:
    assets = plugin / "skills/setup/assets"
    removed = (
        assets / "profiles/adaptive/spark-worker.toml",
        assets / "profiles/shared/explorer.toml",
        assets / "profiles/shared/luna-worker.toml",
        assets / "profiles/shared/researcher.toml",
        assets / "profiles/shared/reviewer.toml",
        assets / "worker_guard.py",
        plugin / "skills/orchestrate/references/protocol.md",
    )
    present = [str(path.relative_to(plugin)) for path in removed if path.exists()]
    record(results, assets, not present, "all custom roles, guard, and protocol are removed" if not present else f"still present: {', '.join(present)}")


def check_lifecycle(plugin: Path, repo: Path, results: list[Result]) -> None:
    common = plugin / "skills/setup/scripts/common.sh"
    install = plugin / "skills/setup/scripts/install.sh"
    doctor = plugin / "skills/setup/scripts/doctor.sh"
    common_text = load_text(common)
    install_text = load_text(install)
    doctor_text = load_text(doctor)

    required_common = (
        "ASPERA_PLUGIN_VERSION='0.5.0'",
        "ASPERA_STATE_SCHEMA='5'",
        "ASPERA_ALL_MANAGED_FILES=(",
        "ASPERA_OBSOLETE_MANAGED_FILES",
        "'.codex/agents/aspera-spark-worker.toml'",
        "versions = {1:",
        "5: {'0.5.0'}",
        "schema == 5",
        "[ \"$policy_bytes\" -le 1536 ]",
    )
    missing = [term for term in required_common if term not in common_text]
    record(results, common, not missing, "schema-5 migration contract is complete" if not missing else f"missing: {', '.join(missing)}")

    required_install = (
        "schema_version': 5",
        "plugin_version': '0.5.0'",
        "'profile': 'luna'",
        "'managed_files': {}",
        "snapshot-before",
        "snapshot-after",
        "rollback_install",
        "asp_verify_installation",
    )
    missing = [term for term in required_install if term not in install_text]
    record(results, install, not missing, "transactional schema-5 reconcile is complete" if not missing else f"missing: {', '.join(missing)}")
    record(results, install, "--profile" not in install_text, "installer exposes no profile surface")
    record(results, doctor, "worker_guard" not in doctor_text and "aspera-luna-worker" not in doctor_text and "--profile" not in doctor_text, "diagnosis has no removed runtime or profile probes")

    cli = repo / "aspera"
    cli_text = load_text(cli)
    required_cli = ("install)", "diagnose)", "uninstall)", "plugin marketplace list --json", "plugin remove", "plugin add")
    missing = [term for term in required_cli if term not in cli_text]
    record(results, cli, not missing, "root command retains supported plugin and project lifecycle" if not missing else f"missing: {', '.join(missing)}")


def check_manifest_and_eval(plugin: Path, repo: Path, results: list[Result]) -> None:
    manifest_path = plugin / ".codex-plugin/plugin.json"
    manifest = load_json(manifest_path)
    valid_manifest = manifest.get("name") == plugin.name and manifest.get("version") == "0.5.0"
    record(results, manifest_path, valid_manifest, "manifest identifies Aspera 0.5.0")

    marketplace_path = repo / ".agents/plugins/marketplace.json"
    marketplace = load_json(marketplace_path)
    entries = [entry for entry in marketplace.get("plugins", []) if entry.get("name") == plugin.name]
    valid_marketplace = len(entries) == 1 and entries[0].get("source", {}).get("path") == f"./plugins/{plugin.name}"
    record(results, marketplace_path, valid_marketplace, "marketplace references the plugin source")

    eval_path = repo / "tests/evals/manual-eval-spec.json"
    evaluation = load_json(eval_path)
    required_thresholds = {
        ("quality", "max_pass_deficit_vs_sol"): 0,
        ("quality", "max_pass_deficit_vs_0_4_1"): 0,
        ("luna_core", "max_median_total_quota_ratio_vs_sol"): 0.6,
        ("no_fit", "max_quota_ratio_vs_direct_sol"): 1.05,
        ("routing_overhead", "max_median_tokens_vs_0_4_1"): 1.0,
    }
    thresholds = evaluation.get("thresholds", {})
    bad = [f"{section}.{key}" for (section, key), value in required_thresholds.items() if thresholds.get(section, {}).get(key) != value]
    record(results, eval_path, not bad, "quality, quota, and routing-overhead gates are pinned" if not bad else f"bad gates: {', '.join(bad)}")

    records = evaluation.get("activation_records", [])
    counts = evaluation.get("fixture_counts", {})
    positive = sum(record.get("category") == "positive" for record in records)
    negative = sum(record.get("category") == "negative" for record in records)
    valid_counts = positive == counts.get("positive_activation_records") and negative == counts.get("negative_activation_records")
    record(results, eval_path, valid_counts, "activation fixture counts match")

    instructions = evaluation.get("instructions", {})
    controls = (
        instructions.get("use_identical_frozen_repository_state") is True
        and instructions.get("use_identical_user_prompt_across_routes") is True
        and instructions.get("include_parent_routing_and_brief_construction") is True
        and instructions.get("compare_routing_tokens_with_0_4_1") is True
    )
    record(results, eval_path, controls, "paired evaluation controls include the complete routing cost")


def check_forbidden(plugin: Path, results: list[Result]) -> None:
    offenders: list[str] = []
    for path in plugin.rglob("*"):
        if path.is_file() and ".codex/config.toml" in load_text(path):
            offenders.append(str(path.relative_to(plugin)))
    record(results, plugin, not offenders, "plugin never manages .codex/config.toml" if not offenders else f"forbidden references: {', '.join(offenders)}")


def main() -> int:
    args = parse_args()
    repo = Path(args.repo_root).resolve()
    plugin = Path(args.plugin_root).resolve() if args.plugin_root else repo / "plugins/aspera-orchestrator"
    results: list[Result] = []

    check_syntax(plugin, repo, results)
    check_skills(plugin, results)
    check_routing(plugin, repo, results)
    check_runtime_surface(plugin, results)
    check_lifecycle(plugin, repo, results)
    check_manifest_and_eval(plugin, repo, results)
    check_forbidden(plugin, results)

    failures = [result for result in results if result.status == "fail"]
    for result in results:
        print(f"[{'OK' if result.status == 'ok' else 'FAIL'}] {result.path} :: {result.message}")
    print(f"[SUMMARY] checks={len(results)} fails={len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
