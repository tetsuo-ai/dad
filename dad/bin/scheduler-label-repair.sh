#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: scheduler-label-repair.sh --socket <socket> --window <window-id> [--inject]

Build an explicit DAD scheduler-label repair directive for a live DAD window.
Without --inject, print the directive. With --inject, submit it to the Dad pane
through tmux-submit.sh. The Dad model owns scheduler_create/delete because those
are Grok built-in tools, not shell commands.
USAGE
  exit 2
}

socket=""
window=""
inject=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --socket)
      [[ $# -ge 2 ]] || usage
      socket="$2"
      shift 2
      ;;
    --window)
      [[ $# -ge 2 ]] || usage
      window="$2"
      shift 2
      ;;
    --inject)
      inject=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$socket" && -n "$window" ]] || usage

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dad-env.sh
source "$script_dir/dad-env.sh"
dad_root="$(dad_root)"
repo_root="$(dad_plugin_root)"
submit="${DAD_TMUX_SUBMIT:-$script_dir/tmux-submit.sh}"
prompt_gen="${DAD_SCHEDULER_PROMPT:-$script_dir/scheduler-prompt.sh}"
skill_path="${DAD_SKILL_FILE:-$repo_root/skills/dad/SKILL.md}"
design_path="${DAD_DESIGN_FILE:-$dad_root/DAD.md}"
policy_file="${DAD_POLICY_VERSION_FILE:-$dad_root/POLICY_VERSION}"
policy_version="$(tr -d '[:space:]' < "$policy_file" 2>/dev/null || true)"
[[ -n "$policy_version" ]] || policy_version="failclosed-lease-evidence-v1"

tmux_get() {
  tmux -S "$socket" show-window-option -v -t "$window" "$1" 2>/dev/null || true
}

tmux_set() {
  tmux -S "$socket" set-window-option -t "$window" "$1" "$2" >/dev/null 2>&1
}

window_exists() {
  tmux -S "$socket" display-message -p -t "$window" '#{window_id}' >/dev/null 2>&1
}

pane_belongs_to_window() {
  pane="$1"
  tmux -S "$socket" list-panes -t "$window" -F '#{pane_id} #{pane_dead}' 2>/dev/null |
    awk -v pane="$pane" '$1 == pane && $2 == "0" { found = 1 } END { exit(found ? 0 : 1) }'
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

[[ -x "$submit" && -x "$prompt_gen" ]] || {
  echo "scheduler-label-repair: missing submit or prompt generator helper" >&2
  exit 1
}

if ! window_exists; then
  echo "scheduler-label-repair: window not found: $window" >&2
  exit 1
fi

dad_pane="$(tmux_get @dad_dad_pane)"
son_pane="$(tmux_get @dad_son_pane)"
objective="$(tmux_get @dad_objective)"

[[ -n "$dad_pane" && -n "$son_pane" ]] || {
  echo "scheduler-label-repair: missing @dad_dad_pane or @dad_son_pane metadata" >&2
  exit 1
}

if ! pane_belongs_to_window "$dad_pane"; then
  echo "scheduler-label-repair: Dad pane $dad_pane is not live in window $window" >&2
  exit 1
fi

if ! pane_belongs_to_window "$son_pane"; then
  echo "scheduler-label-repair: Son pane $son_pane is not live in window $window" >&2
  exit 1
fi

objective="${objective:-the original DAD objective for this session}"
fast_prompt="$("$prompt_gen" fast "$window" "$son_pane" - <<<"$objective")"
deep_prompt="$("$prompt_gen" deep "$window" "$son_pane" - <<<"$objective")"
strategic_prompt="$("$prompt_gen" strategic "$window" "$son_pane" - <<<"$objective")"

directive="$(cat <<EOF
DAD explicit scheduler-label repair ($(date -Is)).

This is a user/tool initiated repair turn, not a recurring fast/deep/strategic pass.

Window: $window
Dad pane: $dad_pane
Son pane: $son_pane
Policy version: $policy_version

Task:
1. Read $design_path and $skill_path from disk.
2. Use Grok built-in scheduler tools directly. Do not use shell commands named scheduler_list/create/delete.
3. Call scheduler_list exactly once. For this DAD window, identify any existing fast/deep/strategic scheduler tasks by stored IDs, prompt metadata, or window id.
4. Delete only this window's stale/mismatched/durable fast/deep/strategic tasks. Do not touch unrelated tasks or the Son pane.
5. Recreate exactly three non-durable recurring tasks. Every scheduler_create call must set recurring=true, durable=false, and use the prompt text below:
   - fast: interval 2m, prompt from FAST_PROMPT below
   - deep: interval 12m, prompt from DEEP_PROMPT below
   - strategic: interval 30m, prompt from STRATEGIC_PROMPT below
6. Store returned IDs in @dad_fast_scheduler_id, @dad_deep_scheduler_id, and @dad_strategic_scheduler_id.
7. Set @dad_policy_version=$policy_version, clear @dad_scheduler_repair_required, update @dad_scheduler_repaired_at, release any stale loop lease fields, and return a concise normal repair summary.

Do not run project commands, edit project artifacts, verify Son work, approve plans, or call stop/cancel in this repair turn.

FAST_PROMPT:
$fast_prompt

DEEP_PROMPT:
$deep_prompt

STRATEGIC_PROMPT:
$strategic_prompt
EOF
)"

if [[ "$inject" -eq 0 ]]; then
  printf '%s\n' "$directive"
  exit 0
fi

dad_snapshot="$(tmux -S "$socket" capture-pane -t "$dad_pane" -p -S -40 2>/dev/null || true)"
if active_turn_in_snapshot "$dad_snapshot"; then
  tmux_set @dad_scheduler_label_repair_status waiting:dad_busy || true
  echo "scheduler-label-repair: Dad pane is active; refusing to inject scheduler repair into a running turn" >&2
  exit 1
fi

if ! "$submit" --socket "$socket" --window "$window" --target "$dad_pane" --expect-command grok --mode text --text "$directive"; then
  tmux_set @dad_scheduler_label_repair_status submit_failed || true
  echo "scheduler-label-repair: failed to submit repair directive" >&2
  exit 1
fi

tmux_set @dad_scheduler_label_repair_status submitted || true
tmux_set @dad_scheduler_label_repair_requested_at "$(date -Is)" || true
tmux_set @dad_scheduler_repair_required label_repair_submitted || true
printf 'submitted scheduler-label repair directive to %s in %s\n' "$dad_pane" "$window"
