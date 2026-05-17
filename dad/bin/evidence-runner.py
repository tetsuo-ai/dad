#!/usr/bin/env python3
"""Bounded evidence runner for DAD.

Runs one declared command in an isolated subprocess/process group, captures
output, enforces a hard timeout, and writes a JSON evidence record. It does not
infer project commands or decide whether a domain-specific smoke is sufficient;
DAD/the verifier interpret the observation against the objective.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pty
import re
import select
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Sequence

from dad_paths import evidence_root


DEFAULT_TIMEOUT_SECONDS = 30.0
KILL_GRACE_SECONDS = 2.0
MAX_CAPTURE_BYTES = 262_144
DEFAULT_EVIDENCE_ROOT = evidence_root()
SAFE_ENV_KEYS = {
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "LC_ALL",
    "VIRTUAL_ENV",
    "PYENV_VERSION",
    "NODE_VERSION",
}
SECRET_VALUE_RE = re.compile(
    r"(?i)\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIAL|AUTHORIZATION)[A-Z0-9_]*)\b\s*[:=]\s*['\"]?[^'\"\s]+"
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


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat()


def safe_label(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "-" for ch in value.strip())
    cleaned = "-".join(part for part in cleaned.split("-") if part)
    return cleaned[:80] or "evidence"


def truncate_bytes(data: bytes) -> bytes:
    if len(data) <= MAX_CAPTURE_BYTES:
        return data
    notice = b"\n\n[DAD evidence-runner: output truncated]\n\n"
    marker_offsets = [
        offset
        for marker in (b"EVIDENCE_", b"ASSERT", b"Traceback", b"Error", b"ERROR", b"FAIL", b"fatal")
        if (offset := data.find(marker, MAX_CAPTURE_BYTES // 4)) != -1
    ]
    if marker_offsets:
        middle_budget = MAX_CAPTURE_BYTES // 3
        middle_center = marker_offsets[0]
        middle_start = max(0, middle_center - middle_budget // 2)
        middle = data[middle_start : middle_start + middle_budget]
        side_budget = (MAX_CAPTURE_BYTES - len(middle) - (2 * len(notice))) // 2
        return data[:side_budget] + notice + middle + notice + data[-side_budget:]
    head = data[: MAX_CAPTURE_BYTES // 2]
    tail = data[-MAX_CAPTURE_BYTES // 2 :]
    return head + notice + tail


def decode_output(data: bytes) -> str:
    return data.decode("utf-8", errors="replace")


def redact_text(text: str) -> str:
    text = PRIVATE_KEY_RE.sub("[redacted-private-key]", text)
    text = URL_CREDENTIAL_RE.sub(r"\1[redacted]:[redacted]@", text)
    text = BEARER_RE.sub(r"\1 [redacted]", text)
    text = SECRET_VALUE_RE.sub(lambda match: f"{match.group(1)}=[redacted]", text)
    text = HIGH_ENTROPY_TOKEN_RE.sub("[redacted-high-entropy-token]", text)
    return text


def write_private_text(path: Path, text: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", errors="replace") as handle:
        handle.write(text)


def write_private_json(path: Path, record: dict[str, object]) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(record, indent=2, sort_keys=True) + "\n")


def kill_process_group(proc: subprocess.Popen[bytes]) -> bool:
    try:
        pgid = os.getpgid(proc.pid)
    except ProcessLookupError:
        return False

    killed = False
    try:
        os.killpg(pgid, signal.SIGTERM)
        killed = True
    except ProcessLookupError:
        return killed

    deadline = time.monotonic() + KILL_GRACE_SECONDS
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return killed
        time.sleep(0.05)

    try:
        os.killpg(pgid, signal.SIGKILL)
        killed = True
    except ProcessLookupError:
        pass
    return killed


def command_display(cmd: Sequence[str], shell: str | None) -> str:
    if shell is not None:
        return redact_text(shell)
    return redact_text(" ".join(shlex.quote(part) for part in cmd))


def command_argv(cmd: Sequence[str], shell: str | None) -> list[str]:
    if shell is not None:
        return []
    return [redact_text(part) for part in cmd]


def status_from_returncode(returncode: int | None, timed_out: bool, spawn_error: str | None) -> str:
    if spawn_error:
        return "SPAWN_ERROR"
    if timed_out:
        return "TIMEOUT"
    if returncode == 0:
        return "EXIT_ZERO"
    if returncode is not None and returncode < 0:
        return f"SIGNAL_{abs(returncode)}"
    return "EXIT_NONZERO"


def build_env(inherit_env: bool, env_overrides: Sequence[str]) -> tuple[dict[str, str], str]:
    if inherit_env:
        env = os.environ.copy()
        mode = "inherited"
    else:
        env = {key: value for key, value in os.environ.items() if key in SAFE_ENV_KEYS or key.startswith("LC_")}
        mode = "allowlist"

    env.setdefault("TERM", "xterm-256color")
    env.setdefault("COLUMNS", "120")
    env.setdefault("LINES", "40")

    for item in env_overrides:
        if "=" not in item:
            raise ValueError(f"--env requires KEY=VALUE, got {item!r}")
        key, value = item.split("=", 1)
        if not key or "\0" in key:
            raise ValueError(f"invalid env key {key!r}")
        env[key] = value
    return env, mode


def run_git(cwd: Path, args: Sequence[str]) -> str:
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


def git_metadata(cwd: Path) -> dict[str, object]:
    head = run_git(cwd, ["rev-parse", "HEAD"])
    branch = run_git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])
    status = run_git(cwd, ["status", "--porcelain=v1", "--untracked-files=all"])
    return {
        "head": head,
        "branch": branch,
        "statusSha256": hashlib.sha256(status.encode("utf-8", "replace")).hexdigest() if status else "",
        "statusLineCount": len(status.splitlines()) if status else 0,
        "dirty": bool(status),
    }


def runner_sha256() -> str:
    try:
        return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    except Exception:
        return ""


def read_json_file(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception as exc:
        raise ValueError(f"failed to read scenario {path}: {type(exc).__name__}: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"scenario must be a JSON object: {path}")
    return data


def scenario_bool(scenario: dict[str, Any], key: str) -> bool | None:
    if key not in scenario:
        return None
    value = scenario[key]
    if not isinstance(value, bool):
        raise ValueError(f"scenario field {key} must be a boolean")
    return value


def scenario_float(value: Any, field: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be a number") from exc


def scenario_int(value: Any, field: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be an integer") from exc


def evaluate_assertions(
    *,
    status: str,
    returncode: int | None,
    transcript: str,
    expect_exit: int | None,
    expect_output: str,
) -> tuple[str, list[dict[str, object]]]:
    assertions: list[dict[str, object]] = []
    final_status = status

    if expect_exit is not None:
        passed = returncode == expect_exit
        assertions.append(
            {
                "type": "exit_code",
                "expected": expect_exit,
                "actual": returncode,
                "passed": passed,
            }
        )
        if not passed:
            final_status = "ASSERTION_FAILED"
        elif status == "EXIT_NONZERO":
            final_status = "EXIT_EXPECTED"

    if expect_output:
        try:
            passed = re.search(expect_output, transcript, flags=re.MULTILINE) is not None
            error = ""
        except re.error as exc:
            passed = False
            error = f"{type(exc).__name__}: {exc}"
        assertions.append(
            {
                "type": "output_regex",
                "expectedSha256": hashlib.sha256(expect_output.encode("utf-8", "replace")).hexdigest(),
                "passed": passed,
                "error": error,
            }
        )
        if not passed:
            final_status = "ASSERTION_FAILED"

    return final_status, assertions


def run_pipe(
    cmd: Sequence[str],
    *,
    cwd: Path,
    timeout_seconds: float,
    shell: str | None,
    env: dict[str, str],
) -> tuple[bytes, int | None, bool, bool, str | None]:
    proc: subprocess.Popen[bytes] | None = None
    output = bytearray()
    timed_out = False
    killed = False
    spawn_error = None

    try:
        proc = subprocess.Popen(
            shell if shell is not None else list(cmd),
            cwd=str(cwd),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            shell=shell is not None,
            preexec_fn=os.setsid,
        )
    except Exception as exc:  # noqa: BLE001 - must capture spawn failures as evidence.
        return b"", None, False, False, f"{type(exc).__name__}: {exc}"

    assert proc.stdout is not None
    fd = proc.stdout.fileno()
    deadline = time.monotonic() + timeout_seconds

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = proc.poll() is None
            if timed_out:
                killed = kill_process_group(proc)
            break

        ready, _, _ = select.select([fd], [], [], min(0.1, remaining))
        if ready:
            chunk = os.read(fd, 8192)
            if chunk:
                output.extend(chunk)
                if len(output) > MAX_CAPTURE_BYTES * 2:
                    output[:] = truncate_bytes(bytes(output))
            elif proc.poll() is not None:
                break
        elif proc.poll() is not None:
            rest = proc.stdout.read() or b""
            output.extend(rest)
            break

    return truncate_bytes(bytes(output)), proc.poll(), timed_out, killed, spawn_error


def run_pty(
    cmd: Sequence[str],
    *,
    cwd: Path,
    timeout_seconds: float,
    shell: str | None,
    env: dict[str, str],
) -> tuple[bytes, int | None, bool, bool, str | None]:
    output = bytearray()
    timed_out = False
    killed = False
    spawn_error = None
    master_fd: int | None = None
    slave_fd: int | None = None
    proc: subprocess.Popen[bytes] | None = None

    try:
        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            shell if shell is not None else list(cmd),
            cwd=str(cwd),
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            shell=shell is not None,
            preexec_fn=os.setsid,
            close_fds=True,
        )
        os.close(slave_fd)
        slave_fd = None
    except Exception as exc:  # noqa: BLE001 - must capture spawn failures as evidence.
        if master_fd is not None:
            os.close(master_fd)
        if slave_fd is not None:
            os.close(slave_fd)
        return b"", None, False, False, f"{type(exc).__name__}: {exc}"

    deadline = time.monotonic() + timeout_seconds
    assert master_fd is not None

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = proc.poll() is None
            if timed_out:
                killed = kill_process_group(proc)
            break

        ready, _, _ = select.select([master_fd], [], [], min(0.1, remaining))
        if ready:
            try:
                chunk = os.read(master_fd, 8192)
            except OSError:
                chunk = b""
            if chunk:
                output.extend(chunk)
                if len(output) > MAX_CAPTURE_BYTES * 2:
                    output[:] = truncate_bytes(bytes(output))
            elif proc.poll() is not None:
                break
        elif proc.poll() is not None:
            break

    os.close(master_fd)
    return truncate_bytes(bytes(output)), proc.poll(), timed_out, killed, spawn_error


def drain_pty(master_fd: int, output: bytearray, proc: subprocess.Popen[bytes], *, until: float) -> None:
    while time.monotonic() < until:
        timeout = max(0.0, min(0.05, until - time.monotonic()))
        ready, _, _ = select.select([master_fd], [], [], timeout)
        if ready:
            try:
                chunk = os.read(master_fd, 8192)
            except OSError:
                chunk = b""
            if chunk:
                output.extend(chunk)
                if len(output) > MAX_CAPTURE_BYTES * 2:
                    output[:] = truncate_bytes(bytes(output))
                continue
        if proc.poll() is not None and not ready:
            break


def run_pty_scenario(
    cmd: Sequence[str],
    *,
    cwd: Path,
    timeout_seconds: float,
    shell: str | None,
    env: dict[str, str],
    steps: Sequence[dict[str, Any]],
) -> tuple[bytes, int | None, bool, bool, str | None, list[dict[str, object]], list[dict[str, object]]]:
    output = bytearray()
    assertions: list[dict[str, object]] = []
    actions: list[dict[str, object]] = []
    timed_out = False
    killed = False
    spawn_error = None
    master_fd: int | None = None
    slave_fd: int | None = None
    proc: subprocess.Popen[bytes] | None = None

    try:
        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            shell if shell is not None else list(cmd),
            cwd=str(cwd),
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            shell=shell is not None,
            preexec_fn=os.setsid,
            close_fds=True,
        )
        os.close(slave_fd)
        slave_fd = None
    except Exception as exc:  # noqa: BLE001 - must capture spawn failures as evidence.
        if master_fd is not None:
            os.close(master_fd)
        if slave_fd is not None:
            os.close(slave_fd)
        return b"", None, False, False, f"{type(exc).__name__}: {exc}", assertions, actions

    assert master_fd is not None
    assert proc is not None
    deadline = time.monotonic() + timeout_seconds

    for idx, step in enumerate(steps):
        if time.monotonic() >= deadline:
            break
        if not isinstance(step, dict):
            assertions.append({"type": "scenario_step", "index": idx, "passed": False, "error": "step_not_object"})
            continue

        if "wait" in step or "sleep" in step:
            try:
                seconds = scenario_float(step.get("wait", step.get("sleep", 0)), f"steps[{idx}].wait")
            except ValueError as exc:
                assertions.append({"type": "scenario_step", "index": idx, "passed": False, "error": str(exc)})
                continue
            drain_pty(master_fd, output, proc, until=min(deadline, time.monotonic() + max(0.0, seconds)))

        if "send" in step:
            text = str(step.get("send", ""))
            os.write(master_fd, text.encode("utf-8", errors="replace"))
            actions.append(
                {
                    "type": "send",
                    "index": idx,
                    "textSha256": hashlib.sha256(text.encode("utf-8", "replace")).hexdigest(),
                    "textPreview": redact_text(text[:120]),
                }
            )
            drain_pty(master_fd, output, proc, until=min(deadline, time.monotonic() + 0.05))

        if "expect" in step:
            expect = step.get("expect")
            if isinstance(expect, dict):
                pattern = str(expect.get("regex", ""))
                label = str(expect.get("label", f"expect[{idx}]"))
                raw_timeout = expect.get("timeout", step.get("timeout", 2.0))
            else:
                pattern = str(expect)
                label = f"expect[{idx}]"
                raw_timeout = step.get("timeout", 2.0)
            error = ""
            passed = False
            try:
                step_timeout = scenario_float(raw_timeout, f"steps[{idx}].timeout")
                compiled = re.compile(pattern, flags=re.MULTILINE)
                until = min(deadline, time.monotonic() + max(0.0, step_timeout))
                while time.monotonic() < until:
                    transcript = redact_text(decode_output(bytes(output)))
                    if compiled.search(transcript):
                        passed = True
                        break
                    drain_pty(master_fd, output, proc, until=min(until, time.monotonic() + 0.05))
                    if proc.poll() is not None:
                        transcript = redact_text(decode_output(bytes(output)))
                        if compiled.search(transcript):
                            passed = True
                        break
            except (ValueError, re.error) as exc:
                error = f"{type(exc).__name__}: {exc}"
            assertions.append(
                {
                    "type": "scenario_output_regex",
                    "label": label,
                    "expectedSha256": hashlib.sha256(pattern.encode("utf-8", "replace")).hexdigest(),
                    "passed": passed,
                    "error": error,
                }
            )

        if "expectAbsent" in step:
            pattern = str(step.get("expectAbsent", ""))
            try:
                wait_seconds = scenario_float(step.get("timeout", step.get("wait", 0.5)), f"steps[{idx}].timeout")
            except ValueError as exc:
                assertions.append(
                    {
                        "type": "scenario_output_absent",
                        "expectedAbsentSha256": hashlib.sha256(pattern.encode("utf-8", "replace")).hexdigest(),
                        "passed": False,
                        "error": str(exc),
                    }
                )
                continue
            drain_pty(master_fd, output, proc, until=min(deadline, time.monotonic() + max(0.0, wait_seconds)))
            error = ""
            try:
                passed = re.search(pattern, redact_text(decode_output(bytes(output))), flags=re.MULTILINE) is None
            except re.error as exc:
                passed = False
                error = f"{type(exc).__name__}: {exc}"
            assertions.append(
                {
                    "type": "scenario_output_absent",
                    "expectedAbsentSha256": hashlib.sha256(pattern.encode("utf-8", "replace")).hexdigest(),
                    "passed": passed,
                    "error": error,
                }
            )

    while time.monotonic() < deadline and proc.poll() is None:
        drain_pty(master_fd, output, proc, until=min(deadline, time.monotonic() + 0.1))

    if proc.poll() is None:
        timed_out = True
        killed = kill_process_group(proc)

    try:
        drain_pty(master_fd, output, proc, until=time.monotonic() + 0.1)
    finally:
        os.close(master_fd)

    return truncate_bytes(bytes(output)), proc.poll(), timed_out, killed, spawn_error, assertions, actions


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run one bounded command and write a DAD evidence JSON record.",
        usage="%(prog)s [options] -- <command> [args...]",
    )
    parser.add_argument("--cwd", default=os.getcwd(), help="Workspace to run in.")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS, help="Hard timeout in seconds.")
    parser.add_argument("--label", default="evidence", help="Short evidence label for output filenames.")
    parser.add_argument("--mode", choices=("pty", "pipe"), default="pty", help="Capture mode.")
    parser.add_argument("--output-dir", default=str(DEFAULT_EVIDENCE_ROOT), help="Directory for JSON/text records.")
    parser.add_argument("--shell", help="Explicit shell command string. Mutually exclusive with command args.")
    parser.add_argument("--allow-shell", action="store_true", help="Allow --shell execution for this one run.")
    parser.add_argument("--inherit-env", action="store_true", help="Inherit the full parent environment instead of the safe allowlist.")
    parser.add_argument("--env", action="append", default=[], help="Add one environment variable as KEY=VALUE.")
    parser.add_argument("--expect-exit", type=int, default=None, help="Optional expected process exit code.")
    parser.add_argument("--expect-output", default="", help="Optional regex that must match the captured transcript.")
    parser.add_argument("--scenario", help="JSON scenario file for generic CLI/PTY action-effect evidence.")
    parser.add_argument("--timeout-ok", action="store_true", help="Return exit 0 on TIMEOUT when timeout is an expected bounded observation.")
    parser.add_argument("cmd", nargs=argparse.REMAINDER, help="Command to execute after --.")
    args = parser.parse_args()

    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.scenario and (args.shell or args.cmd):
        parser.error("--scenario cannot be combined with --shell or command args")
    if args.shell and args.cmd:
        parser.error("--shell cannot be combined with command args")
    if args.shell and not args.allow_shell and os.environ.get("DAD_EVIDENCE_ALLOW_SHELL") != "1":
        parser.error("--shell requires --allow-shell or DAD_EVIDENCE_ALLOW_SHELL=1")
    if not args.shell and not args.scenario:
        cmd = args.cmd
        if cmd and cmd[0] == "--":
            cmd = cmd[1:]
        if not cmd:
            parser.error("missing command after --")
        args.cmd = cmd

    return args


def main() -> int:
    args = parse_args()
    scenario: dict[str, Any] | None = None
    scenario_path = ""
    scenario_actions: list[dict[str, object]] = []
    scenario_assertions: list[dict[str, object]] = []
    if args.scenario:
        scenario_path = str(Path(args.scenario).expanduser().resolve())
        try:
            scenario = read_json_file(Path(scenario_path))
        except ValueError as exc:
            print(f"EVIDENCE_RESULT: SPAWN_ERROR scenario_error={exc}", file=sys.stderr)
            return 2
        allowed_scenario_keys = {
            "allowShell",
            "command",
            "cwd",
            "env",
            "expectExit",
            "expectOutput",
            "inheritEnv",
            "label",
            "mode",
            "shell",
            "steps",
            "timeoutOk",
            "timeoutSeconds",
        }
        unknown_keys = sorted(set(scenario) - allowed_scenario_keys)
        if unknown_keys:
            print(
                f"EVIDENCE_RESULT: SPAWN_ERROR scenario_unknown_keys={','.join(unknown_keys)}",
                file=sys.stderr,
            )
            return 2
        if "cwd" in scenario:
            args.cwd = str(scenario["cwd"])
        if "timeoutSeconds" in scenario:
            try:
                args.timeout = scenario_float(scenario["timeoutSeconds"], "scenario timeoutSeconds")
            except ValueError as exc:
                print(f"EVIDENCE_RESULT: SPAWN_ERROR {exc}", file=sys.stderr)
                return 2
            if args.timeout <= 0:
                print("EVIDENCE_RESULT: SPAWN_ERROR scenario_timeoutSeconds_must_be_positive", file=sys.stderr)
                return 2
        if "label" in scenario:
            args.label = str(scenario["label"])
        if "mode" in scenario:
            args.mode = str(scenario["mode"])
            if args.mode not in {"pty", "pipe"}:
                print("EVIDENCE_RESULT: SPAWN_ERROR scenario_mode_invalid", file=sys.stderr)
                return 2
        if "expectExit" in scenario:
            try:
                args.expect_exit = scenario_int(scenario["expectExit"], "scenario expectExit")
            except ValueError as exc:
                print(f"EVIDENCE_RESULT: SPAWN_ERROR {exc}", file=sys.stderr)
                return 2
        if "expectOutput" in scenario:
            args.expect_output = str(scenario["expectOutput"])
        try:
            timeout_ok = scenario_bool(scenario, "timeoutOk")
            inherit_env = scenario_bool(scenario, "inheritEnv")
            allow_shell = scenario_bool(scenario, "allowShell")
        except ValueError as exc:
            print(f"EVIDENCE_RESULT: SPAWN_ERROR {exc}", file=sys.stderr)
            return 2
        if timeout_ok is not None:
            args.timeout_ok = timeout_ok
        if inherit_env is not None:
            args.inherit_env = inherit_env
        if "env" in scenario:
            if not isinstance(scenario["env"], list) or not all(isinstance(item, str) for item in scenario["env"]):
                print("EVIDENCE_RESULT: SPAWN_ERROR scenario_env_must_be_string_array", file=sys.stderr)
                return 2
            args.env.extend(scenario["env"])

    cwd = Path(args.cwd).expanduser().resolve()
    if not cwd.is_dir():
        print(f"EVIDENCE_RESULT: SPAWN_ERROR cwd_not_found={cwd}", file=sys.stderr)
        return 2

    started_at = utc_now()
    start_monotonic = time.monotonic()
    try:
        env, env_mode = build_env(args.inherit_env, args.env)
    except ValueError as exc:
        print(f"EVIDENCE_RESULT: SPAWN_ERROR env_error={exc}", file=sys.stderr)
        return 2

    shell = args.shell
    if scenario is not None:
        if "shell" in scenario:
            if not allow_shell and os.environ.get("DAD_EVIDENCE_ALLOW_SHELL") != "1":
                print("EVIDENCE_RESULT: SPAWN_ERROR scenario_shell_requires_allowShell", file=sys.stderr)
                return 2
            shell = str(scenario["shell"])
            cmd = []
        else:
            raw_command = scenario.get("command")
            if not isinstance(raw_command, list) or not all(isinstance(part, str) for part in raw_command):
                print("EVIDENCE_RESULT: SPAWN_ERROR scenario_command_must_be_string_array", file=sys.stderr)
                return 2
            cmd = list(raw_command)
    else:
        cmd = [] if shell else list(args.cmd)
    display = command_display(cmd, shell)
    argv = command_argv(cmd, shell)
    if scenario is not None:
        raw_steps = scenario.get("steps", [])
        if not isinstance(raw_steps, list):
            print("EVIDENCE_RESULT: SPAWN_ERROR scenario_steps_must_be_array", file=sys.stderr)
            return 2
        if args.mode != "pty":
            print("EVIDENCE_RESULT: SPAWN_ERROR scenario_mode_unsupported: only pty supports steps", file=sys.stderr)
            return 2
        output, returncode, timed_out, killed, spawn_error, scenario_assertions, scenario_actions = run_pty_scenario(
            cmd,
            cwd=cwd,
            timeout_seconds=float(args.timeout),
            shell=shell,
            env=env,
            steps=raw_steps,
        )
    else:
        runner = run_pty if args.mode == "pty" else run_pipe
        output, returncode, timed_out, killed, spawn_error = runner(
            cmd,
            cwd=cwd,
            timeout_seconds=float(args.timeout),
            shell=shell,
            env=env,
        )
    ended_at = utc_now()
    duration_seconds = round(time.monotonic() - start_monotonic, 3)
    status = status_from_returncode(returncode, timed_out, spawn_error)
    raw_transcript_sha256 = hashlib.sha256(output).hexdigest()
    transcript = redact_text(decode_output(output))
    status, assertions = evaluate_assertions(
        status=status,
        returncode=returncode,
        transcript=transcript,
        expect_exit=args.expect_exit,
        expect_output=args.expect_output,
    )
    assertions = [*scenario_assertions, *assertions]
    if any(isinstance(assertion, dict) and assertion.get("passed") is False for assertion in assertions):
        status = "ASSERTION_FAILED"
    digest = hashlib.sha256((display + "\0" + transcript).encode("utf-8", errors="replace")).hexdigest()[:16]

    out_dir = Path(args.output_dir).expanduser() / dt.datetime.now().strftime("%Y%m%d")
    out_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(out_dir, 0o700)
    base = f"{dt.datetime.now().strftime('%H%M%S')}-{safe_label(args.label)}-{digest}"
    json_path = out_dir / f"{base}.json"
    text_path = out_dir / f"{base}.log"

    record = {
        "schema": "dad.evidence.v2",
        "label": args.label,
        "status": status,
        "cwd": str(cwd),
        "command": display,
        "commandSha256": hashlib.sha256(display.encode("utf-8", "replace")).hexdigest(),
        "argv": argv,
        "argvSha256": hashlib.sha256(json.dumps(argv, sort_keys=True).encode("utf-8")).hexdigest(),
        "mode": args.mode,
        "envMode": env_mode,
        "envKeys": sorted(env.keys()),
        "timeoutSeconds": args.timeout,
        "timeoutExpected": bool(args.timeout_ok),
        "timedOut": timed_out,
        "processGroupKilled": killed,
        "returnCode": returncode,
        "spawnError": spawn_error,
        "startedAt": started_at,
        "endedAt": ended_at,
        "durationSeconds": duration_seconds,
        "transcriptPath": str(text_path),
        "transcriptSha256": hashlib.sha256(transcript.encode("utf-8", "replace")).hexdigest(),
        "rawTranscriptSha256": raw_transcript_sha256,
        "transcriptBytes": len(transcript.encode("utf-8", "replace")),
        "redacted": True,
        "git": git_metadata(cwd),
        "runnerSha256": runner_sha256(),
        "assertions": assertions,
        "scenario": {
            "path": scenario_path,
            "actionCount": len(scenario_actions),
            "actions": scenario_actions,
        } if scenario is not None else {},
        "tmux": {
            "pane": os.environ.get("TMUX_PANE", ""),
            "socket": os.environ.get("TMUX", ""),
        },
    }

    write_private_text(text_path, transcript)
    write_private_json(json_path, record)

    print(f"EVIDENCE_RESULT: {status}")
    print(f"EVIDENCE_JSON: {json_path}")
    print(f"EVIDENCE_LOG: {text_path}")
    print(f"EVIDENCE_COMMAND: {display}")
    print(f"EVIDENCE_DURATION_SECONDS: {duration_seconds}")
    if transcript:
        print("EVIDENCE_TRANSCRIPT_TAIL:")
        print("\n".join(transcript.splitlines()[-40:]))
    if assertions:
        print("EVIDENCE_ASSERTIONS:")
        print(json.dumps(assertions, sort_keys=True))

    if spawn_error:
        return 2
    if timed_out:
        if args.timeout_ok and status != "ASSERTION_FAILED":
            return 0
        return 124
    if status == "ASSERTION_FAILED":
        return 1
    if status == "EXIT_EXPECTED":
        return 0
    if returncode is None:
        return 1
    return returncode if 0 <= returncode <= 125 else 1


if __name__ == "__main__":
    raise SystemExit(main())
