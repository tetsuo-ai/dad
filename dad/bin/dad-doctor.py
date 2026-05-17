#!/usr/bin/env python3
"""DAD install and platform preflight checks."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


REQUIRED_TOOLS = ("bash", "python3", "git", "tmux", "pgrep", "timeout", "flock", "sha256sum")


def issue(code: str, detail: str) -> str:
    return f"{code}: {detail}"


def check_platform() -> list[str]:
    issues: list[str] = []
    forced_missing = {item for item in os.environ.get("DAD_DOCTOR_MISSING_TOOLS", "").split(",") if item}
    if platform.system() != "Linux":
        issues.append(issue("platform_not_linux", f"detected {platform.system()}"))
    if not Path("/proc").is_dir():
        issues.append(issue("procfs_missing", "/proc is required for daemon ownership checks"))
    for tool in REQUIRED_TOOLS:
        if tool in forced_missing or shutil.which(tool) is None:
            issues.append(issue("required_tool_missing", tool))
    try:
        result = subprocess.run(
            ["date", "-d", "@0", "+%s"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
        if result.returncode != 0 or result.stdout.strip() != "0":
            issues.append(issue("gnu_date_missing", "date -d @0 did not work"))
    except Exception as exc:
        issues.append(issue("gnu_date_missing", type(exc).__name__))
    return issues


def walk_objects(value: Any) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    if isinstance(value, dict):
        found.append(value)
        for item in value.values():
            found.extend(walk_objects(item))
    elif isinstance(value, list):
        for item in value:
            found.extend(walk_objects(item))
    return found


def extract_dad_skill_sources(inspect_data: Any) -> list[str]:
    sources: list[str] = []
    for obj in walk_objects(inspect_data):
        name = str(obj.get("name") or obj.get("id") or obj.get("skill") or "")
        path = str(obj.get("path") or obj.get("source") or obj.get("file") or obj.get("root") or "")
        if name == "dad" or path.endswith("/skills/dad/SKILL.md") or "/skills/dad" in path:
            if path:
                sources.append(path)
            elif name:
                sources.append(name)
    deduped: list[str] = []
    for source in sources:
        if source not in deduped:
            deduped.append(source)
    return deduped


def check_inspect_json(path: str | None) -> list[str]:
    if not path:
        return []
    text = sys.stdin.read() if path == "-" else Path(path).read_text(encoding="utf-8", errors="replace")
    data = json.loads(text)
    dad_sources = extract_dad_skill_sources(data)
    issues: list[str] = []
    legacy_sources = [source for source in dad_sources if "/.grok/skills/dad" in source or source.endswith(".grok/skills/dad")]
    plugin_sources = [source for source in dad_sources if "/plugins/dad" in source or "/git/dad" in source]
    if len(dad_sources) > 1:
        issues.append(issue("duplicate_dad_skill", ", ".join(dad_sources)))
    if legacy_sources and plugin_sources:
        issues.append(issue("legacy_dad_skill_shadows_plugin", ", ".join(legacy_sources)))
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform-only", action="store_true", help="Run platform checks only.")
    parser.add_argument("--skip-platform", action="store_true", help="Skip platform checks.")
    parser.add_argument("--inspect-json", help="Path to grok inspect --json output, or '-' for stdin.")
    parser.add_argument("--json", action="store_true", help="Emit JSON.")
    args = parser.parse_args()

    issues = [] if args.skip_platform else check_platform()
    if not args.platform_only:
        issues.extend(check_inspect_json(args.inspect_json))

    payload = {"status": "PASS" if not issues else "FAIL", "issues": issues}
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"DAD_DOCTOR_RESULT: {payload['status']}")
        for item in issues:
            print(f"DAD_DOCTOR_ISSUE: {item}")
    return 0 if not issues else 1


if __name__ == "__main__":
    raise SystemExit(main())
