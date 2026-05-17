#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: watchdog.sh <tmux-socket> <window-id> <dad-pane-id>" >&2
  exit 2
fi

socket="$1"
window="$2"
dad_pane="$3"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dad-env.sh
source "$script_dir/dad-env.sh"
dad_root="$(dad_root)"
repo_root="$(dad_plugin_root)"
data_root="$(dad_data_root)"
log_root="$(dad_logs_root)"

poll_seconds="${DAD_WATCHDOG_POLL_SECONDS:-5}"
max_thinking_seconds="${DAD_WATCHDOG_MAX_THINKING_SECONDS:-240}"
recovering_max_thinking_seconds="${DAD_WATCHDOG_RECOVERING_MAX_THINKING_SECONDS:-30}"
repeat_grace_seconds="${DAD_WATCHDOG_REPEAT_GRACE_SECONDS:-30}"
log_file="${DAD_WATCHDOG_LOG:-$log_root/dad-watchdog-${window#@}-${dad_pane#%}.log}"
max_recoveries="${DAD_WATCHDOG_MAX_RECOVERIES:-3}"
compact_wait_seconds="${DAD_WATCHDOG_COMPACT_WAIT_SECONDS:-300}"
compact_prompt="${DAD_WATCHDOG_COMPACT_PROMPT:-/compact Preserve only the DAD operating state: objective, tmux window/pane IDs, scheduler IDs, accepted checkpoints, Son status, current recovery reason, and the next safe supervisor action. Discard the degenerate repetition loop, repeated low-value output, failed scheduler-turn transcript, and any analysis produced during the unhealthy Dad turn. Do not preserve the repeated text as useful memory.}"
memory_recovery_command="${DAD_WATCHDOG_MEMORY_RECOVERY_COMMAND:-/memory off}"
submit="${DAD_TMUX_SUBMIT:-$script_dir/tmux-submit.sh}"
idle_controller="${DAD_IDLE_CONTROLLER:-$script_dir/idle-controller.sh}"
scheduler_prompt="${DAD_SCHEDULER_PROMPT:-$script_dir/scheduler-prompt.sh}"
scheduler_health="${DAD_SCHEDULER_HEALTH:-$script_dir/scheduler-health.sh}"
lease_helper="${DAD_LEASE_HELPER:-$script_dir/dad-lease.sh}"
script_path="${DAD_WATCHDOG_SCRIPT:-$script_dir/watchdog.sh}"
skill_path="${DAD_SKILL_FILE:-$repo_root/skills/dad/SKILL.md}"
design_path="${DAD_DESIGN_FILE:-$dad_root/DAD.md}"
command_mismatch_max_seconds="${DAD_WATCHDOG_COMMAND_MISMATCH_SECONDS:-60}"
replacement_enabled="${DAD_WATCHDOG_REPLACE_ON_EXHAUSTED:-1}"
max_replacements="${DAD_WATCHDOG_MAX_REPLACEMENTS:-2}"
replacement_command="${DAD_WATCHDOG_REPLACEMENT_COMMAND:-grok --yolo}"
replacement_wait_seconds="${DAD_WATCHDOG_REPLACEMENT_WAIT_SECONDS:-60}"
quarantine_old_dad="${DAD_WATCHDOG_QUARANTINE_OLD_DAD:-1}"
quarantine_suspend_old_dad="${DAD_WATCHDOG_SUSPEND_OLD_DAD:-1}"
scheduler_health_interval_seconds="${DAD_WATCHDOG_SCHEDULER_HEALTH_INTERVAL_SECONDS:-30}"

thinking_since=""
command_mismatch_since=""
broken_active_since=""
started_at="$(date -Is)"
last_scheduler_cancel_signature=""
last_scheduler_health_check=0
dad_prepare_log_file "$log_file" || exit 2

recovery_block_signature() {
  reason="$1"
  printf '%s\n' "$reason" | sed -E 's/:[0-9]+s$/:Xs/'
}

tmux_set() {
  if ! tmux -S "$socket" set-window-option -t "$window" "$1" "$2" >/dev/null 2>&1; then
    log "tmux_set_failed key=$1"
    return 1
  fi
}

tmux_get() {
  tmux -S "$socket" show-window-option -v -t "$window" "$1" 2>/dev/null || true
}

now_epoch() {
  date +%s
}

epoch() {
  value="$1"
  date -d "$value" +%s 2>/dev/null || printf '0'
}

log() {
  dad_log_append "$log_file" "$*"
}

window_exists() {
  tmux -S "$socket" display-message -p -t "$window" '#{window_id}' >/dev/null 2>&1
}

pane_belongs_to_window() {
  pane="$1"
  tmux -S "$socket" list-panes -t "$window" -F '#{pane_id} #{pane_dead}' 2>/dev/null |
    awk -v pane="$pane" '$1 == pane && $2 == "0" { found = 1 } END { exit(found ? 0 : 1) }'
}

current_dad_pane_matches() {
  current="$(tmux_get @dad_dad_pane)"
  [[ -z "$current" || "$current" == "$dad_pane" ]]
}

pid_matches_this_watchdog() {
  pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  cmdline="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  printf '%s\n' "$cmdline" | grep -Fxq "$script_path" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$socket" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$window" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$dad_pane"
}

pane_command_is_grok() {
  command="$(tmux -S "$socket" display-message -p -t "$dad_pane" '#{pane_current_command}' 2>/dev/null || true)"
  [[ "$command" == "grok" ]]
}

normalized_signal() {
  awk '
    {
      line = $0
      gsub(/\x1b\[[0-9;]*[[:alpha:]]/, "", line)
      gsub(/^[[:space:]│┃╭╮╰╯◆↻:⸬❯•>*\[\]0-9.,;!|()_-]+/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      lower = tolower(line)

      if (line == "") next
      if (lower ~ /thinking|grok build|shift|ctrl|enter:|resume this session|grok --resume/) next
      if (lower ~ /\[loop\]|scheduler trampoline|tool_use|pre_tool_use|post_tool_use/) next
      if (lower ~ /thought for|run |read |skill |tmux |capture-pane|show-options/) next
      if (lower ~ /^(turn cancelled by user|compacting|waiting|responding|build anything)$/) next
      if (lower ~ /^[^ ]+ on [^ ]+( via | took | *\[|$)/) next
      if (lower ~ /^(~\/|\/home\/|branch:|tree clean|git status|git log)/) next
      if (line ~ /^~\// || line ~ /^\// || lower ~ / on .*took /) next
      if (length(line) > 80) next
      if (line !~ /[[:alpha:]]/) next

      semantic = lower
      gsub(/[[:punct:]]+/, "", semantic)
      gsub(/[[:space:]]+/, " ", semantic)
      sub(/^ /, "", semantic)
      sub(/ $/, "", semantic)
      if (semantic == "") next

      key = semantic
      if (key ~ /^(yes|good|ok|okay|done|the end|end|normal)$/) {
        closure_count++
      }
      count[key]++
      total++
      if (!(key in seen)) {
        seen[key] = 1
        unique++
      }
    }
    END {
      for (key in count) {
        if (count[key] >= 6) {
          print "repeated_line:" key
          exit 0
        }
      }
      if (total >= 12 && unique <= 3) {
        print "low_unique_ratio:total=" total ",unique=" unique
        exit 0
      }
      if (total >= 2 && total <= 10 && unique <= 4 && closure_count >= 2) {
        print "low_entropy_closure:total=" total ",unique=" unique ",closure=" closure_count
        exit 0
      }
    }
  '
}

semantic_repetition_signal() {
  awk '
    {
      line = $0
      gsub(/\x1b\[[0-9;]*[[:alpha:]]/, "", line)
      gsub(/^[[:space:]│┃╭╮╰╯◆↻:⸬❯•>*\[\]0-9.,;!|()_-]+/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      lower = tolower(line)

      if (line == "") next
      if (lower ~ /thinking|grok build|shift|ctrl|enter:|resume this session|grok --resume/) next
      if (lower ~ /\[loop\]|tool_use|pre_tool_use|post_tool_use/) next
      if (lower ~ /thought for|run |read |skill |tmux |capture-pane|show-options/) next
      if (lower ~ /^(turn cancelled by user|compacting|waiting|responding|build anything)$/) next
      if (lower ~ /^[^ ]+ on [^ ]+( via | took | *\[|$)/) next
      if (lower ~ /^(~\/|\/home\/|branch:|tree clean|git status|git log)/) next
      if (line ~ /^~\// || line ~ /^\// || lower ~ / on .*took /) next

      gsub(/[^a-z0-9_:-]+/, " ", lower)
      n = split(lower, words, /[ ]+/)
      for (i = 1; i <= n; i++) {
        word = words[i]
        if (word == "" || length(word) < 3) continue
        if (word ~ /^(the|and|for|that|this|with|you|are|was|were|has|have|had|not|but|from|into|then|than|will|must|should|could|would|now|one|two)$/) continue
        total++
        if (!(word in seen)) {
          seen[word] = 1
          unique++
        }
        if (prev2 != "" && prev1 != "") {
          phrase = prev2 " " prev1 " " word
          phrase_count[phrase]++
        }
        prev2 = prev1
        prev1 = word
      }
    }
    END {
      for (phrase in phrase_count) {
        if (phrase_count[phrase] >= 3) {
          print "repeated_phrase:" phrase ":count=" phrase_count[phrase]
          exit 0
        }
      }
      if (total >= 40 && unique * 100 <= total * 35) {
        print "low_word_entropy:total=" total ",unique=" unique
        exit 0
      }
    }
  '
}

structured_trace_signal() {
  awk '
    {
      line = $0
      gsub(/\x1b\[[0-9;]*[[:alpha:]]/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      lower = tolower(line)

      if (match(lower, /run ([a-z0-9_.:-]+)/, m)) {
        tool = m[1]
        tool_count[tool]++
        total_tools++
      }
    }
    END {
      for (tool in tool_count) {
        if (tool_count[tool] >= 4) {
          print "tool_cycle:" tool ":count=" tool_count[tool] ",total=" total_tools
          exit 0
        }
      }
    }
  '
}

scheduler_cancel_signal() {
  awk '
    {
      line = $0
      gsub(/\x1b\[[0-9;]*[[:alpha:]]/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      lower = tolower(line)

      if (lower ~ /dad scheduler trampoline/) saw_scheduler = 1
      if (lower ~ /run scheduler_list/) scheduler_list_count++
      if (lower ~ /run stop/) saw_stop = 1
      if (lower ~ /turn cancelled by user/) saw_cancel = 1
    }
    END {
      if (saw_scheduler && saw_cancel && (scheduler_list_count > 0 || saw_stop)) {
        print "scheduler_turn_cancel:scheduler_list=" scheduler_list_count ",stop=" saw_stop
        exit 0
      }
    }
  '
}

active_reasoning_block() {
  awk '
    /^[[:space:]│┃]*([◆⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+|::[[:space:]]*)?Thinking(\.\.\.|…)/ {
      if (!capture) {
        buf = ""
        capture = 1
      }
    }
    capture {
      buf = buf $0 "\n"
    }
    END {
      if (capture) {
        printf "%s", buf
      }
    }
  '
}

visible_thinking_elapsed_seconds() {
  awk '
    /Thinking(\.\.\.|…)[[:space:]]*[0-9]/ {
      line = $0
      sub(/^.*Thinking(\.\.\.|…)[[:space:]]*/, "", line)
      sub(/[[:space:]].*$/, "", line)
      token = line
    }
    END {
      if (token == "") exit 1
      total = 0
      rest = token
      if (match(rest, /^[0-9]+h/)) {
        total += substr(rest, RSTART, RLENGTH - 1) * 3600
        rest = substr(rest, RLENGTH + 1)
      }
      if (match(rest, /^[0-9]+m/)) {
        total += substr(rest, RSTART, RLENGTH - 1) * 60
        rest = substr(rest, RLENGTH + 1)
      }
      if (match(rest, /^[0-9]+([.][0-9]+)?s/)) {
        total += int(substr(rest, RSTART, RLENGTH - 1) + 0)
      }
      printf "%d\n", total
    }
  '
}

mark_structured_cycle() {
  signal="$1"
  elapsed="$2"
  snapshot="$3"

  tmux_set @dad_watchdog_status "observing:$signal"
  tmux_set @dad_watchdog_reason "$signal"
  tmux_set @dad_last_seen_summary "Mechanical watchdog observed structured Dad tool trajectory $signal after ${elapsed}s. It did not interrupt because structured tool cycles require deterministic repair/escalation, not pane-text loop recovery."

  case "$signal" in
    tool_cycle:scheduler_list:*)
      tmux_set @dad_scheduler_repair_required manual
      tmux_set @dad_failure_signature dad_scheduler_inspection_cycle
      ;;
    tool_cycle:*)
      tmux_set @dad_failure_signature dad_structured_tool_cycle
      ;;
  esac

  log "structured_cycle signal=$signal elapsed=${elapsed}s"

  if [[ "$elapsed" -ge "$max_thinking_seconds" ]]; then
    recover "dad_structured_tool_cycle:$signal:${elapsed}s" "$snapshot"
    {
      printf '%s STRUCTURED_CYCLE_RECOVERY %s elapsed=%ss\n' "$(date -Is)" "$signal" "$elapsed"
      printf '%s\n' "$snapshot" | tail -80
      printf '\n'
    } >> "$log_file"
  fi
}

mark_scheduler_cancel_observed() {
  signal="$1"
  snapshot="$2"

  tmux_set @dad_watchdog_status "observed:$signal"
  tmux_set @dad_watchdog_reason "$signal"
  tmux_set @dad_scheduler_repair_required manual
  tmux_set @dad_failure_signature dad_scheduler_prompt_cancel
  tmux_set @dad_last_seen_summary "Mechanical watchdog observed a scheduled DAD turn cancel itself after scheduler/stop tool use: $signal. It did not send Ctrl-C; the scheduler prompt contract needs explicit repair."

  {
    printf '%s SCHEDULER_CANCEL_OBSERVED %s\n' "$(date -Is)" "$signal"
    printf '%s\n' "$snapshot" | tail -80
    printf '\n'
  } >> "$log_file"
}

wait_until_not_thinking() {
  max_wait="$1"
  waited=0
  while [[ "$waited" -lt "$max_wait" ]]; do
    snapshot="$(tmux -S "$socket" capture-pane -t "$dad_pane" -p -S -40 2>/dev/null || true)"
    status_tail="$(printf '%s\n' "$snapshot" | tail -12)"
    if ! printf '%s\n' "$status_tail" | grep -Eq 'Thinking(\.\.\.|…)'; then
      return 0
    fi
    interruptible_sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
  return 1
}

recovering_finished() {
  snapshot="$1"
  tail_text="$(printf '%s\n' "$snapshot" | tail -22)"
  if printf '%s\n' "$tail_text" | grep -Eiq 'Thinking(\.\.\.|…)|Responding|Compacting|Waiting…|Waiting\.\.\.|^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; then
    return 1
  fi
  if printf '%s\n' "$tail_text" | grep -Eq '(^|[[:space:]│])❯[[:space:]]*$|Build anything|Type feedback|Grok Build|Turn completed'; then
    return 0
  fi
  return 1
}

clear_orphaned_lease_if_idle() {
  snapshot="$1"
  active="$(tmux_get @dad_loop_active)"
  [[ -n "$active" ]] || return 0
  started_at="$(tmux_get @dad_loop_started_at)"
  started_epoch="$(epoch "$started_at")"
  now="$(now_epoch)"
  age=0
  if [[ "$started_epoch" -gt 0 ]]; then
    age=$((now - started_epoch))
  fi
  [[ "$age" -ge "${DAD_WATCHDOG_ORPHANED_LEASE_GRACE_SECONDS:-20}" ]] || return 0
  tail_text="$(printf '%s\n' "$snapshot" | tail -18)"
  if printf '%s\n' "$tail_text" | grep -Eiq 'Thinking(\.\.\.|…)|Responding|Compacting|Waiting…|Waiting\.\.\.|^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; then
    return 0
  fi
  if ! printf '%s\n' "$tail_text" | grep -Eq '(^|[[:space:]│])❯[[:space:]]*$|Build anything|Type feedback|Grok Build'; then
    return 0
  fi
  run_id="$(tmux_get @dad_loop_run_id)"
  [[ -n "$run_id" ]] || {
    log "orphaned_lease_missing_run_id active=$active age=${age}s"
    return 0
  }
  if ! "$lease_helper" clear "$socket" "$window" "$run_id" orphaned_lease_cleared >/dev/null 2>&1; then
    log "orphaned_lease_clear_skipped active=$active run_id=$run_id current_run_id=$(tmux_get @dad_loop_run_id)"
    return 0
  fi
  tmux_set @dad_scheduler_repair_required orphaned_lease_cleared
  tmux_set @dad_last_seen_summary "Mechanical watchdog cleared orphaned scheduled-pass lease active=$active run_id=$run_id age=${age}s after Dad returned to a safe composer."
  log "cleared_orphaned_lease active=$active run_id=$run_id age=${age}s"
}

clear_resolved_lease_failure_signature() {
  active="$(tmux_get @dad_loop_active)"
  [[ -z "$active" ]] || return 0
  case "$(tmux_get @dad_failure_signature)" in
    dad_loop_orphaned_lease_cleared|dad_loop_stale_lease_cleared)
      tmux_set @dad_failure_signature ''
      log "cleared_resolved_lease_failure_signature"
      ;;
  esac
}

clear_loop_lease() {
  run_id="$(tmux_get @dad_loop_run_id)"
  if [[ -z "$run_id" ]]; then
    return 0
  fi
  if "$lease_helper" clear "$socket" "$window" "$run_id" watchdog_clear >/dev/null 2>&1; then
    log "cleared_loop_lease run_id=$run_id"
    return 0
  fi
  log "clear_loop_lease_skipped expected_run_id=$run_id current_run_id=$(tmux_get @dad_loop_run_id)"
  return 0
}

check_scheduler_health_if_due() {
  [[ -x "$scheduler_health" ]] || return 0
  now="$(now_epoch)"
  if [[ $((now - last_scheduler_health_check)) -lt "$scheduler_health_interval_seconds" ]]; then
    return 0
  fi
  last_scheduler_health_check="$now"
  if output="$("$scheduler_health" --socket "$socket" --window "$window" --repair 2>&1)"; then
    log "scheduler_health $output"
  else
    log "scheduler_health_error $output"
  fi
}

reset_blocked_recovery_budget_if_exhausted() {
  recoveries="$(tmux_get @dad_watchdog_recovery_count)"
  [[ "$recoveries" =~ ^[0-9]+$ ]] || recoveries=0
  blocked_signature="$(tmux_get @dad_watchdog_blocked_signature)"
  if [[ "$recoveries" -ge "$max_recoveries" || -n "$blocked_signature" ]]; then
    tmux_set @dad_watchdog_recovery_count 0
    tmux_set @dad_watchdog_blocked_signature ''
    log "reset_blocked_recovery_budget recoveries=$recoveries"
  fi
}

submit_recovery_command() {
  command_text="$1"
  label="$2"
  input_wait="${DAD_WATCHDOG_RECOVERY_INPUT_WAIT_SECONDS:-45}"
  if ! wait_until_recovering_finished "$input_wait"; then
    tmux_set @dad_watchdog_status "broken:${label}_input_not_ready"
    tmux_set @dad_last_seen_summary "Mechanical watchdog could not submit $label recovery command because Dad pane did not reach a safe composer/completed-turn state within ${input_wait}s. Son pane was left untouched."
    log "recovery_command_input_not_ready label=$label wait=${input_wait}s"
    return 1
  fi
  if ! printf '%s' "$command_text" |
      "$submit" --socket "$socket" --window "$window" --target "$dad_pane" --expect-command grok --mode text --stdin; then
    tmux_set @dad_watchdog_status "broken:${label}_submit_failed"
    tmux_set @dad_last_seen_summary "Mechanical watchdog could not submit $label recovery command through tmux-submit.sh. Son pane was left untouched."
    log "recovery_command_submit_failed label=$label"
    return 1
  fi
  log "recovery_command_submitted label=$label"
  return 0
}

wait_until_recovering_finished() {
  max_wait="$1"
  waited=0
  while [[ "$waited" -lt "$max_wait" ]]; do
    snapshot="$(tmux -S "$socket" capture-pane -t "$dad_pane" -p -S -80 2>/dev/null || true)"
    if recovering_finished "$snapshot"; then
      return 0
    fi
    interruptible_sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
  return 1
}

pane_accepting_input() {
  target_pane="$1"
  snapshot="$(tmux -S "$socket" capture-pane -t "$target_pane" -p -S -80 2>/dev/null || true)"
  recovering_finished "$snapshot"
}

wait_until_pane_accepting_input() {
  target_pane="$1"
  max_wait="$2"
  waited=0
  while [[ "$waited" -lt "$max_wait" ]]; do
    command="$(tmux -S "$socket" display-message -p -t "$target_pane" '#{pane_current_command}' 2>/dev/null || true)"
    if [[ "$command" == "grok" ]] && pane_accepting_input "$target_pane"; then
      return 0
    fi
    interruptible_sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
  return 1
}

replacement_bootstrap_prompt() {
  old_dad_pane="$1"
  new_dad_pane="$2"
  reason="$3"
  objective="$(tmux_get @dad_objective)"
  workspace_root="$(tmux_get @dad_workspace_root)"
  son_pane="$(tmux_get @dad_son_pane)"
  policy_file="${DAD_POLICY_VERSION_FILE:-$dad_root/POLICY_VERSION}"
  policy_version="$(tr -d '[:space:]' < "$policy_file" 2>/dev/null || true)"
  [[ -n "$policy_version" ]] || policy_version="failclosed-lease-evidence-v1"
  [[ -n "$objective" ]] || objective="the original DAD objective for this session"
  [[ -n "$workspace_root" ]] || workspace_root="$(tmux -S "$socket" display-message -p -t "$new_dad_pane" '#{pane_current_path}' 2>/dev/null || pwd)"
  [[ -n "$son_pane" ]] || son_pane="$(tmux_get @dad_son_watchdog_pane)"

  fast_prompt="<scheduler prompt generator unavailable>"
  deep_prompt="<scheduler prompt generator unavailable>"
  strategic_prompt="<scheduler prompt generator unavailable>"
  if [[ -x "$scheduler_prompt" && -n "$son_pane" ]]; then
    fast_prompt="$("$scheduler_prompt" fast "$window" "$son_pane" - <<<"$objective" 2>/dev/null || printf '<fast prompt generation failed>')"
    deep_prompt="$("$scheduler_prompt" deep "$window" "$son_pane" - <<<"$objective" 2>/dev/null || printf '<deep prompt generation failed>')"
    strategic_prompt="$("$scheduler_prompt" strategic "$window" "$son_pane" - <<<"$objective" 2>/dev/null || printf '<strategic prompt generation failed>')"
  fi

  cat <<EOF
DAD replacement supervisor bootstrap ($(date -Is)).

You are the replacement Dad pane for an already-live DAD window. The previous Dad pane exhausted mechanical recovery and is now quarantined. Do not kill, interrupt, send keys to, inspect through tools, or rely on the old Dad pane. Leave it alone.

Bootstrap facts:
- Window ID: $window
- New Dad pane: $new_dad_pane
- Old quarantined Dad pane: $old_dad_pane
- Son pane: ${son_pane:-unknown}
- Original objective: $objective
- Workspace root: $workspace_root
- Policy version: $policy_version
- Replacement reason: $reason

Immediate recovery duties:
1. Read $design_path and $skill_path from disk.
2. Treat tmux @dad_* metadata as authoritative. Confirm @dad_dad_pane=$new_dad_pane, @dad_son_pane=${son_pane:-unknown}, and @dad_state=working. Do not copy reasoning or memory from the old quarantined Dad pane.
3. Clear only stale Dad-recovery metadata: @dad_watchdog_recovery_count=0, @dad_watchdog_blocked_signature='', @dad_failure_signature='' unless a current non-Dad artifact blocker is still present.
4. This is an explicit replacement-repair turn, not a recurring scheduled pass. Use Grok scheduler tools directly to replace only this window's fast/deep/strategic scheduler tasks if needed, including any durable DAD tasks for this window. Do not touch unrelated tasks or the Son pane.
5. Recreate exactly three non-durable recurring DAD scheduler tasks for this window if they are missing or stale. Every scheduler_create call must set recurring=true and durable=false so closing the Grok/DAD session does not leave orphan background scheduler work:
   - fast: every 2 minutes, prompt from FAST_PROMPT below
   - deep: every 12 minutes, prompt from DEEP_PROMPT below
   - strategic: every 30 minutes, prompt from STRATEGIC_PROMPT below
6. Store returned scheduler IDs in @dad_fast_scheduler_id, @dad_deep_scheduler_id, and @dad_strategic_scheduler_id. Set @dad_policy_version=$policy_version and @dad_replacement_recovered_at=$(date -Is).
7. After repair, continue normal skeptical DAD supervision. If the Son is idle or parked at a claim, use the existing DAD policy to choose one objective-grounded next action. Do not declare completion from inherited claims.

FAST_PROMPT:
$fast_prompt

DEEP_PROMPT:
$deep_prompt

STRATEGIC_PROMPT:
$strategic_prompt
EOF
}

quarantine_old_dad_pane() {
  old_dad_pane="$1"
  [[ "$quarantine_old_dad" == "1" ]] || return 0
  pane_belongs_to_window "$old_dad_pane" || return 0

  quarantine_name="DAD-Quarantine-${window#@}-${old_dad_pane#%}"
  stopped_pids=()
  if [[ "$quarantine_suspend_old_dad" == "1" ]]; then
    tty_path="$(tmux -S "$socket" display-message -p -t "$old_dad_pane" '#{pane_tty}' 2>/dev/null || true)"
    tty_name="${tty_path#/dev/}"
    if [[ -n "$tty_name" ]]; then
      while read -r pid comm; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$comm" == "grok" ]] || continue
        if kill -STOP "$pid" 2>/dev/null; then
          stopped_pids+=("$pid")
        fi
      done < <(ps -t "$tty_name" -o pid= -o comm= 2>/dev/null || true)
    fi
    interruptible_sleep 1
  fi

  if tmux -S "$socket" break-pane -d -s "$old_dad_pane" -n "$quarantine_name" >/dev/null 2>&1; then
    quarantine_window="$(tmux -S "$socket" display-message -p -t "$old_dad_pane" '#{window_id}' 2>/dev/null || true)"
    tmux_set @dad_quarantined_old_dad_pane "$old_dad_pane"
    tmux_set @dad_quarantined_old_dad_window "$quarantine_window"
    tmux_set @dad_quarantined_old_dad_at "$(date -Is)"
    tmux_set @dad_quarantine_method "sigstop_and_break_pane"
    if [[ "${#stopped_pids[@]}" -gt 0 ]]; then
      stopped_pid_list="$(IFS=,; printf '%s' "${stopped_pids[*]}")"
      tmux_set @dad_quarantined_old_dad_pids "$stopped_pid_list"
    fi
    if [[ -n "$quarantine_window" ]]; then
      tmux -S "$socket" set-window-option -t "$quarantine_window" @dad_quarantined_from_window "$window" >/dev/null 2>&1 || true
      tmux -S "$socket" set-window-option -t "$quarantine_window" @dad_quarantined_reason "$(tmux_get @dad_replacement_reason)" >/dev/null 2>&1 || true
      if [[ "${#stopped_pids[@]}" -gt 0 ]]; then
        tmux -S "$socket" set-window-option -t "$quarantine_window" @dad_quarantined_old_dad_pids "$stopped_pid_list" >/dev/null 2>&1 || true
      fi
    fi
    log "quarantined_old_dad old=$old_dad_pane quarantine_window=${quarantine_window:-unknown}"
    return 0
  fi

  tmux_set @dad_quarantine_status failed
  log "quarantine_old_dad_failed old=$old_dad_pane"
  return 1
}

replace_dad_pane() {
  reason="$1"
  snapshot="$2"
  [[ "$replacement_enabled" == "1" ]] || return 1
  replacements="$(tmux_get @dad_watchdog_replacement_count)"
  [[ "$replacements" =~ ^[0-9]+$ ]] || replacements=0
  if [[ "$replacements" -ge "$max_replacements" ]]; then
    tmux_set @dad_watchdog_status blocked:too_many_replacements
    tmux_set @dad_last_seen_summary "Mechanical watchdog could not replace Dad pane after $replacements replacements; manual repair required. Son pane was left untouched."
    log "blocked too_many_replacements count=$replacements reason=$reason"
    return 1
  fi

  son_pane="$(tmux_get @dad_son_pane)"
  old_dad_pane="$dad_pane"
  current_path="$(tmux -S "$socket" display-message -p -t "$old_dad_pane" '#{pane_current_path}' 2>/dev/null || true)"
  [[ -n "$current_path" ]] || current_path="$(tmux_get @dad_workspace_root)"
  [[ -n "$current_path" ]] || current_path="$PWD"

  tmux_set @dad_state recovering
  tmux_set @dad_watchdog_status replacing_dad_pane
  tmux_set @dad_watchdog_reason "$reason"
  tmux_set @dad_replaced_old_dad_pane "$old_dad_pane"
  tmux_set @dad_replacement_started_at "$(date -Is)"
  tmux_set @dad_replacement_reason "$reason"

  if ! new_dad_pane="$(tmux -S "$socket" split-window -t "$window" -h -d -c "$current_path" -P -F '#{pane_id}' "$replacement_command" 2>/dev/null)"; then
    tmux_set @dad_state broken
    tmux_set @dad_watchdog_status broken:dad_replacement_failed
    tmux_set @dad_last_seen_summary "Mechanical watchdog could not create a replacement Dad pane. It did not kill the old Dad pane or touch the Son pane."
    log "replacement_failed split_window reason=$reason"
    return 1
  fi

  tmux_set @dad_dad_pane "$new_dad_pane"
  tmux_set @dad_watchdog_replacement_count "$((replacements + 1))"
  tmux_set @dad_watchdog_recovery_count 0
  tmux_set @dad_watchdog_blocked_signature ''
  tmux_set @dad_failure_signature ''
  clear_loop_lease
  quarantine_old_dad_pane "$old_dad_pane" || true
  tmux_set @dad_last_seen_summary "Mechanical watchdog replaced Dad pane $old_dad_pane with $new_dad_pane after exhausted recovery: $reason. The old Dad pane was suspended and moved to quarantine when possible, not killed. Son pane was left untouched."

  {
    printf '%s DAD_REPLACEMENT_START old=%s new=%s reason=%s\n' "$(date -Is)" "$old_dad_pane" "$new_dad_pane" "$reason"
    printf '%s\n' "$snapshot" | tail -80
    printf '\n'
  } >> "$log_file"

  if ! wait_until_pane_accepting_input "$new_dad_pane" "$replacement_wait_seconds"; then
    tmux_set @dad_state broken
    tmux_set @dad_watchdog_status broken:replacement_input_not_ready
    tmux_set @dad_last_seen_summary "Mechanical watchdog created replacement Dad pane $new_dad_pane but it did not reach safe input within ${replacement_wait_seconds}s. Old Dad pane $old_dad_pane was not killed."
    log "replacement_input_not_ready new=$new_dad_pane"
    return 1
  fi

  prompt="$(replacement_bootstrap_prompt "$old_dad_pane" "$new_dad_pane" "$reason")"
  if ! printf '%s' "$prompt" |
      "$submit" --socket "$socket" --window "$window" --target "$new_dad_pane" --expect-command grok --mode text --stdin; then
    tmux_set @dad_state broken
    tmux_set @dad_watchdog_status broken:replacement_bootstrap_submit_failed
    tmux_set @dad_last_seen_summary "Mechanical watchdog created replacement Dad pane $new_dad_pane but could not submit the replacement bootstrap prompt. Old Dad pane $old_dad_pane was not killed."
    log "replacement_bootstrap_submit_failed new=$new_dad_pane"
    return 1
  fi

  tmux_set @dad_state working
  tmux_set @dad_watchdog_status replaced:handoff
  tmux_set @dad_watchdog_recovered_at "$(date -Is)"
  tmux_set @dad_replacement_completed_at "$(date -Is)"
  tmux_set @dad_last_seen_summary "Mechanical watchdog handed supervision to replacement Dad pane $new_dad_pane. Old Dad pane $old_dad_pane is quarantined out of the DAD window when possible and was not killed; Son pane was left untouched."
  log "replacement_submitted old=$old_dad_pane new=$new_dad_pane reason=$reason"

  new_watchdog_log="${DAD_WATCHDOG_LOG:-$log_root/dad-watchdog-${window#@}-${new_dad_pane#%}.log}"
  dad_spawn_daemon "$socket" "$window" "$new_watchdog_log" "$script_path" "$socket" "$window" "$new_dad_pane" >/dev/null 2>&1 || true
  if [[ -x "$idle_controller" && -n "$son_pane" ]]; then
    new_idle_log="${DAD_IDLE_CONTROLLER_LOG:-$log_root/dad-idle-controller-${window#@}-${son_pane#%}.log}"
    dad_spawn_daemon "$socket" "$window" "$new_idle_log" "$idle_controller" "$socket" "$window" "$new_dad_pane" "$son_pane" >/dev/null 2>&1 || true
  fi
  return 0
}

recover() {
  reason="$1"
  snapshot="$2"
  old_recoveries="$(tmux_get @dad_watchdog_recovery_count)"
  [[ "$old_recoveries" =~ ^[0-9]+$ ]] || old_recoveries=0
  if [[ "$old_recoveries" -ge "$max_recoveries" ]]; then
    if replace_dad_pane "$reason" "$snapshot"; then
      exit 0
    fi
    block_signature="$(recovery_block_signature "$reason")"
    if [[ "$(tmux_get @dad_watchdog_blocked_signature)" == "$block_signature" ]]; then
      return 0
    fi
    old_count="$(tmux_get @dad_failure_count)"
    [[ "$old_count" =~ ^[0-9]+$ ]] || old_count=0
    tmux_set @dad_failure_count "$((old_count + 1))"
    tmux_set @dad_state broken
    tmux_set @dad_watchdog_status blocked:too_many_recoveries
    tmux_set @dad_watchdog_reason "$reason"
    tmux_set @dad_watchdog_blocked_signature "$block_signature"
    tmux_set @dad_last_seen_summary "Mechanical watchdog blocked another Dad recovery before sending Ctrl-C because $old_recoveries recoveries already reached the limit. Son pane was left untouched."
    log "blocked too_many_recoveries count=$old_recoveries reason=$reason"
    return 0
  fi
  new_recoveries=$((old_recoveries + 1))

  tmux -S "$socket" send-keys -t "$dad_pane" C-c >/dev/null 2>&1 || true
  tmux_set @dad_state recovering
  tmux_set @dad_failure_signature dad_self_repetition_loop
  tmux_set @dad_watchdog_status recovering
  tmux_set @dad_watchdog_reason "$reason"
  tmux_set @dad_watchdog_blocked_signature ''
  tmux_set @dad_watchdog_tripped_at "$(date -Is)"
  tmux_set @dad_watchdog_recovery_count "$new_recoveries"
  clear_loop_lease
  tmux_set @dad_last_seen_summary "Mechanical watchdog interrupted Dad pane $dad_pane for recovery: $reason. Son pane was left untouched."

  {
    printf '%s RECOVERY_START %s\n' "$(date -Is)" "$reason"
    printf '%s\n' "$snapshot" | tail -80
    printf '\n'
  } >> "$log_file"

  if ! wait_until_not_thinking 30; then
    tmux_set @dad_state broken
    tmux_set @dad_watchdog_status broken
    tmux_set @dad_failure_count "$new_recoveries"
    tmux_set @dad_last_seen_summary "Mechanical watchdog could not stop Dad pane $dad_pane cleanly after $reason. Son pane was left untouched."
    log "broken unable_to_interrupt"
    return 0
  fi

  tmux_set @dad_watchdog_status compacting
  tmux_set @dad_watchdog_compact_started_at "$(date -Is)"
  if [[ -n "$memory_recovery_command" ]]; then
    if ! submit_recovery_command "$memory_recovery_command" memory_clear; then
      tmux_set @dad_state broken
      return 0
    fi
  fi
  if ! submit_recovery_command "$compact_prompt" compact; then
    tmux_set @dad_state broken
    return 0
  fi

  if wait_until_recovering_finished "$compact_wait_seconds"; then
    tmux_set @dad_state working
    tmux_set @dad_failure_signature ''
    clear_loop_lease
    tmux_set @dad_watchdog_status running
    tmux_set @dad_watchdog_recovered_at "$(date -Is)"
    tmux_set @dad_last_seen_summary "Mechanical watchdog recovered Dad pane $dad_pane by interrupting the degenerate turn and running /compact. Supervision may continue; Son pane was left untouched."
    log "recovered reason=$reason"
  else
    tmux_set @dad_state broken
    tmux_set @dad_watchdog_status broken
    tmux_set @dad_failure_count "$new_recoveries"
    tmux_set @dad_last_seen_summary "Mechanical watchdog sent /compact to Dad pane $dad_pane, but compaction did not finish within ${compact_wait_seconds}s. Son pane was left untouched."
    log "broken compact_timeout"
  fi

  thinking_since=""
  return 0
}

if [[ "${DAD_WATCHDOG_TEST_CLASSIFY:-0}" == "1" ]]; then
  input="$(cat)"
  cancel="$(printf '%s\n' "$input" | scheduler_cancel_signal || true)"
  if [[ -n "$cancel" ]]; then
    printf '%s\n' "$cancel"
    exit 0
  fi
  structured="$(printf '%s\n' "$input" | structured_trace_signal || true)"
  if [[ -n "$structured" ]]; then
    printf '%s\n' "$structured"
    exit 0
  fi
  semantic="$(printf '%s\n' "$input" | semantic_repetition_signal || true)"
  if [[ -n "$semantic" ]]; then
    printf '%s\n' "$semantic"
    exit 0
  fi
  normalized="$(printf '%s\n' "$input" | normalized_signal || true)"
  if [[ -n "$normalized" ]]; then
    printf '%s\n' "$normalized"
    exit 0
  fi
  exit 1
fi

if [[ "${DAD_WATCHDOG_TEST_BLOCK_SIGNATURE:-0}" == "1" ]]; then
  recovery_block_signature "${4:-${1:-}}"
  exit 0
fi

if [[ "${DAD_WATCHDOG_TEST_BROKEN_POLICY:-0}" == "1" ]]; then
  input="$(cat)"
  if recovering_finished "$input"; then
    printf 'recover_broken_to_working_reset\n'
  else
    printf 'monitor_broken\n'
  fi
  exit 0
fi

if [[ "${DAD_WATCHDOG_TEST_VISIBLE_ELAPSED:-0}" == "1" ]]; then
  input="$(cat)"
  visible_thinking_elapsed_seconds <<<"$input"
  exit 0
fi

if ! window_exists; then
  echo "watchdog: window not found: $window" >&2
  exit 1
fi

if ! pane_belongs_to_window "$dad_pane"; then
  echo "watchdog: Dad pane $dad_pane is not live in window $window" >&2
  exit 1
fi

existing_pid="$(tmux_get @dad_watchdog_pid)"
if pid_matches_this_watchdog "$existing_pid"; then
  log "duplicate existing_pid=$existing_pid window=$window dad_pane=$dad_pane"
  exit 0
fi

cleanup() {
  if window_exists && [[ "$(tmux_get @dad_watchdog_pid)" == "$$" ]]; then
    tmux_set @dad_watchdog_status exited
    tmux_set @dad_watchdog_exited_at "$(date -Is)"
  fi
}

terminate() {
  signal="${1:-TERM}"
  child="${sleep_pid:-}"
  if [[ "$child" =~ ^[0-9]+$ ]]; then
    kill "$child" 2>/dev/null || true
  fi
  log "exit signal=$signal"
  exit 0
}

interruptible_sleep() {
  duration="$1"
  sleep "$duration" &
  sleep_pid="$!"
  wait "$sleep_pid" 2>/dev/null || true
  sleep_pid=""
}

trap cleanup EXIT
trap 'terminate TERM' TERM
trap 'terminate INT' INT

tmux_set @dad_watchdog_pid "$$"
tmux_set @dad_watchdog_started_at "$started_at"
tmux_set @dad_watchdog_status running
log "started socket=$socket window=$window dad_pane=$dad_pane"

while true; do
  if ! window_exists; then
    log "exit window_missing window=$window"
    exit 0
  fi

  if ! pane_belongs_to_window "$dad_pane"; then
    log "exit dad_pane_missing pane=$dad_pane"
    tmux_set @dad_watchdog_status exited
    exit 0
  fi

  if ! current_dad_pane_matches; then
    tmux_set @dad_watchdog_status exited:dad_pane_replaced
    log "exit dad_pane_replaced old=$dad_pane current=$(tmux_get @dad_dad_pane)"
    exit 0
  fi

  if ! pane_command_is_grok; then
    if [[ -z "$command_mismatch_since" ]]; then
      command_mismatch_since="$(now_epoch)"
    fi
    mismatch_elapsed=$(( $(now_epoch) - command_mismatch_since ))
    tmux_set @dad_watchdog_status waiting:command_mismatch
    log "skip command_mismatch pane=$dad_pane elapsed=${mismatch_elapsed}s"
    if [[ "$mismatch_elapsed" -ge "$command_mismatch_max_seconds" ]]; then
      tmux_set @dad_state broken
      clear_loop_lease
      tmux_set @dad_watchdog_status blocked:command_mismatch
      tmux_set @dad_failure_signature dad_pane_command_mismatch
      tmux_set @dad_last_seen_summary "Mechanical watchdog found Dad pane $dad_pane is no longer running grok for ${mismatch_elapsed}s. It cleared scheduler lease metadata and marked DAD broken instead of waiting forever."
    fi
    interruptible_sleep "$poll_seconds"
    continue
  fi
  command_mismatch_since=""

  state="$(tmux_get @dad_state)"
  case "$state" in
    stopped)
      tmux_set @dad_watchdog_status exited
      log "exit state=stopped"
      exit 0
      ;;
    paused)
      tmux_set @dad_watchdog_status "idle:paused"
      interruptible_sleep "$poll_seconds"
      continue
      ;;
    broken)
      broken_snapshot="$(tmux -S "$socket" capture-pane -t "$dad_pane" -p -S -100 2>/dev/null || true)"
      clear_orphaned_lease_if_idle "$broken_snapshot"
      clear_resolved_lease_failure_signature
      if recovering_finished "$broken_snapshot"; then
        reset_blocked_recovery_budget_if_exhausted
        tmux_set @dad_state working
        tmux_set @dad_failure_signature ''
        clear_loop_lease
        tmux_set @dad_watchdog_status running
        tmux_set @dad_watchdog_recovered_at "$(date -Is)"
        tmux_set @dad_last_seen_summary "Mechanical watchdog observed a previously broken Dad pane back at a safe composer/completed turn and returned DAD to working. Son pane was left untouched."
        log "recovered_observed state=broken"
        thinking_since=""
        broken_active_since=""
      else
        broken_tail="$(printf '%s\n' "$broken_snapshot" | tail -20)"
        if printf '%s\n' "$broken_tail" | grep -Eiq 'Thinking(\.\.\.|…)|Responding|Compacting|Waiting…|Waiting\.\.\.|^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; then
          if [[ -z "$broken_active_since" ]]; then
            broken_active_since="$(now_epoch)"
          fi
          broken_elapsed=$(( $(now_epoch) - broken_active_since ))
          visible_elapsed="$(printf '%s\n' "$broken_tail" | visible_thinking_elapsed_seconds || true)"
          if [[ "$visible_elapsed" =~ ^[0-9]+$ && "$visible_elapsed" -gt "$broken_elapsed" ]]; then
            broken_elapsed="$visible_elapsed"
          fi
          if [[ "$broken_elapsed" -ge "${DAD_WATCHDOG_BROKEN_ACTIVE_MAX_SECONDS:-180}" ]]; then
            recover "broken_active_timeout:${broken_elapsed}s" "$broken_snapshot"
          else
            tmux_set @dad_watchdog_status "broken:monitoring_active"
          fi
        else
          broken_active_since=""
          tmux_set @dad_watchdog_status "broken:monitoring"
        fi
      fi
      interruptible_sleep "$poll_seconds"
      continue
      ;;
    recovering)
      recovery_snapshot="$(tmux -S "$socket" capture-pane -t "$dad_pane" -p -S -80 2>/dev/null || true)"
      if recovering_finished "$recovery_snapshot"; then
        reset_blocked_recovery_budget_if_exhausted
        tmux_set @dad_state working
        tmux_set @dad_failure_signature ''
        clear_loop_lease
        tmux_set @dad_watchdog_status running
        tmux_set @dad_watchdog_recovered_at "$(date -Is)"
        tmux_set @dad_last_seen_summary "Mechanical watchdog observed Dad recovery/compaction complete and returned DAD to working. Son pane was left untouched."
        log "recovered_observed state=recovering"
        thinking_since=""
      else
        recovery_tail="$(printf '%s\n' "$recovery_snapshot" | tail -20)"
        recovery_has_scheduler=0
        if printf '%s\n' "$recovery_snapshot" | grep -Fq 'DAD scheduler trampoline'; then
          recovery_has_scheduler=1
        fi
        recovery_thinking=0
        if printf '%s\n' "$recovery_tail" | grep -Eq 'Thinking(\.\.\.|…)'; then
          recovery_thinking=1
        fi
        if [[ "$recovery_has_scheduler" -eq 1 && "$recovery_thinking" -eq 1 ]]; then
          if [[ -z "$thinking_since" ]]; then
            thinking_since="$(now_epoch)"
          fi
          elapsed=$(( $(now_epoch) - thinking_since ))
          visible_elapsed="$(printf '%s\n' "$recovery_tail" | visible_thinking_elapsed_seconds || true)"
          if [[ "$visible_elapsed" =~ ^[0-9]+$ && "$visible_elapsed" -gt "$elapsed" ]]; then
            elapsed="$visible_elapsed"
          fi
          active_text="$(printf '%s\n' "$recovery_snapshot" | tail -100 | active_reasoning_block || true)"
          [[ -n "$active_text" ]] || active_text="$(printf '%s\n' "$recovery_snapshot" | tail -40)"
          signal="$(printf '%s\n' "$active_text" | semantic_repetition_signal || true)"
          [[ -n "$signal" ]] || signal="$(printf '%s\n' "$active_text" | normalized_signal || true)"
          if [[ -n "$signal" && "$elapsed" -ge "$repeat_grace_seconds" ]]; then
            recover "recovering_scheduler_turn_loop:$signal" "$recovery_snapshot"
          elif [[ "$elapsed" -ge "$recovering_max_thinking_seconds" ]]; then
            recover "recovering_scheduler_turn_timeout:${elapsed}s" "$recovery_snapshot"
          else
            tmux_set @dad_watchdog_status "recovering:scheduled_turn_active"
          fi
        else
          thinking_since=""
          tmux_set @dad_watchdog_status recovering
        fi
      fi
      interruptible_sleep "$poll_seconds"
      continue
      ;;
  esac

  current_status="$(tmux_get @dad_watchdog_status)"
  if [[ "$current_status" == idle:paused ]]; then
    tmux_set @dad_watchdog_status running
  fi
  check_scheduler_health_if_due

  pane_text="$(tmux -S "$socket" capture-pane -t "$dad_pane" -p -S -140 2>/dev/null || true)"
  status_tail="$(printf '%s\n' "$pane_text" | tail -14)"
  clear_orphaned_lease_if_idle "$pane_text"
  clear_resolved_lease_failure_signature
  cancel_signal="$(printf '%s\n' "$pane_text" | tail -100 | scheduler_cancel_signal || true)"
  if [[ -n "$cancel_signal" && "$cancel_signal" != "$last_scheduler_cancel_signature" ]]; then
    last_scheduler_cancel_signature="$cancel_signal"
    mark_scheduler_cancel_observed "$cancel_signal" "$pane_text"
  fi

  has_scheduler_context=0
  if printf '%s\n' "$pane_text" | grep -Fq 'DAD scheduler trampoline'; then
    has_scheduler_context=1
  fi
  if [[ -n "$(tmux_get @dad_loop_active)" ]]; then
    has_scheduler_context=1
  fi

  active_thinking=0
  if printf '%s\n' "$status_tail" | grep -Eq 'Thinking(\.\.\.|…)'; then
    active_thinking=1
  fi

  if [[ "$has_scheduler_context" -eq 1 && "$active_thinking" -eq 1 ]]; then
    if [[ -z "$thinking_since" ]]; then
      thinking_since="$(now_epoch)"
    fi

    elapsed=$(( $(now_epoch) - thinking_since ))
    visible_elapsed="$(printf '%s\n' "$status_tail" | visible_thinking_elapsed_seconds || true)"
    if [[ "$visible_elapsed" =~ ^[0-9]+$ && "$visible_elapsed" -gt "$elapsed" ]]; then
      elapsed="$visible_elapsed"
    fi
    active_text="$(printf '%s\n' "$pane_text" | tail -100 | active_reasoning_block || true)"
    if [[ -z "$active_text" ]]; then
      active_text="$(printf '%s\n' "$pane_text" | tail -40)"
    fi
    structured_signal="$(printf '%s\n' "$active_text" | structured_trace_signal || true)"
    if [[ -n "$structured_signal" ]]; then
      mark_structured_cycle "$structured_signal" "$elapsed" "$pane_text"
      interruptible_sleep "$poll_seconds"
      continue
    fi

    signal="$(printf '%s\n' "$active_text" | semantic_repetition_signal || true)"
    [[ -n "$signal" ]] || signal="$(printf '%s\n' "$active_text" | normalized_signal || true)"

    if [[ -n "$signal" && "$elapsed" -ge "$repeat_grace_seconds" ]]; then
      recover "dad_self_repetition_loop:$signal" "$pane_text"
      interruptible_sleep "$poll_seconds"
      continue
    elif [[ "$elapsed" -ge "$max_thinking_seconds" ]]; then
      recover "dad_turn_timeout:${elapsed}s" "$pane_text"
      interruptible_sleep "$poll_seconds"
      continue
    fi
  else
    thinking_since=""
  fi

  interruptible_sleep "$poll_seconds"
done
