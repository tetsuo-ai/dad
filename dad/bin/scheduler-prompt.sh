#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: scheduler-prompt.sh <fast|deep|strategic> <window-id> <son-pane-id> [objective-file|-]

Print the current DAD scheduler trampoline prompt for scheduler_create or /loop
repair. The policy version is read from the installed DAD root so prompt labels
do not drift with dates or copied inline strings.
USAGE
  exit 2
}

[[ $# -ge 3 ]] || usage

loop="$1"
window="$2"
son_pane="$3"
objective_source="${4:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dad-env.sh
source "$script_dir/dad-env.sh"
dad_root="$(dad_root)"
repo_root="$(dad_plugin_root)"
skill_path="${DAD_SKILL_FILE:-$repo_root/skills/dad/SKILL.md}"
design_path="${DAD_DESIGN_FILE:-$dad_root/DAD.md}"
lease_helper="${DAD_LEASE_HELPER:-$script_dir/dad-lease.sh}"
version_file="${DAD_POLICY_VERSION_FILE:-$dad_root/POLICY_VERSION}"
version="${DAD_POLICY_VERSION:-}"
if [[ -z "$version" && -r "$version_file" ]]; then
  version="$(tr -d '[:space:]' < "$version_file")"
fi
version="${version:-failclosed-lease-evidence-v1}"

case "$loop" in
  fast)
    role="fast"
    policy="Fast Loop Policy"
    lease="one loop lease"
    pass="one bounded fast-loop pass"
    ;;
  deep)
    role="deep"
    policy="Deep Loop Policy"
    lease="one loop lease"
    pass="one bounded deep-loop pass"
    ;;
  strategic)
    role="strategic"
    policy="Strategic Loop Policy"
    lease="one strategic loop lease"
    pass="one bounded strategic-loop pass"
    ;;
  *)
    usage
    ;;
esac

if [[ "$objective_source" == "-" ]]; then
  objective="$(cat)"
elif [[ -n "$objective_source" ]]; then
  [[ -r "$objective_source" ]] || { echo "scheduler-prompt: objective file not readable: $objective_source" >&2; exit 1; }
  objective="$(<"$objective_source")"
else
  objective="<objective>"
fi

printf 'DAD scheduler trampoline version: %s. You are the %s supervisor trampoline for this DAD window. Bootstrap facts only: DAD window ID: %s. Son pane ID: %s. Original objective: %s. Skill path: %s. Design path: %s. Before taking any action, read both files from disk and follow the current DAD policy found there, especially `Evidence Contract`, `Bounded Evidence Runner`, `Prompt Submission and UI Actions`, `Mechanical Watchdog`, `Mechanical Son Watcher`, `Mechanical Son Watchdog`, `Mechanical Idle Controller`, `Structured Event Trace Hooks`, `Forever Supervision and Verified Checkpoints`, `Continuous Improvement Ratchet`, `Research-Grounded Quality Ratchet`, `Reference Scout / Code Harvest Ratchet`, `Implementation Delta Ratchet`, `Context-Bounded Coding Standards`, `No Delegated Verification`, `Stable Branch and Commit Discipline`, `Scheduler Trampoline and Run Policies`, and `%s`. Do not rely on cached policy details from this scheduler prompt. Use these bootstrap facts only to locate the window/pane and reconcile metadata. This recurring pass must not call scheduler_list, scheduler_create, scheduler_delete, or Grok'"'"'s stop/cancel tool. If @dad_state is recovering or broken, fail closed and do not act. Ensure the mechanical watchdog, passive Son watcher, Son watchdog, and idle controller are running. Acquire %s with %s, execute exactly %s, release the same lease, and end the turn with a concise normal status response.\n' \
  "$version" "$role" "$window" "$son_pane" "$objective" "$skill_path" "$design_path" "$policy" "$lease" "$lease_helper" "$pass"
