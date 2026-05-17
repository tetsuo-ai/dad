#!/usr/bin/env python3
"""Shared DAD path resolution helpers."""

from __future__ import annotations

import os
from pathlib import Path


def _env_path(name: str) -> Path | None:
    value = os.environ.get(name, "").strip()
    if not value:
        return None
    return Path(value).expanduser()


def _module_dad_root() -> Path:
    return Path(__file__).resolve().parents[1]


def dad_root() -> Path:
    """Return the DAD implementation root."""

    return _env_path("DAD_ROOT") or _module_dad_root()


def plugin_root() -> Path:
    """Return the plugin/repository root that contains the dad/ directory."""

    return (
        _env_path("DAD_PLUGIN_ROOT")
        or _env_path("GROK_PLUGIN_ROOT")
        or _env_path("CLAUDE_PLUGIN_ROOT")
        or dad_root().parent
    )


def grok_home() -> Path:
    """Return Grok's home directory for plugin runtime data."""

    return _env_path("GROK_HOME") or (Path.home() / ".grok")


def data_root() -> Path:
    """Return the writable DAD runtime-data root.

    Precedence:
    DAD_DATA_ROOT > GROK_PLUGIN_DATA > CLAUDE_PLUGIN_DATA >
    $GROK_HOME/dad-data for plugin installs > local dad/ for checkout tests.
    """

    configured = (
        _env_path("DAD_DATA_ROOT")
        or _env_path("GROK_PLUGIN_DATA")
        or _env_path("CLAUDE_PLUGIN_DATA")
    )
    if configured is not None:
        return configured

    if (
        os.environ.get("DAD_PLUGIN_ROOT")
        or os.environ.get("GROK_PLUGIN_ROOT")
        or os.environ.get("CLAUDE_PLUGIN_ROOT")
        or os.environ.get("GROK_HOME")
    ):
        return grok_home() / "dad-data"

    return dad_root()


def events_root() -> Path:
    return data_root() / "events"


def evidence_root() -> Path:
    return data_root() / "evidence"


def gate_root() -> Path:
    return evidence_root() / "gates"


def logs_root() -> Path:
    return data_root() / "logs"
