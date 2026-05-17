#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: son-watcher.sh <tmux-socket> <window-id> <son-pane-id>" >&2
  exit 2
fi

socket="$1"
window="$2"
son_pane="$3"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dad-env.sh
source "$script_dir/dad-env.sh"
script_path="${DAD_SON_WATCHER_SCRIPT:-$script_dir/son-watcher.sh}"
dad_root="$(dad_root)"
data_root="$(dad_data_root)"
log_root="$(dad_logs_root)"

poll_seconds="${DAD_SON_WATCHER_POLL_SECONDS:-15}"
context_threshold="${DAD_SON_WATCHER_CONTEXT_THRESHOLD:-50}"
log_file="${DAD_SON_WATCHER_LOG:-$log_root/dad-son-watcher-${window#@}-${son_pane#%}.log}"
event_dir="${DAD_SON_WATCHER_EVENT_DIR:-$data_root/events}"
started_at="$(date -Is)"
socket_hash="$(printf '%s' "$socket" | sha256sum | awk '{ print substr($1, 1, 12) }')"
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

window_exists() {
  tmux -S "$socket" display-message -p -t "$window" '#{window_id}' >/dev/null 2>&1
}

pane_belongs_to_window() {
  tmux -S "$socket" list-panes -t "$window" -F '#{pane_id} #{pane_dead}' 2>/dev/null |
    awk -v pane="$son_pane" '$1 == pane && $2 == "0" { found = 1 } END { exit(found ? 0 : 1) }'
}

pid_matches_this_watcher() {
  pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  cmdline="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  printf '%s\n' "$cmdline" | grep -Fxq "$script_path" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$socket" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$window" || return 1
  printf '%s\n' "$cmdline" | grep -Fxq "$son_pane"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;?]*[ -/]*[@-~]//g' | tr -d '\r'
}

fingerprint_text() {
  sha256sum | awk '{ print substr($1, 1, 16) }'
}

max_percent() {
  grep -Ei 'grok build|always-approve|[█▉▊▋▌▍▎▏].*[0-9]+([.][0-9]+)?%|[0-9]+([.][0-9]+)?%.*[█▉▊▋▌▍▎▏]' |
    grep -Eo '[0-9]+([.][0-9]+)?%' |
    sed 's/%$//' |
    sort -nr |
    head -1
}

has_context_pressure() {
  value="$1"
  [[ -n "$value" ]] || return 1
  awk -v value="$value" -v threshold="$context_threshold" 'BEGIN { exit(value >= threshold ? 0 : 1) }'
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

normalized_loop_signal() {
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

semantic_loop_signal() {
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
  clean_text="$1"
  tail_text="$(printf '%s\n' "$clean_text" | tail -100)"
  status_tail="$(printf '%s\n' "$clean_text" | tail -20)"

  if ! printf '%s\n' "$status_tail" | grep -Eiq 'Thinking(\.\.\.|…)'; then
    return 1
  fi
  if printf '%s\n' "$tail_text" | grep -Eiq '^[[:space:]│┃]*[◆⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Run|Read|Edit|Write|Apply|Search|Fetch|Compile|Test|Install)|^[[:space:]│┃]*◆[[:space:]]+(Run|Read|Edit|Write|Apply|Search|Fetch|Compile|Test|Install)|^[[:space:]│┃]*(pre_tool_use|post_tool_use|Tool Use)|[[:space:]](pre_tool_use|post_tool_use)[[:space:]]*$'; then
    return 1
  fi

  elapsed="$(printf '%s\n' "$status_tail" | visible_thinking_elapsed_seconds || true)"
  [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0
  grace="${DAD_SON_WATCHER_LOOP_GRACE_SECONDS:-45}"
  [[ "$elapsed" -ge "$grace" ]] || return 1

  active_text="$(printf '%s\n' "$tail_text" | active_reasoning_block || true)"
  [[ -n "$active_text" ]] || active_text="$tail_text"
  signal="$(printf '%s\n' "$active_text" | semantic_loop_signal || true)"
  [[ -n "$signal" ]] || signal="$(printf '%s\n' "$active_text" | normalized_loop_signal || true)"
  [[ -n "$signal" ]] || return 1

  printf '%s after %ss' "$signal" "$elapsed"
}

classify_clean_text() {
  clean_text="$1"
  tail_text="$(printf '%s\n' "$clean_text" | tail -80)"
  status_tail="$(printf '%s\n' "$clean_text" | tail -20)"

  loop_signal="$(son_loop_signal "$clean_text" || true)"
  if [[ -n "$loop_signal" ]]; then
    printf 'loop\tactive Son low-entropy self-repetition: %s\n' "$loop_signal"
    return 0
  fi

  if printf '%s\n' "$status_tail" | grep -Eiq '^[[:space:]│┃]*::[[:space:]]*(Thinking(\.\.\.|…)|Waiting(\.\.\.|…)|Responding|Running|Building|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing|Compacting)([[:space:][:punct:]]|$)|^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Run|Read|Edit|Search|Write|Apply|Thinking|Waiting|Responding|Running|Building|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing|Compacting)|^[[:space:]│┃]*◆[[:space:]]+(Run|Read|Edit|Search|Write|Apply|Thinking)|^[[:space:]│┃]*Tool Use'; then
    printf 'active\tvisible active Grok status\n'
    return 0
  fi

  if printf '%s\n' "$tail_text" | grep -Eiq 'Grok Build .*plan approval|Waiting on plan approval|a:approve|\[a\]pprove|q:quit plan'; then
    printf 'plan_approval\tvisible plan approval UI\n'
    return 0
  fi

  material_claim_re='ready for (the )?next|ready for whatever comes next|ready for acceptance|ready to close|completion gate|completed milestone|objective complete|complete(d)?[[:punct:][:space:]]*$|shipped|final|done[[:punct:][:space:]]*$|gate[[:space:]]+PASS|EVIDENCE_JSON|Commit:|tests? passed|passed assertions?|verified|playable|it works|works now|runs now|fixed the|bug fixed|issue fixed|resolved the|Do you want me to|Next \(your call\)|Say the word'
  delegated_verification_re='test yourself|try it yourself|run it yourself|you can verify|you can test|manual test for you|for you to test|please test|ask the user to test'
  code_handoff_re='copy (and )?(paste )?this code|paste this code|apply this patch|save this as|replace .* with this|here is the code|full code below|code snippet|code snippets|for you to apply'

  if printf '%s\n' "$tail_text" | grep -Eq '(^|[[:space:]│])❯[[:space:]]*$|Grok Build|Build anything|Type feedback'; then
    if printf '%s\n' "$tail_text" | grep -Eiq 'Turn (completed|cancelled|canceled) in'; then
      if printf '%s\n' "$tail_text" | grep -Eiq "$delegated_verification_re"; then
        printf 'claim\tdelegated verification to user instead of Son-run evidence\n'
        return 0
      fi
      if printf '%s\n' "$tail_text" | grep -Eiq "$code_handoff_re"; then
        printf 'claim\tcode handoff to user instead of workspace edit\n'
        return 0
      fi
      if printf '%s\n' "$tail_text" | grep -Eiq 'Do you want me to|Next \(your call\)|Say the word|Direct the exact next action|What'\''s next|remaining high-leverage options|high-leverage options are|options are'; then
        printf 'claim\tcompleted turn at composer asking for next action\n'
        return 0
      fi
      if printf '%s\n' "$tail_text" | grep -Eiq "$material_claim_re"; then
        printf 'claim\tcompleted turn at composer after material claim or handoff request\n'
        return 0
      fi
      printf 'idle\tcompleted turn at composer with no active status\n'
      return 0
    fi
  fi

  if printf '%s\n' "$tail_text" | grep -Eq '(^|[[:space:]│])❯[[:space:]]*$|Grok Build|Build anything|Type feedback'; then
    if printf '%s\n' "$tail_text" | grep -Eiq "$delegated_verification_re"; then
      printf 'claim\tdelegated verification to user instead of Son-run evidence\n'
      return 0
    fi
    if printf '%s\n' "$tail_text" | grep -Eiq "$code_handoff_re"; then
      printf 'claim\tcode handoff to user instead of workspace edit\n'
      return 0
    fi
    if printf '%s\n' "$tail_text" | grep -Eiq "$material_claim_re"; then
      printf 'claim\tstopped at composer after material claim/evidence text\n'
      return 0
    fi
    printf 'idle\tcomposer or prompt visible with no active status\n'
    return 0
  fi

  printf 'unknown\tno deterministic high-confidence state\n'
}

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g'
}

event_snippet() {
  sed 's/[[:cntrl:]]//g' | tail -30 | awk '{
    text = text $0 "\\n"
  } END {
    if (length(text) > 900) {
      print substr(text, length(text) - 899)
    } else {
      printf "%s", text
    }
  }'
}

extract_recent_user_feedback() {
  awk '
    function clean(line) {
      gsub(/^[[:space:]│]*❯[[:space:]]*/, "", line)
      gsub(/^[[:space:]│]+/, "", line)
      gsub(/[[:space:]│]+$/, "", line)
      return line
    }
    /[│[:space:]]❯[[:space:]]*[^[:space:]│]/ {
      current = clean($0)
      next
    }
    current != "" && /^[[:space:]]*│[[:space:]]+[^[:space:]│]/ {
      line = clean($0)
      if (line !~ /^(Grok Build|Shift|Ctrl|Enter|Tab|pre_tool_use|post_tool_use|Tool Use|Turn completed|Turn cancelled|Turn canceled|◆|┃|╭|╰|─|✓|#?[0-9]+[[:space:]])/) {
        current = current " " line
      }
    }
    END {
      gsub(/[[:space:]]+/, " ", current)
      sub(/^ /, "", current)
      sub(/ $/, "", current)
      if (length(current) > 800) {
        current = substr(current, 1, 800) "...[truncated]"
      }
      print current
    }
  '
}

human_feedback_is_corrective() {
  feedback="$1"
  [[ -n "$feedback" ]] || return 1
  if printf '%s\n' "$feedback" | grep -Eiq '^(DAD mechanical|DAD degraded|DAD scheduler|You are stopped at the prompt|Original objective:|Current Dad|/compact|/memory|Build anything$)|pre_tool_use|post_tool_use|Turn cancelled by user|Turn canceled by user|global/settings:'; then
    return 1
  fi
  printf '%s\n' "$feedback" | grep -Eiq 'actually|write code|code code|make it better|go online|look at (good|real)|research|what (is|are|the)|where is|why (is|are|no)|how (does|do)|doesn'\''t|does not|do not|don'\''t|stop|broken|idle|stuck|loop|test (myself|yourself)|use the software|user has no|no explanation|no file system|no filesystem|no cd|no ls|bad|sucks|garbage|trash|dogshit|fucking|wtf'
}

record_human_feedback() {
  ts="$1"
  clean_text="$2"
  feedback="$(printf '%s\n' "$clean_text" | tail -140 | extract_recent_user_feedback)"
  human_feedback_is_corrective "$feedback" || return 0

  feedback_fp="$(printf '%s\n' "$feedback" | fingerprint_text)"
  old_feedback_fp="$(tmux_get @dad_user_feedback_fingerprint)"
  tmux_set @dad_last_user_feedback "$feedback"
  tmux_set @dad_last_user_feedback_at "$ts"
  tmux_set @dad_user_feedback_fingerprint "$feedback_fp"
  tmux_set @dad_failure_signature human_feedback_pressure
  if [[ "$feedback_fp" != "$old_feedback_fp" ]]; then
    count="$(tmux_get @dad_user_feedback_count)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    tmux_set @dad_user_feedback_count "$((count + 1))"
    emit_event "$ts" human_feedback "$feedback_fp" "corrective human feedback visible in Son pane" "$feedback"
    log "human_feedback fingerprint=$feedback_fp text=$feedback"
  fi
}

emit_event() {
  ts="$1"
  state="$2"
  fingerprint="$3"
  reason="$4"
  snippet="${5:-}"
  mkdir -p "$event_dir"
  chmod 700 "$event_dir" 2>/dev/null || true
  reason_json="$(printf '%s' "$reason" | json_escape)"
  snippet_json="$(printf '%s' "$snippet" | json_escape)"
  event_file="$event_dir/${socket_hash}-${window#@}-${son_pane#%}.son-events.jsonl"
  printf '{"ts":"%s","socketHash":"%s","window":"%s","pane":"%s","state":"%s","fingerprint":"%s","reason":"%s","snippet":"%s"}\n' \
    "$ts" "$socket_hash" "$window" "$son_pane" "$state" "$fingerprint" "$reason_json" "$snippet_json" >> "$event_file"
  chmod 600 "$event_file" 2>/dev/null || true
}

cleanup() {
  if window_exists && [[ "$(tmux_get @dad_son_watcher_pid)" == "$$" ]]; then
    tmux_set @dad_son_watcher_status exited
    tmux_set @dad_son_watcher_exited_at "$(date -Is)"
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

if [[ "${DAD_SON_WATCHER_TEST_CLASSIFY:-0}" == "1" ]]; then
  input="$(cat | strip_ansi)"
  classify_clean_text "$input"
  exit 0
fi

if [[ "${DAD_SON_WATCHER_TEST_HUMAN_FEEDBACK:-0}" == "1" ]]; then
  input="$(cat | strip_ansi)"
  feedback="$(printf '%s\n' "$input" | extract_recent_user_feedback)"
  if human_feedback_is_corrective "$feedback"; then
    printf 'corrective\t%s\n' "$feedback"
  else
    printf 'none\t%s\n' "$feedback"
  fi
  exit 0
fi

if ! window_exists; then
  echo "son-watcher: window not found: $window" >&2
  exit 1
fi

if ! pane_belongs_to_window; then
  echo "son-watcher: pane $son_pane is not live in window $window" >&2
  exit 1
fi

existing_pid="$(tmux_get @dad_son_watcher_pid)"
if pid_matches_this_watcher "$existing_pid"; then
  log "duplicate existing_pid=$existing_pid window=$window son_pane=$son_pane"
  exit 0
fi

trap cleanup EXIT
trap 'terminate TERM' TERM
trap 'terminate INT' INT

tmux_set @dad_son_watcher_pid "$$"
tmux_set @dad_son_watcher_started_at "$started_at"
tmux_set @dad_son_watcher_status running
tmux_set @dad_son_watcher_window "$window"
tmux_set @dad_son_watcher_pane "$son_pane"
log "started socket=$socket window=$window son_pane=$son_pane"

last_event_key=""

while true; do
  if ! window_exists; then
    log "exit window_missing window=$window"
    exit 0
  fi

  if ! pane_belongs_to_window; then
    tmux_set @dad_son_watcher_status exited:pane_missing
    tmux_set @dad_son_watcher_exited_at "$(date -Is)"
    log "exit pane_missing pane=$son_pane"
    exit 0
  fi

  state="$(tmux_get @dad_state)"
  if [[ "$state" == "stopped" ]]; then
    tmux_set @dad_son_watcher_status exited:stopped
    tmux_set @dad_son_watcher_exited_at "$(date -Is)"
    log "exit state=stopped"
    exit 0
  fi

  ts="$(date -Is)"
  pane_text="$(tmux -S "$socket" capture-pane -t "$son_pane" -p -S -140 2>/dev/null || true)"
  clean_text="$(printf '%s\n' "$pane_text" | strip_ansi)"
  record_human_feedback "$ts" "$clean_text"
  stable_tail="$(printf '%s\n' "$clean_text" | tail -100 | sed 's/[[:space:]]\+/ /g')"
  fingerprint="$(printf '%s\n' "$stable_tail" | fingerprint_text)"
  old_fingerprint="$(tmux_get @dad_son_fingerprint)"
  old_state="$(tmux_get @dad_son_state)"
  classification="$(classify_clean_text "$clean_text")"
  son_state="${classification%%$'\t'*}"
  reason="${classification#*$'\t'}"
  percent="$(printf '%s\n' "$clean_text" | max_percent || true)"

  if [[ "$fingerprint" != "$old_fingerprint" ]]; then
    tmux_set @dad_son_fingerprint_changed_at "$ts"
  fi

  if [[ "$son_state" == "idle" ]]; then
    old_idle_since="$(tmux_get @dad_son_idle_since)"
    if [[ "$old_state" != "idle" || -z "$old_idle_since" ]]; then
      tmux_set @dad_son_idle_since "$ts"
    fi
  else
    tmux_set @dad_son_idle_since ''
  fi

  if [[ "$son_state" == "claim" && ( "$old_state" != "claim" || "$fingerprint" != "$old_fingerprint" ) ]]; then
    tmux_set @dad_son_last_claim_at "$ts"
  fi

  if has_context_pressure "$percent"; then
    tmux_set @dad_son_context_pressure "high:${percent}%"
  elif [[ -n "$percent" ]]; then
    tmux_set @dad_son_context_pressure "ok:${percent}%"
  else
    tmux_set @dad_son_context_pressure unknown
  fi

  tmux_set @dad_son_observed_at "$ts"
  tmux_set @dad_son_state "$son_state"
  tmux_set @dad_son_state_reason "$reason"
  tmux_set @dad_son_fingerprint "$fingerprint"
  tmux_set @dad_son_watcher_status "running:$son_state"

  event_key="$son_state:$fingerprint"
  if [[ "$event_key" != "$last_event_key" ]]; then
    snippet="$(printf '%s\n' "$clean_text" | event_snippet)"
    emit_event "$ts" "$son_state" "$fingerprint" "$reason" "$snippet"
    last_event_key="$event_key"
    log "event state=$son_state fingerprint=$fingerprint reason=$reason"
  fi

  interruptible_sleep "$poll_seconds"
done
