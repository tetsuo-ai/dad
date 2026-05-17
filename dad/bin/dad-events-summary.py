#!/usr/bin/env python3
"""Summarize DAD trajectory events for a supervisor pass."""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import subprocess
from collections import Counter
from pathlib import Path
from typing import Any

from dad_paths import events_root


DEFAULT_ROOT = events_root()


def sha256_text(text: str, length: int = 16) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:length]


def parse_ts(value: str) -> _dt.datetime | None:
    if not value:
        return None
    try:
        parsed = _dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=_dt.timezone.utc)
        return parsed
    except ValueError:
        return None


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    if not path.exists():
        return events
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
                if isinstance(item, dict):
                    events.append(item)
            except json.JSONDecodeError:
                continue
    return events


def event_files_for_args(root: Path, args: argparse.Namespace) -> list[Path]:
    files: list[Path] = []
    if args.session_id:
        safe_session = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in args.session_id)[:96]
        files.append(root / "sessions" / f"{safe_session}.jsonl")
    elif args.cwd_hash:
        files.append(root / "cwd" / f"{args.cwd_hash}.jsonl")
    elif args.cwd:
        files.append(root / "cwd" / f"{sha256_text(args.cwd, 16)}.jsonl")
    else:
        files.append(root / "all-events.jsonl")

    if args.tmux_window:
        window = args.tmux_window.lstrip("@")
        files.extend(sorted(root.glob(f"*-{window}-*.son-events.jsonl")))
        files.extend(sorted(root.glob(f"*-{window}-*.idle-events.jsonl")))
        files.append(root / f"{window}.son-events.jsonl")
        files.append(root / f"{window}.idle-events.jsonl")
    return list(dict.fromkeys(files))


def truncate(value: str, limit: int) -> str:
    value = value.replace("\r", "").replace("\n", "\\n")
    if len(value) > limit:
        return value[:limit] + "...[truncated]"
    return value


def unique_recent(values: list[str], limit: int) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in reversed(values):
        if not value or value in seen:
            continue
        seen.add(value)
        result.append(value)
        if len(result) >= limit:
            break
    return list(reversed(result))


def summarize(events: list[dict[str, Any]], limit: int) -> dict[str, Any]:
    events = events[-limit:]
    event_counts = Counter(str(item.get("event") or item.get("action") or f"son_{item.get('state', 'unknown')}") for item in events)
    status_counts = Counter(str(item.get("status") or item.get("state") or item.get("action") or "unknown") for item in events)
    tool_counts = Counter(str(item.get("tool", "") or "(none)") for item in events)

    failures: list[dict[str, str]] = []
    commands: list[str] = []
    path_refs: list[str] = []
    evidence_refs: list[str] = []
    lifecycle: list[str] = []

    for item in events:
        event_name = str(item.get("event") or item.get("action") or f"son_{item.get('state', 'unknown')}")
        status = str(item.get("status") or item.get("state") or item.get("action") or "")
        tool = str(item.get("tool", ""))
        tool_input = item.get("tool_input") if isinstance(item.get("tool_input"), dict) else {}
        if isinstance(tool_input, dict):
            command = tool_input.get("command_preview") or tool_input.get("command_kind")
            if isinstance(command, str):
                commands.append(command)
            refs = tool_input.get("path_refs")
            if isinstance(refs, list):
                path_refs.extend(str(ref) for ref in refs)
        refs = item.get("evidence_refs")
        if isinstance(refs, list):
            evidence_refs.extend(str(ref) for ref in refs)
        if status == "failure" or "failure" in event_name.lower():
            failures.append(
                {
                    "ts": str(item.get("ts", "")),
                    "event": event_name,
                    "tool": tool,
                    "error": truncate(str(item.get("error", "")), 300),
                }
            )
        if item.get("reason") and ("failed" in event_name.lower() or str(item.get("state", "")) == "claim"):
            failures.append(
                {
                    "ts": str(item.get("ts", "")),
                    "event": event_name,
                    "tool": tool,
                    "error": truncate(str(item.get("reason", "")), 300),
                }
            )
        if event_name.lower() in {
            "stop",
            "sessionend",
            "session_end",
            "precompact",
            "pre_compact",
            "userpromptsubmit",
            "user_prompt_submit",
        }:
            lifecycle.append(f"{item.get('ts', '')} {event_name} {item.get('stop_reason', '')}".strip())

    last_stop_idx = -1
    for idx, item in enumerate(events):
        if str(item.get("event", "")).lower() in {"stop", "sessionend", "session_end"}:
            last_stop_idx = idx
    if last_stop_idx >= 0:
        start = 0
        for idx in range(last_stop_idx, -1, -1):
            if str(events[idx].get("event", "")).lower() in {"userpromptsubmit", "user_prompt_submit"}:
                start = idx
                break
        segment = events[start : last_stop_idx + 1]
    else:
        segment = events[-20:]

    fingerprint_source = "|".join(str(item.get("fingerprint", "")) for item in segment if item.get("fingerprint"))
    turn_fingerprint = sha256_text(fingerprint_source, 24) if fingerprint_source else ""

    return {
        "event_count": len(events),
        "first_ts": events[0].get("ts", "") if events else "",
        "last_ts": events[-1].get("ts", "") if events else "",
        "last_event": events[-1] if events else None,
        "event_counts": dict(event_counts),
        "status_counts": dict(status_counts),
        "tool_counts": dict(tool_counts),
        "recent_commands": [truncate(cmd, 240) for cmd in unique_recent(commands, 6)],
        "recent_path_refs": unique_recent(path_refs, 12),
        "recent_evidence_refs": unique_recent(evidence_refs, 8),
        "recent_failures": failures[-6:],
        "recent_lifecycle": lifecycle[-8:],
        "turn_fingerprint": turn_fingerprint,
    }


def format_text(summary: dict[str, Any]) -> str:
    lines = [
        f"DAD event trace: {summary['event_count']} events",
        f"time: {summary.get('first_ts') or 'unknown'} -> {summary.get('last_ts') or 'unknown'}",
        f"turn_fingerprint: {summary.get('turn_fingerprint') or 'none'}",
    ]
    if summary.get("tool_counts"):
        tools = ", ".join(f"{key}:{value}" for key, value in sorted(summary["tool_counts"].items()))
        lines.append(f"tools: {tools}")
    if summary.get("recent_failures"):
        lines.append("recent_failures:")
        for failure in summary["recent_failures"]:
            lines.append(
                f"- {failure.get('ts')} {failure.get('tool') or failure.get('event')}: "
                f"{failure.get('error') or 'failure'}"
            )
    if summary.get("recent_evidence_refs"):
        lines.append("recent_evidence_refs:")
        for ref in summary["recent_evidence_refs"]:
            lines.append(f"- {ref}")
    if summary.get("recent_commands"):
        lines.append("recent_commands:")
        for command in summary["recent_commands"]:
            lines.append(f"- {command}")
    if summary.get("recent_lifecycle"):
        lines.append("recent_lifecycle:")
        for item in summary["recent_lifecycle"]:
            lines.append(f"- {item}")
    return "\n".join(lines)


def set_tmux_metadata(socket: str, window_id: str, summary: dict[str, Any], text: str) -> None:
    pairs = {
        "@dad_event_trace_last_seen_at": str(summary.get("last_ts", "")),
        "@dad_event_trace_last_turn_fingerprint": str(summary.get("turn_fingerprint", "")),
        "@dad_event_trace_evidence_refs": truncate(", ".join(summary.get("recent_evidence_refs", [])), 900),
        "@dad_event_trace_recent_failures": truncate(
            "; ".join(
                f"{failure.get('tool') or failure.get('event')}:{failure.get('error')}"
                for failure in summary.get("recent_failures", [])
            ),
            900,
        ),
        "@dad_event_trace_last_summary": truncate(text, 1200),
    }
    for key, value in pairs.items():
        subprocess.run(
            ["tmux", "-S", socket, "set-window-option", "-t", window_id, key, value],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-root", default=str(DEFAULT_ROOT))
    parser.add_argument("--session-id", default="")
    parser.add_argument("--cwd", default="")
    parser.add_argument("--cwd-hash", default="")
    parser.add_argument("--tmux-window", default="")
    parser.add_argument("--tmux-pane", default="")
    parser.add_argument("--since-minutes", type=int, default=0)
    parser.add_argument("--limit", type=int, default=200)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--tmux-socket", default="")
    parser.add_argument("--window-id", default="")
    args = parser.parse_args()

    root = Path(args.event_root).expanduser()
    events: list[dict[str, Any]] = []
    for event_file in event_files_for_args(root, args):
        events.extend(read_jsonl(event_file))
    events.sort(key=lambda item: str(item.get("ts", "")))
    if args.tmux_window:
        events = [
            item
            for item in events
            if (
                isinstance(item.get("tmux"), dict)
                and str(item["tmux"].get("window_id", "")) == args.tmux_window
            )
            or str(item.get("window", "")) == args.tmux_window
        ]
    if args.tmux_pane:
        events = [
            item
            for item in events
            if (
                isinstance(item.get("tmux"), dict)
                and str(item["tmux"].get("pane", "")) == args.tmux_pane
            )
            or str(item.get("pane", "")) == args.tmux_pane
            or str(item.get("sonPane", "")) == args.tmux_pane
            or str(item.get("dadPane", "")) == args.tmux_pane
        ]
    if args.since_minutes > 0:
        cutoff = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(minutes=args.since_minutes)
        events = [
            item
            for item in events
            if (parsed := parse_ts(str(item.get("ts", "")))) is not None and parsed >= cutoff
        ]
    summary = summarize(events, args.limit)
    text = format_text(summary)

    if args.tmux_socket and args.window_id:
        set_tmux_metadata(args.tmux_socket, args.window_id, summary, text)

    if args.json:
        print(json.dumps(summary, indent=2, sort_keys=True, ensure_ascii=True))
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
