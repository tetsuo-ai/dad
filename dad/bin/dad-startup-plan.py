#!/usr/bin/env python3
"""Build a deterministic DAD startup plan for public-safe modes."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys


MODES = {"safe", "review-only", "yolo"}


def scheduler_supported() -> bool:
    value = os.environ.get("DAD_STARTUP_TEST_SCHEDULER_SUPPORT")
    if value is not None:
        return value not in {"0", "false", "False", "no"}
    return True


def tmux_available() -> bool:
    if os.environ.get("DAD_STARTUP_TEST_HAS_TMUX") == "1":
        return True
    if os.environ.get("DAD_STARTUP_TEST_MISSING_TMUX") == "1":
        return False
    return shutil.which("tmux") is not None


def infer_read_only(mode: str, objective: str) -> bool:
    lowered = objective.lower()
    return mode == "review-only" or any(token in lowered for token in ("read-only", "readonly", "audit", "inspect only", "review only"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=sorted(MODES), default="safe")
    parser.add_argument("--objective", default="")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    issues: list[str] = []
    if not tmux_available():
        issues.append("missing_tmux")
    if not scheduler_supported():
        issues.append("missing_scheduler_support")

    read_only = infer_read_only(args.mode, args.objective)
    son_command = ["grok"]
    if args.mode == "yolo":
        son_command.append("--yolo")

    payload = {
        "mode": args.mode,
        "sonCommand": son_command,
        "writeAllowed": args.mode == "yolo" and not read_only,
        "requiresApproval": args.mode in {"safe", "review-only"},
        "readOnly": read_only,
        "schedulerEnabled": not issues,
        "issues": issues,
    }

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"DAD_STARTUP_MODE: {payload['mode']}")
        print(f"DAD_STARTUP_SON_COMMAND: {' '.join(son_command)}")
        for item in issues:
            print(f"DAD_STARTUP_ISSUE: {item}")
    return 0 if not issues else 1


if __name__ == "__main__":
    raise SystemExit(main())
