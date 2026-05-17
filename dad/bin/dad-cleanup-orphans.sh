#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: dad-cleanup-orphans.sh [--socket <socket> --window <window-id>] [--kill-dad-windows] [--dry-run] [--confirm-global]

Clean up DAD-owned background resources that outlived their tmux owner:
- terminates DAD watchdog/watcher/controller daemons whose window or pane is gone
- with --kill-dad-windows and explicit --socket/--window, closes only that DAD-owned window
- global --kill-dad-windows is dry-run only unless --confirm-global is also set

This does not inspect or edit project artifacts.
USAGE
  exit 2
}

kill_dad_windows=0
dry_run=0
socket_filter=""
window_filter=""
confirm_global=0
kill_cmd="${DAD_CLEANUP_KILL_CMD:-kill}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --socket)
      [[ $# -ge 2 ]] || usage
      socket_filter="$2"
      shift 2
      ;;
    --window)
      [[ $# -ge 2 ]] || usage
      window_filter="$2"
      shift 2
      ;;
    --kill-dad-windows)
      kill_dad_windows=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --confirm-global)
      confirm_global=1
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

log() {
  printf '%s\n' "$*"
}

run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf 'DRY_RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

matches_filters() {
  socket="$1"
  window="$2"
  [[ -z "$socket_filter" || "$socket" == "$socket_filter" ]] || return 1
  [[ -z "$window_filter" || "$window" == "$window_filter" ]] || return 1
}

window_exists() {
  socket="$1"
  window="$2"
  tmux -S "$socket" display-message -p -t "$window" '#{window_id}' >/dev/null 2>&1
}

pane_in_window() {
  socket="$1"
  window="$2"
  pane="$3"
  [[ -n "$pane" ]] || return 0
  tmux -S "$socket" list-panes -t "$window" -F '#{pane_id} #{pane_dead}' 2>/dev/null |
    awk -v pane="$pane" '$1 == pane && $2 == "0" { found = 1 } END { exit(found ? 0 : 1) }'
}

terminate_orphan_daemons() {
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] || continue
    [[ -r "/proc/$pid/cmdline" ]] || continue
    mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || continue
    script_index=-1
    for i in "${!args[@]}"; do
      case "${args[$i]}" in
        */dad/bin/watchdog.sh|\
        */dad/bin/idle-controller.sh|\
        */dad/bin/son-watcher.sh|\
        */dad/bin/son-watchdog.sh)
          script_index="$i"
          break
          ;;
      esac
    done
    [[ "$script_index" -ge 0 ]] || continue

    script="${args[$script_index]}"
    socket="${args[$((script_index + 1))]:-}"
    window="${args[$((script_index + 2))]:-}"
    first_pane="${args[$((script_index + 3))]:-}"
    second_pane="${args[$((script_index + 4))]:-}"
    [[ -n "$socket" && -n "$window" ]] || continue
    matches_filters "$socket" "$window" || continue

    reason=""
    if ! window_exists "$socket" "$window"; then
      reason="window_missing"
    elif ! pane_in_window "$socket" "$window" "$first_pane"; then
      reason="pane_missing:$first_pane"
    elif [[ "$script" == */dad/bin/idle-controller.sh ]] &&
        ! pane_in_window "$socket" "$window" "$second_pane"; then
      reason="pane_missing:$second_pane"
    fi

    [[ -n "$reason" ]] || continue
    log "terminating_orphan_daemon pid=$pid script=$(basename "$script") window=$window reason=$reason"
    run "$kill_cmd" -TERM "$pid" 2>/dev/null || true
  done < <(pgrep -f 'dad/bin/(watchdog|idle-controller|son-watcher|son-watchdog)\.sh' || true)
}

candidate_sockets() {
  if [[ -n "$socket_filter" ]]; then
    printf '%s\n' "$socket_filter"
    return
  fi
  {
    [[ -n "${TMUX:-}" ]] && printf '%s\n' "${TMUX%%,*}"
    printf '/tmp/tmux-%s/default\n' "$(id -u)"
    find /tmp -maxdepth 2 -type s \( -path "/tmp/tmux-$(id -u)/*" -o -name 'grok*.sock' \) -print 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

window_is_dad_owned() {
  socket="$1"
  window="$2"
  name="$3"
  [[ "$name" == DAD-* || "$name" == DAD_* ]] && return 0
  state="$(tmux -S "$socket" show-window-option -v -t "$window" @dad_state 2>/dev/null || true)"
  dad_id="$(tmux -S "$socket" show-window-option -v -t "$window" @dad_window_id 2>/dev/null || true)"
  [[ -n "$state" || -n "$dad_id" ]]
}

kill_dad_windows_if_requested() {
  [[ "$kill_dad_windows" -eq 1 ]] || return 0
  if [[ -z "$socket_filter" || -z "$window_filter" ]]; then
    if [[ "$dry_run" -ne 1 && "$confirm_global" -ne 1 ]]; then
      echo "dad-cleanup: global destructive window cleanup requires --dry-run or --confirm-global" >&2
      return 2
    fi
  fi
  while read -r socket; do
    [[ -n "$socket_filter" || -S "$socket" ]] || continue
    while IFS=$'\t' read -r window name; do
      [[ -n "$window" ]] || continue
      matches_filters "$socket" "$window" || continue
      if window_is_dad_owned "$socket" "$window" "$name"; then
        log "closing_dad_window socket=$socket window=$window name=$name"
        run tmux -S "$socket" kill-window -t "$window" 2>/dev/null || true
      fi
    done < <(tmux -S "$socket" list-windows -a -F '#{window_id}	#{window_name}' 2>/dev/null || true)
  done < <(candidate_sockets)
}

cleanup_quarantined_pids() {
  while read -r socket; do
    [[ -n "$socket_filter" || -S "$socket" ]] || continue
    while IFS=$'\t' read -r window name; do
      [[ -n "$window" ]] || continue
      matches_filters "$socket" "$window" || continue
      pids="$(tmux -S "$socket" show-window-option -v -t "$window" @dad_quarantined_old_dad_pids 2>/dev/null || true)"
      [[ -n "$pids" ]] || continue
      IFS=',' read -r -a pid_list <<< "$pids"
      for pid in "${pid_list[@]}"; do
        [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] || continue
        [[ -r "/proc/$pid/cmdline" ]] || continue
        cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
        [[ "$cmdline" == *grok* ]] || {
          log "skip_quarantined_pid pid=$pid reason=not_grok window=$window"
          continue
        }
        log "terminating_quarantined_old_dad pid=$pid window=$window"
        run "$kill_cmd" -CONT "$pid" 2>/dev/null || true
        run "$kill_cmd" -TERM "$pid" 2>/dev/null || true
        if [[ "$dry_run" -eq 0 ]]; then
          sleep 1
          if kill -0 "$pid" 2>/dev/null; then
            run "$kill_cmd" -KILL "$pid" 2>/dev/null || true
          fi
        fi
      done
    done < <(tmux -S "$socket" list-windows -a -F '#{window_id}	#{window_name}' 2>/dev/null || true)
  done < <(candidate_sockets)
}

terminate_orphan_daemons
cleanup_quarantined_pids
kill_dad_windows_if_requested
