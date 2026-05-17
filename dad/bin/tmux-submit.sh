#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage:
  tmux-submit.sh --socket <socket> --target <pane> [--window <window-id>] [--expect-command <cmd>] --mode text [--text <text> | --file <path> | --stdin] [--no-enter]
  tmux-submit.sh --socket <socket> --target <pane> [--window <window-id>] [--expect-command <cmd>] --mode submit-existing
  tmux-submit.sh --socket <socket> --target <pane> [--window <window-id>] [--expect-command <cmd>] --mode key (--key <tmux-key> | --literal-key <text>)

Text mode pastes the payload through a tmux buffer and sends a plain Enter by
default. submit-existing sends Enter to an already-populated composer and fails
if the composer still appears pending. Key mode never sends Enter unless the key
itself is Enter.
USAGE
  exit 2
}

socket=""
target=""
window=""
expect_command=""
mode=""
text=""
file=""
read_stdin=0
send_enter=1
key=""
literal_key=""
enter_delay_ms="${DAD_TMUX_SUBMIT_ENTER_DELAY_MS:-350}"
enter_retries="${DAD_TMUX_SUBMIT_ENTER_RETRIES:-4}"
buffer=""

cleanup_buffer() {
  if [[ -n "${buffer:-}" ]]; then
    tmux -S "$socket" delete-buffer -b "$buffer" >/dev/null 2>&1 || true
    buffer=""
  fi
}

trap cleanup_buffer EXIT

set_submit_status() {
  status="$1"
  detail="${2:-}"
  [[ -n "$window" ]] || return 0
  tmux -S "$socket" set-window-option -t "$window" @dad_tmux_submit_last_status "$status" >/dev/null 2>&1 || true
  tmux -S "$socket" set-window-option -t "$window" @dad_tmux_submit_last_at "$(date -Is)" >/dev/null 2>&1 || true
  if [[ -n "$detail" ]]; then
    tmux -S "$socket" set-window-option -t "$window" @dad_tmux_submit_last_detail "$detail" >/dev/null 2>&1 || true
  fi
}

sleep_ms() {
  ms="$1"
  awk -v ms="$ms" 'BEGIN { if (ms > 0) printf "%.3f", ms / 1000; else printf "0" }' |
    xargs sleep
}

submission_pending_in_snapshot() {
  snapshot="$1"
  tail_text="$(printf '%s\n' "$snapshot" | tail -14)"
  if printf '%s\n' "$tail_text" | grep -Eq '\[Pasted:'; then
    return 0
  fi
  if printf '%s\n' "$tail_text" | grep -q 'Enter:send'; then
    if printf '%s\n' "$tail_text" | grep -Eq '│[[:space:]]*❯[[:space:]]*[^│[:space:]][^│]*│|│[[:space:]]{2,}[^│[:space:]❯][^│]{2,}│'; then
      return 0
    fi
  fi
  return 1
}

active_turn_in_snapshot() {
  snapshot="$1"
  tail_text="$(printf '%s\n' "$snapshot" | tail -24)"
  if printf '%s\n' "$tail_text" | grep -Eiq 'Thinking(\.\.\.|…)|Responding|Running|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing|Compacting|Waiting(\.\.\.|…)'; then
    return 0
  fi
  if printf '%s\n' "$tail_text" | grep -Eiq '^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Run|Read|Edit|Search|Write|Apply|Thinking|Waiting|Responding|Running|Building|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing|Compacting)|^[[:space:]│┃]*◆[[:space:]]+(Run|Read|Edit|Search|Write|Apply|Thinking)|^[[:space:]│┃]*Tool Use'; then
    return 0
  fi
  return 1
}

control_payload_requires_safe_input() {
  payload="$1"
  first_line="$(printf '%s\n' "$payload" | sed '/^[[:space:]]*$/d' | head -1)"
  printf '%s\n' "$first_line" | grep -Eq '^[[:space:]]*/(compact|memory)([[:space:]]|$)'
}

pending_control_payload_in_snapshot() {
  snapshot="$1"
  tail_text="$(printf '%s\n' "$snapshot" | tail -16)"
  printf '%s\n' "$tail_text" | grep -Eq '│[[:space:]]*❯[[:space:]]*/(compact|memory)([[:space:]]|│|$)'
}

send_submit_enter() {
  attempt=1
  while [[ "$attempt" -le "$enter_retries" ]]; do
    sleep_ms "$enter_delay_ms"
    if ! tmux -S "$socket" send-keys -t "$target" Enter; then
      set_submit_status failed_enter "enter_attempt=$attempt"
      echo "tmux-submit: failed to send Enter to $target" >&2
      return 1
    fi
    sleep_ms "$enter_delay_ms"
    if ! snapshot="$(tmux -S "$socket" capture-pane -t "$target" -p -S -12 2>/dev/null)"; then
      set_submit_status failed_capture "enter_attempt=$attempt"
      echo "tmux-submit: failed to capture pane after Enter attempt $attempt" >&2
      return 1
    fi
    if ! submission_pending_in_snapshot "$snapshot"; then
      set_submit_status submitted "enter_attempt=$attempt"
      return 0
    fi
    attempt=$((attempt + 1))
  done
  set_submit_status failed_pending "enter_retries=$enter_retries"
  echo "tmux-submit: prompt still appears pending after $enter_retries Enter attempts" >&2
  return 1
}

focus_prompt_if_needed() {
  snapshot="$(tmux -S "$socket" capture-pane -t "$target" -p -S -20 2>/dev/null || true)"
  if printf '%s\n' "$snapshot" | tail -10 | grep -Eq 'Space:prompt'; then
    tmux -S "$socket" send-keys -t "$target" -l ' '
    sleep_ms "$enter_delay_ms"
  fi
}

if [[ "${DAD_TMUX_SUBMIT_TEST_PENDING:-0}" == "1" ]]; then
  test_snapshot="$(cat)"
  if submission_pending_in_snapshot "$test_snapshot"; then
    printf 'pending\n'
  else
    printf 'submitted\n'
  fi
  exit 0
fi

if [[ "${DAD_TMUX_SUBMIT_TEST_ACTIVE_CONTROL:-0}" == "1" ]]; then
  test_payload="${1:-/compact}"
  test_snapshot="$(cat)"
  if control_payload_requires_safe_input "$test_payload" && active_turn_in_snapshot "$test_snapshot"; then
    printf 'blocked\n'
  else
    printf 'allowed\n'
  fi
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --socket)
      [[ $# -ge 2 ]] || usage
      socket="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || usage
      target="$2"
      shift 2
      ;;
    --window)
      [[ $# -ge 2 ]] || usage
      window="$2"
      shift 2
      ;;
    --expect-command)
      [[ $# -ge 2 ]] || usage
      expect_command="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || usage
      mode="$2"
      shift 2
      ;;
    --text)
      [[ $# -ge 2 ]] || usage
      text="$2"
      shift 2
      ;;
    --file)
      [[ $# -ge 2 ]] || usage
      file="$2"
      shift 2
      ;;
    --stdin)
      read_stdin=1
      shift
      ;;
    --no-enter)
      send_enter=0
      shift
      ;;
    --key)
      [[ $# -ge 2 ]] || usage
      key="$2"
      shift 2
      ;;
    --literal-key)
      [[ $# -ge 2 ]] || usage
      literal_key="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$socket" && -n "$target" && -n "$mode" ]] || usage

if ! tmux -S "$socket" display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1; then
  echo "tmux-submit: target pane not found: $target" >&2
  exit 1
fi

if [[ -n "$window" ]]; then
  if ! tmux -S "$socket" display-message -p -t "$window" '#{window_id}' >/dev/null 2>&1; then
    echo "tmux-submit: window not found: $window" >&2
    exit 1
  fi
  if ! tmux -S "$socket" list-panes -t "$window" -F '#{pane_id} #{pane_dead}' 2>/dev/null |
      awk -v pane="$target" '$1 == pane && $2 == "0" { found = 1 } END { exit(found ? 0 : 1) }'; then
    echo "tmux-submit: target pane $target is not live in window $window" >&2
    exit 1
  fi
fi

if [[ -n "$expect_command" ]]; then
  actual_command="$(tmux -S "$socket" display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)"
  if [[ "$actual_command" != "$expect_command" ]]; then
    echo "tmux-submit: target pane command mismatch: expected $expect_command, got ${actual_command:-unknown}" >&2
    exit 1
  fi
fi

case "$mode" in
  text)
    sources=0
    [[ -n "$text" ]] && sources=$((sources + 1))
    [[ -n "$file" ]] && sources=$((sources + 1))
    [[ "$read_stdin" -eq 1 ]] && sources=$((sources + 1))
    [[ "$sources" -eq 1 ]] || usage
    [[ -z "$key" && -z "$literal_key" ]] || usage

    if [[ -n "$file" ]]; then
      [[ -r "$file" ]] || { echo "tmux-submit: cannot read file: $file" >&2; exit 1; }
      payload="$(<"$file")"
    elif [[ "$read_stdin" -eq 1 ]]; then
      payload="$(cat)"
    else
      payload="$text"
    fi

    if control_payload_requires_safe_input "$payload"; then
      snapshot="$(tmux -S "$socket" capture-pane -t "$target" -p -S -40 2>/dev/null || true)"
      if active_turn_in_snapshot "$snapshot"; then
        set_submit_status failed_active_control "refused active /compact or /memory"
        echo "tmux-submit: refusing /compact or /memory while target pane is active" >&2
        exit 1
      fi
    fi

    buffer="dad-submit-$$-$(date +%s%N)"
    printf '%s' "$payload" | tmux -S "$socket" load-buffer -b "$buffer" -
    focus_prompt_if_needed
    tmux -S "$socket" paste-buffer -t "$target" -b "$buffer"
    cleanup_buffer
    if [[ "$send_enter" -eq 1 ]]; then
      send_submit_enter
    else
      set_submit_status pasted_without_enter "text_mode_no_enter"
    fi
    ;;
  submit-existing)
    [[ "$send_enter" -eq 1 ]] || usage
    [[ -z "$text" && -z "$file" && "$read_stdin" -eq 0 && -z "$key" && -z "$literal_key" ]] || usage
    snapshot="$(tmux -S "$socket" capture-pane -t "$target" -p -S -40 2>/dev/null || true)"
    if pending_control_payload_in_snapshot "$snapshot" && active_turn_in_snapshot "$snapshot"; then
      set_submit_status failed_active_control "refused pending active /compact or /memory"
      echo "tmux-submit: refusing to submit pending /compact or /memory while target pane is active" >&2
      exit 1
    fi
    focus_prompt_if_needed
    send_submit_enter
    ;;
  key)
    [[ "$send_enter" -eq 1 ]] || usage
    [[ -z "$text" && -z "$file" && "$read_stdin" -eq 0 ]] || usage
    if [[ -n "$literal_key" && -n "$key" ]]; then
      usage
    elif [[ -n "$literal_key" ]]; then
      tmux -S "$socket" send-keys -t "$target" -l "$literal_key"
    elif [[ -n "$key" ]]; then
      tmux -S "$socket" send-keys -t "$target" "$key"
    else
      usage
    fi
    set_submit_status key_sent "${literal_key:-$key}"
    ;;
  *)
    usage
    ;;
esac
