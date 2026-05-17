#!/usr/bin/env bash
# Shared DAD path resolution helpers. Source this file from DAD bash scripts.

DAD_ENV_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

dad_root() {
  if [[ -n "${DAD_ROOT:-}" ]]; then
    printf '%s\n' "$DAD_ROOT"
    return
  fi
  CDPATH= cd -- "$DAD_ENV_SCRIPT_DIR/.." && pwd
}

dad_plugin_root() {
  if [[ -n "${DAD_PLUGIN_ROOT:-}" ]]; then
    printf '%s\n' "$DAD_PLUGIN_ROOT"
  elif [[ -n "${GROK_PLUGIN_ROOT:-}" ]]; then
    printf '%s\n' "$GROK_PLUGIN_ROOT"
  elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"
  else
    CDPATH= cd -- "$(dad_root)/.." && pwd
  fi
}

dad_grok_home() {
  printf '%s\n' "${GROK_HOME:-$HOME/.grok}"
}

dad_data_root() {
  if [[ -n "${DAD_DATA_ROOT:-}" ]]; then
    printf '%s\n' "$DAD_DATA_ROOT"
  elif [[ -n "${GROK_PLUGIN_DATA:-}" ]]; then
    printf '%s\n' "$GROK_PLUGIN_DATA"
  elif [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
    printf '%s\n' "$CLAUDE_PLUGIN_DATA"
  elif [[ -n "${DAD_PLUGIN_ROOT:-}" || -n "${GROK_PLUGIN_ROOT:-}" || -n "${CLAUDE_PLUGIN_ROOT:-}" || -n "${GROK_HOME:-}" ]]; then
    printf '%s/dad-data\n' "$(dad_grok_home)"
  else
    dad_root
  fi
}

dad_logs_root() {
  if [[ -n "${DAD_LOG_ROOT:-}" ]]; then
    printf '%s\n' "$DAD_LOG_ROOT"
  else
    printf '%s/logs\n' "$(dad_data_root)"
  fi
}

dad_validate_window_id() {
  [[ "$1" =~ ^@[0-9]+$ ]]
}

dad_validate_pane_id() {
  [[ "$1" =~ ^%[0-9]+$ ]]
}

dad_prepare_log_file() {
  local path="$1"
  local dir
  dir="$(dirname -- "$path")"
  if [[ -L "$dir" || -L "$path" ]]; then
    printf 'dad-log: refusing symlink log target: %s\n' "$path" >&2
    return 1
  fi
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  if [[ -e "$path" && ! -f "$path" ]]; then
    printf 'dad-log: refusing non-file log target: %s\n' "$path" >&2
    return 1
  fi
  if [[ -L "$path" ]]; then
    printf 'dad-log: refusing symlink log target: %s\n' "$path" >&2
    return 1
  fi
  (umask 177; : >> "$path") || return 1
  chmod 600 "$path" 2>/dev/null || true
  [[ -f "$path" && ! -L "$path" ]]
}

dad_redact_log_text() {
  python3 "$DAD_ENV_SCRIPT_DIR/dad-log-redact.py"
}

dad_log_append() {
  local path="$1"
  shift
  dad_prepare_log_file "$path" || return 1
  printf '%s %s\n' "$(date -Is)" "$*" | dad_redact_log_text >> "$path"
  chmod 600 "$path" 2>/dev/null || true
}

dad_quote_argv() {
  local out=""
  local quoted
  local arg
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    out="${out:+$out }$quoted"
  done
  printf '%s\n' "$out"
}

dad_spawn_daemon() {
  local socket="$1"
  local window="$2"
  local log_file="$3"
  shift 3
  local script="$1"
  shift
  local launcher="${DAD_DAEMON_LAUNCHER:-$DAD_ENV_SCRIPT_DIR/dad-daemon-launcher.sh}"
  local command
  local arg_index=0
  local arg

  dad_validate_window_id "$window" || {
    printf 'dad-spawn: invalid window target: %s\n' "$window" >&2
    return 2
  }
  [[ -x "$launcher" ]] || {
    printf 'dad-spawn: launcher not executable: %s\n' "$launcher" >&2
    return 2
  }
  [[ -x "$script" ]] || {
    printf 'dad-spawn: daemon not executable: %s\n' "$script" >&2
    return 2
  }
  dad_prepare_log_file "$log_file" || return 2

  for arg in "$@"; do
    arg_index=$((arg_index + 1))
    if [[ "$arg_index" -eq 2 ]]; then
      dad_validate_window_id "$arg" || {
        printf 'dad-spawn: invalid daemon window argument: %s\n' "$arg" >&2
        return 2
      }
    elif [[ "$arg" == %* ]]; then
      dad_validate_pane_id "$arg" || {
        printf 'dad-spawn: invalid daemon pane argument: %s\n' "$arg" >&2
        return 2
      }
    fi
  done

  command="$(dad_quote_argv "$launcher" "$log_file" "$script" "$@")"
  tmux -S "$socket" run-shell -b "$command"
}
