#!/usr/bin/env python3
"""Normalize Grok hook events into DAD-readable trajectory JSONL.

This hook is intentionally passive. It never blocks, never sends input, never
manages tmux, and never runs project commands. Its only job is to preserve a
small structured trace that Dad can later audit before trusting Son claims.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from dad_paths import events_root


SCHEMA = "dad-event/v1"
DEFAULT_ROOT = events_root()
SECRET_KEY_RE = re.compile(
    r"(secret|token|password|passwd|authorization|api[_-]?key|private[_-]?key|credential|bearer)",
    re.IGNORECASE,
)
SECRET_VALUE_RE = re.compile(
    r"(?i)\b([A-Z0-9_]*(?:api[_-]?key|token|secret|password|passwd|authorization|private[_-]?key|credential)[A-Z0-9_]*)\b\s*[:=]\s*['\"]?[^'\"\s]+"
)
BEARER_RE = re.compile(r"(?i)\b(Bearer)\s+[A-Za-z0-9._~+/=-]+")
URL_CREDENTIAL_RE = re.compile(r"([a-z][a-z0-9+.-]*://)([^/\s:@]+):([^/\s@]+)@")
PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)
HIGH_ENTROPY_TOKEN_RE = re.compile(
    r"\b(?=[A-Za-z0-9._~+/=-]{32,}\b)"
    r"(?=[A-Za-z0-9._~+/=-]*[A-Z])"
    r"(?=[A-Za-z0-9._~+/=-]*[a-z])"
    r"(?=[A-Za-z0-9._~+/=-]*[0-9])"
    r"[A-Za-z0-9._~+/=-]{32,}\b"
)
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
EVIDENCE_MARKER_RE = re.compile(
    r"\b(?:EVIDENCE_JSON|EVIDENCE_LOG)\s*[:=]\s*([^ \t\r\n'\"`\\]+)"
)
EVIDENCE_PATH_RE = re.compile(
    r"((?:~|/)[^ \t\r\n'\"`\\]*?/evidence/[^ \t\r\n'\"`\\]+)"
)


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, default=str)


def sha256_text(text: str, length: int = 16) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:length]


def safe_filename(value: str, fallback: str) -> str:
    value = value.strip() or fallback
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", value)
    return safe[:96] or fallback


def scrub_text(text: str, limit: int = 500) -> str:
    text = ANSI_RE.sub("", text)
    text = PRIVATE_KEY_RE.sub("[redacted-private-key]", text)
    text = URL_CREDENTIAL_RE.sub(r"\1[redacted]:[redacted]@", text)
    text = BEARER_RE.sub(r"\1 [redacted]", text)
    text = SECRET_VALUE_RE.sub(lambda m: f"{m.group(1)}=[redacted]", text)
    text = HIGH_ENTROPY_TOKEN_RE.sub("[redacted-high-entropy-token]", text)
    text = text.replace("\r", "")
    if len(text) > limit:
        return text[:limit] + "...[truncated]"
    return text


def scrub_evidence_ref(text: str, limit: int = 300) -> str:
    text = ANSI_RE.sub("", text)
    text = URL_CREDENTIAL_RE.sub(r"\1[redacted]:[redacted]@", text)
    text = SECRET_VALUE_RE.sub(lambda m: f"{m.group(1)}=[redacted]", text)
    text = text.replace("\r", "")
    if len(text) > limit:
        return text[:limit] + "...[truncated]"
    return text


def scrub_value(value: Any) -> Any:
    if isinstance(value, str):
        return scrub_text(value, 1000)
    if isinstance(value, dict):
        cleaned: dict[str, Any] = {}
        for key, item in value.items():
            key_text = str(key)
            if SECRET_KEY_RE.search(key_text):
                cleaned[key_text] = "[redacted]"
            else:
                cleaned[key_text] = scrub_value(item)
        return cleaned
    if isinstance(value, list):
        return [scrub_value(item) for item in value[:200]]
    return value


def value_digest(value: Any) -> str:
    return sha256_text(canonical_json(value), 24)


def collect_strings(value: Any, out: list[str], max_items: int = 80) -> None:
    if len(out) >= max_items:
        return
    if isinstance(value, str):
        out.append(value)
        return
    if isinstance(value, dict):
        for item in value.values():
            collect_strings(item, out, max_items)
            if len(out) >= max_items:
                return
    elif isinstance(value, list):
        for item in value:
            collect_strings(item, out, max_items)
            if len(out) >= max_items:
                return


def extract_evidence_refs(raw_text: str, event: dict[str, Any]) -> list[str]:
    strings: list[str] = [raw_text]
    collect_strings(event, strings)
    refs: set[str] = set()
    for text in strings:
        for pattern in (EVIDENCE_MARKER_RE, EVIDENCE_PATH_RE):
            for match in pattern.finditer(text):
                refs.add(scrub_evidence_ref(match.group(1).rstrip(".,;:)]}"), 300))
    return sorted(refs)


def summarize_path_values(value: Any, limit: int = 16) -> list[str]:
    paths: list[str] = []

    def walk(key: str, node: Any) -> None:
        if len(paths) >= limit:
            return
        key_l = key.lower()
        if isinstance(node, str):
            if any(marker in key_l for marker in ("path", "file", "cwd", "dir", "root")):
                paths.append(scrub_text(node, 300))
            return
        if isinstance(node, dict):
            for child_key, child in node.items():
                walk(str(child_key), child)
                if len(paths) >= limit:
                    return
        elif isinstance(node, list):
            for child in node:
                walk(key, child)
                if len(paths) >= limit:
                    return

    walk("", value)
    return paths


def find_first_string(value: Any, keys: tuple[str, ...]) -> str:
    if not isinstance(value, dict):
        return ""
    for key in keys:
        candidate = value.get(key)
        if isinstance(candidate, str):
            return candidate
    for child in value.values():
        if isinstance(child, dict):
            found = find_first_string(child, keys)
            if found:
                return found
    return ""


def summarize_tool_input(tool_input: Any) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "sha256": value_digest(tool_input),
        "type": type(tool_input).__name__,
    }
    if isinstance(tool_input, dict):
        summary["keys"] = sorted(str(key) for key in tool_input.keys())[:40]
        command = find_first_string(tool_input, ("command", "cmd", "script", "shell_command"))
        if command:
            command_words = command.strip().split()
            if command_words:
                summary["command_kind"] = scrub_text(command_words[0], 80)
            if os.environ.get("DAD_EVENT_INCLUDE_COMMAND_PREVIEW") == "1":
                summary["command_preview"] = scrub_text(command, 500)
            summary["command_sha256"] = sha256_text(command, 24)
        paths = summarize_path_values(tool_input)
        if paths:
            summary["path_refs"] = paths
        for key in ("background", "is_background", "timeout", "timeout_ms", "cwd", "working_dir"):
            if key in tool_input and not SECRET_KEY_RE.search(key):
                value = tool_input[key]
                if isinstance(value, (str, int, float, bool)) or value is None:
                    summary[key] = scrub_text(str(value), 180) if isinstance(value, str) else value
    return summary


def extract_error(event: dict[str, Any], event_name: str) -> str:
    fields = ("error", "message", "reason", "stderr", "exception")
    for field in fields:
        value = event.get(field)
        if isinstance(value, str) and value.strip():
            return scrub_text(value, 500)
        if isinstance(value, dict):
            text = find_first_string(value, ("message", "error", "reason"))
            if text:
                return scrub_text(text, 500)
    if "failure" in event_name.lower():
        return "tool failure event"
    return ""


def infer_status(event_name: str, event: dict[str, Any]) -> str:
    lowered = event_name.lower()
    if "failure" in lowered:
        return "failure"
    if lowered == "pretooluse" or lowered == "pre_tool_use":
        return "pending"
    if lowered == "posttooluse" or lowered == "post_tool_use":
        return "completed_unknown"
    if "compact" in lowered:
        return "compact"
    if lowered in {"stop", "sessionend", "session_end"}:
        return "completed"
    explicit = event.get("status") or event.get("result")
    if isinstance(explicit, str) and explicit:
        return scrub_text(explicit, 80)
    return "observed"


def tmux_context() -> dict[str, str]:
    pane = os.environ.get("TMUX_PANE", "")
    tmux_value = os.environ.get("TMUX", "")
    socket = tmux_value.split(",", 1)[0] if tmux_value else ""
    context = {
        "pane": pane,
        "socket_tuple": tmux_value,
        "socket": socket,
        "window_id": "",
        "window_name": "",
        "dad_state": "",
        "dad_window_id": "",
    }
    if not pane or not socket:
      return context
    try:
        window_id = subprocess.run(
            ["tmux", "-S", socket, "display-message", "-p", "-t", pane, "#{window_id}"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=0.2,
            check=False,
        ).stdout.strip()
        window_name = subprocess.run(
            ["tmux", "-S", socket, "display-message", "-p", "-t", pane, "#{window_name}"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=0.2,
            check=False,
        ).stdout.strip()
        dad_state = subprocess.run(
            ["tmux", "-S", socket, "show-window-option", "-v", "-t", window_id, "@dad_state"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=0.2,
            check=False,
        ).stdout.strip()
        dad_window_id = subprocess.run(
            ["tmux", "-S", socket, "show-window-option", "-v", "-t", window_id, "@dad_window_id"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=0.2,
            check=False,
        ).stdout.strip()
        context.update(
            {
                "window_id": window_id,
                "window_name": window_name,
                "dad_state": dad_state,
                "dad_window_id": dad_window_id,
            }
        )
    except Exception:
        pass
    return context


def should_record_context(context: dict[str, str]) -> bool:
    if os.environ.get("DAD_EVENT_CAPTURE_NON_DAD") == "1":
        return True
    if os.environ.get("DAD_EVENT_FORCE") == "1":
        return True
    if context.get("dad_state") or context.get("dad_window_id"):
        return True
    if context.get("window_name", "").startswith("DAD-"):
        return True
    return False


def normalize_event(raw_text: str) -> dict[str, Any]:
    try:
        event = json.loads(raw_text or "{}")
        if not isinstance(event, dict):
            event = {"payload": event}
    except json.JSONDecodeError as exc:
        event = {"parse_error": str(exc), "payload_sha256": sha256_text(raw_text, 24)}

    env_event = os.environ.get("GROK_HOOK_EVENT", "")
    event_name = str(event.get("hookEventName") or env_event or "unknown")
    session_id = str(event.get("sessionId") or os.environ.get("GROK_SESSION_ID") or "unknown")
    cwd = str(
        event.get("cwd")
        or event.get("workspaceRoot")
        or os.environ.get("GROK_WORKSPACE_ROOT")
        or os.getcwd()
    )
    workspace_root = str(event.get("workspaceRoot") or os.environ.get("GROK_WORKSPACE_ROOT") or cwd)
    tool_name = str(event.get("toolName") or event.get("tool") or "")
    timestamp = str(event.get("timestamp") or now_iso())
    tool_input = event.get("toolInput", {})

    tmux = tmux_context()
    record: dict[str, Any] = {
        "schema": SCHEMA,
        "ts": timestamp,
        "received_at": now_iso(),
        "event": event_name,
        "session_id": session_id,
        "cwd": cwd,
        "cwd_hash": sha256_text(cwd, 16),
        "workspace_root": workspace_root,
        "tool": tool_name,
        "status": infer_status(event_name, event),
        "tool_input": summarize_tool_input(tool_input),
        "evidence_refs": extract_evidence_refs(raw_text, event),
        "error": extract_error(event, event_name),
        "raw_event_sha256": sha256_text(raw_text, 24),
        "tmux": tmux,
    }

    stop_reason = event.get("stopReason") or event.get("reason")
    if isinstance(stop_reason, str) and stop_reason:
        record["stop_reason"] = scrub_text(stop_reason, 160)

    prompt = event.get("prompt") or event.get("userPrompt") or event.get("text")
    if isinstance(prompt, str) and prompt:
        record["prompt"] = {
            "sha256": sha256_text(prompt, 24),
            "chars": len(prompt),
        }
        if os.environ.get("DAD_EVENT_INCLUDE_TEXT") == "1":
            record["prompt"]["preview"] = scrub_text(prompt, 500)

    if os.environ.get("DAD_EVENT_STORE_RAW") == "1":
        record["raw_event"] = scrub_value(event)

    fingerprint_payload = {key: value for key, value in record.items() if key != "received_at"}
    record["fingerprint"] = sha256_text(canonical_json(fingerprint_payload), 24)
    return record


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    line = canonical_json(record) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as handle:
        handle.write(line)


def write_health(root: Path, status: str, detail: str = "") -> None:
    health = {
        "schema": "dad-event-hook-health/v1",
        "status": status,
        "detail": scrub_text(detail, 500),
        "ts": now_iso(),
    }
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    fd = os.open(root / "hook-health.json", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(canonical_json(health) + "\n")


def set_tmux_hook_health(record: dict[str, Any], status: str, detail: str = "") -> None:
    tmux = record.get("tmux") if isinstance(record.get("tmux"), dict) else {}
    socket = str(tmux.get("socket", ""))
    window_id = str(tmux.get("window_id", ""))
    if not socket or not window_id:
        return
    pairs = {
        "@dad_event_hook_status": status,
        "@dad_event_hook_last_seen_at": now_iso(),
        "@dad_event_hook_last_detail": scrub_text(detail, 300),
    }
    for key, value in pairs.items():
        subprocess.run(
            ["tmux", "-S", socket, "set-window-option", "-t", window_id, key, value],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=0.2,
            check=False,
        )


def write_index(path: Path, cwd_hash: str, cwd: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    existing = ""
    if path.exists():
        existing = path.read_text(encoding="utf-8", errors="replace")
        if f"{cwd_hash}\t" in existing:
            return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as handle:
        handle.write(f"{cwd_hash}\t{cwd}\n")


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--event-root", default=os.environ.get("DAD_EVENT_ROOT", str(DEFAULT_ROOT)))
    args, _ = parser.parse_known_args()

    try:
        raw_text = sys.stdin.read()
        record = normalize_event(raw_text)
        root = Path(args.event_root).expanduser()
        if not should_record_context(record.get("tmux", {}) if isinstance(record.get("tmux"), dict) else {}):
            if os.environ.get("DAD_EVENT_STORE_UNSCOPED") == "1":
                append_jsonl(root / "unscoped-events.jsonl", record)
            write_health(root, "ok:unscoped")
            return 0
        session_file = root / "sessions" / f"{safe_filename(record['session_id'], 'unknown')}.jsonl"
        cwd_file = root / "cwd" / f"{record['cwd_hash']}.jsonl"

        append_jsonl(root / "all-events.jsonl", record)
        append_jsonl(session_file, record)
        append_jsonl(cwd_file, record)
        write_index(root / "cwd-index.tsv", record["cwd_hash"], record["cwd"])
        latest = root / "latest.json"
        fd = os.open(latest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(canonical_json(record) + "\n")
        write_health(root, "ok")
        set_tmux_hook_health(record, "ok")
    except Exception:
        # Hook failure must never block or perturb Grok.
        try:
            root = Path(args.event_root).expanduser()
            write_health(root, "error", repr(sys.exc_info()[1]))
            log_dir = Path.home() / ".grok" / "logs"
            log_dir.mkdir(parents=True, exist_ok=True)
            with (log_dir / "dad-event-hook.err").open("a", encoding="utf-8") as handle:
                handle.write(f"[{now_iso()}] {repr(sys.exc_info()[1])}\n")
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
