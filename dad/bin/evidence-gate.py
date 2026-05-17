#!/usr/bin/env python3
"""Deterministic DAD evidence gate.

This gate does not decide product quality. It rejects missing, stale, malformed,
or contradictory evidence before Dad/verifier prose is allowed to call a
checkpoint accepted.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from dad_paths import gate_root


PASS_STATUSES = {"EXIT_ZERO", "EXIT_EXPECTED"}
OBSERVATION_STATUSES = {"EXIT_ZERO", "EXIT_EXPECTED", "TIMEOUT"}
FAIL_STATUSES = {"EXIT_NONZERO", "SPAWN_ERROR", "ASSERTION_FAILED"}
DEFAULT_GATE_ROOT = gate_root()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


def run_git(cwd: Path, args: list[str]) -> str:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=str(cwd),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
    except Exception:
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def current_git(cwd: Path) -> dict[str, Any]:
    status = run_git(cwd, ["status", "--porcelain=v1", "--untracked-files=all"])
    return {
        "head": run_git(cwd, ["rev-parse", "HEAD"]),
        "statusSha256": hashlib.sha256(status.encode("utf-8", "replace")).hexdigest() if status else "",
        "statusLineCount": len(status.splitlines()) if status else 0,
        "dirty": bool(status),
    }


def is_git_workspace(cwd: Path) -> bool:
    return run_git(cwd, ["rev-parse", "--is-inside-work-tree"]) == "true"


def load_record(path: Path) -> tuple[dict[str, Any] | None, str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception as exc:
        return None, f"invalid_json:{type(exc).__name__}:{exc}"
    if not isinstance(data, dict):
        return None, "invalid_json:not_object"
    return data, ""


def safe_nonnegative_int(value: Any, field: str, issues: list[str]) -> int:
    try:
        parsed = int(value or 0)
    except (TypeError, ValueError):
        issues.append(f"{field}_invalid")
        return 0
    if parsed < 0:
        issues.append(f"{field}_invalid")
        return 0
    return parsed


def validate_one(
    path: Path,
    workspace: Path,
    require_real_run: bool,
    allow_timeout: bool,
    require_assertions: bool,
    min_transcript_bytes: int,
    require_output_regexes: list[str],
    require_action_effect: bool,
) -> tuple[bool, list[str], dict[str, Any]]:
    issues: list[str] = []
    record, error = load_record(path)
    if record is None:
        return False, [error], {"path": str(path)}

    status = str(record.get("status", ""))
    schema = str(record.get("schema", ""))
    raw_transcript_path = Path(str(record.get("transcriptPath", ""))).expanduser()
    transcript_path = raw_transcript_path if raw_transcript_path.is_absolute() else path.parent / raw_transcript_path
    cwd = Path(str(record.get("cwd", ""))).expanduser()
    record_dir = path.resolve().parent

    if schema != "dad.evidence.v2":
        issues.append("schema_missing_or_unknown")
    if not status:
        issues.append("status_missing")
    if any(status.startswith(prefix) for prefix in FAIL_STATUSES) or status.startswith("SIGNAL_"):
        issues.append(f"failing_status:{status}")
    if status == "TIMEOUT" and not allow_timeout:
        issues.append("timeout_not_allowed")
    if require_real_run and status not in OBSERVATION_STATUSES:
        issues.append(f"not_real_run_observation:{status}")
    if not require_real_run and status not in PASS_STATUSES and status != "TIMEOUT":
        issues.append(f"nonpassing_status:{status}")

    transcript = ""
    actual_transcript_bytes = 0
    try:
        transcript_resolved = transcript_path.resolve()
        if not transcript_resolved.is_relative_to(record_dir):
            issues.append(f"transcript_path_outside_evidence_record:{transcript_resolved}")
    except Exception:
        transcript_resolved = transcript_path
        issues.append("transcript_path_unresolvable")

    if not transcript_path.is_file():
        issues.append("transcript_missing")
    else:
        transcript = transcript_path.read_bytes().decode("utf-8", errors="replace")
        actual_transcript_bytes = len(transcript.encode("utf-8", "replace"))
        transcript_hash = sha256_text(transcript)
        if record.get("transcriptSha256") and transcript_hash != record.get("transcriptSha256"):
            issues.append("transcript_hash_mismatch")
        recorded_transcript_bytes = safe_nonnegative_int(record.get("transcriptBytes"), "transcript_bytes", issues)
        if recorded_transcript_bytes != actual_transcript_bytes:
            issues.append(f"transcript_bytes_mismatch:{recorded_transcript_bytes}!={actual_transcript_bytes}")
        if require_real_run and actual_transcript_bytes == 0:
            issues.append("empty_transcript_for_real_run")
        if min_transcript_bytes > 0 and actual_transcript_bytes < min_transcript_bytes:
            issues.append(f"transcript_too_small:{actual_transcript_bytes}<min:{min_transcript_bytes}")
        for idx, pattern in enumerate(require_output_regexes):
            try:
                matched = re.search(pattern, transcript, flags=re.MULTILINE) is not None
            except re.error as exc:
                issues.append(f"required_output_regex_invalid:{idx}:{type(exc).__name__}:{exc}")
                continue
            if not matched:
                pattern_hash = hashlib.sha256(pattern.encode("utf-8", "replace")).hexdigest()[:12]
                issues.append(f"required_output_regex_missing:{idx}:{pattern_hash}")

    try:
        cwd_resolved = cwd.resolve()
        workspace_resolved = workspace.resolve()
        if cwd_resolved != workspace_resolved:
            issues.append(f"cwd_mismatch:{cwd_resolved}")
    except Exception:
        issues.append("cwd_unresolvable")

    git = record.get("git") if isinstance(record.get("git"), dict) else {}
    current = current_git(workspace)
    if not record.get("runnerSha256"):
        issues.append("runner_identity_missing")
    if not record.get("commandSha256") or not record.get("argvSha256"):
        issues.append("command_identity_missing")
    if git:
        if is_git_workspace(workspace) and not git.get("head"):
            issues.append("git_head_missing")
        if git.get("head") and current.get("head") and git.get("head") != current.get("head"):
            issues.append("git_head_stale")
        if git.get("statusSha256") != current.get("statusSha256"):
            issues.append("git_status_stale")
    else:
        issues.append("git_metadata_missing")

    assertions = record.get("assertions")
    passed_assertions = 0
    passed_action_effect_assertions = 0
    if isinstance(assertions, list):
        for idx, assertion in enumerate(assertions):
            if isinstance(assertion, dict):
                if assertion.get("passed") is False:
                    issues.append(f"assertion_failed:{idx}")
                elif assertion.get("passed") is True:
                    passed_assertions += 1
                    if str(assertion.get("type", "")).startswith("scenario_"):
                        passed_action_effect_assertions += 1
    if require_assertions and passed_assertions == 0:
        issues.append("passed_assertion_required")

    scenario = record.get("scenario") if isinstance(record.get("scenario"), dict) else {}
    action_count = safe_nonnegative_int(scenario.get("actionCount"), "action_count", issues) if scenario else 0
    if require_action_effect and action_count == 0:
        issues.append("action_effect_required")
    if require_action_effect and passed_action_effect_assertions == 0:
        issues.append("action_effect_assertion_required")

    summary = {
        "path": str(path),
        "status": status,
        "schema": schema,
        "cwd": str(cwd),
        "transcriptPath": str(transcript_path),
        "actualTranscriptBytes": actual_transcript_bytes,
        "issues": issues,
        "assertionCount": len(assertions) if isinstance(assertions, list) else 0,
        "passedAssertionCount": passed_assertions,
        "passedActionEffectAssertionCount": passed_action_effect_assertions,
        "actionCount": action_count,
    }
    return not issues, issues, summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True, help="Workspace the evidence must belong to.")
    parser.add_argument("--evidence", action="append", default=[], help="Evidence JSON path. May be repeated.")
    parser.add_argument("--require-real-run", action="store_true", help="Require objective-relevant run/smoke evidence.")
    parser.add_argument("--allow-timeout", action="store_true", help="Allow TIMEOUT as an observation for long-lived software.")
    parser.add_argument("--require-assertions", action="store_true", help="Require at least one passed evidence-runner assertion.")
    parser.add_argument("--min-transcript-bytes", type=int, default=0, help="Require transcript to be at least this many bytes.")
    parser.add_argument("--require-output-regex", action="append", default=[], help="Require the transcript to match this regex. May be repeated.")
    parser.add_argument("--require-action-effect", action="store_true", help="Require scenario/user input actions in the evidence record.")
    parser.add_argument("--result-output", default="", help="Optional path for durable gate result JSON.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable result.")
    args = parser.parse_args()
    if not args.evidence:
        parser.error("--evidence is required")
    if args.min_transcript_bytes < 0:
        parser.error("--min-transcript-bytes must be >= 0")
    return args


def main() -> int:
    args = parse_args()
    workspace = Path(args.workspace).expanduser().resolve()
    if not workspace.is_dir():
        print("EVIDENCE_GATE_RESULT: FAIL workspace_missing", file=sys.stderr)
        return 2

    summaries: list[dict[str, Any]] = []
    all_issues: list[str] = []
    for item in args.evidence:
        path = Path(item).expanduser()
        ok, issues, summary = validate_one(
            path,
            workspace,
            args.require_real_run,
            args.allow_timeout,
            args.require_assertions,
            args.min_transcript_bytes,
            args.require_output_regex,
            args.require_action_effect,
        )
        summaries.append(summary)
        if not ok:
            all_issues.extend(f"{path}:{issue}" for issue in issues)

    result = "PASS" if not all_issues else "FAIL"
    payload = {
        "schema": "dad.evidence_gate.v1",
        "result": result,
        "workspace": str(workspace),
        "requireRealRun": args.require_real_run,
        "allowTimeout": args.allow_timeout,
        "requireAssertions": args.require_assertions,
        "minTranscriptBytes": args.min_transcript_bytes,
        "requiredOutputRegexCount": len(args.require_output_regex),
        "requireActionEffect": args.require_action_effect,
        "issues": all_issues,
        "evidence": summaries,
    }

    output_path = Path(args.result_output).expanduser() if args.result_output else None
    if output_path is None:
        digest_source = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256(digest_source.encode("utf-8", "replace")).hexdigest()[:16]
        day_dir = DEFAULT_GATE_ROOT / dt.datetime.now(dt.UTC).strftime("%Y%m%d")
        output_path = day_dir / f"{dt.datetime.now(dt.UTC).strftime('%H%M%S')}-gate-{digest}.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.parent.chmod(0o700)
    fd = output_path.open("w", encoding="utf-8")
    try:
        json.dump(payload, fd, indent=2, sort_keys=True)
        fd.write("\n")
    finally:
        fd.close()
    try:
        output_path.chmod(0o600)
    except OSError:
        pass

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"EVIDENCE_GATE_RESULT: {result}")
        print(f"EVIDENCE_GATE_JSON: {output_path}")
        for issue in all_issues:
            print(f"EVIDENCE_GATE_ISSUE: {issue}")

    return 0 if result == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
