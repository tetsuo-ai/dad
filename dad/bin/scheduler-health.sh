#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: scheduler-health.sh --socket <socket> --window <window-id> [--repair]

Checks the visible Grok scheduler rows and DAD scheduler metadata for a live
DAD window. With --repair, submits the bounded scheduler-label repair directive
when the Dad pane is idle enough to accept it.
USAGE
  exit 2
}

socket=""
window=""
repair=0

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
    --repair)
      repair=1
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dad_root="$(cd "$script_dir/.." && pwd)"
repair_helper="${DAD_SCHEDULER_LABEL_REPAIR:-$script_dir/scheduler-label-repair.sh}"
policy_file="${DAD_POLICY_VERSION_FILE:-$dad_root/POLICY_VERSION}"
repair_cooldown_seconds="${DAD_SCHEDULER_HEALTH_REPAIR_COOLDOWN_SECONDS:-180}"

tmux_get() {
  tmux -S "$socket" show-window-option -v -t "$window" "$1" 2>/dev/null || true
}

tmux_set() {
  tmux -S "$socket" set-window-option -t "$window" "$1" "$2" >/dev/null 2>&1
}

epoch() {
  value="$1"
  date -d "$value" +%s 2>/dev/null || printf '0'
}

scheduler_health_signal() {
  snapshot="$1"
  fast_id="${2:-}"
  deep_id="${3:-}"
  strategic_id="${4:-}"
  metadata_policy="${5:-}"
  disk_policy="${6:-}"

  rows="$(printf '%s\n' "$snapshot" | grep -E '\[loop\].*DAD scheduler trampoline' || true)"

  if printf '%s\n' "$rows" | grep -Eiq '(^|[^[:alpha:]])(failed|errored|error|cancelled|canceled)([^[:alpha:]]|$)'; then
    printf 'failed_visible_scheduler_loop\n'
    return 0
  fi

  if [[ -z "$rows" ]]; then
    printf 'missing_visible_scheduler_rows\n'
    return 0
  fi

  if ! printf '%s\n' "$rows" | grep -Eq 'every[[:space:]]+2[[:space:]]+minutes'; then
    printf 'missing_visible_fast_loop\n'
    return 0
  fi
  if ! printf '%s\n' "$rows" | grep -Eq 'every[[:space:]]+12[[:space:]]+minutes'; then
    printf 'missing_visible_deep_loop\n'
    return 0
  fi
  if ! printf '%s\n' "$rows" | grep -Eq 'every[[:space:]]+30[[:space:]]+minutes'; then
    printf 'missing_visible_strategic_loop\n'
    return 0
  fi

  if [[ -z "$fast_id" || -z "$deep_id" || -z "$strategic_id" ]]; then
    printf 'missing_scheduler_ids\n'
    return 0
  fi

  if [[ -n "$disk_policy" && -n "$metadata_policy" && "$metadata_policy" != "$disk_policy" ]]; then
    printf 'policy_version_mismatch\n'
    return 0
  fi

  printf 'healthy\n'
}

if [[ "${DAD_SCHEDULER_HEALTH_TEST_CLASSIFY:-0}" == "1" ]]; then
  snapshot="$(cat)"
  scheduler_health_signal \
    "$snapshot" \
    "${DAD_TEST_FAST_SCHEDULER_ID-fast-id}" \
    "${DAD_TEST_DEEP_SCHEDULER_ID-deep-id}" \
    "${DAD_TEST_STRATEGIC_SCHEDULER_ID-strategic-id}" \
    "${DAD_TEST_POLICY_VERSION-policy-v1}" \
    "${DAD_TEST_DISK_POLICY_VERSION-policy-v1}"
  exit 0
fi

[[ -n "$socket" && -n "$window" ]] || usage

if ! tmux -S "$socket" display-message -p -t "$window" '#{window_id}' >/dev/null 2>&1; then
  echo "scheduler-health: window not found: $window" >&2
  exit 1
fi

dad_pane="$(tmux_get @dad_dad_pane)"
[[ -n "$dad_pane" ]] || {
  tmux_set @dad_scheduler_health_status missing_dad_pane || true
  echo "SCHEDULER_HEALTH_RESULT: FAIL missing_dad_pane"
  exit 0
}

if ! tmux -S "$socket" list-panes -t "$window" -F '#{pane_id} #{pane_dead}' 2>/dev/null |
    awk -v pane="$dad_pane" '$1 == pane && $2 == "0" { found = 1 } END { exit(found ? 0 : 1) }'; then
  tmux_set @dad_scheduler_health_status dad_pane_not_live || true
  echo "SCHEDULER_HEALTH_RESULT: FAIL dad_pane_not_live"
  exit 0
fi

snapshot="$(tmux -S "$socket" capture-pane -t "$dad_pane" -p -S -200 2>/dev/null || true)"
fast_id="$(tmux_get @dad_fast_scheduler_id)"
deep_id="$(tmux_get @dad_deep_scheduler_id)"
strategic_id="$(tmux_get @dad_strategic_scheduler_id)"
metadata_policy="$(tmux_get @dad_policy_version)"
disk_policy="$(tr -d '[:space:]' < "$policy_file" 2>/dev/null || true)"
signal="$(scheduler_health_signal "$snapshot" "$fast_id" "$deep_id" "$strategic_id" "$metadata_policy" "$disk_policy")"

tmux_set @dad_scheduler_health_checked_at "$(date -Is)" || true

if [[ "$signal" == "healthy" ]]; then
  tmux_set @dad_scheduler_health_status healthy || true
  if [[ "$(tmux_get @dad_scheduler_repair_required)" =~ ^(failed_visible_scheduler_loop|missing_visible_|missing_scheduler_ids|policy_version_mismatch|label_repair_submitted)$ ]]; then
    tmux_set @dad_scheduler_repair_required '' || true
  fi
  echo "SCHEDULER_HEALTH_RESULT: PASS healthy"
  exit 0
fi

tmux_set @dad_scheduler_health_status "unhealthy:$signal" || true
tmux_set @dad_scheduler_repair_required "$signal" || true

if [[ "$repair" -eq 0 ]]; then
  echo "SCHEDULER_HEALTH_RESULT: FAIL $signal"
  exit 0
fi

last_attempt="$(tmux_get @dad_scheduler_health_repair_attempted_at)"
last_epoch="$(epoch "$last_attempt")"
now_epoch="$(date +%s)"
if [[ "$last_epoch" -gt 0 && $((now_epoch - last_epoch)) -lt "$repair_cooldown_seconds" ]]; then
  tmux_set @dad_scheduler_health_status "cooldown:$signal" || true
  echo "SCHEDULER_HEALTH_RESULT: COOLDOWN $signal"
  exit 0
fi

tmux_set @dad_scheduler_health_repair_checked_at "$(date -Is)" || true
if output="$("$repair_helper" --socket "$socket" --window "$window" --inject 2>&1)"; then
  tmux_set @dad_scheduler_health_repair_attempted_at "$(date -Is)" || true
  tmux_set @dad_scheduler_health_status "repair_submitted:$signal" || true
  tmux_set @dad_scheduler_repair_required label_repair_submitted || true
  printf 'SCHEDULER_HEALTH_RESULT: REPAIR_SUBMITTED %s\n%s\n' "$signal" "$output"
  exit 0
fi

if printf '%s\n' "$output" | grep -Fq 'Dad pane is active'; then
  tmux_set @dad_scheduler_health_status "waiting:dad_busy:$signal" || true
  printf 'SCHEDULER_HEALTH_RESULT: WAITING_DAD_BUSY %s\n%s\n' "$signal" "$output"
  exit 0
fi

tmux_set @dad_scheduler_health_status "repair_failed:$signal" || true
printf 'SCHEDULER_HEALTH_RESULT: REPAIR_FAILED %s\n%s\n' "$signal" "$output"
