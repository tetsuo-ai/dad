#!/usr/bin/env python3
"""Generic context-bounded code standards check for DAD/Son work.

The check is intentionally language-neutral. It looks for hand-authored text
files that are too large for an agent to keep in working context and reports a
hard failure before DAD accepts a checkpoint.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable


DEFAULT_WARN_LINES = 800
DEFAULT_MAX_LINES = 1200
DEFAULT_CRITICAL_LINES = 2000
SAMPLE_BYTES = 8192

EXCLUDED_DIR_NAMES = {
    ".cache",
    ".git",
    ".hg",
    ".mypy_cache",
    ".next",
    ".pytest_cache",
    ".ruff_cache",
    ".svn",
    ".tox",
    ".venv",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "events",
    "evidence",
    "logs",
    "locks",
    "node_modules",
    "out",
    "target",
    "tmp",
    "vendor",
    "venv",
}

EXCLUDED_SUFFIXES = {
    ".7z",
    ".a",
    ".avi",
    ".bin",
    ".bmp",
    ".class",
    ".dll",
    ".dylib",
    ".gif",
    ".gz",
    ".ico",
    ".jar",
    ".jpeg",
    ".jpg",
    ".jsonl",
    ".log",
    ".lock",
    ".mov",
    ".mp3",
    ".mp4",
    ".o",
    ".pdf",
    ".png",
    ".pyc",
    ".so",
    ".sqlite",
    ".sqlite3",
    ".tar",
    ".tgz",
    ".ttf",
    ".wasm",
    ".webp",
    ".woff",
    ".woff2",
    ".zip",
}

EXCLUDED_FILENAMES = {
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "cargo.lock",
    "composer.lock",
    "gemfile.lock",
    "poetry.lock",
}


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=5,
        check=False,
    )


def is_git_repo(root: Path) -> bool:
    return run(["git", "rev-parse", "--is-inside-work-tree"], root).stdout.strip() == "true"


def git_lines(root: Path, args: list[str]) -> list[str]:
    result = run(["git", *args], root)
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line]


def status_paths(root: Path) -> list[str]:
    result = run(["git", "status", "--porcelain=v1", "-z", "--untracked-files=normal"], root)
    if result.returncode != 0:
        return []
    paths: list[str] = []
    entries = [entry for entry in result.stdout.split("\0") if entry]
    idx = 0
    while idx < len(entries):
        entry = entries[idx]
        code = entry[:2]
        payload = entry[3:] if len(entry) > 3 else ""
        if code.startswith("R") or code.startswith("C"):
            idx += 1
            if idx < len(entries):
                paths.append(entries[idx])
        elif payload:
            paths.append(payload)
        idx += 1
    return paths


def latest_commit_paths(root: Path) -> list[str]:
    if run(["git", "rev-parse", "--verify", "HEAD"], root).returncode != 0:
        return []
    if run(["git", "rev-parse", "--verify", "HEAD^"], root).returncode == 0:
        return git_lines(root, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
    return git_lines(root, ["ls-tree", "--name-only", "-r", "HEAD"])


def candidate_paths(root: Path, mode: str) -> list[Path]:
    rels: set[str] = set()
    if mode in {"changed", "changed-and-head"} and is_git_repo(root):
        rels.update(git_lines(root, ["diff", "--name-only", "--diff-filter=ACMRTUXB", "HEAD", "--"]))
        rels.update(git_lines(root, ["diff", "--cached", "--name-only", "--diff-filter=ACMRTUXB", "--"]))
        rels.update(status_paths(root))
    if mode == "changed-and-head" and is_git_repo(root):
        rels.update(latest_commit_paths(root))
    if mode == "all" or (not rels and not is_git_repo(root)):
        for path in root.rglob("*"):
            if path.is_file():
                rels.add(str(path.relative_to(root)))
    return sorted((root / rel).resolve() for rel in rels)


def is_excluded(path: Path, root: Path) -> bool:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return True
    lower_parts = {part.lower() for part in rel.parts[:-1]}
    if lower_parts & EXCLUDED_DIR_NAMES:
        return True
    name = rel.name.lower()
    if name in EXCLUDED_FILENAMES:
        return True
    if path.suffix.lower() in EXCLUDED_SUFFIXES:
        return True
    return False


def looks_text(path: Path) -> bool:
    try:
        data = path.read_bytes()[:SAMPLE_BYTES]
    except OSError:
        return False
    if b"\0" in data:
        return False
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        try:
            data.decode("latin-1")
        except UnicodeDecodeError:
            return False
    return True


def count_lines(path: Path) -> int:
    try:
        with path.open("rb") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return 0


def generated_marker(path: Path) -> bool:
    try:
        head = path.read_text(encoding="utf-8", errors="replace").splitlines()[:20]
    except OSError:
        return False
    text = "\n".join(head).lower()
    return "generated" in text and ("do not edit" in text or "auto-generated" in text)


def analyze(paths: Iterable[Path], root: Path, warn_lines: int, max_lines: int, critical_lines: int) -> dict[str, object]:
    checked: list[dict[str, object]] = []
    warnings: list[dict[str, object]] = []
    failures: list[dict[str, object]] = []
    critical: list[dict[str, object]] = []
    skipped = 0

    for path in paths:
        if not path.exists() or not path.is_file() or is_excluded(path, root) or not looks_text(path):
            skipped += 1
            continue
        rel = str(path.relative_to(root))
        lines = count_lines(path)
        item = {"path": rel, "lines": lines}
        checked.append(item)
        if generated_marker(path):
            continue
        if lines > critical_lines:
            critical.append(item)
            failures.append(item)
        elif lines > max_lines:
            failures.append(item)
        elif lines > warn_lines:
            warnings.append(item)

    return {
        "schema": "dad.code-standards.v1",
        "root": str(root),
        "status": "FAIL" if failures else "PASS",
        "thresholds": {
            "warnLines": warn_lines,
            "maxLines": max_lines,
            "criticalLines": critical_lines,
        },
        "checkedCount": len(checked),
        "skippedCount": skipped,
        "warnings": warnings,
        "failures": failures,
        "critical": critical,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="Workspace root to check.")
    parser.add_argument(
        "--mode",
        choices=["changed", "changed-and-head", "all"],
        default="changed-and-head",
        help="changed = worktree/index only; changed-and-head also checks the latest commit; all scans all text files.",
    )
    parser.add_argument("--warn-lines", type=int, default=DEFAULT_WARN_LINES)
    parser.add_argument("--max-lines", type=int, default=DEFAULT_MAX_LINES)
    parser.add_argument("--critical-lines", type=int, default=DEFAULT_CRITICAL_LINES)
    parser.add_argument("--json", action="store_true", help="Print full JSON only.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.root).expanduser().resolve()
    if not root.is_dir():
        print(f"CODE_STANDARDS_RESULT: FAIL root_not_found={root}", file=sys.stderr)
        return 2
    if args.warn_lines < 1 or args.max_lines < args.warn_lines or args.critical_lines < args.max_lines:
        print("CODE_STANDARDS_RESULT: FAIL invalid_thresholds", file=sys.stderr)
        return 2

    report = analyze(candidate_paths(root, args.mode), root, args.warn_lines, args.max_lines, args.critical_lines)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"CODE_STANDARDS_RESULT: {report['status']}")
        print(f"CODE_STANDARDS_CHECKED: {report['checkedCount']}")
        thresholds = report["thresholds"]
        print(
            "CODE_STANDARDS_THRESHOLDS: "
            f"warn>{thresholds['warnLines']} max>{thresholds['maxLines']} critical>{thresholds['criticalLines']}"
        )
        for item in report["warnings"]:
            print(f"CODE_STANDARDS_WARNING: {item['path']} lines={item['lines']}")
        for item in report["failures"]:
            print(f"CODE_STANDARDS_FAILURE: {item['path']} lines={item['lines']}")
        if report["failures"]:
            print(
                "CODE_STANDARDS_INSTRUCTION: split oversized hand-authored files into focused modules before claiming completion"
            )
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
