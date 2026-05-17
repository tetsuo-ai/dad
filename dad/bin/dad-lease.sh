#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage:
  dad-lease.sh acquire <tmux-socket> <window-id> <kind> [ttl-seconds]
  dad-lease.sh release <tmux-socket> <window-id> <run-id>
  dad-lease.sh clear <tmux-socket> <window-id> <expected-run-id> [reason]
  dad-lease.sh status <tmux-socket> <window-id>

Exit codes:
  0  success
  10 live lease already owned by another run
  20 stale lease cleared; caller must stop and let a later pass start cleanly
  30 lock acquisition timed out
  2  invalid input
USAGE
  exit 2
}

[[ $# -ge 3 ]] || usage

command_name="$1"
socket="$2"
window="$3"
shift 3

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dad-env.sh
source "$script_dir/dad-env.sh"
dad_root="$(dad_root)"
data_root="$(dad_data_root)"
lock_root="${DAD_LEASE_LOCK_DIR:-$data_root/locks}"
min_ttl="${DAD_LEASE_MIN_TTL_SECONDS:-60}"
lock_timeout="${DAD_LEASE_LOCK_TIMEOUT_SECONDS:-5}"

dad_validate_window_id "$window" || {
  echo "dad-lease: invalid window target: $window" >&2
  exit 2
}
[[ "$lock_timeout" =~ ^[0-9]+$ ]] || {
  echo "dad-lease: lock timeout must be a non-negative integer" >&2
  exit 2
}
socket_hash="$(printf '%s' "$socket" | sha256sum | awk '{ print substr($1, 1, 12) }')"
window_id="${window#@}"
lock_file="$lock_root/${socket_hash}-window-${window_id}.lease.lock"

mkdir -p "$lock_root"
chmod 700 "$lock_root" 2>/dev/null || true

tmux_get() {
  tmux -S "$socket" show-window-option -v -t "$window" "$1" 2>/dev/null || true
}

tmux_set() {
  if ! tmux -S "$socket" set-window-option -t "$window" "$1" "$2" >/dev/null 2>&1; then
    echo "dad-lease: failed to set tmux option $1 on $window" >&2
    return 1
  fi
}

epoch() {
  value="$1"
  date -d "$value" +%s 2>/dev/null || printf '0'
}

window_exists() {
  tmux -S "$socket" display-message -p -t "$window" '#{window_id}' >/dev/null 2>&1
}

window_exists || {
  echo "dad-lease: window not found: $window" >&2
  exit 2
}

acquire_locked() {
  kind="$1"
  ttl="${2:-540}"
  case "$kind" in
    fast|deep|strategic) ;;
    *) echo "dad-lease: invalid kind: $kind" >&2; exit 2 ;;
  esac
  [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]] || {
    echo "dad-lease: ttl must be a positive integer" >&2
    exit 2
  }
  if [[ "$min_ttl" =~ ^[0-9]+$ && "$ttl" -lt "$min_ttl" ]]; then
    ttl="$min_ttl"
  fi

  active="$(tmux_get @dad_loop_active)"
  run_id="$(tmux_get @dad_loop_run_id)"
  started_at="$(tmux_get @dad_loop_started_at)"
  now="$(date +%s)"
  started_epoch="$(epoch "$started_at")"

  if [[ -n "$active" ]]; then
    if [[ "$started_epoch" -gt 0 && $((now - started_epoch)) -le "$ttl" ]]; then
      echo "BUSY active=$active run_id=$run_id started_at=$started_at age=$((now - started_epoch))s"
      exit 10
    fi
    tmux_set @dad_scheduler_repair_required stale_lease_cleared
    tmux_set @dad_loop_active ''
    tmux_set @dad_loop_run_id ''
    tmux_set @dad_loop_started_at ''
    tmux_set @dad_loop_lease_owner ''
    tmux_set @dad_loop_stale_cleared_at "$(date -Is)"
    tmux_set @dad_last_seen_summary "Mechanical lease helper cleared stale scheduled-pass lease active=$active run_id=$run_id started_at=$started_at before acquiring a fresh lease. This prevents stale model state from permanently blocking supervision."
    echo "STALE_CLEARED active=$active run_id=$run_id started_at=$started_at" >&2
    if [[ "${DAD_LEASE_CLEAR_AND_CONTINUE:-0}" != "1" ]]; then
      exit 20
    fi
  fi

  new_run_id="${kind}-$(date +%s)-$$"
  ts="$(date -Is)"
  tmux_set @dad_loop_active "$kind"
  tmux_set @dad_loop_run_id "$new_run_id"
  tmux_set @dad_loop_started_at "$ts"
  tmux_set @dad_loop_lease_owner "$socket_hash:$window:$new_run_id"
  echo "$new_run_id"
}

release_locked() {
  expected_run_id="$1"
  [[ -n "$expected_run_id" ]] || usage
  current_run_id="$(tmux_get @dad_loop_run_id)"
  if [[ "$current_run_id" != "$expected_run_id" ]]; then
    echo "MISMATCH current_run_id=$current_run_id expected_run_id=$expected_run_id"
    exit 10
  fi
  ts="$(date -Is)"
  tmux_set @dad_loop_release_pending "$expected_run_id"
  tmux_set @dad_loop_released_at "$ts"
  tmux_set @dad_last_seen_summary "Mechanical lease helper recorded release-pending for scheduled-pass lease run_id=$expected_run_id. The watchdog will clear the active lease only after Dad returns to a safe composer/completed-turn state."
  echo "RELEASE_PENDING $expected_run_id"
}

clear_locked() {
  expected_run_id="$1"
  reason="${2:-watchdog_clear}"
  [[ -n "$expected_run_id" ]] || usage
  [[ "$reason" =~ ^[A-Za-z0-9._:-]+$ ]] || {
    echo "dad-lease: invalid clear reason: $reason" >&2
    exit 2
  }
  current_run_id="$(tmux_get @dad_loop_run_id)"
  current_active="$(tmux_get @dad_loop_active)"
  if [[ "$current_run_id" != "$expected_run_id" ]]; then
    echo "MISMATCH current_run_id=$current_run_id expected_run_id=$expected_run_id"
    exit 10
  fi
  tmux_set @dad_loop_active ''
  tmux_set @dad_loop_run_id ''
  tmux_set @dad_loop_started_at ''
  tmux_set @dad_loop_lease_owner ''
  tmux_set @dad_loop_release_pending ''
  tmux_set @dad_loop_released_at ''
  tmux_set @dad_loop_cleared_at "$(date -Is)"
  tmux_set @dad_loop_clear_reason "$reason"
  echo "CLEARED active=$current_active run_id=$current_run_id reason=$reason"
}

status_locked() {
  printf 'active=%s\n' "$(tmux_get @dad_loop_active)"
  printf 'run_id=%s\n' "$(tmux_get @dad_loop_run_id)"
  printf 'started_at=%s\n' "$(tmux_get @dad_loop_started_at)"
  printf 'owner=%s\n' "$(tmux_get @dad_loop_lease_owner)"
  printf 'release_pending=%s\n' "$(tmux_get @dad_loop_release_pending)"
  printf 'released_at=%s\n' "$(tmux_get @dad_loop_released_at)"
}

(
  if ! flock -w "$lock_timeout" -x 9; then
    echo "dad-lease: timed out acquiring lease lock after ${lock_timeout}s: $lock_file" >&2
    exit 30
  fi
  case "$command_name" in
    acquire)
      [[ $# -ge 1 && $# -le 2 ]] || usage
      acquire_locked "$@"
      ;;
    release)
      [[ $# -eq 1 ]] || usage
      release_locked "$1"
      ;;
    clear)
      [[ $# -ge 1 && $# -le 2 ]] || usage
      clear_locked "$@"
      ;;
    status)
      [[ $# -eq 0 ]] || usage
      status_locked
      ;;
    *)
      usage
      ;;
  esac
) 9>"$lock_file"
