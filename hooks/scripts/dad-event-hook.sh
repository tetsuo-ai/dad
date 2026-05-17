#!/usr/bin/env bash
# Passive DAD trajectory hook. Fail-open by design.

set +e

if [ -n "${DAD_PLUGIN_ROOT:-}" ]; then
  PLUGIN_ROOT="${DAD_PLUGIN_ROOT}"
elif [ -n "${GROK_PLUGIN_ROOT:-}" ]; then
  PLUGIN_ROOT="${GROK_PLUGIN_ROOT}"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
else
  SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
  PLUGIN_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)"
fi

export DAD_PLUGIN_ROOT="${DAD_PLUGIN_ROOT:-$PLUGIN_ROOT}"
export DAD_ROOT="${DAD_ROOT:-${PLUGIN_ROOT}/dad}"
SCRIPT="${DAD_EVENT_HOOK_SCRIPT:-${PLUGIN_ROOT}/dad/bin/dad-event-hook.py}"

ENV_SCRIPT="${PLUGIN_ROOT}/dad/bin/dad-env.sh"
if [ -r "$ENV_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$ENV_SCRIPT"
  export DAD_DATA_ROOT="${DAD_DATA_ROOT:-$(dad_data_root)}"
fi

if [ -n "${DAD_DATA_ROOT:-}" ] && [ -z "${DAD_EVENT_ROOT:-}" ]; then
  export DAD_EVENT_ROOT="${DAD_DATA_ROOT}/events"
fi

if [ -x "$SCRIPT" ]; then
  "$SCRIPT"
fi

exit 0
