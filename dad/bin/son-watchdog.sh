#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: son-watchdog.sh <tmux-socket> <window-id> <son-pane-id>" >&2
  exit 2
fi

socket="$1"
window="$2"
son_pane="$3"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dad-env.sh
source "$script_dir/dad-env.sh"
script_path="${DAD_SON_WATCHDOG_SCRIPT:-$script_dir/son-watchdog.sh}"
evidence_runner="${DAD_EVIDENCE_RUNNER:-$script_dir/evidence-runner.py}"
dad_root="$(dad_root)"
data_root="$(dad_data_root)"
log_root="$(dad_logs_root)"

poll_seconds="${DAD_SON_WATCHDOG_POLL_SECONDS:-5}"
repeat_grace_seconds="${DAD_SON_WATCHDOG_REPEAT_GRACE_SECONDS:-60}"
max_recoveries="${DAD_SON_WATCHDOG_MAX_RECOVERIES:-3}"
input_wait_seconds="${DAD_SON_WATCHDOG_INPUT_WAIT_SECONDS:-45}"
compact_wait_seconds="${DAD_SON_WATCHDOG_COMPACT_WAIT_SECONDS:-300}"
memory_recovery_command="${DAD_SON_WATCHDOG_MEMORY_RECOVERY_COMMAND:-/memory off}"
compact_prompt="${DAD_SON_WATCHDOG_COMPACT_PROMPT:-/compact Preserve only the Son operating state for this DAD-supervised task: original objective, current workspace, latest accepted checkpoint, latest failing/missing evidence, and the next truthful recovery action. Discard the degenerate repeated low-value text and any instruction that demanded a PASS-only answer. Do not preserve the loop transcript as useful memory.}"
submit="${DAD_TMUX_SUBMIT:-$script_dir/tmux-submit.sh}"
log_file="${DAD_SON_WATCHDOG_LOG:-$log_root/dad-son-watchdog-${window#@}-${son_pane#%}.log}"
started_at="$(date -Is)"
thinking_since=""
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

log() {
  dad_log_append "$log_file" "$*"
}

window_exists() {
  tmux -S "$socket" display-message -p -t "$window" '#{window_id}' >/dev/null 2>&1
}

pane_belongs_to_window() {
  tmux -S "$socket" list-panes -t "$window" -F '#{pane_id} #{pane_dead}' 2>/dev/null |
    awk -v pane="$son_pane" '$1 == pane && $2 == "0" { found = 1 } END { exit(found ? 0 : 1) }'
}

pane_command_is_grok() {
  command="$(tmux -S "$socket" display-message -p -t "$son_pane" '#{pane_current_command}' 2>/dev/null || true)"
  [[ "$command" == "grok" ]]
}

pid_matches_this_watchdog() {
  pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  cmdline="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  printf '%s\n' "$cmdline" | grep -Fxq "$script_path" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$socket" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$window" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$son_pane"
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

active_reasoning_block() {
  awk '
    /^[[:space:]│┃]*([◆⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+|::[[:space:]]*)?Thinking(\.\.\.|…)/ {
      if (!capture) {
        buf = ""
        capture = 1
      }
      next
    }
    capture && /^[[:space:]]*#[0-9]+[[:space:]]/ { exit }
    capture && /^[[:space:]│╭╰─]*[╭╰]/ { exit }
    capture && /Grok Build|Shift\+Tab|Ctrl\+|Enter:|Space:prompt|Build anything/ { exit }
    capture && /^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Thinking|Waiting|Responding|Running|Reading|Searching|Editing|Writing|Applying|Compacting)/ { exit }
    capture {
      if ($0 ~ /^[[:space:]│┃]*$/ || $0 ~ /^[[:space:]│┃]+/) {
        buf = buf $0 "\n"
      }
    }
    END {
      if (capture) {
        printf "%s", buf
      }
    }
  '
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
      if (line ~ /^[[:space:]]*#[0-9]+[[:space:]]/) next
      if (line ~ /[│┃][[:space:]]*❯/) next
      if (lower ~ /thinking|grok build|shift|ctrl|enter:|resume this session|grok --resume/) next
      if (lower ~ /\[loop\]|scheduler trampoline|tool_use|pre_tool_use|post_tool_use/) next
      if (lower ~ /thought for|run |read |edit |write |apply |search |skill |tmux |capture-pane|show-options/) next
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
      if (key ~ /^(yes|good|ok|okay|done|the end|end|normal|the answer|the response is that|i will stop here)$/) {
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
      if (total >= 3 && total <= 14 && unique <= 6 && closure_count >= 3) {
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
      if (line ~ /^[[:space:]]*#[0-9]+[[:space:]]/) next
      if (line ~ /[│┃][[:space:]]*❯/) next
      if (lower ~ /thinking|grok build|shift|ctrl|enter:|resume this session|grok --resume/) next
      if (lower ~ /\[loop\]|tool_use|pre_tool_use|post_tool_use/) next
      if (lower ~ /thought for|run |read |edit |write |apply |search |skill |tmux |capture-pane|show-options/) next
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

son_loop_signal() {
  snapshot="$1"
  tail_text="$(printf '%s\n' "$snapshot" | tail -100)"
  status_tail="$(printf '%s\n' "$snapshot" | tail -20)"

  if ! printf '%s\n' "$status_tail" | grep -Eiq 'Thinking(\.\.\.|…)'; then
    return 1
  fi
  if printf '%s\n' "$tail_text" | grep -Eiq '^[[:space:]│┃]*[◆⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Run|Read|Edit|Write|Apply|Search|Fetch|Compile|Test|Install)|^[[:space:]│┃]*◆[[:space:]]+(Run|Read|Edit|Write|Apply|Search|Fetch|Compile|Test|Install)|^[[:space:]│┃]*(pre_tool_use|post_tool_use|Tool Use)|[[:space:]](pre_tool_use|post_tool_use)[[:space:]]*$'; then
    return 1
  fi

  elapsed="$(printf '%s\n' "$status_tail" | visible_thinking_elapsed_seconds || true)"
  if [[ ! "$elapsed" =~ ^[0-9]+$ ]]; then
    if [[ -z "$thinking_since" ]]; then
      elapsed=0
    else
      elapsed=$(( $(now_epoch) - thinking_since ))
    fi
  fi
  [[ "$elapsed" -ge "$repeat_grace_seconds" ]] || return 1

  active_text="$(printf '%s\n' "$tail_text" | active_reasoning_block || true)"
  [[ -n "$active_text" ]] || active_text="$tail_text"
  signal="$(printf '%s\n' "$active_text" | semantic_repetition_signal || true)"
  [[ -n "$signal" ]] || signal="$(printf '%s\n' "$active_text" | normalized_signal || true)"
  [[ -n "$signal" ]] || return 1

  printf '%s:%ss' "$signal" "$elapsed"
}

safe_for_input() {
  snapshot="$1"
  tail_text="$(printf '%s\n' "$snapshot" | tail -22)"
  if printf '%s\n' "$tail_text" | grep -Eiq 'Thinking(\.\.\.|…)|Responding|Compacting|Waiting…|Waiting\.\.\.|^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; then
    return 1
  fi
  if printf '%s\n' "$tail_text" | grep -Eq '(^|[[:space:]│])❯[[:space:]]*$|Build anything|Type feedback|Grok Build|Turn completed|Turn cancelled|Turn canceled'; then
    return 0
  fi
  return 1
}

wait_until_not_thinking() {
  max_wait="$1"
  waited=0
  while [[ "$waited" -lt "$max_wait" ]]; do
    snapshot="$(tmux -S "$socket" capture-pane -t "$son_pane" -p -S -50 2>/dev/null || true)"
    if ! printf '%s\n' "$snapshot" | tail -16 | grep -Eq 'Thinking(\.\.\.|…)'; then
      return 0
    fi
    interruptible_sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
  return 1
}

wait_until_safe_for_input() {
  max_wait="$1"
  waited=0
  while [[ "$waited" -lt "$max_wait" ]]; do
    snapshot="$(tmux -S "$socket" capture-pane -t "$son_pane" -p -S -80 2>/dev/null || true)"
    if safe_for_input "$snapshot"; then
      return 0
    fi
    interruptible_sleep "$poll_seconds"
    waited=$((waited + poll_seconds))
  done
  return 1
}

submit_recovery_command() {
  text="$1"
  label="$2"
  if ! wait_until_safe_for_input "$input_wait_seconds"; then
    tmux_set @dad_son_watchdog_status "broken:${label}_input_not_ready"
    log "recovery_input_not_ready label=$label"
    return 1
  fi
  if ! printf '%s' "$text" |
      "$submit" --socket "$socket" --window "$window" --target "$son_pane" --expect-command grok --mode text --stdin; then
    tmux_set @dad_son_watchdog_status "broken:${label}_submit_failed"
    log "recovery_submit_failed label=$label"
    return 1
  fi
  log "recovery_submitted label=$label"
}

reset_blocked_recovery_budget_if_safe() {
  snapshot="$1"
  safe_for_input "$snapshot" || return 0
  recoveries="$(tmux_get @dad_son_watchdog_recovery_count)"
  [[ "$recoveries" =~ ^[0-9]+$ ]] || recoveries=0
  blocked_signature="$(tmux_get @dad_son_watchdog_blocked_signature)"
  if [[ "$recoveries" -ge "$max_recoveries" || -n "$blocked_signature" ]]; then
    tmux_set @dad_son_watchdog_recovery_count 0
    tmux_set @dad_son_watchdog_blocked_signature ''
    tmux_set @dad_son_loop_reason ''
    log "reset_blocked_recovery_budget safe_input recoveries=$recoveries"
  fi
}

objective_text() {
  objective="$(tmux_get @dad_objective)"
  if [[ -z "$objective" ]]; then
    window_name="$(tmux -S "$socket" display-message -p -t "$window" '#{window_name}' 2>/dev/null || true)"
    objective_file="$data_root/windows/$window_name/objective.txt"
    if [[ -r "$objective_file" ]]; then
      objective="$(<"$objective_file")"
    fi
  fi
  printf '%s\n' "${objective:-the original DAD objective for this session}" | awk '{
    text = text $0 "\n"
  } END {
    if (length(text) > 1200) print substr(text, 1, 1200) "...[truncated]"
    else printf "%s", text
  }'
}

recovery_prompt() {
  reason="$1"
  objective="$(objective_text)"
  evidence_status="$(tmux_get @dad_evidence_contract_last_status)"
  verifier_verdict="$(tmux_get @dad_verifier_last_verdict)"
  corrective_task="$(tmux_get @dad_last_corrective_task)"
  frontier="$(tmux_get @dad_improvement_frontier)"
  cat <<EOF
DAD mechanical SON loop recovery ($(date -Is)).

Your previous active turn was interrupted because the external DAD Son watchdog detected a low-entropy self-repetition loop: $reason

Original objective:
$objective

Current Dad metadata:
- verifier_last_verdict: ${verifier_verdict:-unknown}
- evidence_contract_last_status: ${evidence_status:-unknown}
- last_corrective_task: ${corrective_task:-unknown}
- improvement_frontier: ${frontier:-unknown}

Important correction: do not try to satisfy any previous instruction by inventing or forcing a PASS. If a gate/check fails, returns NEEDS_MORE_EVIDENCE, lacks assertions, or is impossible as stated, report the literal actual result and fix the smallest blocker or produce the missing evidence. Truthful FAIL/NEEDS_MORE_EVIDENCE is progress; fabricated PASS or endless thinking is failure.

Now take exactly one bounded objective-relevant recovery step. Prefer: inspect the cited evidence/gate result, run the deterministic gate if needed, report the actual PASS/FAIL/NEEDS_MORE_EVIDENCE, and either repair the missing evidence/assertions or move to the first concrete frontier item if evidence is already valid. Use $evidence_runner for freeze-prone/user-facing runtime checks. Do not ask Dad/user what to do next and do not declare final victory.
EOF
}

recover() {
  reason="$1"
  snapshot="$2"
  old_recoveries="$(tmux_get @dad_son_watchdog_recovery_count)"
  [[ "$old_recoveries" =~ ^[0-9]+$ ]] || old_recoveries=0
  if [[ "$old_recoveries" -ge "$max_recoveries" ]]; then
    block_signature="$(recovery_block_signature "$reason")"
    if [[ "$(tmux_get @dad_son_watchdog_blocked_signature)" == "$block_signature" ]]; then
      return 0
    fi
    tmux_set @dad_son_watchdog_status blocked:too_many_recoveries
    tmux_set @dad_son_watchdog_reason "$reason"
    tmux_set @dad_son_watchdog_blocked_signature "$block_signature"
    tmux_set @dad_son_loop_reason "$reason"
    tmux_set @dad_last_seen_summary "Mechanical Son watchdog blocked another Son recovery after $old_recoveries attempts. It will not cancel the Son again until the pane returns to a safe input state or the watchdog is restarted."
    log "blocked too_many_recoveries count=$old_recoveries reason=$reason"
    return 0
  fi
  new_recoveries=$((old_recoveries + 1))

  tmux_set @dad_son_watchdog_status recovering
  tmux_set @dad_son_watchdog_reason "$reason"
  tmux_set @dad_son_watchdog_blocked_signature ''
  tmux_set @dad_son_watchdog_tripped_at "$(date -Is)"
  tmux_set @dad_son_watchdog_recovery_count "$new_recoveries"
  tmux_set @dad_son_loop_reason "$reason"
  tmux_set @dad_son_state loop
  tmux_set @dad_son_state_reason "mechanical Son watchdog recovery: $reason"
  tmux_set @dad_last_seen_summary "Mechanical Son watchdog interrupted Son pane $son_pane for low-entropy active loop: $reason. Project artifacts were not edited by the watchdog."

  {
    printf '%s SON_RECOVERY_START %s\n' "$(date -Is)" "$reason"
    printf '%s\n' "$snapshot" | tail -80
    printf '\n'
  } >> "$log_file"

  if [[ "$new_recoveries" -gt "$max_recoveries" ]]; then
    tmux_set @dad_son_watchdog_status broken:too_many_recoveries
    tmux_set @dad_last_seen_summary "Mechanical Son watchdog refused another Son recovery after $new_recoveries attempts; Dad/user repair required. Project artifacts were not edited by the watchdog."
    log "broken too_many_recoveries count=$new_recoveries"
    return 0
  fi

  tmux -S "$socket" send-keys -t "$son_pane" C-c >/dev/null 2>&1 || true
  if ! wait_until_not_thinking 30; then
    tmux_set @dad_son_watchdog_status broken:unable_to_interrupt
    log "broken unable_to_interrupt"
    return 0
  fi

  if [[ -n "$memory_recovery_command" ]]; then
    submit_recovery_command "$memory_recovery_command" memory_clear || return 0
  fi
  submit_recovery_command "$compact_prompt" compact || return 0

  if wait_until_safe_for_input "$compact_wait_seconds"; then
    submit_recovery_command "$(recovery_prompt "$reason")" recovery_prompt || return 0
    tmux_set @dad_son_watchdog_status running
    tmux_set @dad_son_watchdog_recovered_at "$(date -Is)"
    tmux_set @dad_last_seen_summary "Mechanical Son watchdog recovered Son pane $son_pane from low-entropy active loop and submitted a truthful evidence recovery prompt. Project artifacts were not edited by the watchdog."
    log "recovered reason=$reason"
  else
    tmux_set @dad_son_watchdog_status broken:compact_timeout
    log "broken compact_timeout"
  fi
  thinking_since=""
}

cleanup() {
  if window_exists && [[ "$(tmux_get @dad_son_watchdog_pid)" == "$$" ]]; then
    tmux_set @dad_son_watchdog_status exited
    tmux_set @dad_son_watchdog_exited_at "$(date -Is)"
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

if [[ "${DAD_SON_WATCHDOG_TEST_CLASSIFY:-0}" == "1" ]]; then
  input="$(cat)"
  signal="$(son_loop_signal "$input" || true)"
  [[ -n "$signal" ]] || exit 1
  printf '%s\n' "$signal"
  exit 0
fi

if [[ "${DAD_SON_WATCHDOG_TEST_BLOCK_SIGNATURE:-0}" == "1" ]]; then
  recovery_block_signature "${4:-${1:-}}"
  exit 0
fi

if [[ "${DAD_SON_WATCHDOG_TEST_SAFE_INPUT:-0}" == "1" ]]; then
  input="$(cat)"
  if safe_for_input "$input"; then
    printf 'safe\n'
  else
    printf 'busy\n'
  fi
  exit 0
fi

if ! window_exists; then
  echo "son-watchdog: window not found: $window" >&2
  exit 1
fi

if ! pane_belongs_to_window; then
  echo "son-watchdog: pane $son_pane is not live in window $window" >&2
  exit 1
fi

existing_pid="$(tmux_get @dad_son_watchdog_pid)"
if pid_matches_this_watchdog "$existing_pid"; then
  log "duplicate existing_pid=$existing_pid window=$window son_pane=$son_pane"
  exit 0
fi

trap cleanup EXIT
trap 'terminate TERM' TERM
trap 'terminate INT' INT

tmux_set @dad_son_watchdog_pid "$$"
tmux_set @dad_son_watchdog_started_at "$started_at"
tmux_set @dad_son_watchdog_status running
tmux_set @dad_son_watchdog_window "$window"
tmux_set @dad_son_watchdog_pane "$son_pane"
log "started socket=$socket window=$window son_pane=$son_pane"

while true; do
  if ! window_exists; then
    log "exit window_missing window=$window"
    exit 0
  fi
  if ! pane_belongs_to_window; then
    tmux_set @dad_son_watchdog_status exited:pane_missing
    log "exit pane_missing pane=$son_pane"
    exit 0
  fi

  state="$(tmux_get @dad_state)"
  case "$state" in
    stopped)
      tmux_set @dad_son_watchdog_status exited:stopped
      log "exit state=stopped"
      exit 0
      ;;
    paused)
      tmux_set @dad_son_watchdog_status idle:paused
      interruptible_sleep "$poll_seconds"
      continue
      ;;
  esac

  if ! pane_command_is_grok; then
    tmux_set @dad_son_watchdog_status waiting:command_mismatch
    interruptible_sleep "$poll_seconds"
    continue
  fi

  snapshot="$(tmux -S "$socket" capture-pane -t "$son_pane" -p -S -140 2>/dev/null || true)"
  if printf '%s\n' "$snapshot" | tail -20 | grep -Eq 'Thinking(\.\.\.|…)'; then
    if [[ -z "$thinking_since" ]]; then
      thinking_since="$(now_epoch)"
    fi
    signal="$(son_loop_signal "$snapshot" || true)"
    if [[ -n "$signal" ]]; then
      recover "son_self_repetition_loop:$signal" "$snapshot"
    else
      tmux_set @dad_son_watchdog_status observing:active
    fi
  else
    thinking_since=""
    reset_blocked_recovery_budget_if_safe "$snapshot"
    tmux_set @dad_son_watchdog_status running
  fi

  interruptible_sleep "$poll_seconds"
done
