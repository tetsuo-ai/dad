#!/usr/bin/env python3
"""Redact and bound DAD daemon log text from stdin."""

from __future__ import annotations

import os
import re
import sys


PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)
BEARER_RE = re.compile(r"(?i)\b(Bearer)\s+[A-Za-z0-9._~+/=-]+")
URL_CREDENTIAL_RE = re.compile(r"([a-z][a-z0-9+.-]*://)([^/\s:@]+):([^/\s@]+)@")
SECRET_VALUE_RE = re.compile(
    r"(?i)\b([A-Z0-9_]*(?:api[_-]?key|token|secret|password|passwd|authorization|private[_-]?key|credential)[A-Z0-9_]*)\b\s*[:=]\s*['\"]?[^'\"\s]+"
)
HIGH_ENTROPY_TOKEN_RE = re.compile(
    r"\b(?=[A-Za-z0-9._~+/=-]{32,}\b)"
    r"(?=[A-Za-z0-9._~+/=-]*[A-Z])"
    r"(?=[A-Za-z0-9._~+/=-]*[a-z])"
    r"(?=[A-Za-z0-9._~+/=-]*[0-9])"
    r"[A-Za-z0-9._~+/=-]{32,}\b"
)


def main() -> int:
    text = sys.stdin.read()
    text = PRIVATE_KEY_RE.sub("[redacted-private-key]", text)
    text = BEARER_RE.sub(r"\1 [redacted]", text)
    text = URL_CREDENTIAL_RE.sub(r"\1[redacted]:[redacted]@", text)
    text = SECRET_VALUE_RE.sub(lambda match: f"{match.group(1)}=[redacted]", text)
    text = HIGH_ENTROPY_TOKEN_RE.sub("[redacted-high-entropy-token]", text)
    text = text.replace("\r", "")
    limit = int(os.environ.get("DAD_LOG_REDACT_LIMIT", "4000"))
    if len(text) > limit:
        text = text[:limit] + "...[truncated]"
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
