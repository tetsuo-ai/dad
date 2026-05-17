#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "usage: idle-controller.sh <tmux-socket> <window-id> <dad-pane-id> <son-pane-id>" >&2
  exit 2
fi

socket="$1"
window="$2"
dad_pane="$3"
son_pane="$4"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dad-env.sh
source "$script_dir/dad-env.sh"
dad_root="$(dad_root)"
data_root="$(dad_data_root)"
log_root="$(dad_logs_root)"

poll_seconds="${DAD_IDLE_CONTROLLER_POLL_SECONDS:-20}"
idle_sla_seconds="${DAD_IDLE_CONTROLLER_SLA_SECONDS:-180}"
claim_escalation_seconds="${DAD_IDLE_CONTROLLER_CLAIM_ESCALATION_SECONDS:-120}"
handoff_claim_escalation_seconds="${DAD_IDLE_CONTROLLER_HANDOFF_CLAIM_ESCALATION_SECONDS:-25}"
action_cooldown_seconds="${DAD_IDLE_CONTROLLER_COOLDOWN_SECONDS:-180}"
stale_observation_seconds="${DAD_IDLE_CONTROLLER_STALE_OBSERVATION_SECONDS:-90}"
delegated_verification_escalation_count="${DAD_IDLE_CONTROLLER_DELEGATED_VERIFICATION_ESCALATION_COUNT:-2}"
log_file="${DAD_IDLE_CONTROLLER_LOG:-$log_root/dad-idle-controller-${window#@}-${son_pane#%}.log}"
event_dir="${DAD_IDLE_CONTROLLER_EVENT_DIR:-$data_root/events}"
submit="${DAD_TMUX_SUBMIT:-$script_dir/tmux-submit.sh}"
watcher="${DAD_SON_WATCHER:-$script_dir/son-watcher.sh}"
son_watchdog="${DAD_SON_WATCHDOG:-$script_dir/son-watchdog.sh}"
code_standards="${DAD_CODE_STANDARDS:-$script_dir/code-standards-check.py}"
started_at="$(date -Is)"
socket_hash="$(printf '%s' "$socket" | sha256sum | awk '{ print substr($1, 1, 12) }')"
event_file="$event_dir/${socket_hash}-${window#@}-${son_pane#%}.idle-events.jsonl"
dad_prepare_log_file "$log_file" || exit 2

tmux_set() {
  if ! tmux -S "$socket" set-window-option -t "$window" "$1" "$2" >/dev/null 2>&1; then
    log "tmux_set_failed key=$1"
    return 1
  fi
}

tmux_get() {
  tmux -S "$socket" show-window-option -v -t "$window" "$1" 2>/dev/null || true
}

log() {
  dad_log_append "$log_file" "$*"
}

epoch() {
  value="$1"
  date -d "$value" +%s 2>/dev/null || printf '0'
}

now_epoch() {
  date +%s
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

pane_accepting_input() {
  pane="$1"
  text="$(tmux -S "$socket" capture-pane -t "$pane" -p -S -40 2>/dev/null || true)"
  text_accepting_input "$text"
}

text_accepting_input() {
  text="$1"
  tail_text="$(printf '%s\n' "$text" | tail -20)"
  if printf '%s\n' "$tail_text" | grep -Eiq '^[[:space:]│┃]*::[[:space:]]*(Thinking(\.\.\.|…)|Waiting(\.\.\.|…)|Responding|Running|Building|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing|Compacting)([[:space:][:punct:]]|$)|^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Run|Read|Edit|Search|Write|Apply|Thinking|Waiting|Responding|Running|Building|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing|Compacting)|^[[:space:]│┃]*◆[[:space:]]+(Run|Read|Edit|Search|Write|Apply)|^[[:space:]│┃]*Tool Use'; then
    return 1
  fi
  if printf '%s\n' "$tail_text" | grep -Eq '(^|[[:space:]│])❯[[:space:]]*$|Build anything|Type feedback|Grok Build'; then
    return 0
  fi
  return 1
}

pending_pasted_prompt() {
  pane="$1"
  text="$(tmux -S "$socket" capture-pane -t "$pane" -p -S -20 2>/dev/null || true)"
  tail_text="$(printf '%s\n' "$text" | tail -12)"
  if printf '%s\n' "$tail_text" | grep -Eq '\[Pasted:'; then
    return 0
  fi
  if printf '%s\n' "$tail_text" | grep -q 'Enter:send' &&
      printf '%s\n' "$tail_text" | grep -Eq '│ ❯ .{3,}|│   [^│[:space:]].{3,}'; then
    return 0
  fi
  return 1
}

pid_matches_this_controller() {
  pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  pid_matches_script "$pid" "$script_dir/idle-controller.sh" "$dad_pane" "$son_pane"
}

pid_matches_script() {
  pid="$1"
  script="$2"
  shift 2
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  cmdline="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  printf '%s\n' "$cmdline" | grep -Fxq "$script" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$socket" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$window" || return 1
  for expected in "$@"; do
    printf '%s\n' "$cmdline" | grep -Fxq "$expected" || return 1
  done
}

pid_matches_son_watcher() {
  pid="$1"
  pid_matches_script "$pid" "$watcher" "$son_pane"
}

pid_matches_son_watchdog() {
  pid="$1"
  pid_matches_script "$pid" "$son_watchdog" "$son_pane"
}

ensure_son_watcher() {
  pid="$(tmux_get @dad_son_watcher_pid)"
  if pid_matches_son_watcher "$pid"; then
    return 0
  fi
  tmux_set @dad_son_watcher_status restarting_by_idle_controller
  watcher_log="${DAD_SON_WATCHER_LOG:-$log_root/dad-son-watcher-${window#@}-${son_pane#%}.log}"
  dad_spawn_daemon "$socket" "$window" "$watcher_log" "$watcher" "$socket" "$window" "$son_pane" >/dev/null 2>&1 || {
    log "son_watcher_restart_failed"
    return 1
  }
  log "son_watcher_restart_requested"
  return 0
}

ensure_son_watchdog() {
  [[ -x "$son_watchdog" ]] || return 0
  pid="$(tmux_get @dad_son_watchdog_pid)"
  if pid_matches_son_watchdog "$pid"; then
    return 0
  fi
  tmux_set @dad_son_watchdog_status restarting_by_idle_controller
  son_watchdog_log="${DAD_SON_WATCHDOG_LOG:-$log_root/dad-son-watchdog-${window#@}-${son_pane#%}.log}"
  dad_spawn_daemon "$socket" "$window" "$son_watchdog_log" "$son_watchdog" "$socket" "$window" "$son_pane" >/dev/null 2>&1 || {
    log "son_watchdog_restart_failed"
    return 1
  }
  log "son_watchdog_restart_requested"
  return 0
}

emit_event() {
  ts="$1"
  action="$2"
  reason="$3"
  mkdir -p "$event_dir"
  chmod 700 "$event_dir" 2>/dev/null || true
  python3 - "$event_file" "$ts" "$socket_hash" "$window" "$dad_pane" "$son_pane" "$action" "$reason" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = {
    "ts": sys.argv[2],
    "socketHash": sys.argv[3],
    "window": sys.argv[4],
    "dadPane": sys.argv[5],
    "sonPane": sys.argv[6],
    "action": sys.argv[7],
    "reason": sys.argv[8],
}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
with os.fdopen(fd, "a", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, ensure_ascii=True)
    handle.write("\n")
path.chmod(0o600)
PY
}

clip() {
  limit="$1"
  awk -v limit="$limit" '{
    text = text $0 "\n"
  } END {
    if (length(text) > limit) {
      print substr(text, 1, limit) "...[truncated]"
    } else {
      printf "%s", text
    }
  }'
}

sanitize_delegated_verification() {
  sed -E \
    -e 's/[Tt]est yourself[^.\n;]*/SON must run this check itself/g' \
    -e 's/[Tt]ry it yourself[^.\n;]*/SON must run this check itself/g' \
    -e 's/[Rr]un it yourself[^.\n;]*/SON must run this check itself/g' \
    -e 's/[Yy]ou can (verify|test)[^.\n;]*/SON must verify this itself/g' \
    -e 's/[Ff]or you to test[^.\n;]*/for SON to test itself/g'
}

metadata_value() {
  key="$1"
  limit="${2:-1200}"
  printf '%s\n' "$(tmux_get "$key")" | sanitize_delegated_verification | clip "$limit"
}

git_read() {
  repo="$1"
  shift
  timeout 3 git -C "$repo" "$@" 2>/dev/null || true
}

is_trunk_branch() {
  case "$1" in
    main|master|trunk|develop|dev) return 0 ;;
    *) return 1 ;;
  esac
}

branch_list_contains() {
  branch_list="$1"
  branch="$2"
  printf '%s\n' "$branch_list" | tr ',' '\n' | grep -Fxq "$branch"
}

should_adopt_current_branch() {
  current_branch="$1"
  session_branch="$2"
  dirty_count="$3"
  branch_list="$4"
  session_is_ancestor="${5:-unknown}"

  [[ -n "$current_branch" && -n "$session_branch" ]] || return 1
  [[ "$current_branch" != "$session_branch" ]] || return 1
  [[ "$dirty_count" =~ ^[0-9]+$ && "$dirty_count" -eq 0 ]] || return 1

  if ! branch_list_contains "$branch_list" "$session_branch"; then
    return 0
  fi

  if is_trunk_branch "$session_branch" &&
      ! is_trunk_branch "$current_branch" &&
      [[ "$session_is_ancestor" != "no" ]]; then
    return 0
  fi

  return 1
}

refresh_branch_state() {
  cwd="$(tmux -S "$socket" display-message -p -t "$son_pane" '#{pane_current_path}' 2>/dev/null || true)"
  [[ -n "$cwd" && -d "$cwd" ]] || return 0
  inside="$(git_read "$cwd" rev-parse --is-inside-work-tree)"
  [[ "$inside" == "true" ]] || return 0

  root="$(git_read "$cwd" rev-parse --show-toplevel | head -n 1)"
  [[ -n "$root" ]] || return 0
  branch="$(git_read "$root" branch --show-current | head -n 1)"
  if [[ -z "$branch" ]]; then
    head="$(git_read "$root" rev-parse --short HEAD | head -n 1)"
    dirty_count="$(git_read "$root" status --porcelain --untracked-files=normal | wc -l | tr -d '[:space:]')"
    tmux_set @dad_workspace_root "$root"
    tmux_set @dad_branch_dirty_count "${dirty_count:-0}"
    tmux_set @dad_branch_status "root=$root branch=DETACHED head=$head dirty=${dirty_count:-0}"
    tmux_set @dad_failure_signature detached_head
    tmux_set @dad_branch_problem "detached HEAD at ${head:-unknown}; checkout or create exactly one repo-approved workstream branch before continuing"
    return 2
  fi
  head="$(git_read "$root" rev-parse --short HEAD | head -n 1)"
  dirty_count="$(git_read "$root" status --porcelain --untracked-files=normal | wc -l | tr -d '[:space:]')"
  branch_list="$(git_read "$root" for-each-ref --format='%(refname:short)' refs/heads | sort | paste -sd, -)"
  session_branch="$(tmux_get @dad_session_branch)"
  branch_baseline="$(tmux_get @dad_branch_baseline)"

  [[ -n "$session_branch" ]] || {
    session_branch="$branch"
    tmux_set @dad_session_branch "$session_branch"
  }
  [[ -n "$branch_baseline" ]] || {
    branch_baseline="$branch_list"
    tmux_set @dad_branch_baseline "$branch_baseline"
  }

  tmux_set @dad_workspace_root "$root"
  tmux_set @dad_branch_dirty_count "${dirty_count:-0}"
  tmux_set @dad_branch_status "root=$root branch=$branch session_branch=$session_branch head=$head dirty=${dirty_count:-0} branches=$branch_list"

  session_is_ancestor=unknown
  if branch_list_contains "$branch_list" "$session_branch"; then
    if git -C "$root" merge-base --is-ancestor "$session_branch" "$branch" >/dev/null 2>&1; then
      session_is_ancestor=yes
    else
      session_is_ancestor=no
    fi
  fi

  if should_adopt_current_branch "$branch" "$session_branch" "${dirty_count:-0}" "$branch_list" "$session_is_ancestor"; then
    session_branch="$branch"
    branch_baseline="$branch_list"
    tmux_set @dad_session_branch "$session_branch"
    tmux_set @dad_branch_baseline "$branch_baseline"
    tmux_set @dad_branch_problem ''
    tmux_set @dad_branch_reconciled_at "$(date -Is)"
    case "$(tmux_get @dad_failure_signature)" in
      branch_sprawl|detached_head|uncommitted_delta_after_claim) tmux_set @dad_failure_signature '' ;;
    esac
    tmux_set @dad_branch_status "root=$root branch=$branch session_branch=$session_branch head=$head dirty=${dirty_count:-0} branches=$branch_list reconciled=adopted_current_clean_branch"
    return 0
  fi

  if [[ "$branch" != "$session_branch" ]]; then
    tmux_set @dad_failure_signature branch_sprawl
    tmux_set @dad_branch_problem "branch drift: current=$branch session=$session_branch"
    return 2
  fi
  if [[ -n "$branch_baseline" && "$branch_list" != "$branch_baseline" ]]; then
    tmux_set @dad_failure_signature branch_sprawl
    tmux_set @dad_branch_problem "branch set changed: baseline=$branch_baseline current=$branch_list"
    return 2
  fi
  tmux_set @dad_branch_problem ''
  case "$(tmux_get @dad_failure_signature)" in
    branch_sprawl|detached_head|uncommitted_delta_after_claim) tmux_set @dad_failure_signature '' ;;
  esac
  return 0
}

refresh_code_standards_state() {
  root="$1"
  [[ -x "$code_standards" && -n "$root" && -d "$root" ]] || return 0

  if output="$(timeout 8 "$code_standards" --root "$root" 2>&1)"; then
    rc=0
  else
    rc="$?"
  fi

  result_line="$(printf '%s\n' "$output" | grep -m 1 '^CODE_STANDARDS_RESULT:' || true)"
  [[ -n "$result_line" ]] || result_line="CODE_STANDARDS_RESULT: UNKNOWN rc=$rc"
  tmux_set @dad_code_standards_status "$result_line"
  tmux_set @dad_code_standards_last_checked_at "$(date -Is)"
  tmux_set @dad_code_standards_last_output "$(printf '%s\n' "$output" | clip 1600)"

  if [[ "$result_line" == CODE_STANDARDS_RESULT:\ FAIL* ]]; then
    tmux_set @dad_failure_signature context_hostile_monolith
    tmux_set @dad_code_standards_problem "$(printf '%s\n' "$output" | clip 1600)"
    return 2
  fi

  tmux_set @dad_code_standards_problem ''
  case "$(tmux_get @dad_failure_signature)" in
    context_hostile_monolith) tmux_set @dad_failure_signature '' ;;
  esac
  return 0
}

fingerprint_text() {
  sha256sum | awk '{ print substr($1, 1, 16) }'
}

numeric_or_zero() {
  value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

record_delegated_verification_failure() {
  count="$(numeric_or_zero "$(tmux_get @dad_delegated_verification_count)")"
  count=$((count + 1))
  tmux_set @dad_delegated_verification_count "$count"
  tmux_set @dad_delegated_verification_last_at "$(date -Is)"
  tmux_set @dad_delegated_verification_last_fingerprint "$(tmux_get @dad_son_fingerprint)"
  if [[ "$count" -ge "$delegated_verification_escalation_count" ]]; then
    tmux_set @dad_failure_signature delegated_verification_repeat
  else
    tmux_set @dad_failure_signature delegated_verification
  fi
  printf '%s\n' "$count"
}

reset_delegated_verification_streak() {
  tmux_set @dad_delegated_verification_count 0 >/dev/null 2>&1 || true
}

refresh_son_observation() {
  pane_text="$(tmux -S "$socket" capture-pane -t "$son_pane" -p -S -140 2>/dev/null || true)"
  classification="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$watcher" "$socket" "$window" "$son_pane" <<<"$pane_text" 2>/dev/null || true)"
  [[ "$classification" == *$'\t'* ]] || return 1
  refreshed_state="${classification%%$'\t'*}"
  refreshed_reason="${classification#*$'\t'}"
  stable_tail="$(printf '%s\n' "$pane_text" | tail -100 | sed 's/[[:space:]]\+/ /g')"
  refreshed_fingerprint="$(printf '%s\n' "$stable_tail" | fingerprint_text)"
  old_state="$(tmux_get @dad_son_state)"
  old_fingerprint="$(tmux_get @dad_son_fingerprint)"
  ts="$(date -Is)"

  tmux_set @dad_son_observed_at "$ts"
  tmux_set @dad_son_state "$refreshed_state"
  tmux_set @dad_son_state_reason "$refreshed_reason"
  tmux_set @dad_son_fingerprint "$refreshed_fingerprint"
  tmux_set @dad_son_watcher_status "refreshed_by_idle_controller:$refreshed_state"
  if [[ "$refreshed_fingerprint" != "$old_fingerprint" ]]; then
    tmux_set @dad_son_fingerprint_changed_at "$ts"
  fi
  if [[ "$refreshed_state" == "idle" ]]; then
    old_idle_since="$(tmux_get @dad_son_idle_since)"
    if [[ "$old_state" != "idle" || -z "$old_idle_since" ]]; then
      tmux_set @dad_son_idle_since "$ts"
    fi
  elif [[ "$refreshed_state" == "claim" ]]; then
    if [[ "$old_state" != "claim" || "$refreshed_fingerprint" != "$old_fingerprint" ]]; then
      tmux_set @dad_son_last_claim_at "$ts"
    fi
    tmux_set @dad_son_idle_since ''
  else
    tmux_set @dad_son_idle_since ''
  fi
  emit_event "$ts" "refresh_son_observation" "stale watcher self-classified Son as $refreshed_state: $refreshed_reason"
  log "refresh_son_observation state=$refreshed_state reason=$refreshed_reason"
  return 0
}

mark_state_after_prompt() {
  current_state="$(tmux_get @dad_state)"
  case "$current_state" in
    ""|booting|waiting|done)
      tmux_set @dad_state working
      ;;
    working)
      ;;
    *)
      tmux_set @dad_idle_controller_preserved_dad_state "$current_state"
      ;;
  esac
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
  if [[ -z "$objective" ]]; then
    objective="the original DAD objective for this session"
  fi
  printf '%s\n' "$objective" | clip 1200
}

source "$script_dir/idle-controller-actions.sh"

cleanup() {
  if window_exists && [[ "$(tmux_get @dad_idle_controller_pid)" == "$$" ]]; then
    tmux_set @dad_idle_controller_status exited
    tmux_set @dad_idle_controller_exited_at "$(date -Is)"
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

if [[ "${DAD_IDLE_CONTROLLER_TEST_DECIDE:-0}" == "1" ]]; then
  test_state="${DAD_TEST_DAD_STATE:-working}"
  test_son_state="${DAD_TEST_SON_STATE:-idle}"
  test_son_reason="${DAD_TEST_SON_REASON:-}"
  test_idle_age="${DAD_TEST_IDLE_AGE:-0}"
  test_claim_age="${DAD_TEST_CLAIM_AGE:-0}"
  test_last_action="${DAD_TEST_LAST_ACTION:-}"
  test_action_age="${DAD_TEST_ACTION_AGE:-999999}"
  test_dad_accepts="${DAD_TEST_DAD_ACCEPTS_INPUT:-true}"
  test_claim_after_action="${DAD_TEST_CLAIM_AFTER_ACTION:-false}"
  test_delegated_count="${DAD_TEST_DELEGATED_VERIFICATION_COUNT:-0}"
  test_branch_problem="${DAD_TEST_BRANCH_PROBLEM:-false}"

  case "$test_state" in
    stopped)
      printf 'exit:stopped\n'
      exit 0
      ;;
    paused)
      printf 'idle:paused\n'
      exit 0
      ;;
  esac

  test_degraded=false
  if [[ "$test_state" == "broken" || "$test_state" == "recovering" ]]; then
    test_degraded=true
  fi

  if [[ "${DAD_TEST_CODE_STANDARDS_PROBLEM:-false}" == "true" && ( "$test_son_state" == "idle" || "$test_son_state" == "claim" ) &&
      ( "$test_action_age" -ge "$action_cooldown_seconds" || ( "$test_son_state" == "claim" && "$test_claim_after_action" == "true" ) ) ]]; then
    printf 'direct_son_code_write_correction\n'
    exit 0
  fi

  if [[ "$test_branch_problem" == "true" && ( "$test_son_state" == "idle" || "$test_son_state" == "claim" ) && "$test_action_age" -ge "$action_cooldown_seconds" ]]; then
    printf 'direct_son_branch_consolidation\n'
    exit 0
  fi

  if [[ "$test_son_state" == "idle" && "$test_idle_age" -ge "$idle_sla_seconds" && "$test_action_age" -ge "$action_cooldown_seconds" ]]; then
    if [[ "$test_degraded" == true ]]; then
      printf 'direct_son_degraded_continuation\n'
    else
      printf 'direct_son_idle_recovery\n'
    fi
    exit 0
  fi

  if [[ "$test_son_state" == "claim" ]]; then
    if [[ "$test_claim_after_action" == "true" ]]; then
      test_action_age=999999
      test_last_action=""
    fi
    claim_allowed=true
    if [[ ( "$test_last_action" == "direct_son_claim_continuation" || "$test_last_action" == "direct_son_degraded_continuation" || "$test_last_action" == "direct_son_code_write_correction" ) &&
        "$test_action_age" -lt "$action_cooldown_seconds" ]]; then
      claim_allowed=false
    fi
    test_claim_sla="$claim_escalation_seconds"
    if [[ "$test_son_reason" == *"asking for next action"* ]]; then
      test_claim_sla="$handoff_claim_escalation_seconds"
    fi
    if [[ "$test_son_reason" == *"delegated verification"* ]]; then
      test_claim_sla=0
    fi
    if [[ "$test_son_reason" == *"code handoff"* ]]; then
      test_claim_sla=0
    fi
    if [[ "$test_claim_age" -ge "$test_claim_sla" && "$claim_allowed" == true ]]; then
      if [[ "$test_son_reason" == *"code handoff"* ]]; then
        printf 'direct_son_code_write_correction\n'
      elif [[ "$test_son_reason" == *"delegated verification"* && $((test_delegated_count + 1)) -ge "$delegated_verification_escalation_count" ]]; then
        printf 'direct_son_code_write_correction\n'
      elif [[ "$test_degraded" == true ]]; then
        printf 'direct_son_degraded_continuation\n'
      else
        printf 'direct_son_claim_continuation\n'
      fi
    elif [[ "$test_degraded" == true ]]; then
      printf 'degraded:claim_waiting\n'
    else
      printf 'waiting:claim_verification_escalation\n'
    fi
    exit 0
  fi

  if [[ "$test_son_state" == "plan_approval" ]]; then
      if [[ "$test_degraded" == true ]]; then
        printf 'plan_approval_requires_review\n'
    else
      printf 'dad_plan_approval_sla\n'
    fi
    exit 0
  fi

  if [[ "$test_son_state" == "loop" ]]; then
    printf 'son_watchdog_recovery\n'
    exit 0
  fi

  printf 'running:%s\n' "${test_son_state:-unknown}"
  exit 0
fi

if [[ "${DAD_IDLE_CONTROLLER_TEST_EMIT_EVENT:-0}" == "1" ]]; then
  emit_event \
    "${DAD_TEST_EVENT_TS:-$(date -Is)}" \
    "${DAD_TEST_EVENT_ACTION:-direct_son_idle_recovery}" \
    "${DAD_TEST_EVENT_REASON:-test reason}"
  exit 0
fi

if [[ "${DAD_IDLE_CONTROLLER_TEST_BRANCH_ADOPTION:-0}" == "1" ]]; then
  if should_adopt_current_branch \
      "${DAD_TEST_CURRENT_BRANCH:-}" \
      "${DAD_TEST_SESSION_BRANCH:-}" \
      "${DAD_TEST_DIRTY_COUNT:-0}" \
      "${DAD_TEST_BRANCH_LIST:-}" \
      "${DAD_TEST_SESSION_IS_ANCESTOR:-unknown}"; then
    printf 'adopt\n'
  else
    printf 'drift\n'
  fi
  exit 0
fi

if [[ "${DAD_IDLE_CONTROLLER_TEST_ACCEPTING:-0}" == "1" ]]; then
  input="$(cat)"
  if text_accepting_input "$input"; then
    printf 'accepting\n'
  else
    printf 'busy\n'
  fi
  exit 0
fi

if ! window_exists; then
  echo "idle-controller: window not found: $window" >&2
  exit 1
fi

if ! pane_belongs_to_window "$dad_pane"; then
  echo "idle-controller: Dad pane $dad_pane is not live in window $window" >&2
  exit 1
fi

if ! pane_belongs_to_window "$son_pane"; then
  echo "idle-controller: Son pane $son_pane is not live in window $window" >&2
  exit 1
fi

existing_pid="$(tmux_get @dad_idle_controller_pid)"
if pid_matches_this_controller "$existing_pid"; then
  log "duplicate existing_pid=$existing_pid window=$window son_pane=$son_pane"
  exit 0
fi

trap cleanup EXIT
trap 'terminate TERM' TERM
trap 'terminate INT' INT

tmux_set @dad_idle_controller_pid "$$"
tmux_set @dad_idle_controller_started_at "$started_at"
tmux_set @dad_idle_controller_status running
tmux_set @dad_idle_controller_window "$window"
tmux_set @dad_idle_controller_dad_pane "$dad_pane"
tmux_set @dad_idle_controller_son_pane "$son_pane"
log "started socket=$socket window=$window dad_pane=$dad_pane son_pane=$son_pane"

while true; do
  if ! window_exists; then
    log "exit window_missing window=$window"
    exit 0
  fi
  if ! pane_belongs_to_window "$dad_pane"; then
    tmux_set @dad_idle_controller_status exited:dad_pane_missing
    log "exit dad_pane_missing pane=$dad_pane"
    exit 0
  fi
  if ! current_dad_pane_matches; then
    tmux_set @dad_idle_controller_status exited:dad_pane_replaced
    log "exit dad_pane_replaced old=$dad_pane current=$(tmux_get @dad_dad_pane)"
    exit 0
  fi
  if ! pane_belongs_to_window "$son_pane"; then
    tmux_set @dad_idle_controller_status exited:son_pane_missing
    log "exit son_pane_missing pane=$son_pane"
    exit 0
  fi

  state="$(tmux_get @dad_state)"
  dad_degraded=false
  case "$state" in
    stopped)
      tmux_set @dad_idle_controller_status exited:stopped
      log "exit state=stopped"
      exit 0
      ;;
    paused)
      tmux_set @dad_idle_controller_status "idle:${state}"
      interruptible_sleep "$poll_seconds"
      continue
      ;;
    recovering|broken)
      dad_degraded=true
      tmux_set @dad_idle_controller_status "degraded:${state}"
      ;;
  esac

  ensure_son_watchdog || true

  son_state="$(tmux_get @dad_son_state)"
  son_state_reason="$(tmux_get @dad_son_state_reason)"
  observed_at="$(tmux_get @dad_son_observed_at)"
  idle_since="$(tmux_get @dad_son_idle_since)"
  last_action="$(tmux_get @dad_idle_action_sent_at)"
  last_action_name="$(tmux_get @dad_idle_controller_last_action)"
  last_claim_at="$(tmux_get @dad_son_last_claim_at)"
  now="$(now_epoch)"
  observed_epoch="$(epoch "$observed_at")"
  idle_epoch="$(epoch "$idle_since")"
  last_action_epoch="$(epoch "$last_action")"
  claim_epoch="$(epoch "$last_claim_at")"
  if [[ "$claim_epoch" -eq 0 && "$son_state" == "claim" ]]; then
    claim_epoch="$(epoch "$(tmux_get @dad_son_fingerprint_changed_at)")"
  fi
  [[ "$claim_epoch" -gt 0 ]] || claim_epoch="$observed_epoch"
  if [[ "$last_action_epoch" -gt 0 && "$claim_epoch" -gt "$last_action_epoch" && "$last_action_name" == "submit_pending_son_paste" ]]; then
    last_action_epoch=0
    last_action_name=""
  fi

  if [[ "$observed_epoch" -eq 0 || $((now - observed_epoch)) -gt "$stale_observation_seconds" ]]; then
    ensure_son_watcher || true
    if refresh_son_observation; then
      son_state="$(tmux_get @dad_son_state)"
      son_state_reason="$(tmux_get @dad_son_state_reason)"
      observed_at="$(tmux_get @dad_son_observed_at)"
      idle_since="$(tmux_get @dad_son_idle_since)"
      observed_epoch="$(epoch "$observed_at")"
      idle_epoch="$(epoch "$idle_since")"
      last_claim_at="$(tmux_get @dad_son_last_claim_at)"
      claim_epoch="$(epoch "$last_claim_at")"
      if [[ "$claim_epoch" -eq 0 && "$son_state" == "claim" ]]; then
        claim_epoch="$(epoch "$(tmux_get @dad_son_fingerprint_changed_at)")"
      fi
      [[ "$claim_epoch" -gt 0 ]] || claim_epoch="$observed_epoch"
    else
      tmux_set @dad_idle_controller_status "waiting:stale_observation"
      interruptible_sleep "$poll_seconds"
      continue
    fi
  fi

  branch_problem=false
  if refresh_branch_state; then
    branch_problem=false
  else
    branch_problem=true
  fi
  code_standards_problem=false
  workspace_root="$(tmux_get @dad_workspace_root)"
  if [[ -n "$workspace_root" ]]; then
    if refresh_code_standards_state "$workspace_root"; then
      code_standards_problem=false
    else
      code_standards_problem=true
    fi
  fi
  dirty_count="$(tmux_get @dad_branch_dirty_count)"
  [[ "$dirty_count" =~ ^[0-9]+$ ]] || dirty_count=0
  if [[ "$dirty_count" -gt 0 && ( "$son_state" == "idle" || "$son_state" == "claim" ) ]]; then
    tmux_set @dad_failure_signature uncommitted_delta_after_claim
    tmux_set @dad_branch_problem "uncommitted delta on ${son_state} state: dirty_count=$dirty_count"
    branch_problem=true
  fi

  if submit_pending_paste "$son_pane" submit_pending_son_paste "Son composer contains a pasted prompt that was not submitted"; then
    tmux_set @dad_idle_controller_status action:submit_pending_son_paste
    interruptible_sleep "$poll_seconds"
    continue
  fi

  if [[ "$code_standards_problem" == true && ( "$son_state" == "idle" || "$son_state" == "claim" ) ]]; then
    action_age=0
    [[ "$last_action_epoch" -gt 0 ]] && action_age=$((now - last_action_epoch))
    code_standards_allowed=false
    if [[ "$last_action_epoch" -eq 0 || "$action_age" -ge "$action_cooldown_seconds" ||
        ( "$son_state" == "claim" && "$claim_epoch" -gt "$last_action_epoch" ) ]]; then
      code_standards_allowed=true
    fi
    if [[ "$code_standards_allowed" == true ]]; then
      reason="$(tmux_get @dad_code_standards_problem)"
      [[ -n "$reason" ]] || reason="context-bounded coding standards failed"
      if submit_code_write_correction_to_son "Context-bounded coding standards failed: $reason" "code-standards"; then
        tmux_set @dad_idle_controller_status action:direct_son_code_write_correction
        emit_event "$(date -Is)" direct_son_code_write_correction "context_hostile_monolith"
        log "action direct_son_code_write_correction reason=context_hostile_monolith"
      else
        tmux_set @dad_idle_controller_status failed:direct_son_code_write_correction
        emit_event "$(date -Is)" failed_direct_son_code_write_correction "context_hostile_monolith"
        log "failed direct_son_code_write_correction reason=context_hostile_monolith"
      fi
      interruptible_sleep "$poll_seconds"
      continue
    fi
  fi

  if [[ "$branch_problem" == true && ( "$son_state" == "idle" || "$son_state" == "claim" ) ]]; then
    action_age=0
    [[ "$last_action_epoch" -gt 0 ]] && action_age=$((now - last_action_epoch))
    if [[ "$last_action_epoch" -eq 0 || "$action_age" -ge "$action_cooldown_seconds" ]]; then
      reason="$(tmux_get @dad_branch_problem)"
      [[ -n "$reason" ]] || reason="branch drift or branch sprawl detected"
      if submit_branch_consolidation_to_son "$reason"; then
        tmux_set @dad_idle_controller_status action:direct_son_branch_consolidation
        emit_event "$(date -Is)" direct_son_branch_consolidation "$reason"
        log "action direct_son_branch_consolidation reason=$reason"
      else
        rc="$?"
        if [[ "$rc" -eq 2 ]]; then
          tmux_set @dad_idle_controller_status waiting:son_busy_branch_consolidation
          log "waiting son_busy_branch_consolidation reason=$reason"
        else
          tmux_set @dad_idle_controller_status failed:direct_son_branch_consolidation
          emit_event "$(date -Is)" failed_direct_son_branch_consolidation "$reason"
          log "failed direct_son_branch_consolidation reason=$reason"
        fi
      fi
      interruptible_sleep "$poll_seconds"
      continue
    fi
  fi

  if [[ "$son_state" == "idle" && "$idle_epoch" -gt 0 && $((now - idle_epoch)) -ge "$idle_sla_seconds" ]]; then
    if [[ "$last_action_epoch" -eq 0 || $((now - last_action_epoch)) -ge "$action_cooldown_seconds" ]]; then
      reason="Son idle for $((now - idle_epoch))s; watcher observed at $observed_at"
      if [[ "$dad_degraded" == true ]]; then
        if submit_degraded_continuation_to_son "$reason; Dad state=${state:-unknown}" idle; then
          tmux_set @dad_idle_controller_status action:direct_son_degraded_continuation
          emit_event "$(date -Is)" direct_son_degraded_continuation "$reason"
          log "action direct_son_degraded_continuation reason=$reason"
        else
          tmux_set @dad_idle_controller_status failed:direct_son_degraded_continuation
          emit_event "$(date -Is)" failed_direct_son_degraded_continuation "$reason"
          log "failed direct_son_degraded_continuation reason=$reason"
        fi
      elif submit_to_son "$reason"; then
        tmux_set @dad_idle_controller_status action:direct_son_idle_recovery
        emit_event "$(date -Is)" direct_son_idle_recovery "$reason"
        log "action direct_son_idle_recovery reason=$reason"
      else
        tmux_set @dad_idle_controller_status failed:direct_son_idle_recovery
        emit_event "$(date -Is)" failed_direct_son_idle_recovery "$reason"
        log "failed direct_son_idle_recovery reason=$reason"
      fi
    else
      tmux_set @dad_idle_controller_status "waiting:cooldown"
    fi
  elif [[ "$son_state" == "plan_approval" ]]; then
    if [[ "$dad_degraded" == true ]]; then
      reason="Son waiting in plan approval UI while Dad state=${state:-unknown}; watcher observed at $observed_at"
      tmux_set @dad_failure_signature plan_approval_requires_review
      tmux_set @dad_idle_controller_status waiting:plan_approval_requires_review
      tmux_set @dad_last_seen_summary "Mechanical idle controller refused to approve Son plan while Dad state=${state:-unknown}. Plan approval requires Dad review after Dad recovers."
      emit_event "$(date -Is)" plan_approval_requires_review "$reason"
      log "blocked plan_approval_requires_review reason=$reason"
    elif [[ "$last_action_epoch" -eq 0 || $((now - last_action_epoch)) -ge "$action_cooldown_seconds" ]]; then
      reason="Son waiting in plan approval UI; watcher observed at $observed_at"
      if submit_to_dad dad_plan_approval_sla "$reason"; then
        tmux_set @dad_idle_controller_status action:dad_plan_approval_sla
        emit_event "$(date -Is)" dad_plan_approval_sla "$reason"
        log "action dad_plan_approval_sla reason=$reason"
      fi
    fi
  elif [[ "$son_state" == "claim" ]]; then
    reason="Son stopped after a material claim; watcher observed at $observed_at"
    claim_age=$((now - claim_epoch))
    claim_sla="$claim_escalation_seconds"
    if [[ "$son_state_reason" == *"asking for next action"* ]]; then
      claim_sla="$handoff_claim_escalation_seconds"
      reason="Son stopped after asking for next action; watcher observed at $observed_at"
    fi
    if [[ "$son_state_reason" == *"delegated verification"* ]]; then
      claim_sla=0
      reason="Son delegated verification to the user instead of running/using the artifact itself; watcher observed at $observed_at"
    fi
    if [[ "$son_state_reason" == *"code handoff"* ]]; then
      claim_sla=0
      reason="Son handed code to the user instead of editing the workspace itself; watcher observed at $observed_at"
    fi
    action_age=0
    [[ "$last_action_epoch" -gt 0 ]] && action_age=$((now - last_action_epoch))
    claim_continuation_allowed=true
    if [[ ( "$last_action_name" == "direct_son_claim_continuation" || "$last_action_name" == "direct_son_degraded_continuation" || "$last_action_name" == "direct_son_code_write_correction" ) &&
        "$last_action_epoch" -gt 0 && "$action_age" -lt "$action_cooldown_seconds" ]]; then
      claim_continuation_allowed=false
    fi
    dad_accepts_input=false
    if pane_accepting_input "$dad_pane"; then
      dad_accepts_input=true
    fi

    if [[ ( "$son_state_reason" == *"delegated verification"* || "$son_state_reason" == *"code handoff"* ) && "$claim_epoch" -gt "$last_action_epoch" ]]; then
      claim_continuation_allowed=true
    fi

    if [[ "$son_state_reason" == *"code handoff"* && "$claim_epoch" -gt 0 && "$claim_age" -ge "$claim_sla" && "$claim_continuation_allowed" == true ]]; then
      reset_delegated_verification_streak
      reason="$reason; mechanical code-write correction required"
      if submit_code_write_correction_to_son "$reason" "code-handoff"; then
        tmux_set @dad_failure_signature code_handoff_no_workspace_edit
        tmux_set @dad_idle_controller_status action:direct_son_code_write_correction
        emit_event "$(date -Is)" direct_son_code_write_correction "$reason"
        log "action direct_son_code_write_correction reason=$reason"
      else
        tmux_set @dad_idle_controller_status failed:direct_son_code_write_correction
        emit_event "$(date -Is)" failed_direct_son_code_write_correction "$reason"
        log "failed direct_son_code_write_correction reason=$reason"
      fi
    elif [[ "$son_state_reason" == *"delegated verification"* && "$claim_epoch" -gt 0 && "$claim_age" -ge "$claim_sla" && "$claim_continuation_allowed" == true ]]; then
      delegated_count="$(record_delegated_verification_failure)"
      reason="$reason; delegated verification count=${delegated_count}; mechanical code-write escalation threshold=${delegated_verification_escalation_count}"
      if [[ "$delegated_count" -ge "$delegated_verification_escalation_count" ]]; then
        if submit_code_write_correction_to_son "$reason" "$delegated_count"; then
          tmux_set @dad_idle_controller_status action:direct_son_code_write_correction
          emit_event "$(date -Is)" direct_son_code_write_correction "$reason"
          log "action direct_son_code_write_correction reason=$reason"
        else
          tmux_set @dad_idle_controller_status failed:direct_son_code_write_correction
          emit_event "$(date -Is)" failed_direct_son_code_write_correction "$reason"
          log "failed direct_son_code_write_correction reason=$reason"
        fi
      elif [[ "$dad_degraded" == true ]]; then
        reason="$reason; claim parked for ${claim_age}s while Dad state=${state:-unknown}"
        if submit_degraded_continuation_to_son "$reason" claim; then
          tmux_set @dad_idle_controller_status action:direct_son_degraded_continuation
          emit_event "$(date -Is)" direct_son_degraded_continuation "$reason"
          log "action direct_son_degraded_continuation reason=$reason"
        else
          tmux_set @dad_idle_controller_status failed:direct_son_degraded_continuation
          emit_event "$(date -Is)" failed_direct_son_degraded_continuation "$reason"
          log "failed direct_son_degraded_continuation reason=$reason"
        fi
      else
        reason="$reason; claim parked for ${claim_age}s past SLA; mechanical loop chooses concrete next frontier item"
        if submit_claim_continuation_to_son "$reason"; then
          tmux_set @dad_idle_controller_status action:direct_son_claim_continuation
          emit_event "$(date -Is)" direct_son_claim_continuation "$reason"
          log "action direct_son_claim_continuation reason=$reason"
        else
          tmux_set @dad_idle_controller_status failed:direct_son_claim_continuation
          emit_event "$(date -Is)" failed_direct_son_claim_continuation "$reason"
          log "failed direct_son_claim_continuation reason=$reason"
        fi
      fi
    elif [[ "$dad_degraded" == true && "$claim_epoch" -gt 0 && "$claim_age" -ge "$claim_sla" && "$claim_continuation_allowed" == true ]]; then
      reset_delegated_verification_streak
      reason="$reason; claim parked for ${claim_age}s while Dad state=${state:-unknown}"
      if submit_degraded_continuation_to_son "$reason" claim; then
        tmux_set @dad_idle_controller_status action:direct_son_degraded_continuation
        emit_event "$(date -Is)" direct_son_degraded_continuation "$reason"
        log "action direct_son_degraded_continuation reason=$reason"
      else
        tmux_set @dad_idle_controller_status failed:direct_son_degraded_continuation
        emit_event "$(date -Is)" failed_direct_son_degraded_continuation "$reason"
        log "failed direct_son_degraded_continuation reason=$reason"
      fi
    elif [[ "$dad_degraded" == true ]]; then
      tmux_set @dad_idle_controller_status "degraded:claim_waiting"
    elif [[ "$claim_epoch" -gt 0 && "$claim_age" -ge "$claim_sla" && "$claim_continuation_allowed" == true ]]; then
      reset_delegated_verification_streak
      reason="$reason; claim parked for ${claim_age}s past SLA; mechanical loop chooses concrete next frontier item"
      if submit_claim_continuation_to_son "$reason"; then
        tmux_set @dad_idle_controller_status action:direct_son_claim_continuation
        emit_event "$(date -Is)" direct_son_claim_continuation "$reason"
        log "action direct_son_claim_continuation reason=$reason"
      else
        tmux_set @dad_idle_controller_status failed:direct_son_claim_continuation
        emit_event "$(date -Is)" failed_direct_son_claim_continuation "$reason"
        log "failed direct_son_claim_continuation reason=$reason"
      fi
    elif [[ "$claim_epoch" -gt 0 ]]; then
      tmux_set @dad_idle_controller_status "waiting:claim_continuation_sla"
    elif [[ "$last_action_name" == "dad_claim_verification_sla" ]]; then
      tmux_set @dad_idle_controller_status "waiting:claim_verification_escalation"
    else
      tmux_set @dad_idle_controller_status "waiting:cooldown"
    fi
  else
    tmux_set @dad_idle_controller_status "running:${son_state:-unknown}"
  fi

  interruptible_sleep "$poll_seconds"
done
