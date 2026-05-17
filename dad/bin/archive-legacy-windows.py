#!/usr/bin/env python3
"""Archive obsolete file-backed DAD window records.

Current DAD state lives in tmux window options. Older DADs wrote large
`windows/<name>/current.dad.json` files that can mislead newer supervision
passes because they describe manual loops, stale panes, and old policy states.
This script preserves those records under `legacy/` and replaces the current
file with a small archive pointer.
"""

from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from dad_paths import dad_root, data_root


ARCHIVE_SCHEMA = "dad-window-archive-pointer-v1"
POLICY_VERSION_FILE = dad_root() / "POLICY_VERSION"


def current_policy_version() -> str:
    try:
        value = POLICY_VERSION_FILE.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        value = ""
    return value or "failclosed-lease-evidence-v1"


def now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} did not contain a JSON object")
    return data


def is_current_policy(data: dict[str, Any]) -> bool:
    schema = data.get("schema")
    return schema == ARCHIVE_SCHEMA


def pointer_for(original: dict[str, Any], archive_path: Path, current_path: Path) -> dict[str, Any]:
    objective = str(original.get("objective") or original.get("full_objective") or "")
    if len(objective) > 500:
        objective = objective[:500] + "...[truncated]"
    return {
        "schema": ARCHIVE_SCHEMA,
        "policy_version": current_policy_version(),
        "status": "archived_legacy",
        "archived_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "archive_path": os.path.relpath(archive_path, current_path.parent),
        "legacy_status": original.get("status") or original.get("phase") or "unknown",
        "legacy_window_id": original.get("tmux_window_id") or original.get("window_id") or "",
        "legacy_dad_pane_id": original.get("dad_pane_id") or "",
        "legacy_son_pane_id": original.get("son_pane_id") or "",
        "objective": objective,
        "note": "Archived legacy file-backed DAD state. Live DAD state is stored in tmux @dad_* window options; do not use this pointer as live state.",
    }


def archive_file(current_path: Path, apply: bool, stamp: str) -> str:
    original = load_json(current_path)
    if is_current_policy(original):
        return f"skip current-policy {current_path}"

    archive_dir = current_path.parent / "legacy"
    archive_path = archive_dir / f"current.dad.{stamp}.json"
    if not apply:
        return f"would-archive {current_path} -> {archive_path}"

    archive_dir.mkdir(mode=0o700, exist_ok=True)
    current_path.rename(archive_path)
    pointer = pointer_for(original, archive_path, current_path)
    with current_path.open("w", encoding="utf-8") as handle:
        json.dump(pointer, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(archive_path, 0o600)
    os.chmod(current_path, 0o600)
    return f"archived {current_path} -> {archive_path}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(data_root() / "windows"))
    parser.add_argument("--apply", action="store_true", help="Actually archive files. Default is dry-run.")
    parser.add_argument("--include-template", action="store_true", help="Also archive DAD-Template/current.dad.json.")
    args = parser.parse_args()

    root = Path(args.root).expanduser()
    if not root.exists():
        print(f"window root not found: {root}")
        return 1

    stamp = now_stamp()
    paths = sorted(root.glob("*/current.dad.json"))
    if not paths:
        print("no current.dad.json files found")
        return 0

    for path in paths:
        if path.parent.name == "DAD-Template" and not args.include_template:
            print(f"skip template {path}")
            continue
        try:
            print(archive_file(path, args.apply, stamp))
        except Exception as exc:
            print(f"error {path}: {exc}")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
