#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="${DAD_TEST_ROOT:-$REPO_ROOT/dad}"
SKILL_FILE="${DAD_TEST_SKILL_FILE:-$REPO_ROOT/skills/dad/SKILL.md}"
DESIGN_FILE="${DAD_TEST_DESIGN_FILE:-$ROOT/DAD.md}"
GLOBAL_CLAUDE_FILE="${DAD_TEST_GLOBAL_CLAUDE_FILE:-}"
IDLE="$ROOT/bin/idle-controller.sh"
IDLE_ACTIONS="$ROOT/bin/idle-controller-actions.sh"
WATCHDOG="$ROOT/bin/watchdog.sh"
SON_WATCHDOG="$ROOT/bin/son-watchdog.sh"
RUNNER="$ROOT/bin/evidence-runner.py"
GATE="$ROOT/bin/evidence-gate.py"
SUBMIT="$ROOT/bin/tmux-submit.sh"
WATCHER="$ROOT/bin/son-watcher.sh"
EVENT_HOOK="$ROOT/bin/dad-event-hook.py"
ARCHIVE="$ROOT/bin/archive-legacy-windows.py"
SCHED_PROMPT="$ROOT/bin/scheduler-prompt.sh"
SCHED_REPAIR="$ROOT/bin/scheduler-label-repair.sh"
SCHED_HEALTH="$ROOT/bin/scheduler-health.sh"
CLEANUP="$ROOT/bin/dad-cleanup-orphans.sh"
CODE_STANDARDS="$ROOT/bin/code-standards-check.py"
DOCTOR="$ROOT/bin/dad-doctor.py"
PACKAGE="$ROOT/bin/dad-package.sh"
STARTUP_PLAN="$ROOT/bin/dad-startup-plan.py"
POLICY_VERSION="$(tr -d '[:space:]' < "$ROOT/POLICY_VERSION")"
PLUGIN_MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
PLUGIN_HOOKS="$REPO_ROOT/hooks/hooks.json"
PLUGIN_HOOK_SCRIPT="$REPO_ROOT/hooks/scripts/dad-event-hook.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  expected="$1"
  actual="$2"
  label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
}

assert_match() {
  pattern="$1"
  actual="$2"
  label="$3"
  [[ "$actual" =~ $pattern ]] || fail "$label: expected pattern [$pattern], got [$actual]"
}

tmp="$(mktemp -d)"
trap 'if [[ -n "${grok_pid:-}" ]] && kill -0 "$grok_pid" 2>/dev/null; then kill -CONT "$grok_pid" 2>/dev/null || true; kill -TERM "$grok_pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
export DAD_DATA_ROOT="$tmp/dad-data"
IDLE_SURFACE="$tmp/idle-controller-surface.sh"
cat "$IDLE" "$IDLE_ACTIONS" > "$IDLE_SURFACE"

if [[ -d "$ROOT/windows" ]]; then
  while IFS= read -r -d '' current_window_state; do
    if grep -q 'mechanical-guard-v2' "$current_window_state"; then
      fail "current DAD window state contains stale mechanical-guard-v2 policy: $current_window_state"
    fi
  done < <(find "$ROOT/windows" -maxdepth 2 -name current.dad.json -print0)
fi

python3 - "$PLUGIN_MANIFEST" "$PLUGIN_HOOKS" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
hooks = json.loads(Path(sys.argv[2]).read_text())
assert manifest["name"] == "dad"
assert manifest["version"]
assert "hooks" in hooks and isinstance(hooks["hooks"], dict)
PY
grep -q 'user_invocable: true' "$SKILL_FILE" || fail "DAD skill must be slash-invocable when installed as a plugin"
grep -q 'CLAUDE_PLUGIN_ROOT' "$PLUGIN_HOOKS" || fail "plugin hooks must resolve through CLAUDE_PLUGIN_ROOT"
grep -q 'CLAUDE_PLUGIN_ROOT' "$PLUGIN_HOOK_SCRIPT" || fail "plugin hook wrapper must self-locate from CLAUDE_PLUGIN_ROOT"
grep -q 'GROK_PLUGIN_ROOT' "$PLUGIN_HOOK_SCRIPT" || fail "plugin hook wrapper must honor GROK_PLUGIN_ROOT"
grep -q 'GROK_PLUGIN_DATA' "$ROOT/bin/dad-env.sh" || fail "DAD shell path helper must honor GROK_PLUGIN_DATA"
grep -q 'GROK_PLUGIN_DATA' "$ROOT/bin/dad_paths.py" || fail "DAD Python path helper must honor GROK_PLUGIN_DATA"
grep -q 'GROK_PLUGIN_DATA' "$SKILL_FILE" || fail "DAD skill must document Grok plugin data root precedence"
grep -q 'GROK_PLUGIN_DATA' "$DESIGN_FILE" || fail "DAD design must document Grok plugin data root precedence"
grep -q 'GROK_PLUGIN_DATA' "$REPO_ROOT/README.md" || fail "README must document Grok plugin data root precedence"
legacy_hook_template="$REPO_ROOT/hooks/dad-events"".json.template"
mcp_config_path="$REPO_ROOT/.mcp"".json"
[[ ! -e "$legacy_hook_template" ]] || fail "plugin hook config must live at hooks/hooks.json, not a template path"
[[ ! -e "$mcp_config_path" ]] || fail "portable DAD plugin must ship native tmux only"
grep -q 'Linux with procfs' "$REPO_ROOT/README.md" || fail "README must document Linux/procfs platform requirement"
grep -q 'dad-doctor.py' "$REPO_ROOT/README.md" || fail "README must document DAD doctor preflight"
grep -q 'dad-package.sh' "$REPO_ROOT/README.md" || fail "README must document clean package export"
grep -q 'dad-startup-plan.py' "$SKILL_FILE" || fail "DAD skill must use deterministic startup modes"
grep -q 'dad-startup-plan.py' "$DESIGN_FILE" || fail "DAD design must document deterministic startup modes"
grep -q -- '--mode safe' "$REPO_ROOT/README.md" || fail "README must document safe startup mode"
grep -q -- '--mode review-only' "$REPO_ROOT/README.md" || fail "README must document review-only startup mode"
grep -q -- '--mode yolo' "$REPO_ROOT/README.md" || fail "README must document yolo startup mode"
python3 - "$PLUGIN_HOOKS" "$REPO_ROOT/README.md" "$SKILL_FILE" "$DESIGN_FILE" <<'PY'
import json
import sys
from pathlib import Path

events = set(json.loads(Path(sys.argv[1]).read_text())["hooks"])
assert "PostToolUseFailure" in events
assert "PreCompact" in events
docs = "\n".join(Path(path).read_text() for path in sys.argv[2:])
assert "StopFailure" not in docs
assert "PostCompact" not in docs
PY

if DAD_DOCTOR_MISSING_TOOLS=flock python3 "$DOCTOR" --platform-only >"$tmp/doctor-platform.out" 2>&1; then
  fail "doctor preflight passed with a forced missing required tool"
fi
grep -q 'required_tool_missing: flock' "$tmp/doctor-platform.out" || fail "doctor preflight missing-tool failure was not clear"
inspect_fixture="$tmp/grok-inspect.json"
cat > "$inspect_fixture" <<'EOF'
{
  "plugins": [{"name": "dad", "path": "/home/user/.grok/plugins/dad/skills/dad/SKILL.md"}],
  "skills": [{"name": "dad", "path": "/home/user/.grok/skills/dad/SKILL.md"}]
}
EOF
if python3 "$DOCTOR" --skip-platform --inspect-json "$inspect_fixture" >"$tmp/doctor-inspect.out" 2>&1; then
  fail "doctor accepted duplicate legacy and plugin dad skills"
fi
grep -q 'legacy_dad_skill_shadows_plugin' "$tmp/doctor-inspect.out" || fail "doctor duplicate-skill warning missing legacy shadow detail"

safe_plan="$(DAD_STARTUP_TEST_HAS_TMUX=1 python3 "$STARTUP_PLAN" --mode safe --objective "build safely" --json)"
printf '%s\n' "$safe_plan" | python3 -c 'import json, sys; data=json.load(sys.stdin); assert data["sonCommand"] == ["grok"]; assert data["requiresApproval"] is True'
yolo_plan="$(DAD_STARTUP_TEST_HAS_TMUX=1 python3 "$STARTUP_PLAN" --mode yolo --objective "build autonomously" --json)"
printf '%s\n' "$yolo_plan" | python3 -c 'import json, sys; data=json.load(sys.stdin); assert data["sonCommand"] == ["grok", "--yolo"]; assert data["writeAllowed"] is True'
review_plan="$(DAD_STARTUP_TEST_HAS_TMUX=1 python3 "$STARTUP_PLAN" --mode review-only --objective "read-only audit" --json)"
printf '%s\n' "$review_plan" | python3 -c 'import json, sys; data=json.load(sys.stdin); assert data["readOnly"] is True; assert data["writeAllowed"] is False'
if DAD_STARTUP_TEST_MISSING_TMUX=1 python3 "$STARTUP_PLAN" --mode safe --objective "x" >"$tmp/startup-missing-tmux.out" 2>&1; then
  fail "startup plan accepted missing tmux"
fi
grep -q 'missing_tmux' "$tmp/startup-missing-tmux.out" || fail "startup missing-tmux failure missing detail"
if DAD_STARTUP_TEST_HAS_TMUX=1 DAD_STARTUP_TEST_SCHEDULER_SUPPORT=0 python3 "$STARTUP_PLAN" --mode safe --objective "x" >"$tmp/startup-missing-scheduler.out" 2>&1; then
  fail "startup plan accepted missing scheduler support"
fi
grep -q 'missing_scheduler_support' "$tmp/startup-missing-scheduler.out" || fail "startup missing-scheduler failure missing detail"

package_root="$tmp/package-root"
mkdir -p "$package_root/.claude-plugin" "$package_root/dad/bin/__pycache__" "$package_root/dad/evidence" "$package_root/dad/events" "$package_root/dad/logs" "$package_root/dad/locks" "$package_root/hooks/scripts" "$package_root/skills/dad"
printf '{"name":"dad"}\n' > "$package_root/.claude-plugin/plugin.json"
printf 'license\n' > "$package_root/LICENSE"
printf 'readme\n' > "$package_root/README.md"
printf 'ignore\n' > "$package_root/.gitignore"
printf 'state\n' > "$package_root/dad/evidence/secret.json"
printf 'event\n' > "$package_root/dad/events/all-events.jsonl"
printf 'log\n' > "$package_root/dad/logs/dad.log"
printf 'lock\n' > "$package_root/dad/locks/x.lock"
printf 'pyc\n' > "$package_root/dad/bin/__pycache__/x.pyc"
printf 'script\n' > "$package_root/dad/bin/keep.sh"
printf '{}\n' > "$package_root/hooks/hooks.json"
printf 'hook\n' > "$package_root/hooks/scripts/keep.sh"
printf 'skill\n' > "$package_root/skills/dad/SKILL.md"
package_out="$tmp/dad-package.tar.gz"
"$PACKAGE" --root "$package_root" --output "$package_out" >/dev/null
tar -tzf "$package_out" > "$tmp/dad-package.lst"
grep -q '^LICENSE$' "$tmp/dad-package.lst" || fail "package export omitted LICENSE"
grep -q 'dad/bin/keep.sh' "$tmp/dad-package.lst" || fail "package export omitted source files"
! grep -Eq 'dad/(evidence|events|logs|locks)/|__pycache__|\\.pyc' "$tmp/dad-package.lst" || fail "package export included runtime or generated state"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_IDLE_CONTROLLER_CLAIM_ESCALATION_SECONDS=120 \
  DAD_IDLE_CONTROLLER_COOLDOWN_SECONDS=180 \
  DAD_TEST_DAD_STATE=broken \
  DAD_TEST_SON_STATE=claim \
  DAD_TEST_CLAIM_AGE=121 \
  DAD_TEST_ACTION_AGE=999 \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "direct_son_degraded_continuation" "$out" "broken Dad claim must degrade-direct to Son"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_IDLE_CONTROLLER_SLA_SECONDS=180 \
  DAD_IDLE_CONTROLLER_COOLDOWN_SECONDS=180 \
  DAD_TEST_DAD_STATE=recovering \
  DAD_TEST_SON_STATE=idle \
  DAD_TEST_IDLE_AGE=200 \
  DAD_TEST_ACTION_AGE=999 \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "direct_son_degraded_continuation" "$out" "recovering Dad idle must degrade-direct to Son"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_IDLE_CONTROLLER_CLAIM_ESCALATION_SECONDS=120 \
  DAD_IDLE_CONTROLLER_COOLDOWN_SECONDS=180 \
  DAD_TEST_DAD_STATE=broken \
  DAD_TEST_SON_STATE=claim \
  DAD_TEST_CLAIM_AGE=121 \
  DAD_TEST_LAST_ACTION=direct_son_degraded_continuation \
  DAD_TEST_ACTION_AGE=10 \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "degraded:claim_waiting" "$out" "degraded claim continuation must honor cooldown"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_IDLE_CONTROLLER_CLAIM_ESCALATION_SECONDS=120 \
  DAD_IDLE_CONTROLLER_COOLDOWN_SECONDS=180 \
  DAD_IDLE_CONTROLLER_HANDOFF_CLAIM_ESCALATION_SECONDS=25 \
  DAD_TEST_DAD_STATE=working \
  DAD_TEST_SON_STATE=claim \
  DAD_TEST_CLAIM_AGE=26 \
  DAD_TEST_SON_REASON="completed turn at composer asking for next action" \
  DAD_TEST_LAST_ACTION=submit_pending_son_paste \
  DAD_TEST_ACTION_AGE=10 \
  DAD_TEST_CLAIM_AFTER_ACTION=true \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "direct_son_claim_continuation" "$out" "new claim after prompt submit must not inherit submit cooldown"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_IDLE_CONTROLLER_CLAIM_ESCALATION_SECONDS=120 \
  DAD_IDLE_CONTROLLER_COOLDOWN_SECONDS=180 \
  DAD_IDLE_CONTROLLER_DELEGATED_VERIFICATION_ESCALATION_COUNT=2 \
  DAD_TEST_DAD_STATE=working \
  DAD_TEST_SON_STATE=claim \
  DAD_TEST_CLAIM_AGE=0 \
  DAD_TEST_SON_REASON="delegated verification to user instead of Son-run evidence" \
  DAD_TEST_ACTION_AGE=999 \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "direct_son_claim_continuation" "$out" "delegated verification claim must be corrected immediately"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_IDLE_CONTROLLER_CLAIM_ESCALATION_SECONDS=120 \
  DAD_IDLE_CONTROLLER_COOLDOWN_SECONDS=180 \
  DAD_IDLE_CONTROLLER_DELEGATED_VERIFICATION_ESCALATION_COUNT=2 \
  DAD_TEST_DAD_STATE=working \
  DAD_TEST_SON_STATE=claim \
  DAD_TEST_CLAIM_AGE=0 \
  DAD_TEST_SON_REASON="delegated verification to user instead of Son-run evidence" \
  DAD_TEST_DELEGATED_VERIFICATION_COUNT=1 \
  DAD_TEST_ACTION_AGE=999 \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "direct_son_code_write_correction" "$out" "repeated delegated verification must escalate to code-write correction"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_IDLE_CONTROLLER_CLAIM_ESCALATION_SECONDS=120 \
  DAD_IDLE_CONTROLLER_COOLDOWN_SECONDS=180 \
  DAD_TEST_DAD_STATE=working \
  DAD_TEST_SON_STATE=claim \
  DAD_TEST_CLAIM_AGE=0 \
  DAD_TEST_SON_REASON="code handoff to user instead of workspace edit" \
  DAD_TEST_ACTION_AGE=999 \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "direct_son_code_write_correction" "$out" "code handoff must immediately require workspace edit"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_TEST_DAD_STATE=broken \
  DAD_TEST_SON_STATE=plan_approval \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "plan_approval_requires_review" "$out" "degraded Dad must not approve Son plan without Dad review"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_TEST_DAD_STATE=working \
  DAD_TEST_SON_STATE=loop \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "son_watchdog_recovery" "$out" "idle-controller decision model must recognize Son loop as watchdog-owned recovery"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_TEST_DAD_STATE=working \
  DAD_TEST_SON_STATE=claim \
  DAD_TEST_BRANCH_PROBLEM=true \
  DAD_TEST_ACTION_AGE=999 \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "direct_son_branch_consolidation" "$out" "branch drift/sprawl must become a consolidation correction"

out="$(DAD_IDLE_CONTROLLER_TEST_BRANCH_ADOPTION=1 \
  DAD_TEST_CURRENT_BRANCH=dad/go-through-project \
  DAD_TEST_SESSION_BRANCH=main \
  DAD_TEST_DIRTY_COUNT=0 \
  DAD_TEST_BRANCH_LIST=dad/go-through-project,fix/pre-existing,main \
  DAD_TEST_SESSION_IS_ANCESTOR=yes \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "adopt" "$out" "clean non-trunk workstream branch from main must replace provisional startup session branch"

out="$(DAD_IDLE_CONTROLLER_TEST_BRANCH_ADOPTION=1 \
  DAD_TEST_CURRENT_BRANCH=feature/random \
  DAD_TEST_SESSION_BRANCH=dad/go-through-project \
  DAD_TEST_DIRTY_COUNT=0 \
  DAD_TEST_BRANCH_LIST=dad/go-through-project,feature/random,main \
  DAD_TEST_SESSION_IS_ANCESTOR=no \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "drift" "$out" "established non-trunk session branch must still reject unrelated branch drift"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_TEST_DAD_STATE=working \
  DAD_TEST_SON_STATE=claim \
  DAD_TEST_CODE_STANDARDS_PROBLEM=true \
  DAD_TEST_ACTION_AGE=999 \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "direct_son_code_write_correction" "$out" "code standards failure must become a direct Son code correction"

out="$(DAD_IDLE_CONTROLLER_TEST_DECIDE=1 \
  DAD_TEST_DAD_STATE=working \
  DAD_TEST_SON_STATE=claim \
  DAD_TEST_CODE_STANDARDS_PROBLEM=true \
  DAD_TEST_CLAIM_AFTER_ACTION=true \
  DAD_TEST_ACTION_AGE=1 \
  "$IDLE" dummy @1 %2 %3)"
assert_eq "direct_son_code_write_correction" "$out" "fresh Son claim with code standards failure must bypass cooldown"

safe_pane=$'Turn completed in 1s.\n\n╭────────────────────╮\n│ ❯                  │\n╰──── Grok Build ────╯'
out="$(DAD_WATCHDOG_TEST_BROKEN_POLICY=1 "$WATCHDOG" dummy @1 %2 <<<"$safe_pane")"
assert_eq "recover_broken_to_working_reset" "$out" "watchdog must recover safe broken pane"

thinking_pane=$'DAD scheduler trampoline\n┃  ◆ Thinking…\n┃\n┃  Yes.\n┃  Yes.'
out="$(DAD_WATCHDOG_TEST_BROKEN_POLICY=1 "$WATCHDOG" dummy @1 %2 <<<"$thinking_pane")"
assert_eq "monitor_broken" "$out" "watchdog must monitor unsafe broken pane instead of exiting"

grep -q -- '--mode submit-existing' "$IDLE_SURFACE" || fail "idle-controller pending paste path must use verified submit-existing mode"
grep -q 'focus_prompt_if_needed' "$SUBMIT" || fail "tmux-submit must focus prompt before paste/Enter"
grep -q 'Choose the highest-value concrete next action from last_corrective_task/reference_frontier/quality_frontier/improvement_frontier' "$IDLE_SURFACE" || fail "idle recovery must use Dad reference/quality/frontier/corrective metadata"
grep -q 'Grok online research/web access' "$IDLE_SURFACE" || fail "idle recovery must trigger bounded research when quality metadata is missing"
grep -q 'artifact-changing implementation delta' "$IDLE_SURFACE" || fail "idle recovery must require artifact-changing implementation delta"
grep -q 'Verification-only is not acceptable' "$IDLE_SURFACE" || fail "idle recovery must prevent verification-only treadmill"
grep -q 'Never tell the user to "test yourself"' "$IDLE_SURFACE" || fail "idle recovery must forbid delegated user verification"
grep -q 'DAD mechanical code-write correction' "$IDLE_SURFACE" || fail "idle-controller must have hard repeated-delegated-verification correction"
grep -q 'Do not output code snippets for the user to apply' "$IDLE_SURFACE" || fail "code-write correction must forbid snippet-only handoff"
grep -q 'code_handoff_no_workspace_edit' "$IDLE_SURFACE" || fail "idle-controller must classify code-handoff failures"
grep -q '@dad_delegated_verification_count' "$IDLE_SURFACE" || fail "idle-controller must track delegated verification repetition"
grep -q 'do not offer options' "$IDLE_SURFACE" || fail "idle recovery must not ask user/Dad to choose"
grep -q 'failed_son_plan_approval_pending' "$IDLE_SURFACE" || fail "plan approval key path must verify that approval UI changed"
grep -q 'wait_until_recovering_finished "$input_wait"' "$WATCHDOG" || fail "watchdog recovery commands must wait for safe input before each command"
grep -q 'clear_resolved_lease_failure_signature' "$WATCHDOG" || fail "watchdog must clear stale lease failure signatures after the lease is gone"
! grep -q 'tmux_set @dad_failure_signature dad_loop_.*lease_cleared' "$ROOT/bin/dad-lease.sh" "$WATCHDOG" || fail "lease cleanup must not leave a persistent current failure signature"
grep -q 'replace_dad_pane' "$WATCHDOG" || fail "watchdog must have second-stage Dad pane replacement"
grep -q 'split-window' "$WATCHDOG" || fail "Dad replacement must create a new pane"
grep -q 'break-pane' "$WATCHDOG" || fail "Dad replacement must move the old Dad pane out of the DAD window"
grep -q 'kill -STOP "$pid"' "$WATCHDOG" || fail "Dad replacement must SIGSTOP the old Grok process instead of leaving two Dads running"
grep -q 'DAD replacement supervisor bootstrap' "$WATCHDOG" || fail "replacement Dad pane must receive a bootstrap prompt"
grep -q 'tmux_set @dad_dad_pane "$new_dad_pane"' "$WATCHDOG" || fail "Dad replacement must update @dad_dad_pane"
grep -q '@dad_replaced_old_dad_pane' "$WATCHDOG" || fail "Dad replacement must record the quarantined old Dad pane"
grep -q '@dad_quarantined_old_dad_window' "$WATCHDOG" || fail "Dad replacement must record the quarantine window"
grep -q '@dad_quarantined_old_dad_pids' "$WATCHDOG" || fail "Dad replacement must record quarantined old Dad PIDs"
grep -q 'sigstop_and_break_pane' "$WATCHDOG" || fail "Dad replacement must record SIGSTOP quarantine method"
grep -q 'idle-controller.sh' "$WATCHDOG" || fail "Dad replacement must start a fresh idle controller for the new Dad pane"
grep -q 'exited:dad_pane_replaced' "$IDLE" || fail "old idle-controller must exit when the Dad pane is replaced"
grep -q 'exited:dad_pane_replaced' "$WATCHDOG" || fail "old watchdog must exit when the Dad pane is replaced"
! grep -Eq 'kill-pane|respawn-pane[[:space:]].*-k' "$WATCHDOG" || fail "Dad replacement must not kill or respawn-kill the old Dad pane"
grep -q 'scheduler_list exactly once' "$SCHED_REPAIR" || fail "scheduler label repair helper must constrain scheduler_list use"
grep -q 'scheduler-prompt.sh' "$SCHED_REPAIR" || fail "scheduler label repair helper must use centralized prompt generator"
grep -q 'refusing to inject scheduler repair into a running turn' "$SCHED_REPAIR" || fail "scheduler label repair injection must fail closed when Dad pane is active"
grep -q 'scheduler-health.sh' "$WATCHDOG" || fail "watchdog must run mechanical scheduler health checks"
grep -q 'failed_visible_scheduler_loop' "$SCHED_HEALTH" || fail "scheduler health must classify visible failed Grok loop rows"
grep -q 'scheduler-label-repair.sh' "$SCHED_HEALTH" || fail "scheduler health must submit bounded label repair when unhealthy"
grep -q '@dad_scheduler_health_status' "$SCHED_HEALTH" || fail "scheduler health must record status metadata"
grep -q '@dad_scheduler_repair_required' "$SCHED_HEALTH" || fail "scheduler health must record repair-required metadata"
grep -q 'durable=false' "$SCHED_REPAIR" || fail "scheduler repair must force non-durable scheduler_create calls"
grep -q 'durable=false' "$WATCHDOG" || fail "replacement bootstrap must force non-durable scheduler_create calls"
grep -q 'Use native `tmux` CLI commands through the terminal' "$SKILL_FILE" || fail "DAD skill must use native tmux CLI as the control plane"
grep -q 'Every later tmux command must use `tmux -S <socket>`' "$SKILL_FILE" || fail "DAD skill must require stored socket for tmux commands"
grep -q 'native `tmux` CLI' "$DESIGN_FILE" || fail "DAD design must document native tmux CLI startup"
forbidden_tmux_bridge_re="tmux[[:space:]]+M""CP|tmux-m""cp|M""CP first|Grok's tmux M""CP|dedicated tmux M""CP"
! grep -Eqi "$forbidden_tmux_bridge_re" "$SKILL_FILE" "$DESIGN_FILE" || fail "portable DAD policy must use native tmux only"
grep -q 'durable: false' "$SKILL_FILE" || fail "DAD skill must require non-durable scheduler loops"
grep -q 'durable: false' "$DESIGN_FILE" || fail "DAD design must require non-durable scheduler loops"
grep -q 'dad-cleanup-orphans.sh' "$SKILL_FILE" || fail "DAD skill must document orphan cleanup"
grep -q 'dad-cleanup-orphans.sh' "$DESIGN_FILE" || fail "DAD design must document orphan cleanup"
grep -q 'kill_dad_windows_if_requested' "$CLEANUP" || fail "cleanup helper must be able to close DAD-owned windows"
grep -q 'terminate_orphan_daemons' "$CLEANUP" || fail "cleanup helper must terminate orphan DAD daemons"
grep -q 'cleanup_quarantined_pids' "$CLEANUP" || fail "cleanup helper must clean quarantined old Dad PIDs"
grep -q -- '-CONT' "$CLEANUP" || fail "cleanup helper must SIGCONT quarantined old Dad PIDs before termination"
grep -q 'son-watchdog.sh' "$IDLE_SURFACE" || fail "idle-controller must ensure the Son watchdog is running"
grep -q 'forced PASS prompts cause loops' "$SKILL_FILE" || fail "DAD skill must forbid PASS-only verifier prompts"
grep -q 'PASS-only' "$DESIGN_FILE" || fail "DAD design must document PASS-only prompt failure mode"
grep -q 'Research-Grounded Quality Ratchet' "$SKILL_FILE" || fail "DAD skill must require research-grounded quality ratchet"
grep -q 'Research-Grounded Quality Ratchet' "$DESIGN_FILE" || fail "DAD design must document research-grounded quality ratchet"
grep -q 'Reference Scout / Code Harvest Ratchet' "$SKILL_FILE" || fail "DAD skill must require reference scout/code harvest ratchet"
grep -q 'Reference Scout / Code Harvest Ratchet' "$DESIGN_FILE" || fail "DAD design must document reference scout/code harvest ratchet"
grep -q 'subagent_type: "explore"' "$SKILL_FILE" || fail "DAD skill must use bounded read-only explore scouts when available"
grep -q 'Implementation Delta Ratchet' "$SKILL_FILE" || fail "DAD skill must require implementation delta ratchet"
grep -q 'Implementation Delta Ratchet' "$DESIGN_FILE" || fail "DAD design must document implementation delta ratchet"
grep -q 'Context-Bounded Coding Standards' "$SKILL_FILE" || fail "DAD skill must document context-bounded coding standards"
grep -q 'Context-Bounded Coding Standards' "$DESIGN_FILE" || fail "DAD design must document context-bounded coding standards"
grep -q 'context_hostile_monolith' "$SKILL_FILE" || fail "DAD skill must classify oversized monoliths"
grep -q 'context_hostile_monolith' "$DESIGN_FILE" || fail "DAD design must classify oversized monoliths"
grep -q 'code-standards-check.py' "$IDLE_SURFACE" || fail "idle-controller prompts must require code standards check"
grep -q 'CODE_STANDARDS_RESULT' "$IDLE_SURFACE" || fail "idle-controller prompts must ask Son to report code standards result"
grep -q '@dad_code_standards_status' "$IDLE_SURFACE" || fail "idle-controller must mechanically record code standards status"
grep -q 'context_hostile_monolith' "$IDLE_SURFACE" || fail "idle-controller must classify mechanical code standards failures"
grep -q 'No Delegated Verification' "$SKILL_FILE" || fail "DAD skill must forbid delegated verification"
grep -q 'No Delegated Verification' "$DESIGN_FILE" || fail "DAD design must document delegated verification failure mode"
grep -q '@dad_evidence_only_count' "$SKILL_FILE" || fail "DAD skill must track evidence-only treadmill metadata"
grep -q '@dad_evidence_only_count' "$DESIGN_FILE" || fail "DAD design must track evidence-only treadmill metadata"
grep -q '@dad_delegated_verification_count' "$SKILL_FILE" || fail "DAD skill must track delegated verification repetition metadata"
grep -q '@dad_delegated_verification_count' "$DESIGN_FILE" || fail "DAD design must track delegated verification repetition metadata"
grep -q '@dad_quality_frontier' "$SKILL_FILE" || fail "DAD skill must track quality frontier metadata"
grep -q '@dad_quality_frontier' "$DESIGN_FILE" || fail "DAD design must track quality frontier metadata"
grep -q '@dad_quality_frontier' "$IDLE_SURFACE" || fail "idle-controller must carry quality frontier metadata to Son prompts"
grep -q '@dad_reference_scout_frontier' "$SKILL_FILE" || fail "DAD skill must track reference scout frontier metadata"
grep -q '@dad_reference_scout_frontier' "$DESIGN_FILE" || fail "DAD design must track reference scout frontier metadata"
grep -q '@dad_reference_scout_frontier' "$IDLE_SURFACE" || fail "idle-controller must carry reference scout frontier metadata to Son prompts"
grep -q 'Reference Scout / Code Harvest pass' "$IDLE_SURFACE" || fail "idle-controller must force reference scout into implementation prompts"
grep -q 'one repo-approved stable branch for this DAD workstream' "$IDLE_SURFACE" || fail "idle-controller must enforce one repo-approved stable branch"
grep -q 'commit it locally on the same branch' "$IDLE_SURFACE" || fail "idle-controller must require local commits for coherent deltas"
grep -q 'DAD mechanical branch/commit discipline correction' "$IDLE_SURFACE" || fail "idle-controller must have branch consolidation correction"
grep -q '@dad_session_branch' "$IDLE_SURFACE" || fail "idle-controller must track session branch"
grep -q 'uncommitted_delta_after_claim' "$IDLE_SURFACE" || fail "idle-controller must correct uncommitted deltas after idle/claim"
grep -q 'detached_head' "$IDLE_SURFACE" || fail "idle-controller must fail closed on detached HEAD"
grep -q 'repo-approved stable branch' "$IDLE_SURFACE" || fail "idle-controller prompts must respect repo-approved branch policy"
grep -q 'Conventional Commits' "$IDLE_SURFACE" || fail "idle-controller prompts must require conventional local commits"
grep -q 'Do not fetch, pull, push' "$IDLE_SURFACE" || fail "idle-controller prompts must hard-stop remote operations"
grep -q 'Stable Branch and Commit Discipline' "$SKILL_FILE" || fail "DAD skill must document branch/commit discipline"
grep -q 'Stable Branch and Commit Discipline' "$DESIGN_FILE" || fail "DAD design must document branch/commit discipline"
grep -q 'branch_sprawl' "$SKILL_FILE" || fail "DAD skill must classify branch sprawl"
grep -q 'plan_approval_requires_review' "$SKILL_FILE" || fail "DAD skill must refuse degraded plan approval"
grep -q 'plan_approval_requires_review' "$DESIGN_FILE" || fail "DAD design must refuse degraded plan approval"
grep -q 'Conventional Commits' "$SKILL_FILE" || fail "DAD skill must require conventional local commits"
grep -q 'Do not fetch, pull, push' "$DESIGN_FILE" || fail "DAD design must hard-stop remotes"
if [[ -n "$GLOBAL_CLAUDE_FILE" && -f "$GLOBAL_CLAUDE_FILE" ]]; then
  grep -q 'Branch Discipline: One branch per workstream' "$GLOBAL_CLAUDE_FILE" || fail "global Claude guidance must prevent branch-per-task sprawl"
fi
grep -q '@dad_last_user_feedback' "$SKILL_FILE" || fail "DAD skill must track human feedback pressure metadata"
grep -q '@dad_last_user_feedback' "$DESIGN_FILE" || fail "DAD design must track human feedback pressure metadata"
grep -q '@dad_last_user_feedback' "$IDLE_SURFACE" || fail "idle-controller must carry human feedback pressure metadata to Son prompts"
grep -q 'visible composer during an active turn is not safe' "$SKILL_FILE" || fail "DAD skill must forbid active Son compaction"
grep -q 'visible composer during an active turn is not safe' "$DESIGN_FILE" || fail "DAD design must forbid active Son compaction"
grep -q 'refusing /compact or /memory while target pane is active' "$SUBMIT" || fail "tmux-submit must refuse active /compact or /memory control prompts"
grep -q 'blocked:too_many_recoveries' "$SON_WATCHDOG" || fail "Son watchdog must block instead of repeatedly cancelling after recovery limit"
grep -q 'pre_tool_use' "$SON_WATCHDOG" || fail "Son watchdog must protect active tool/code-writing rows"
grep -q 'blocked another Dad recovery before sending Ctrl-C' "$WATCHDOG" || fail "Dad watchdog must check recovery limit before Ctrl-C"
grep -q '@dad_watchdog_blocked_signature' "$WATCHDOG" || fail "Dad watchdog must dedupe repeated recovery-block observations"
grep -q '@dad_son_watchdog_blocked_signature' "$SON_WATCHDOG" || fail "Son watchdog must dedupe repeated recovery-block observations"
grep -q 'reset_blocked_recovery_budget_if_exhausted' "$WATCHDOG" || fail "Dad watchdog must reset exhausted recovery budget after safe recovery"
grep -q 'reset_blocked_recovery_budget_if_safe' "$SON_WATCHDOG" || fail "Son watchdog must reset exhausted recovery budget after safe input"
grep -q 'broken_active_timeout' "$WATCHDOG" || fail "Dad watchdog must recover broken active compaction/thinking within budget"
grep -q 'DAD_LEASE_CLEAR_AND_CONTINUE' "$ROOT/bin/dad-lease.sh" || fail "lease helper must exit on stale by default"
grep -q 'RELEASE_PENDING' "$ROOT/bin/dad-lease.sh" || fail "lease release must stay active until watchdog sees safe composer"
grep -Fq '/proc/$pid/cmdline' "$WATCHDOG" || fail "Dad watchdog duplicate check must use exact cmdline fields"
grep -Fq '/proc/$pid/cmdline' "$IDLE_SURFACE" || fail "idle-controller duplicate checks must use exact cmdline fields"

scheduler_prompt="$("$SCHED_PROMPT" strategic @17 %23 - <<<"Build anything generic")"
printf '%s\n' "$scheduler_prompt" | grep -q "DAD scheduler trampoline version: $POLICY_VERSION" || fail "scheduler prompt must use centralized policy version"
printf '%s\n' "$scheduler_prompt" | grep -q 'Strategic Loop Policy' || fail "scheduler prompt must include the requested loop policy"
printf '%s\n' "$scheduler_prompt" | grep -q 'Research-Grounded Quality Ratchet' || fail "scheduler prompt must reference research-grounded quality policy"
printf '%s\n' "$scheduler_prompt" | grep -q 'Reference Scout / Code Harvest Ratchet' || fail "scheduler prompt must reference reference scout/code harvest policy"
printf '%s\n' "$scheduler_prompt" | grep -q 'Implementation Delta Ratchet' || fail "scheduler prompt must reference implementation delta policy"
printf '%s\n' "$scheduler_prompt" | grep -q 'Context-Bounded Coding Standards' || fail "scheduler prompt must reference context-bounded coding standards"
printf '%s\n' "$scheduler_prompt" | grep -q 'No Delegated Verification' || fail "scheduler prompt must reference delegated verification policy"
printf '%s\n' "$scheduler_prompt" | grep -q 'Stable Branch and Commit Discipline' || fail "scheduler prompt must reference branch/commit discipline policy"
if printf '%s\n' "$scheduler_prompt" | grep -Eq '20[0-9]{2}-[0-9]{2}-[0-9]{2}'; then
  fail "scheduler prompt must not bake date labels into loop prompts"
fi

out="$(DAD_WATCHDOG_TEST_BLOCK_SIGNATURE=1 "$WATCHDOG" dummy @1 %2 'broken_active_timeout:470s')"
assert_eq "broken_active_timeout:Xs" "$out" "Dad watchdog block signature must normalize elapsed-only repeats"
out="$(DAD_SON_WATCHDOG_TEST_BLOCK_SIGNATURE=1 "$SON_WATCHDOG" dummy @1 %3 'son_self_repetition_loop:repeated_phrase:yes yes yes:153s')"
assert_eq "son_self_repetition_loop:repeated_phrase:yes yes yes:Xs" "$out" "Son watchdog block signature must normalize elapsed-only repeats"

fakebin_repair="$tmp/fakebin-repair"
mkdir "$fakebin_repair"
cat > "$fakebin_repair/tmux" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
cmd="${1:-}"
shift || true
case "$cmd" in
  display-message)
    if [[ "$*" == *pane_current_command* ]]; then
      printf 'grok\n'
    elif [[ "$*" == *window_id* ]]; then
      printf '@1\n'
    else
      printf '%%2\n'
    fi
    ;;
  show-window-option)
    key="${@: -1}"
    case "$key" in
      @dad_dad_pane) printf '%%2\n' ;;
      @dad_son_pane) printf '%%3\n' ;;
      @dad_objective) printf 'generic objective\n' ;;
      *) printf '\n' ;;
    esac
    ;;
  list-panes)
    printf '%%2 0\n%%3 0\n'
    ;;
  *)
    printf 'unsupported fake repair tmux command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fakebin_repair/tmux"
repair_prompt="$(PATH="$fakebin_repair:$PATH" "$SCHED_REPAIR" --socket fake --window @1)"
printf '%s\n' "$repair_prompt" | grep -q 'DAD explicit scheduler-label repair' || fail "scheduler label repair dry-run missing repair heading"
printf '%s\n' "$repair_prompt" | grep -q 'FAST_PROMPT:' || fail "scheduler label repair dry-run missing fast prompt"
printf '%s\n' "$repair_prompt" | grep -q 'interval 30m' || fail "scheduler label repair dry-run missing strategic interval"
if printf '%s\n' "$repair_prompt" | grep -Eq '20[0-9]{2}-[0-9]{2}-[0-9]{2}\\.(strategic|evidence)'; then
  fail "scheduler label repair directive must not emit dated scheduler labels"
fi

fakebin_cleanup="$tmp/fakebin-cleanup"
mkdir "$fakebin_cleanup"
cat > "$fakebin_cleanup/tmux" <<'EOF'
#!/usr/bin/env bash
socket=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S)
      socket="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
cmd="${1:-}"
shift || true
case "$cmd" in
  list-windows)
    case "$socket" in
      fake-cleanup)
        printf '@1\tDAD-One\n@2\tDAD-Two\n'
        ;;
      fake-quarantine)
        printf '@9\tDAD-Quarantine\n'
        ;;
    esac
    ;;
  show-window-option)
    key="${@: -1}"
    if [[ "$key" == "@dad_quarantined_old_dad_pids" && "$socket" == "fake-quarantine" ]]; then
      printf '%s\n' "${FAKE_QUARANTINE_PID:?}"
    else
      printf '\n'
    fi
    ;;
  kill-window)
    target=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t)
          target="$2"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf '%s %s\n' "$socket" "$target" >> "${FAKE_TMUX_KILL_LOG:?}"
    ;;
  display-message|list-panes)
    ;;
  *)
    printf 'unsupported fake cleanup tmux command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fakebin_cleanup/tmux"
if PATH="$fakebin_cleanup:$PATH" FAKE_TMUX_KILL_LOG="$tmp/cleanup-global.kills" \
  "$CLEANUP" --kill-dad-windows >"$tmp/cleanup-global.out" 2>"$tmp/cleanup-global.err"; then
  fail "cleanup helper allowed global destructive DAD window cleanup without --dry-run or --confirm-global"
fi
grep -q 'global destructive window cleanup requires --dry-run or --confirm-global' "$tmp/cleanup-global.err" || fail "global destructive cleanup rejection missing detail"
PATH="$fakebin_cleanup:$PATH" FAKE_TMUX_KILL_LOG="$tmp/cleanup-scoped.kills" \
  "$CLEANUP" --socket fake-cleanup --window @1 --kill-dad-windows >"$tmp/cleanup-scoped.out"
grep -q '^fake-cleanup @1$' "$tmp/cleanup-scoped.kills" || fail "scoped cleanup did not kill the requested DAD window"
! grep -q '@2' "$tmp/cleanup-scoped.kills" || fail "scoped cleanup killed an unrelated DAD window"

bash -c 'exec -a grok sleep 60' &
grok_pid="$!"
sleep 0.2
kill -STOP "$grok_pid"
PATH="$fakebin_cleanup:$PATH" \
  FAKE_QUARANTINE_PID="$grok_pid" \
  FAKE_TMUX_KILL_LOG="$tmp/cleanup-quarantine-window.kills" \
  "$CLEANUP" --socket fake-quarantine --window @9 >"$tmp/cleanup-quarantine.out"
grep -q "terminating_quarantined_old_dad pid=$grok_pid window=@9" "$tmp/cleanup-quarantine.out" || fail "cleanup did not target the recorded quarantined old Dad PID"
quarantine_exited=0
for _ in {1..50}; do
  stat="$(ps -p "$grok_pid" -o stat= 2>/dev/null || true)"
  if [[ -z "$stat" || "$stat" == Z* ]]; then
    quarantine_exited=1
    break
  fi
  sleep 0.1
done
assert_eq "1" "$quarantine_exited" "cleanup must terminate the recorded quarantined old Grok process"
wait "$grok_pid" 2>/dev/null || true
grok_pid=""

pending_composer=$'╭────────────────────╮\n│ ❯ DAD mechanical claim-continuation recovery text still sitting here │\n╰──── Grok Build ────╯\nEnter:send'
out="$(DAD_TMUX_SUBMIT_TEST_PENDING=1 "$SUBMIT" <<<"$pending_composer")"
assert_eq "pending" "$out" "tmux-submit must detect visible unsent composer text"

submitted_composer=$'╭────────────────────╮\n│ ❯                  │\n╰──── Grok Build ────╯\nShift+Tab:mode  │  Ctrl+.:shortcuts'
out="$(DAD_TMUX_SUBMIT_TEST_PENDING=1 "$SUBMIT" <<<"$submitted_composer")"
assert_eq "submitted" "$out" "tmux-submit must treat empty composer as submitted"

active_compact_snapshot=$'┃  ◆ Thinking…\n┃\n┃  Writing the real code edit now.\n\n⠋ Thinking… 2m3s\n╭────────────────────╮\n│ ❯ /compact preserve state │\n╰──── Grok Build ────╯'
out="$(DAD_TMUX_SUBMIT_TEST_ACTIVE_CONTROL=1 "$SUBMIT" /compact <<<"$active_compact_snapshot")"
assert_eq "blocked" "$out" "tmux-submit must block /compact while target pane is active"

fakebin="$tmp/fakebin"
mkdir "$fakebin"
cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
cmd="${1:-}"
shift || true
case "$cmd" in
  display-message)
    if [[ "$*" == *pane_current_command* ]]; then
      printf 'grok\n'
    elif [[ "$*" == *window_id* ]]; then
      printf '@1\n'
    else
      printf '%%2\n'
    fi
    ;;
  list-panes)
    printf '%%2 0\n'
    ;;
  capture-pane)
    if [[ "${FAKE_TMUX_PENDING:-1}" == "1" ]]; then
      printf '╭────────╮\n│ ❯ pending DAD instruction │\n╰────────╯\nEnter:send\n'
    else
      printf '╭────────╮\n│ ❯                  │\n╰ Grok Build ─╯\n'
    fi
    ;;
  send-keys)
    printf 'send-keys %s\n' "$*" >> "${FAKE_TMUX_LOG:?}"
    ;;
  load-buffer)
    cat >/dev/null
    ;;
  paste-buffer|delete-buffer|set-window-option)
    ;;
  *)
    printf 'unsupported fake tmux command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fakebin/tmux"

if PATH="$fakebin:$PATH" FAKE_TMUX_LOG="$tmp/fake-tmux.log" FAKE_TMUX_PENDING=1 \
  DAD_TMUX_SUBMIT_ENTER_DELAY_MS=0 DAD_TMUX_SUBMIT_ENTER_RETRIES=2 \
  "$SUBMIT" --socket fake --window @1 --target %2 --expect-command grok --mode submit-existing >"$tmp/submit-fail.out" 2>"$tmp/submit-fail.err"; then
  fail "tmux-submit accepted a composer that remained pending after Enter retries"
fi
grep -q 'prompt still appears pending' "$tmp/submit-fail.err" || fail "tmux-submit pending failure did not explain the submit failure"
grep -q 'Enter' "$tmp/fake-tmux.log" || fail "tmux-submit did not send Enter while trying to submit pending composer"

PATH="$fakebin:$PATH" FAKE_TMUX_LOG="$tmp/fake-tmux-ok.log" FAKE_TMUX_PENDING=0 \
  DAD_TMUX_SUBMIT_ENTER_DELAY_MS=0 DAD_TMUX_SUBMIT_ENTER_RETRIES=2 \
  "$SUBMIT" --socket fake --window @1 --target %2 --expect-command grok --mode submit-existing >/dev/null

legacy_root="$tmp/windows"
mkdir -p "$legacy_root/DAD-Old"
printf '{"status":"waiting_for_user_loops","objective":"old objective","window_id":"@1","dad_pane_id":"%%2","son_pane_id":"%%3"}\n' > "$legacy_root/DAD-Old/current.dad.json"
archive_out="$("$ARCHIVE" --root "$legacy_root" --apply)"
printf '%s\n' "$archive_out" | grep -q 'archived ' || fail "legacy window archiver did not archive old current.dad.json"
compgen -G "$legacy_root/DAD-Old/legacy/current.dad.*.json" >/dev/null || fail "legacy window archive file was not preserved"
python3 - "$legacy_root/DAD-Old/current.dad.json" "$ROOT/POLICY_VERSION" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["schema"] == "dad-window-archive-pointer-v1"
assert data["policy_version"] == Path(sys.argv[2]).read_text().strip()
assert data["status"] == "archived_legacy"
PY

mkdir -p "$legacy_root/DAD-CurrentPolicy"
printf '{"policy_version":"%s","status":"old-but-current-policy"}\n' "$POLICY_VERSION" > "$legacy_root/DAD-CurrentPolicy/current.dad.json"
archive_out="$("$ARCHIVE" --root "$legacy_root" --apply)"
printf '%s\n' "$archive_out" | grep -q 'DAD-CurrentPolicy/current.dad.json' || fail "archiver must not skip non-pointer files solely because policy version is current"
python3 - "$legacy_root/DAD-CurrentPolicy/current.dad.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data["schema"] == "dad-window-archive-pointer-v1"
PY

completed_choice_pane=$'This was the highest-risk foundational item. It is now done.\nSay the word and we keep moving. We are building the version that can actually go viral.\n\n◆ stop  [hooks: 1]\n\nTurn completed in 9m22s.\n\n╭────────────────────╮\n│ ❯                  │\n╰──── Grok Build ────╯'
out="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$WATCHER" dummy @1 %3 <<<"$completed_choice_pane")"
assert_eq $'claim\tcompleted turn at composer asking for next action' "$out" "completed handoff prose containing building must not classify active"

delegated_verification_pane=$'Implemented and verified. Test yourself in real Hard wave 3.\n\nTurn completed in 42s.\n\n╭────────────────────╮\n│ ❯                  │\n╰──── Grok Build ────╯'
out="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$WATCHER" dummy @1 %3 <<<"$delegated_verification_pane")"
assert_eq $'claim\tdelegated verification to user instead of Son-run evidence' "$out" "Son watcher must classify test-yourself handoffs as delegated verification"

code_handoff_pane=$'Here is the code snippet for you to apply:\n```python\nprint("better")\n```\n\nTurn completed in 10s.\n\n╭────────────────────╮\n│ ❯                  │\n╰──── Grok Build ────╯'
out="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$WATCHER" dummy @1 %3 <<<"$code_handoff_pane")"
assert_eq $'claim\tcode handoff to user instead of workspace edit' "$out" "Son watcher must classify snippet-only code handoff as invalid"

corrective_feedback_pane=$'╭────────────────────╮\n│ ❯ If it is a computer system where is CD LS WHY IS THERE NO FILE SYSTEM ? │\n╰──── Grok Build ────╯'
out="$(DAD_SON_WATCHER_TEST_HUMAN_FEEDBACK=1 "$WATCHER" dummy @1 %3 <<<"$corrective_feedback_pane")"
assert_eq $'corrective\tIf it is a computer system where is CD LS WHY IS THERE NO FILE SYSTEM ?' "$out" "Son watcher must classify corrective human feedback pressure"

benign_feedback_pane=$'╭────────────────────╮\n│ ❯ Build anything │\n╰──── Grok Build ────╯'
out="$(DAD_SON_WATCHER_TEST_HUMAN_FEEDBACK=1 "$WATCHER" dummy @1 %3 <<<"$benign_feedback_pane")"
assert_eq $'none\tBuild anything' "$out" "Son watcher must ignore benign prompt text as feedback pressure"

dad_prompt_feedback_pane=$'╭────────────────────╮\n│ ❯ DAD mechanical claim-continuation recovery (2026-05-16T08:57:46-06:00). │\n│   You are stopped at the prompt after a material claim/report. │\n╰──── Grok Build ────╯'
out="$(DAD_SON_WATCHER_TEST_HUMAN_FEEDBACK=1 "$WATCHER" dummy @1 %3 <<<"$dad_prompt_feedback_pane")"
assert_eq $'none\tDAD mechanical claim-continuation recovery (2026-05-16T08:57:46-06:00). You are stopped at the prompt after a material claim/report.' "$out" "Son watcher must not classify DAD mechanical prompts as human feedback"

active_status_pane=$':: Thinking... 2m8s\n\n╭────────────────────╮\n│ ❯                  │\n╰──── Grok Build ────╯'
out="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$WATCHER" dummy @1 %3 <<<"$active_status_pane")"
assert_eq $'active\tvisible active Grok status' "$out" "real thinking status must classify active"

old_claim_active_pane=$'All tests passed and it is ready for acceptance.\n\nTurn completed in 2m.\n\n:: Thinking... 44s\n\n╭────────────────────╮\n│ ❯                  │\n╰──── Grok Build ────╯'
out="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$WATCHER" dummy @1 %3 <<<"$old_claim_active_pane")"
assert_eq $'active\tvisible active Grok status' "$out" "active status must beat old completed-claim text"

old_plan_active_pane=$'Waiting on plan approval\n[a]pprove  [c]omment\n\n:: Thinking... 44s\n  ◆ Run tests  [hooks: 1]\n\n╭────────────────────╮\n│ ❯                  │\n╰──── Grok Build ────╯'
out="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$WATCHER" dummy @1 %3 <<<"$old_plan_active_pane")"
assert_eq $'active\tvisible active Grok status' "$out" "active status must beat stale plan approval text"

son_yes_loop=$'┃  ◆ Thinking…\n┃\n┃  Yes.\n┃\n┃  The answer.\n┃\n┃  Yes.\n┃\n┃  I will stop here.\n┃\n┃  The response is that.\n┃\n┃  Yes\n\n⠋ Thinking… 13m34s 13m42s ⇣232k [✗]'
out="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$WATCHER" dummy @1 %3 <<<"$son_yes_loop")"
assert_match $'^loop\tactive Son low-entropy self-repetition:' "$out" "Son watcher must classify active low-entropy Son thinking as loop"

out="$(DAD_SON_WATCHDOG_TEST_CLASSIFY=1 "$SON_WATCHDOG" dummy @1 %3 <<<"$son_yes_loop")"
assert_match '^low_entropy_closure:|^repeated_line:|^repeated_phrase:' "$out" "Son watchdog must detect the observed Yes/The answer loop"

normal_son_thinking=$'┃  ◆ Thinking…\n┃\n┃  I need to inspect the failing gate, compare the transcript schema, and patch the assertion extraction path before rerunning.\n┃\n┃  The first step is to read evidence-gate.py and the scenario parser.\n\n⠋ Thinking… 4m12s'
out="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$WATCHER" dummy @1 %3 <<<"$normal_son_thinking")"
assert_eq $'active\tvisible active Grok status' "$out" "Son watcher must not classify normal high-entropy thinking as loop"

if DAD_SON_WATCHDOG_TEST_CLASSIFY=1 "$SON_WATCHDOG" dummy @1 %3 <<<"$normal_son_thinking" >"$tmp/normal-son-watchdog.out" 2>&1; then
  fail "Son watchdog classified normal high-entropy thinking as a loop"
fi

tool_active_repeated_text=$'┃  ◆ Thinking…\n┃\n┃  Yes.\n┃\n┃  Yes.\n┃\n┃  Yes.\n  ◆ Edit engine.py  [hooks: 1]\n    pre_tool_use\n    post_tool_use\n\n⠋ Thinking… 2m15s'
out="$(DAD_SON_WATCHER_TEST_CLASSIFY=1 "$WATCHER" dummy @1 %3 <<<"$tool_active_repeated_text")"
assert_eq $'active\tvisible active Grok status' "$out" "Son watcher must not loop-classify active tool/code-writing rows"

if DAD_SON_WATCHDOG_TEST_CLASSIFY=1 "$SON_WATCHDOG" dummy @1 %3 <<<"$tool_active_repeated_text" >"$tmp/tool-active-watchdog.out" 2>&1; then
  fail "Son watchdog classified active tool/code-writing rows as a loop"
fi

grep -q 'PASS-only' "$SON_WATCHDOG" || fail "Son watchdog recovery prompt must explicitly invalidate PASS-only instructions"
grep -q 'Truthful FAIL/NEEDS_MORE_EVIDENCE is progress' "$SON_WATCHDOG" || fail "Son watchdog recovery prompt must require truthful failure reporting"

out="$(DAD_IDLE_CONTROLLER_TEST_ACCEPTING=1 "$IDLE" dummy @1 %2 %3 <<<"$completed_choice_pane")"
assert_eq "accepting" "$out" "idle-controller must accept completed composer prose containing building"

out="$(DAD_IDLE_CONTROLLER_TEST_ACCEPTING=1 "$IDLE" dummy @1 %2 %3 <<<"$active_status_pane")"
assert_eq "busy" "$out" "idle-controller must reject active thinking status"

spaced_yes_loop=$'┃  Yes .\n┃\n┃  Yes.\n┃\n┃  Yes.\n┃\n┃  Yes.\n┃\n┃  Yes.\n┃\n┃  Yes'
out="$(DAD_WATCHDOG_TEST_CLASSIFY=1 "$WATCHDOG" dummy @1 %2 <<<"$spaced_yes_loop")"
assert_match '^repeated_line:yes|^low_entropy_closure:|^repeated_phrase:yes yes yes:' "$out" "watchdog must detect spaced-punctuation yes loop"

recursive_scheduler_loop=$':: Thinking…\nFirst, the user query is a task to execute a DAD scheduler trampoline instruction for a DAD window execution prompt for a DAD scheduler task to execute one bounded deep-loop pass for the DAD scheduler trampoline for DAD window execution instruction for executing a DAD scheduler trampoline message.'
out="$(DAD_WATCHDOG_TEST_CLASSIFY=1 "$WATCHDOG" dummy @1 %2 <<<"$recursive_scheduler_loop")"
assert_match '^repeated_phrase:|^low_word_entropy:' "$out" "watchdog must detect repetitive recursive reasoning"

full_tui_reasoning_loop=$'↻ DAD scheduler trampoline version\n┃  ◆ Thinking…\n┃\n┃  …\n┃  Yes.\n┃\n┃  Good\n\n⠴ Thinking… 2m3s\n╭────────╮\n│ ❯     │\n╰ Grok Build ─╯'
out="$(DAD_WATCHDOG_TEST_CLASSIFY=1 "$WATCHDOG" dummy @1 %2 <<<"$full_tui_reasoning_loop")"
assert_match '^repeated_phrase:|^low_entropy_closure:|^repeated_line:' "$out" "watchdog must inspect reasoning block, not bottom spinner"
out="$(DAD_WATCHDOG_TEST_VISIBLE_ELAPSED=1 "$WATCHDOG" dummy @1 %2 <<<"$full_tui_reasoning_loop"$'\n⠋ Thinking… 4m32s 4m40s ⇣201k [✗]')"
assert_eq "272" "$out" "watchdog must parse visible thinking elapsed after daemon restart"

delete_icon_scheduler_pane=$' : [loop] every 30 minutes DAD scheduler trampoline version: failclosed (next in 27m34s) [✗]\n : [loop] every 12 minutes DAD scheduler trampoline version: failclosed (next in 9m35s) [✗]\n : [loop] every 2 minutes DAD scheduler trampoline version: failclosed (running) [✗]'
out="$(DAD_SCHEDULER_HEALTH_TEST_CLASSIFY=1 "$SCHED_HEALTH" <<<"$delete_icon_scheduler_pane")"
assert_eq "healthy" "$out" "scheduler health must ignore Grok's visible delete/cancel glyph on healthy loop rows"

failed_scheduler_pane=$' : [loop] every 30 minutes DAD scheduler trampoline version: failclosed (next in 27m34s) [✗]\n : [loop] every 12 minutes DAD scheduler trampoline version: failclosed (failed) [✗]\n : [loop] every 2 minutes DAD scheduler trampoline version: failclosed (running) [✗]'
out="$(DAD_SCHEDULER_HEALTH_TEST_CLASSIFY=1 "$SCHED_HEALTH" <<<"$failed_scheduler_pane")"
assert_eq "failed_visible_scheduler_loop" "$out" "scheduler health must fail rows with explicit failed state text"

missing_scheduler_pane=$' : [loop] every 30 minutes DAD scheduler trampoline version: failclosed [✓]\n : [loop] every 2 minutes DAD scheduler trampoline version: failclosed [✓]'
out="$(DAD_SCHEDULER_HEALTH_TEST_CLASSIFY=1 "$SCHED_HEALTH" <<<"$missing_scheduler_pane")"
assert_eq "missing_visible_deep_loop" "$out" "scheduler health must detect missing visible loop rows"

healthy_scheduler_pane=$' : [loop] every 30 minutes DAD scheduler trampoline version: failclosed [✓]\n : [loop] every 12 minutes DAD scheduler trampoline version: failclosed [✓]\n : [loop] every 2 minutes DAD scheduler trampoline version: failclosed [✓]'
out="$(DAD_SCHEDULER_HEALTH_TEST_CLASSIFY=1 "$SCHED_HEALTH" <<<"$healthy_scheduler_pane")"
assert_eq "healthy" "$out" "scheduler health must pass when all visible loops and IDs are present"

out="$(DAD_SCHEDULER_HEALTH_TEST_CLASSIFY=1 DAD_TEST_FAST_SCHEDULER_ID='' "$SCHED_HEALTH" <<<"$healthy_scheduler_pane")"
assert_eq "missing_scheduler_ids" "$out" "scheduler health must fail when scheduler IDs are missing even if visible rows exist"

out="$(DAD_SCHEDULER_HEALTH_TEST_CLASSIFY=1 "$SCHED_HEALTH" <<<"")"
assert_eq "missing_visible_scheduler_rows" "$out" "scheduler health must fail when visible scheduler rows are empty even if metadata IDs exist"

fakebin_sched_health="$tmp/fakebin-scheduler-health"
mkdir "$fakebin_sched_health"
cat > "$fakebin_sched_health/tmux" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
cmd="${1:-}"
shift || true
case "$cmd" in
  display-message)
    printf '@1\n'
    ;;
  list-panes)
    printf '%%2 0\n'
    ;;
  capture-pane)
    printf 'no visible scheduler rows in this pane\n'
    ;;
  show-window-option)
    key="${@: -1}"
    case "$key" in
      @dad_dad_pane) printf '%%2\n' ;;
      @dad_fast_scheduler_id) printf 'fast-id\n' ;;
      @dad_deep_scheduler_id) printf 'deep-id\n' ;;
      @dad_strategic_scheduler_id) printf 'strategic-id\n' ;;
      @dad_policy_version) printf '%s\n' "${FAKE_POLICY_VERSION:-$POLICY_VERSION}" ;;
      @dad_scheduler_health_repair_attempted_at) printf '%s\n' "${FAKE_REPAIR_ATTEMPTED_AT:-}" ;;
      *) printf '\n' ;;
    esac
    ;;
  set-window-option)
    key=""
    value=""
    for arg in "$@"; do
      if [[ "$arg" == @dad_* ]]; then
        key="$arg"
      elif [[ -n "$key" ]]; then
        value="$arg"
      fi
    done
    printf '%s=%s\n' "$key" "$value" >> "${FAKE_TMUX_SET_LOG:?}"
    ;;
  *)
    printf 'unsupported fake scheduler-health tmux command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fakebin_sched_health/tmux"
repair_busy="$tmp/repair-busy.sh"
cat > "$repair_busy" <<'EOF'
#!/usr/bin/env bash
echo "scheduler-label-repair: Dad pane is active; refusing to inject scheduler repair into a running turn" >&2
exit 1
EOF
chmod +x "$repair_busy"
repair_submit="$tmp/repair-submit.sh"
cat > "$repair_submit" <<'EOF'
#!/usr/bin/env bash
echo "submitted scheduler-label repair directive"
exit 0
EOF
chmod +x "$repair_submit"
PATH="$fakebin_sched_health:$PATH" \
  FAKE_TMUX_SET_LOG="$tmp/scheduler-busy.sets" \
  DAD_SCHEDULER_LABEL_REPAIR="$repair_busy" \
  "$SCHED_HEALTH" --socket fake --window @1 --repair >"$tmp/scheduler-busy.out"
grep -q 'SCHEDULER_HEALTH_RESULT: WAITING_DAD_BUSY missing_visible_scheduler_rows' "$tmp/scheduler-busy.out" || fail "scheduler health busy repair did not report waiting"
! grep -q '@dad_scheduler_health_repair_attempted_at' "$tmp/scheduler-busy.sets" || fail "scheduler health stamped repair cooldown before a repair submission"
PATH="$fakebin_sched_health:$PATH" \
  FAKE_TMUX_SET_LOG="$tmp/scheduler-submit.sets" \
  DAD_SCHEDULER_LABEL_REPAIR="$repair_submit" \
  "$SCHED_HEALTH" --socket fake --window @1 --repair >"$tmp/scheduler-submit.out"
grep -q 'SCHEDULER_HEALTH_RESULT: REPAIR_SUBMITTED missing_visible_scheduler_rows' "$tmp/scheduler-submit.out" || fail "scheduler health did not submit immediately after busy repair refusal"
grep -q '@dad_scheduler_health_repair_attempted_at=' "$tmp/scheduler-submit.sets" || fail "scheduler health did not stamp cooldown after successful repair submission"

repo="$tmp/repo"
mkdir "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email dad-test@example.invalid
git -C "$repo" config user.name dad-test
printf 'initial\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m 'chore: initialize evidence fixture'

grok_plugin_root="$tmp/plugin-code-root"
grok_plugin_data="$tmp/grok-plugin-data"
grok_wrapper_data="$tmp/grok-wrapper-data"
grok_home="$tmp/grok-home"
mkdir -p "$grok_plugin_root" "$grok_plugin_data" "$grok_wrapper_data" "$grok_home"

mapfile -t resolved_shell_paths < <(
  env -u DAD_DATA_ROOT -u CLAUDE_PLUGIN_DATA \
    GROK_PLUGIN_ROOT="$grok_plugin_root" \
    GROK_PLUGIN_DATA="$grok_plugin_data" \
    bash -c 'source "$1"; printf "%s\n%s\n%s\n" "$(dad_plugin_root)" "$(dad_data_root)" "$(dad_logs_root)"' _ "$ROOT/bin/dad-env.sh"
)
assert_eq "$grok_plugin_root" "${resolved_shell_paths[0]}" "shell helper must resolve GROK_PLUGIN_ROOT"
assert_eq "$grok_plugin_data" "${resolved_shell_paths[1]}" "shell helper must resolve GROK_PLUGIN_DATA"
assert_eq "$grok_plugin_data/logs" "${resolved_shell_paths[2]}" "shell helper logs must live under Grok plugin data"

resolved_home_data="$(
  env -u DAD_DATA_ROOT -u GROK_PLUGIN_DATA -u CLAUDE_PLUGIN_DATA \
    GROK_PLUGIN_ROOT="$grok_plugin_root" \
    GROK_HOME="$grok_home" \
    bash -c 'source "$1"; dad_data_root' _ "$ROOT/bin/dad-env.sh"
)"
assert_eq "$grok_home/dad-data" "$resolved_home_data" "shell helper must fall back to GROK_HOME dad-data for plugin installs"

mapfile -t resolved_python_paths < <(
  env -u DAD_DATA_ROOT -u CLAUDE_PLUGIN_DATA \
    GROK_PLUGIN_ROOT="$grok_plugin_root" \
    GROK_PLUGIN_DATA="$grok_plugin_data" \
    python3 - "$ROOT/bin" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from dad_paths import data_root, logs_root, plugin_root
print(plugin_root())
print(data_root())
print(logs_root())
PY
)
assert_eq "$grok_plugin_root" "${resolved_python_paths[0]}" "Python helper must resolve GROK_PLUGIN_ROOT"
assert_eq "$grok_plugin_data" "${resolved_python_paths[1]}" "Python helper must resolve GROK_PLUGIN_DATA"
assert_eq "$grok_plugin_data/logs" "${resolved_python_paths[2]}" "Python helper logs must live under Grok plugin data"

grok_evidence_out="$(
  env -u DAD_DATA_ROOT -u CLAUDE_PLUGIN_DATA \
    GROK_PLUGIN_ROOT="$grok_plugin_root" \
    GROK_PLUGIN_DATA="$grok_plugin_data" \
    "$RUNNER" --cwd "$repo" --mode pipe --timeout 5 --label grok-data-default -- /bin/sh -c "printf grok-root-evidence"
)"
grok_evidence_json="$(printf '%s\n' "$grok_evidence_out" | awk '/^EVIDENCE_JSON: / { sub(/^EVIDENCE_JSON: /, ""); print }')"
case "$grok_evidence_json" in
  "$grok_plugin_data"/evidence/*) ;;
  *) fail "evidence runner default wrote outside GROK_PLUGIN_DATA: $grok_evidence_json" ;;
esac
[[ -f "$grok_evidence_json" ]] || fail "evidence runner did not write Grok plugin data evidence JSON"

grok_gate_out="$(
  env -u DAD_DATA_ROOT -u CLAUDE_PLUGIN_DATA \
    GROK_PLUGIN_ROOT="$grok_plugin_root" \
    GROK_PLUGIN_DATA="$grok_plugin_data" \
    "$GATE" --workspace "$repo" --evidence "$grok_evidence_json"
)"
grok_gate_json="$(printf '%s\n' "$grok_gate_out" | awk '/^EVIDENCE_GATE_JSON: / { sub(/^EVIDENCE_GATE_JSON: /, ""); print }')"
case "$grok_gate_json" in
  "$grok_plugin_data"/evidence/gates/*) ;;
  *) fail "evidence gate default wrote outside GROK_PLUGIN_DATA: $grok_gate_json" ;;
esac
[[ -f "$grok_gate_json" ]] || fail "evidence gate did not write Grok plugin data gate JSON"

printf '{"hookEventName":"UserPromptSubmit","sessionId":"dad-grok","cwd":"%s","prompt":"/dad check"}' "$repo" |
  env -u DAD_DATA_ROOT -u CLAUDE_PLUGIN_DATA \
    DAD_EVENT_FORCE=1 \
    GROK_PLUGIN_ROOT="$grok_plugin_root" \
    GROK_PLUGIN_DATA="$grok_plugin_data" \
    "$EVENT_HOOK"
[[ -f "$grok_plugin_data/events/all-events.jsonl" ]] || fail "event hook did not write events under GROK_PLUGIN_DATA"

printf '{"hookEventName":"UserPromptSubmit","sessionId":"dad-grok-wrapper","cwd":"%s","prompt":"/dad wrapper"}' "$repo" |
  env -u DAD_DATA_ROOT -u CLAUDE_PLUGIN_DATA \
    DAD_EVENT_FORCE=1 \
    DAD_EVENT_HOOK_SCRIPT="$EVENT_HOOK" \
    GROK_PLUGIN_ROOT="$grok_plugin_root" \
    GROK_PLUGIN_DATA="$grok_wrapper_data" \
    "$PLUGIN_HOOK_SCRIPT"
[[ -f "$grok_wrapper_data/events/all-events.jsonl" ]] || fail "plugin hook wrapper did not write events under GROK_PLUGIN_DATA"

fakebin_lease="$tmp/fakebin-lease"
mkdir "$fakebin_lease"
cat > "$fakebin_lease/tmux" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
cmd="${1:-}"
shift || true
case "$cmd" in
  display-message)
    printf '@9\n'
    ;;
  show-window-option)
    printf '\n'
    ;;
  set-window-option)
    ;;
  *)
    printf 'unsupported fake lease tmux command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fakebin_lease/tmux"
env -u DAD_DATA_ROOT -u CLAUDE_PLUGIN_DATA \
  GROK_PLUGIN_ROOT="$grok_plugin_root" \
  GROK_PLUGIN_DATA="$grok_plugin_data" \
  PATH="$fakebin_lease:$PATH" \
  "$ROOT/bin/dad-lease.sh" acquire fake-socket @9 fast 60 >"$tmp/grok-lease.out"
compgen -G "$grok_plugin_data/locks/*.lease.lock" >/dev/null || fail "lease helper did not place locks under GROK_PLUGIN_DATA"
compgen -G "$grok_plugin_data/locks/*-window-9.lease.lock" >/dev/null || fail "lease helper did not use a validated safe window lock filename"

grep -q '"$lease_helper" clear' "$WATCHDOG" || fail "watchdog must clear loop leases through dad-lease.sh clear"
! grep -q "tmux_set @dad_loop_active ''" "$WATCHDOG" || fail "watchdog must not clear loop leases directly outside the lease lock"

bad_lock_dir="$tmp/bad-lease-locks"
if DAD_LEASE_LOCK_DIR="$bad_lock_dir" "$ROOT/bin/dad-lease.sh" status fake-socket '../bad-window' >"$tmp/bad-window.out" 2>&1; then
  fail "lease helper accepted malformed window target"
fi
grep -q 'invalid window target' "$tmp/bad-window.out" || fail "malformed window target rejection missing detail"
[[ ! -e "$bad_lock_dir" ]] || fail "lease helper created a lock directory for malformed window target"

lease_timeout_dir="$tmp/lease-timeout-locks"
mkdir "$lease_timeout_dir"
timeout_socket="timeout-socket"
timeout_hash="$(printf '%s' "$timeout_socket" | sha256sum | awk '{ print substr($1, 1, 12) }')"
timeout_lock="$lease_timeout_dir/${timeout_hash}-window-8.lease.lock"
: > "$timeout_lock"
if (
  flock -x 9
  PATH="$fakebin_lease:$PATH" \
    DAD_LEASE_LOCK_DIR="$lease_timeout_dir" \
    DAD_LEASE_LOCK_TIMEOUT_SECONDS=0 \
    "$ROOT/bin/dad-lease.sh" status "$timeout_socket" @8 >"$tmp/lease-timeout.out" 2>&1
) 9>"$timeout_lock"; then
  fail "lease helper acquired an already-held lock with zero timeout"
else
  lease_timeout_code=$?
fi
assert_eq "30" "$lease_timeout_code" "lease lock contention must return the distinct timeout code"
grep -q 'timed out acquiring lease lock' "$tmp/lease-timeout.out" || fail "lease lock timeout missing explanatory error"

fakebin_lease_clear="$tmp/fakebin-lease-clear"
mkdir "$fakebin_lease_clear"
cat > "$fakebin_lease_clear/tmux" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
cmd="${1:-}"
shift || true
case "$cmd" in
  display-message)
    printf '@9\n'
    ;;
  show-window-option)
    key="${@: -1}"
    case "$key" in
      @dad_loop_run_id) printf '%s\n' "${FAKE_TMUX_RUN_ID:-fresh-run}" ;;
      @dad_loop_active) printf '%s\n' "${FAKE_TMUX_ACTIVE:-fast}" ;;
      *) printf '\n' ;;
    esac
    ;;
  set-window-option)
    key=""
    for arg in "$@"; do
      if [[ "$arg" == @dad_* ]]; then
        key="$arg"
      fi
    done
    printf '%s\n' "$key" >> "${FAKE_TMUX_SET_LOG:?}"
    ;;
  *)
    printf 'unsupported fake lease-clear tmux command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fakebin_lease_clear/tmux"
if PATH="$fakebin_lease_clear:$PATH" \
  FAKE_TMUX_RUN_ID=fresh-run \
  FAKE_TMUX_SET_LOG="$tmp/lease-clear-mismatch.sets" \
  DAD_LEASE_LOCK_DIR="$tmp/lease-clear-locks" \
  "$ROOT/bin/dad-lease.sh" clear fake-socket @9 stale-run watchdog_clear >"$tmp/lease-clear-mismatch.out" 2>&1; then
  fail "lease helper cleared a lease with the wrong expected run id"
fi
grep -q 'MISMATCH current_run_id=fresh-run expected_run_id=stale-run' "$tmp/lease-clear-mismatch.out" || fail "lease compare-and-clear mismatch missing detail"
[[ ! -s "$tmp/lease-clear-mismatch.sets" ]] || fail "lease compare-and-clear wrote tmux options after a run-id mismatch"
PATH="$fakebin_lease_clear:$PATH" \
  FAKE_TMUX_RUN_ID=fresh-run \
  FAKE_TMUX_SET_LOG="$tmp/lease-clear-success.sets" \
  DAD_LEASE_LOCK_DIR="$tmp/lease-clear-locks" \
  "$ROOT/bin/dad-lease.sh" clear fake-socket @9 fresh-run watchdog_clear >"$tmp/lease-clear-success.out"
grep -q 'CLEARED active=fast run_id=fresh-run reason=watchdog_clear' "$tmp/lease-clear-success.out" || fail "lease compare-and-clear success missing detail"
grep -q '@dad_loop_active' "$tmp/lease-clear-success.sets" || fail "lease compare-and-clear success did not clear active metadata"

for unexpected_runtime_path in \
  "$grok_plugin_root/dad/events" \
  "$grok_plugin_root/dad/evidence" \
  "$grok_plugin_root/dad/logs" \
  "$grok_plugin_root/dad/locks"
do
  [[ ! -e "$unexpected_runtime_path" ]] || fail "runtime path was written under plugin code root: $unexpected_runtime_path"
done

grep -q 'dad_spawn_daemon' "$IDLE_SURFACE" || fail "idle-controller must use centralized daemon spawn helper"
grep -q 'dad_spawn_daemon' "$WATCHDOG" || fail "watchdog replacement must use centralized daemon spawn helper"
! grep -q '/tmp/dad-' "$IDLE_SURFACE" "$WATCHDOG" "$SKILL_FILE" || fail "daemon startup must not use predictable /tmp dad log paths"

private_log="$grok_plugin_data/logs/private-daemon.log"
private_key_payload=$'token=raw-token password=hunter2 Bearer AbCdEfGhIjKlMnOpQrStUvWxYz0123456789\n-----BEGIN PRIVATE KEY-----\nabc123\n-----END PRIVATE KEY-----'
env DAD_LOG_REDACT_LIMIT=1000 bash -c 'source "$1"; dad_log_append "$2" "$3"' _ "$ROOT/bin/dad-env.sh" "$private_log" "$private_key_payload"
assert_eq "600" "$(stat -c '%a' "$private_log")" "daemon logs must be private 0600 files"
assert_eq "700" "$(stat -c '%a' "$(dirname -- "$private_log")")" "daemon log directory must be private 0700"
! grep -q 'raw-token' "$private_log" || fail "daemon log failed to redact token values"
! grep -q 'hunter2' "$private_log" || fail "daemon log failed to redact password values"
! grep -q 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789' "$private_log" || fail "daemon log failed to redact bearer/high-entropy token"
! grep -q 'BEGIN PRIVATE KEY' "$private_log" || fail "daemon log failed to redact private key material"
grep -q '\[redacted\]' "$private_log" || fail "daemon log missing redaction marker"
grep -q '\[redacted-private-key\]' "$private_log" || fail "daemon log missing private-key redaction marker"

long_log="$grok_plugin_data/logs/truncated-daemon.log"
long_payload="$(head -c 5000 </dev/zero | tr '\0' A)"
env DAD_LOG_REDACT_LIMIT=120 bash -c 'source "$1"; dad_log_append "$2" "$3"' _ "$ROOT/bin/dad-env.sh" "$long_log" "$long_payload"
grep -q '\[truncated\]' "$long_log" || fail "daemon log did not truncate oversized pane text"

symlink_log="$tmp/symlink-daemon.log"
ln -s "$tmp/symlink-target.log" "$symlink_log"
if bash -c 'source "$1"; dad_prepare_log_file "$2"' _ "$ROOT/bin/dad-env.sh" "$symlink_log" >"$tmp/symlink-log.out" 2>&1; then
  fail "daemon log helper accepted a symlink log target"
fi
grep -q 'refusing symlink log target' "$tmp/symlink-log.out" || fail "symlink log rejection did not explain the failure"

fakebin_spawn="$tmp/fakebin-spawn"
mkdir "$fakebin_spawn"
cat > "$fakebin_spawn/tmux" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -S)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
cmd="${1:-}"
shift || true
case "$cmd" in
  run-shell)
    [[ "${1:-}" == "-b" ]] || { echo "missing -b" >&2; exit 1; }
    shift
    printf '%s\n' "${1:-}" >> "${FAKE_TMUX_RUNS:?}"
    ;;
  *)
    printf 'unsupported fake spawn tmux command: %s\n' "$cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fakebin_spawn/tmux"
spawn_script="$tmp/spawn dir/daemon 'quoted'; \$(touch spawn-pwn).sh"
mkdir -p "$(dirname -- "$spawn_script")"
cat > "$spawn_script" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$spawn_script"
spawn_log="$grok_plugin_data/logs/daemon 'quoted'; \$(touch spawn-pwn).log"
spawn_socket="$tmp/tmux sock 'quoted'; \$(touch spawn-pwn).sock"
PATH="$fakebin_spawn:$PATH" FAKE_TMUX_RUNS="$tmp/run-shell.commands" \
  bash -c 'source "$1"; dad_spawn_daemon "$2" @9 "$3" "$4" "$2" @9 %10' _ "$ROOT/bin/dad-env.sh" "$spawn_socket" "$spawn_log" "$spawn_script"
assert_eq "1" "$(wc -l < "$tmp/run-shell.commands" | tr -d ' ')" "daemon spawn helper must emit exactly one run-shell command"
spawn_command="$(cat "$tmp/run-shell.commands")"
python3 - "$spawn_command" "$ROOT/bin/dad-daemon-launcher.sh" "$spawn_log" "$spawn_script" "$spawn_socket" <<'PY'
import shlex
import sys

parts = shlex.split(sys.argv[1])
expected = [sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], "@9", "%10"]
assert parts == expected, (parts, expected)
PY
if PATH="$fakebin_spawn:$PATH" FAKE_TMUX_RUNS="$tmp/run-shell-invalid-window.commands" \
  bash -c 'source "$1"; dad_spawn_daemon "$2" bad-window "$3" "$4" "$2" bad-window %10' _ "$ROOT/bin/dad-env.sh" "$spawn_socket" "$spawn_log" "$spawn_script" >"$tmp/spawn-invalid-window.out" 2>&1; then
  fail "daemon spawn helper accepted an invalid tmux window target"
fi
grep -q 'invalid window target' "$tmp/spawn-invalid-window.out" || fail "invalid window target rejection missing detail"
if PATH="$fakebin_spawn:$PATH" FAKE_TMUX_RUNS="$tmp/run-shell-invalid-pane.commands" \
  bash -c 'source "$1"; dad_spawn_daemon "$2" @9 "$3" "$4" "$2" @9 %bad' _ "$ROOT/bin/dad-env.sh" "$spawn_socket" "$spawn_log" "$spawn_script" >"$tmp/spawn-invalid-pane.out" 2>&1; then
  fail "daemon spawn helper accepted an invalid tmux pane target"
fi
grep -q 'invalid daemon pane argument' "$tmp/spawn-invalid-pane.out" || fail "invalid pane target rejection missing detail"

"$CODE_STANDARDS" --root "$repo" >"$tmp/code-standards-pass.out"
grep -q 'CODE_STANDARDS_RESULT: PASS' "$tmp/code-standards-pass.out" || fail "code standards checker must pass a small repo"

seq 1 1201 > "$repo/huge-handwritten.txt"
if "$CODE_STANDARDS" --root "$repo" >"$tmp/code-standards-fail.out" 2>&1; then
  fail "code standards checker accepted an oversized hand-authored file"
fi
grep -q 'CODE_STANDARDS_RESULT: FAIL' "$tmp/code-standards-fail.out" || fail "code standards checker failure missing result"
grep -q 'CODE_STANDARDS_FAILURE: huge-handwritten.txt lines=1201' "$tmp/code-standards-fail.out" || fail "code standards checker did not name oversized file"
rm -f "$repo/huge-handwritten.txt"

{
  printf '# generated; do not edit\n'
  seq 1 1400
} > "$repo/generated-fixture.txt"
"$CODE_STANDARDS" --root "$repo" >"$tmp/code-standards-generated.out"
grep -q 'CODE_STANDARDS_RESULT: PASS' "$tmp/code-standards-generated.out" || fail "code standards checker must ignore generated marker files"
rm -f "$repo/generated-fixture.txt"

seq 1 1400 > "$repo/generated-events.jsonl"
seq 1 1400 > "$repo/generated-run.log"
"$CODE_STANDARDS" --root "$repo" >"$tmp/code-standards-log-data.out"
grep -q 'CODE_STANDARDS_RESULT: PASS' "$tmp/code-standards-log-data.out" || fail "code standards checker must ignore generated log/jsonl data"
rm -f "$repo/generated-events.jsonl" "$repo/generated-run.log"

secret_out="$("$RUNNER" --cwd "$repo" --mode pipe --timeout 5 --label secret-redaction --output-dir "$tmp/evidence" -- /bin/sh -c "printf 'opaque AbCdEfGhIjKlMnOpQrStUvWxYz0123456789\\n'")"
secret_json="$(printf '%s\n' "$secret_out" | awk '/^EVIDENCE_JSON: / { sub(/^EVIDENCE_JSON: /, ""); print }')"
python3 - "$secret_json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
transcript = Path(data["transcriptPath"]).read_text()
assert "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789" not in transcript
assert "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789" not in data["command"]
assert "[redacted-high-entropy-token]" in transcript
assert "[redacted-high-entropy-token]" in data["command"]
PY

scenario="$tmp/scenario.json"
cat > "$scenario" <<'EOF'
{
  "label": "generic-action-effect",
  "cwd": "__REPO__",
  "timeoutSeconds": 5,
  "command": ["/bin/sh", "-c", "printf 'ready> '; read line; printf 'EFFECT:%s\\n' \"$line\""],
  "steps": [
    {"expect": {"regex": "ready>", "label": "ready", "timeout": 2}},
    {"send": "abc\n"},
    {"expect": {"regex": "EFFECT:abc", "label": "action effect", "timeout": 2}}
  ],
  "expectExit": 0
}
EOF
sed -i "s|__REPO__|$repo|g" "$scenario"

runner_out="$("$RUNNER" --scenario "$scenario" --output-dir "$tmp/evidence")"
evidence_json="$(printf '%s\n' "$runner_out" | awk '/^EVIDENCE_JSON: / { sub(/^EVIDENCE_JSON: /, ""); print }')"
[[ -n "$evidence_json" && -f "$evidence_json" ]] || fail "scenario runner did not produce evidence JSON"

"$GATE" \
  --workspace "$repo" \
  --require-real-run \
  --require-assertions \
  --require-action-effect \
  --min-transcript-bytes 10 \
  --require-output-regex 'EFFECT:abc' \
  --evidence "$evidence_json" >/dev/null

expected_nonzero_out="$("$RUNNER" --cwd "$repo" --mode pipe --timeout 5 --label expected-nonzero --output-dir "$tmp/evidence" --expect-exit 2 -- /bin/sh -c "printf 'expected failure path\\n'; exit 2")"
expected_nonzero_json="$(printf '%s\n' "$expected_nonzero_out" | awk '/^EVIDENCE_JSON: / { sub(/^EVIDENCE_JSON: /, ""); print }')"
printf '%s\n' "$expected_nonzero_out" | grep -q 'EVIDENCE_RESULT: EXIT_EXPECTED' || fail "expected nonzero exits must produce accepted evidence status"
"$GATE" --workspace "$repo" --require-real-run --require-assertions --min-transcript-bytes 10 --evidence "$expected_nonzero_json" >/dev/null

forged_json="${evidence_json%.json}-forged-schema.json"
cp "$evidence_json" "$forged_json"
python3 - "$forged_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["schema"] = "dad.evidence.v999"
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
if "$GATE" --workspace "$repo" --require-real-run --require-assertions --require-action-effect --min-transcript-bytes 10 --evidence "$forged_json" >"$tmp/forged-gate.out" 2>&1; then
  fail "gate accepted forged evidence schema"
fi
grep -q 'schema_missing_or_unknown' "$tmp/forged-gate.out" || fail "forged schema rejection missing issue"

missing_head_json="${evidence_json%.json}-missing-head.json"
cp "$evidence_json" "$missing_head_json"
python3 - "$missing_head_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["git"]["head"] = ""
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
if "$GATE" --workspace "$repo" --require-real-run --require-assertions --require-action-effect --min-transcript-bytes 10 --evidence "$missing_head_json" >"$tmp/missing-head-gate.out" 2>&1; then
  fail "gate accepted git workspace evidence without git head"
fi
grep -q 'git_head_missing' "$tmp/missing-head-gate.out" || fail "missing git head rejection missing issue"

empty_out="$("$RUNNER" --cwd "$repo" --mode pipe --timeout 5 --label empty-no-assertions --output-dir "$tmp/evidence" -- /bin/true)"
empty_json="$(printf '%s\n' "$empty_out" | awk '/^EVIDENCE_JSON: / { sub(/^EVIDENCE_JSON: /, ""); print }')"
if "$GATE" --workspace "$repo" --require-real-run --require-assertions --require-action-effect --min-transcript-bytes 10 --evidence "$empty_json" >"$tmp/empty-gate.out" 2>&1; then
  fail "gate accepted empty/no-action/no-assertion evidence"
fi
grep -q 'empty_transcript_for_real_run' "$tmp/empty-gate.out" || fail "empty evidence rejection missing empty transcript issue"
grep -q 'passed_assertion_required' "$tmp/empty-gate.out" || fail "empty evidence rejection missing assertion issue"
grep -q 'action_effect_required' "$tmp/empty-gate.out" || fail "empty evidence rejection missing action-effect issue"
grep -q 'action_effect_assertion_required' "$tmp/empty-gate.out" || fail "empty evidence rejection missing action-effect assertion issue"

tampered_json="${evidence_json%.json}-tampered.json"
cp "$evidence_json" "$tampered_json"
python3 - "$tampered_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["transcriptBytes"] = 999999
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
if "$GATE" --workspace "$repo" --require-real-run --require-assertions --require-action-effect --min-transcript-bytes 10 --evidence "$tampered_json" >"$tmp/tampered-gate.out" 2>&1; then
  fail "gate accepted tampered transcriptBytes metadata"
fi
grep -q 'transcript_bytes_mismatch' "$tmp/tampered-gate.out" || fail "tampered transcript bytes rejection missing mismatch issue"
grep -q 'EVIDENCE_GATE_JSON:' "$tmp/tampered-gate.out" || fail "evidence gate must print durable gate result path"

malformed_json="${evidence_json%.json}-malformed-numeric.json"
cp "$evidence_json" "$malformed_json"
python3 - "$malformed_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
data["transcriptBytes"] = "many"
data["scenario"]["actionCount"] = "several"
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
if "$GATE" --workspace "$repo" --require-real-run --require-assertions --require-action-effect --min-transcript-bytes 10 --evidence "$malformed_json" >"$tmp/malformed-gate.out" 2>&1; then
  fail "gate accepted malformed numeric evidence metadata"
fi
grep -q 'transcript_bytes_invalid' "$tmp/malformed-gate.out" || fail "malformed transcriptBytes rejection missing issue"
grep -q 'action_count_invalid' "$tmp/malformed-gate.out" || fail "malformed actionCount rejection missing issue"

no_effect_scenario="$tmp/no-effect-scenario.json"
cat > "$no_effect_scenario" <<'EOF'
{
  "label": "generic-action-without-effect-assertion",
  "cwd": "__REPO__",
  "timeoutSeconds": 5,
  "command": ["/bin/sh", "-c", "read line; printf 'received:%s\\n' \"$line\""],
  "steps": [
    {"send": "abc\n"}
  ],
  "expectExit": 0
}
EOF
sed -i "s|__REPO__|$repo|g" "$no_effect_scenario"
no_effect_out="$("$RUNNER" --scenario "$no_effect_scenario" --output-dir "$tmp/evidence")"
no_effect_json="$(printf '%s\n' "$no_effect_out" | awk '/^EVIDENCE_JSON: / { sub(/^EVIDENCE_JSON: /, ""); print }')"
if "$GATE" --workspace "$repo" --require-real-run --require-assertions --require-action-effect --min-transcript-bytes 10 --evidence "$no_effect_json" >"$tmp/no-effect-gate.out" 2>&1; then
  fail "gate accepted input action without a passed action-effect assertion"
fi
grep -q 'action_effect_assertion_required' "$tmp/no-effect-gate.out" || fail "action-effect assertion rejection missing issue"

bad_scenario="$tmp/bad-scenario.json"
cat > "$bad_scenario" <<'EOF'
{
  "label": "bad",
  "cwd": "__REPO__",
  "timeoutSeconds": 1,
  "command": ["/bin/true"],
  "steps": [],
  "surprise": true
}
EOF
sed -i "s|__REPO__|$repo|g" "$bad_scenario"
if "$RUNNER" --scenario "$bad_scenario" --output-dir "$tmp/evidence" >"$tmp/bad-scenario.out" 2>&1; then
  fail "evidence runner accepted unknown scenario keys"
fi
grep -q 'scenario_unknown_keys=surprise' "$tmp/bad-scenario.out" || fail "unknown scenario key failure missing detail"

bool_scenario="$tmp/bool-scenario.json"
cat > "$bool_scenario" <<'EOF'
{
  "label": "bool-scenario",
  "cwd": "__REPO__",
  "timeoutSeconds": 1,
  "timeoutOk": "false",
  "inheritEnv": "false",
  "allowShell": "false",
  "command": ["/bin/true"]
}
EOF
sed -i "s|__REPO__|$repo|g" "$bool_scenario"
if "$RUNNER" --scenario "$bool_scenario" --output-dir "$tmp/evidence" >"$tmp/bool-scenario.out" 2>&1; then
  fail "evidence runner accepted string booleans in scenario"
fi
grep -q 'scenario field timeoutOk must be a boolean' "$tmp/bool-scenario.out" || fail "scenario string boolean rejection missing detail"

numeric_scenario="$tmp/numeric-scenario.json"
cat > "$numeric_scenario" <<'EOF'
{
  "label": "numeric-scenario",
  "cwd": "__REPO__",
  "timeoutSeconds": "soon",
  "command": ["/bin/true"]
}
EOF
sed -i "s|__REPO__|$repo|g" "$numeric_scenario"
if "$RUNNER" --scenario "$numeric_scenario" --output-dir "$tmp/evidence" >"$tmp/numeric-scenario.out" 2>&1; then
  fail "evidence runner accepted non-numeric scenario timeoutSeconds"
fi
grep -q 'scenario timeoutSeconds must be a number' "$tmp/numeric-scenario.out" || fail "scenario numeric timeout rejection missing detail"

bad_step_scenario="$tmp/bad-step-scenario.json"
cat > "$bad_step_scenario" <<'EOF'
{
  "label": "bad-step-scenario",
  "cwd": "__REPO__",
  "timeoutSeconds": 2,
  "command": ["/bin/sh", "-c", "printf 'ready\\n'"],
  "steps": [
    {"expect": {"regex": "ready", "timeout": "later"}}
  ],
  "expectExit": 0
}
EOF
sed -i "s|__REPO__|$repo|g" "$bad_step_scenario"
if "$RUNNER" --scenario "$bad_step_scenario" --output-dir "$tmp/evidence" >"$tmp/bad-step-scenario.out" 2>&1; then
  fail "evidence runner accepted malformed scenario step timeout"
fi
grep -q 'steps\[0\].timeout must be a number' "$tmp/bad-step-scenario.out" || fail "scenario step timeout rejection missing detail"

shell_bool_scenario="$tmp/shell-bool-scenario.json"
cat > "$shell_bool_scenario" <<'EOF'
{
  "label": "shell-bool-scenario",
  "cwd": "__REPO__",
  "timeoutSeconds": 1,
  "allowShell": false,
  "shell": "printf should-not-run"
}
EOF
sed -i "s|__REPO__|$repo|g" "$shell_bool_scenario"
if "$RUNNER" --scenario "$shell_bool_scenario" --output-dir "$tmp/evidence" >"$tmp/shell-bool-scenario.out" 2>&1; then
  fail "evidence runner accepted shell scenario without boolean allowShell true"
fi
grep -q 'scenario_shell_requires_allowShell' "$tmp/shell-bool-scenario.out" || fail "scenario shell allowShell rejection missing detail"

pipe_scenario="$tmp/pipe-scenario.json"
cat > "$pipe_scenario" <<'EOF'
{
  "label": "pipe-scenario",
  "cwd": "__REPO__",
  "mode": "pipe",
  "timeoutSeconds": 1,
  "command": ["/bin/true"],
  "steps": []
}
EOF
sed -i "s|__REPO__|$repo|g" "$pipe_scenario"
if "$RUNNER" --scenario "$pipe_scenario" --output-dir "$tmp/evidence" >"$tmp/pipe-scenario.out" 2>&1; then
  fail "evidence runner accepted unsupported scenario pipe mode"
fi
grep -q 'scenario_mode_unsupported' "$tmp/pipe-scenario.out" || fail "unsupported scenario mode failure missing detail"

invalid_mode_scenario="$tmp/invalid-mode-scenario.json"
cat > "$invalid_mode_scenario" <<'EOF'
{
  "label": "invalid-mode",
  "cwd": "__REPO__",
  "mode": "nonsense",
  "timeoutSeconds": 1,
  "command": ["/bin/true"]
}
EOF
sed -i "s|__REPO__|$repo|g" "$invalid_mode_scenario"
if "$RUNNER" --scenario "$invalid_mode_scenario" --output-dir "$tmp/evidence" >"$tmp/invalid-mode.out" 2>&1; then
  fail "evidence runner accepted invalid scenario mode"
fi
grep -q 'scenario_mode_invalid' "$tmp/invalid-mode.out" || fail "invalid scenario mode failure missing detail"

event_root="$tmp/events"
mkdir "$event_root"
printf '{"ts":"2026-05-16T00:00:00Z","window":"@17","sonPane":"%%23","action":"direct_son_idle_recovery","reason":"idle SLA"}\n' > "$event_root/abc123-17-23.idle-events.jsonl"
printf '{"ts":"2026-05-16T00:01:00","window":"@17","sonPane":"%%23","event":"PostToolUse"}\n' >> "$event_root/abc123-17-23.idle-events.jsonl"
summary_json="$("$ROOT/bin/dad-events-summary.py" --event-root "$event_root" --tmux-window @17 --json)"
printf '%s\n' "$summary_json" | grep -q '"event_count": 2' || fail "event summary must include flat idle-controller event files and naive UTC timestamps"

idle_json_event_root="$tmp/idle-json-events"
multiline_reason=$'line one\nline "two"\tTabbed control'
DAD_IDLE_CONTROLLER_TEST_EMIT_EVENT=1 \
  DAD_IDLE_CONTROLLER_EVENT_DIR="$idle_json_event_root" \
  DAD_TEST_EVENT_TS="2026-05-16T00:02:00Z" \
  DAD_TEST_EVENT_ACTION="direct_son_idle_recovery" \
  DAD_TEST_EVENT_REASON="$multiline_reason" \
  "$IDLE" fake @17 %2 %23
idle_summary_json="$("$ROOT/bin/dad-events-summary.py" --event-root "$idle_json_event_root" --tmux-window @17 --json)"
python3 -c 'import json, sys; expected = sys.argv[1]; data = json.load(sys.stdin); assert data["event_count"] == 1; assert data["last_event"]["reason"] == expected' "$multiline_reason" <<<"$idle_summary_json"

nofp_root="$tmp/events-nofp"
mkdir "$nofp_root"
printf '{"ts":"2026-05-16T00:00:00Z","window":"@1","event":"UserPromptSubmit"}\n{"ts":"2026-05-16T00:00:01Z","window":"@1","event":"Stop"}\n' > "$nofp_root/abc123-1-8.son-events.jsonl"
nofp_summary="$("$ROOT/bin/dad-events-summary.py" --event-root "$nofp_root" --tmux-window @1 --json)"
printf '%s\n' "$nofp_summary" | python3 -c 'import json, sys; data = json.load(sys.stdin); assert data["turn_fingerprint"] == ""'

hook_root="$tmp/hook-events"
printf '{"hookEventName":"UserPromptSubmit","sessionId":"non-dad","prompt":"hello"}' | "$ROOT/bin/dad-event-hook.py" --event-root "$hook_root"
[[ -f "$hook_root/hook-health.json" ]] || fail "DAD event hook must write health for ignored non-DAD events"
[[ ! -f "$hook_root/unscoped-events.jsonl" ]] || fail "DAD event hook must not store unscoped non-DAD events by default"
printf '{"hookEventName":"UserPromptSubmit","sessionId":"non-dad","prompt":"hello"}' | DAD_EVENT_STORE_UNSCOPED=1 "$ROOT/bin/dad-event-hook.py" --event-root "$hook_root"
[[ -f "$hook_root/unscoped-events.jsonl" ]] || fail "DAD event hook must support explicit unscoped debug capture"

plugin_evidence_event_root="$tmp/plugin-evidence-events"
plugin_evidence_json="$grok_plugin_data/evidence/20260516/plugin-record.json"
plugin_evidence_log="$grok_plugin_data/evidence/20260516/plugin-record.log"
printf '{"hookEventName":"PostToolUse","sessionId":"dad-plugin-evidence","cwd":"%s","tool":{"name":"Bash","response":"EVIDENCE_JSON: %s\\nEVIDENCE_LOG: %s"}}' "$repo" "$plugin_evidence_json" "$plugin_evidence_log" |
  DAD_EVENT_FORCE=1 "$EVENT_HOOK" --event-root "$plugin_evidence_event_root"
python3 - "$plugin_evidence_event_root/latest.json" "$plugin_evidence_json" "$plugin_evidence_log" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
refs = set(data["evidence_refs"])
assert sys.argv[2] in refs, refs
assert sys.argv[3] in refs, refs
PY

stale_out="$("$RUNNER" --scenario "$scenario" --output-dir "$tmp/evidence")"
stale_json="$(printf '%s\n' "$stale_out" | awk '/^EVIDENCE_JSON: / { sub(/^EVIDENCE_JSON: /, ""); print }')"
printf 'changed\n' > "$repo/stale.txt"
if "$GATE" --workspace "$repo" --require-real-run --require-assertions --require-action-effect --min-transcript-bytes 10 --evidence "$stale_json" >"$tmp/stale-gate.out" 2>&1; then
  fail "gate accepted stale git status evidence"
fi
grep -q 'git_status_stale' "$tmp/stale-gate.out" || fail "stale evidence rejection missing git_status_stale"

head_stale_out="$("$RUNNER" --scenario "$scenario" --output-dir "$tmp/evidence")"
head_stale_json="$(printf '%s\n' "$head_stale_out" | awk '/^EVIDENCE_JSON: / { sub(/^EVIDENCE_JSON: /, ""); print }')"
git -C "$repo" add stale.txt
git -C "$repo" commit -q -m 'test: advance evidence fixture head'
if "$GATE" --workspace "$repo" --require-real-run --require-assertions --require-action-effect --min-transcript-bytes 10 --evidence "$head_stale_json" >"$tmp/head-stale-gate.out" 2>&1; then
  fail "gate accepted evidence from an older git head"
fi
grep -q 'git_head_stale' "$tmp/head-stale-gate.out" || fail "head-stale evidence rejection missing git_head_stale"

printf 'PASS: dad supervision tests\n'
