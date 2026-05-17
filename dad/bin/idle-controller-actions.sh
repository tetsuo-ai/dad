submit_to_son() {
  reason="$1"
  if ! pane_accepting_input "$son_pane"; then
    tmux_set @dad_idle_controller_status waiting:son_busy
    return 2
  fi
  objective="$(objective_text)"
  corrective_task="$(metadata_value @dad_last_corrective_task)"
  improvement_frontier="$(metadata_value @dad_improvement_frontier)"
  quality_research="$(metadata_value @dad_quality_research_summary)"
  quality_bar="$(metadata_value @dad_quality_bar)"
  quality_gap="$(metadata_value @dad_quality_gap)"
  quality_frontier="$(metadata_value @dad_quality_frontier)"
  reference_scout="$(metadata_value @dad_reference_scout_summary)"
  reference_frontier="$(metadata_value @dad_reference_scout_frontier)"
  reference_reuse="$(metadata_value @dad_reference_scout_reuse_notes 800)"
  reference_at="$(tmux_get @dad_reference_scout_last_at)"
  user_feedback="$(metadata_value @dad_last_user_feedback 800)"
  user_feedback_at="$(tmux_get @dad_last_user_feedback_at)"
  prompt="$(cat <<EOF
DAD mechanical idle recovery ($(date -Is)).

You have been idle at the prompt in a DAD-supervised session for at least ${idle_sla_seconds}s.

Original objective:
$objective

Current Dad direction, if present:
- last_corrective_task: ${corrective_task:-unknown}
- improvement_frontier: ${improvement_frontier:-unknown}
- quality_research: ${quality_research:-unknown}
- quality_bar: ${quality_bar:-unknown}
- quality_gap: ${quality_gap:-unknown}
- quality_frontier: ${quality_frontier:-unknown}
- reference_scout: ${reference_scout:-unknown}
- reference_frontier: ${reference_frontier:-unknown}
- reference_scout_last_at: ${reference_at:-unknown}
- recent_user_feedback: ${user_feedback:-none}
- recent_user_feedback_at: ${user_feedback_at:-unknown}

Act now. Do not ask what to do next and do not offer options. Treat recent_user_feedback as the highest-priority human correction when present: address the concrete product gap it names instead of summarizing, defending, or asking for clarification. Choose the highest-value concrete next action from last_corrective_task/reference_frontier/quality_frontier/improvement_frontier; when there are alternatives, take the first/highest-priority objective-aligned item as the default. If this work is user-facing, creative, interactive, benchmark-like, or quality-sensitive and quality_bar/quality_frontier/reference_frontier is unknown, stale, local-only, or contradicted by recent evidence, first do one bounded Reference Scout / Code Harvest pass using Grok online research/web access when available, or local references if not. Use a read-only researcher subagent/task when available. Collect 3-5 concrete implementation references with source names/URLs, pick one behavior/API/UX pattern or example structure that clearly improves this artifact, then perform exactly one concrete artifact-changing implementation delta in this same turn. Do not stop at research, notes, comparisons, or a proposal. First inspect the current workspace state and recent logs/errors, then change the product/artifact in one objective-relevant way. Verification-only is not acceptable unless you are proving a specific recent artifact delta, reproducing a current failure, or satisfying a specific missing evidence gate. Never tell the user to "test yourself", "try it yourself", or verify for you; you must run/use the artifact yourself and report the captured evidence. If the artifact is broken, fix the blocker before polishing. If you claim something works, produce objective-relevant observed evidence, preferably with <DAD_ROOT>/bin/evidence-runner.py for anything interactive, long-running, or freeze-prone.

Git discipline: use one repo-approved stable branch for this DAD workstream. If local instructions require a feature branch/worktree, create or select exactly one such branch before continuing and record it as the session branch. Do not create or switch to additional branches unless the user explicitly asks. Stage only relevant files. After a coherent artifact delta passes its relevant checks, commit it locally on the same branch using Conventional Commits. Never bypass hooks. If branch sprawl already exists, consolidate useful work onto the session/current branch and commit there before doing new feature work. Do not fetch, pull, push, open a PR, or touch remotes unless explicitly requested.

Coding standards: keep hand-authored files context-bounded. Do not create or extend monoliths; files over 1200 hand-authored lines fail the DAD coding-standard gate, and files over 2000 lines require modularization before feature work. Run <DAD_ROOT>/bin/code-standards-check.py --root "\$(pwd)" before claiming this delta or completion, and split oversized files before continuing.

You must edit the product/artifact through the available file-editing tool or shell edit workflow. Do not answer with code snippets, plans, reports, or instructions for the user as a substitute for changing the workspace.

For user-facing or interactive software, do not merely launch/open it. Actually use the core user journey inferred from the objective: perform the objective-critical action(s), observe their effect, and include a captured transcript/log/state record plus at least one passed assertion over that effect. Empty transcripts, title-screen-only runs, input spam without observed effects, and TIMEOUT without assertions are not acceptable evidence.

Report changed files, local commit hash when committed, exact commands/checks, CODE_STANDARDS_RESULT, outcomes, and any EVIDENCE_JSON path.
EOF
)"
  if ! "$submit" --socket "$socket" --window "$window" --target "$son_pane" --expect-command grok --mode text --text "$prompt"; then
    tmux_set @dad_idle_controller_last_action failed_direct_son_idle_recovery
    tmux_set @dad_idle_controller_last_reason "$reason"
    return 1
  fi
  tmux_set @dad_last_nudge_at "$(date -Is)"
  count="$(tmux_get @dad_nudge_count)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  tmux_set @dad_nudge_count "$((count + 1))"
  tmux_set @dad_idle_controller_last_action direct_son_idle_recovery
  tmux_set @dad_idle_controller_last_reason "$reason"
  tmux_set @dad_idle_controller_last_fingerprint "$(tmux_get @dad_son_fingerprint)"
  tmux_set @dad_idle_action_sent_at "$(date -Is)"
  mark_state_after_prompt
}

submit_claim_continuation_to_son() {
  reason="$1"
  if ! pane_accepting_input "$son_pane"; then
    tmux_set @dad_idle_controller_status waiting:son_busy_claim_continuation
    return 2
  fi
  objective="$(objective_text)"
  verifier_verdict="$(tmux_get @dad_verifier_last_verdict)"
  evidence_status="$(tmux_get @dad_evidence_contract_last_status)"
  corrective_task="$(metadata_value @dad_last_corrective_task)"
  improvement_frontier="$(metadata_value @dad_improvement_frontier)"
  quality_research="$(metadata_value @dad_quality_research_summary)"
  quality_bar="$(metadata_value @dad_quality_bar)"
  quality_gap="$(metadata_value @dad_quality_gap)"
  quality_frontier="$(metadata_value @dad_quality_frontier)"
  reference_scout="$(metadata_value @dad_reference_scout_summary)"
  reference_frontier="$(metadata_value @dad_reference_scout_frontier)"
  reference_reuse="$(metadata_value @dad_reference_scout_reuse_notes 800)"
  reference_at="$(tmux_get @dad_reference_scout_last_at)"
  user_feedback="$(metadata_value @dad_last_user_feedback 800)"
  user_feedback_at="$(tmux_get @dad_last_user_feedback_at)"
  prompt="$(cat <<EOF
DAD mechanical claim-continuation recovery ($(date -Is)).

You are stopped at the prompt after a material claim/report, but that claim is not accepted as terminal proof. Dad verification has not advanced this session within ${claim_escalation_seconds}s.

Original objective:
$objective

Current Dad metadata:
- verifier_last_verdict: ${verifier_verdict:-unknown}
- evidence_contract_last_status: ${evidence_status:-unknown}
- last_corrective_task: ${corrective_task:-unknown}
- improvement_frontier: ${improvement_frontier:-unknown}
- quality_research: ${quality_research:-unknown}
- quality_bar: ${quality_bar:-unknown}
- quality_gap: ${quality_gap:-unknown}
- quality_frontier: ${quality_frontier:-unknown}
- reference_scout: ${reference_scout:-unknown}
- reference_frontier: ${reference_frontier:-unknown}
- reference_scout_last_at: ${reference_at:-unknown}
- recent_user_feedback: ${user_feedback:-none}
- recent_user_feedback_at: ${user_feedback_at:-unknown}

Act now without waiting for Dad or the user. Treat your last report as untrusted until backed by fresh objective-relevant evidence. First inspect the current workspace state and recent logs/errors, then perform exactly one highest-value next step:
- if recent_user_feedback is present, treat it as the highest-priority correction and make a concrete artifact change that addresses it unless the current artifact is broken and must be fixed first;
- if any cited evidence is stale, failing, missing, or contradicted by current state, fix the blocker or produce fresh bounded evidence;
- if the evidence is valid, move to the next highest-value objective-aligned improvement from last_corrective_task/reference_frontier/quality_frontier/improvement_frontier;
- if this work is user-facing, creative, interactive, benchmark-like, or quality-sensitive and quality_bar/quality_frontier/reference_frontier is unknown, stale, local-only, or contradicted by recent evidence, do one bounded Reference Scout / Code Harvest pass using Grok online research/web access when available, or local references if not, then implement one concrete improvement that closes a quality_gap; use a read-only researcher subagent/task when available, collect 3-5 concrete implementation references with source names/URLs, choose one behavior/API/UX pattern or example structure, and edit the workspace in this same turn;
- do not perform another verification-only/report-only cycle unless it proves a specific recent artifact delta, reproduces a current failure, or satisfies a specific missing evidence gate; otherwise change the product/artifact first, then prove that change;
- if your last report told the user to "test yourself", "try it yourself", or verify manually, that was invalid delegated verification; run/use the artifact yourself now and replace that handoff with captured evidence;
- if this is repeated delegated verification, you must edit the product/artifact before running another evidence/report cycle;
- if any changed/latest-commit hand-authored file is oversized, run <DAD_ROOT>/bin/code-standards-check.py --root "\$(pwd)", split the oversized file(s), and rerun relevant behavior evidence before feature work;
- if metadata contains alternatives or asks for direction, choose the first/highest-priority concrete item as the default; do not ask the user or Dad to choose;
- if the artifact is runnable or user-facing, use <DAD_ROOT>/bin/evidence-runner.py for the relevant real-use check: perform objective-critical action(s), observe their effects, preserve a non-empty transcript/log/state record, and include at least one passed assertion over the observed effect.

Git discipline: use one repo-approved stable branch for this DAD workstream. If local instructions require a feature branch/worktree, create or select exactly one such branch before continuing and record it as the session branch. Do not create or switch to additional branches unless the user explicitly asks. Stage only relevant files. After a coherent artifact delta passes its relevant checks, commit it locally on the same branch using Conventional Commits. Never bypass hooks. If branch sprawl already exists, consolidate useful work onto the session/current branch and commit there before doing new feature work. Do not fetch, pull, push, open a PR, or touch remotes unless explicitly requested.

Coding standards: keep hand-authored files context-bounded. Run <DAD_ROOT>/bin/code-standards-check.py --root "\$(pwd)" before claiming this delta or completion. CODE_STANDARDS_RESULT: FAIL means split oversized hand-authored files before continuing.

Report changed files, local commit hash when committed, exact commands/checks, CODE_STANDARDS_RESULT, outcomes, and any EVIDENCE_JSON path. Do not declare final victory or wait for acceptance. Do not treat launch-only, title-screen-only, empty-transcript, or assertion-free input spam as evidence.
EOF
)"
  if ! "$submit" --socket "$socket" --window "$window" --target "$son_pane" --expect-command grok --mode text --text "$prompt"; then
    tmux_set @dad_idle_controller_last_action failed_direct_son_claim_continuation
    tmux_set @dad_idle_controller_last_reason "$reason"
    return 1
  fi
  tmux_set @dad_last_nudge_at "$(date -Is)"
  count="$(tmux_get @dad_nudge_count)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  tmux_set @dad_nudge_count "$((count + 1))"
  tmux_set @dad_idle_controller_last_action direct_son_claim_continuation
  tmux_set @dad_idle_controller_last_reason "$reason"
  tmux_set @dad_idle_controller_last_fingerprint "$(tmux_get @dad_son_fingerprint)"
  tmux_set @dad_idle_action_sent_at "$(date -Is)"
  mark_state_after_prompt
}

submit_code_write_correction_to_son() {
  reason="$1"
  count="$2"
  if ! pane_accepting_input "$son_pane"; then
    tmux_set @dad_idle_controller_status waiting:son_busy_code_write_correction
    return 2
  fi
  objective="$(objective_text)"
  verifier_verdict="$(tmux_get @dad_verifier_last_verdict)"
  evidence_status="$(tmux_get @dad_evidence_contract_last_status)"
  corrective_task="$(metadata_value @dad_last_corrective_task)"
  improvement_frontier="$(metadata_value @dad_improvement_frontier)"
  quality_bar="$(metadata_value @dad_quality_bar)"
  quality_gap="$(metadata_value @dad_quality_gap)"
  quality_frontier="$(metadata_value @dad_quality_frontier)"
  reference_scout="$(metadata_value @dad_reference_scout_summary)"
  reference_frontier="$(metadata_value @dad_reference_scout_frontier)"
  reference_reuse="$(metadata_value @dad_reference_scout_reuse_notes 800)"
  reference_at="$(tmux_get @dad_reference_scout_last_at)"
  user_feedback="$(metadata_value @dad_last_user_feedback 800)"
  user_feedback_at="$(tmux_get @dad_last_user_feedback_at)"
  prompt="$(cat <<EOF
DAD mechanical code-write correction ($(date -Is)).

Invalid no-artifact handoff detected (event count: ${count}).

Original objective:
$objective

Current Dad metadata:
- verifier_last_verdict: ${verifier_verdict:-unknown}
- evidence_contract_last_status: ${evidence_status:-unknown}
- last_corrective_task: ${corrective_task:-unknown}
- improvement_frontier: ${improvement_frontier:-unknown}
- quality_bar: ${quality_bar:-unknown}
- quality_gap: ${quality_gap:-unknown}
- quality_frontier: ${quality_frontier:-unknown}
- reference_scout: ${reference_scout:-unknown}
- reference_frontier: ${reference_frontier:-unknown}
- reference_scout_last_at: ${reference_at:-unknown}
- recent_user_feedback: ${user_feedback:-none}
- recent_user_feedback_at: ${user_feedback_at:-unknown}
- correction_reason: $reason

Your previous shape was invalid: asking or expecting the user to test is not evidence. Do not run another evidence-only/report-only cycle. Do not output code snippets for the user to apply. Do not write another status report first.

Act now:
1. Inspect the current workspace state and recent logs/errors.
2. If no concrete artifact edit is obvious from the current failure, run a bounded Reference Scout / Code Harvest pass now: use Grok online research/web access or a read-only researcher subagent/task when available, collect 3-5 concrete implementation references with source names/URLs, choose one behavior/API/UX pattern or example structure, and turn it into an artifact edit in this same turn.
3. Edit the product/artifact itself in one objective-relevant way using the available file-editing tool or shell edit workflow. If recent_user_feedback is present, address that concrete product gap first.
4. Keep hand-authored files context-bounded. Run <DAD_ROOT>/bin/code-standards-check.py --root "\$(pwd)" and split any file that fails the 1200-line gate before continuing feature work.
5. Keep the work on one repo-approved stable branch. If local instructions require a feature branch/worktree, create or select exactly one and record it as the session branch. Stage only relevant files. After the coherent delta passes relevant checks and the code-standards gate, commit it locally on that same branch using Conventional Commits. Never bypass hooks or touch remotes unless explicitly requested.
6. Only after a real workspace diff exists, run/use the artifact yourself through the objective-critical workflow and capture transcript/log/state evidence with at least one passed assertion over the action-effect relationship.
7. Report changed files, local commit hash when committed, the exact commands/checks, CODE_STANDARDS_RESULT, outcomes, and any EVIDENCE_JSON path.

If the artifact is currently broken, the edit must address the blocker before polish. If no safe artifact edit is possible, report the exact blocker and do not claim completion.
EOF
)"
  if ! "$submit" --socket "$socket" --window "$window" --target "$son_pane" --expect-command grok --mode text --text "$prompt"; then
    tmux_set @dad_idle_controller_last_action failed_direct_son_code_write_correction
    tmux_set @dad_idle_controller_last_reason "$reason"
    return 1
  fi
  tmux_set @dad_last_nudge_at "$(date -Is)"
  count_meta="$(tmux_get @dad_nudge_count)"
  [[ "$count_meta" =~ ^[0-9]+$ ]] || count_meta=0
  tmux_set @dad_nudge_count "$((count_meta + 1))"
  tmux_set @dad_idle_controller_last_action direct_son_code_write_correction
  tmux_set @dad_idle_controller_last_reason "$reason"
  tmux_set @dad_idle_controller_last_fingerprint "$(tmux_get @dad_son_fingerprint)"
  tmux_set @dad_idle_action_sent_at "$(date -Is)"
  mark_state_after_prompt
}

submit_branch_consolidation_to_son() {
  reason="$1"
  if ! pane_accepting_input "$son_pane"; then
    tmux_set @dad_idle_controller_status waiting:son_busy_branch_consolidation
    return 2
  fi
  objective="$(objective_text)"
  branch_status="$(metadata_value @dad_branch_status 1000)"
  branch_problem="$(metadata_value @dad_branch_problem 1000)"
  prompt="$(cat <<EOF
DAD mechanical branch/commit discipline correction ($(date -Is)).

Original objective:
$objective

Current branch status:
${branch_status:-unknown}

Branch problem:
${branch_problem:-$reason}

Stop feature work until branch/commit discipline is resolved. Use the repo-approved current/session branch as the only workstream branch. If local instructions require a feature branch/worktree, create or select exactly one such branch before continuing and record it as the session branch. Do not create or switch to another branch unless the user explicitly asks. Inspect current uncommitted work and local branches, stage only relevant files, bring the useful work for this DAD objective onto the session/current branch, run the relevant checks, then commit the coherent delta locally on that same branch using Conventional Commits. Never bypass hooks. Do not fetch, pull, push, open a PR, or touch remotes unless explicitly requested.

Report changed files, local commit hash when committed, exact commands/checks, outcomes, and any remaining branch/worktree blocker.
EOF
)"
  if ! "$submit" --socket "$socket" --window "$window" --target "$son_pane" --expect-command grok --mode text --text "$prompt"; then
    tmux_set @dad_idle_controller_last_action failed_direct_son_branch_consolidation
    tmux_set @dad_idle_controller_last_reason "$reason"
    return 1
  fi
  tmux_set @dad_last_nudge_at "$(date -Is)"
  count="$(tmux_get @dad_nudge_count)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  tmux_set @dad_nudge_count "$((count + 1))"
  tmux_set @dad_idle_controller_last_action direct_son_branch_consolidation
  tmux_set @dad_idle_controller_last_reason "$reason"
  tmux_set @dad_idle_action_sent_at "$(date -Is)"
  mark_state_after_prompt
}

submit_degraded_continuation_to_son() {
  reason="$1"
  mode_label="${2:-idle_or_claim}"
  if ! pane_accepting_input "$son_pane"; then
    tmux_set @dad_idle_controller_status waiting:son_busy_degraded_continuation
    return 2
  fi
  objective="$(objective_text)"
  dad_state="$(tmux_get @dad_state)"
  failure_signature="$(tmux_get @dad_failure_signature)"
  verifier_verdict="$(tmux_get @dad_verifier_last_verdict)"
  evidence_status="$(tmux_get @dad_evidence_contract_last_status)"
  corrective_task="$(metadata_value @dad_last_corrective_task)"
  improvement_frontier="$(metadata_value @dad_improvement_frontier)"
  quality_research="$(metadata_value @dad_quality_research_summary)"
  quality_bar="$(metadata_value @dad_quality_bar)"
  quality_gap="$(metadata_value @dad_quality_gap)"
  quality_frontier="$(metadata_value @dad_quality_frontier)"
  reference_scout="$(metadata_value @dad_reference_scout_summary)"
  reference_frontier="$(metadata_value @dad_reference_scout_frontier)"
  reference_reuse="$(metadata_value @dad_reference_scout_reuse_notes 800)"
  reference_at="$(tmux_get @dad_reference_scout_last_at)"
  user_feedback="$(metadata_value @dad_last_user_feedback 800)"
  user_feedback_at="$(tmux_get @dad_last_user_feedback_at)"
  prompt="$(cat <<EOF
DAD degraded-supervision continuation ($(date -Is)).

The Dad supervisor is currently ${dad_state:-unavailable} (${failure_signature:-no failure signature}), so this instruction is mechanical degraded supervision, not acceptance of any claim.

Original objective:
$objective

Current Dad metadata:
- verifier_last_verdict: ${verifier_verdict:-unknown}
- evidence_contract_last_status: ${evidence_status:-unknown}
- last_corrective_task: ${corrective_task:-unknown}
- improvement_frontier: ${improvement_frontier:-unknown}
- quality_research: ${quality_research:-unknown}
- quality_bar: ${quality_bar:-unknown}
- quality_gap: ${quality_gap:-unknown}
- quality_frontier: ${quality_frontier:-unknown}
- reference_scout: ${reference_scout:-unknown}
- reference_frontier: ${reference_frontier:-unknown}
- reference_scout_last_at: ${reference_at:-unknown}
- recent_user_feedback: ${user_feedback:-none}
- recent_user_feedback_at: ${user_feedback_at:-unknown}
- degraded_reason: $reason

Act now without waiting for Dad or the user. Do not ask what to do next and do not offer options. Treat recent_user_feedback as the highest-priority human correction when present. Treat your last report and any prior "works/complete/gate-verified" claim as untrusted until backed by fresh independent evidence. Choose the first/highest-priority concrete item from last_corrective_task/reference_frontier/quality_frontier/improvement_frontier, inspect the current workspace state and recent logs/errors, then perform exactly one highest-value objective-aligned artifact-changing implementation delta. If this work is user-facing, creative, interactive, benchmark-like, or quality-sensitive and quality_bar/quality_frontier/reference_frontier is unknown, stale, local-only, or contradicted by recent evidence, do one bounded Reference Scout / Code Harvest pass using Grok online research/web access when available, or local references if not, then implement one concrete improvement that closes a quality_gap. Use a read-only researcher subagent/task when available, collect 3-5 concrete implementation references with source names/URLs, choose one behavior/API/UX pattern or example structure, and edit the workspace in this same turn. Verification-only is not acceptable unless it proves a specific recent artifact delta, reproduces a current failure, or satisfies a specific missing evidence gate. Never delegate verification to the user; if you wrote "test yourself" or equivalent, replace it by running/using the artifact yourself and reporting captured evidence.

Git discipline: use one repo-approved stable branch for this DAD workstream. If local instructions require a feature branch/worktree, create or select exactly one such branch before continuing and record it as the session branch. Do not create or switch to additional branches unless the user explicitly asks. Stage only relevant files. After a coherent artifact delta passes its relevant checks, commit it locally on the same branch using Conventional Commits. Never bypass hooks. If branch sprawl already exists, consolidate useful work onto the session/current branch and commit there before doing new feature work. Do not fetch, pull, push, open a PR, or touch remotes unless explicitly requested.

Coding standards: keep hand-authored files context-bounded. Run <DAD_ROOT>/bin/code-standards-check.py --root "\$(pwd)" before claiming this delta or completion. If it fails, split oversized hand-authored files before feature work.

If evidence is stale, failing, missing, contradicted by current state, or assertion-free, fix the blocker or produce fresh bounded real-use evidence. For user-facing software, actually use the artifact through the inferred core workflow and preserve action->effect proof: non-empty transcript/log/state plus at least one passed assertion. Do not declare final victory.
EOF
)"
  if ! "$submit" --socket "$socket" --window "$window" --target "$son_pane" --expect-command grok --mode text --text "$prompt"; then
    tmux_set @dad_idle_controller_last_action failed_direct_son_degraded_continuation
    tmux_set @dad_idle_controller_last_reason "$reason"
    return 1
  fi
  tmux_set @dad_last_nudge_at "$(date -Is)"
  count="$(tmux_get @dad_nudge_count)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  tmux_set @dad_nudge_count "$((count + 1))"
  tmux_set @dad_idle_controller_last_action direct_son_degraded_continuation
  tmux_set @dad_idle_controller_last_reason "$reason"
  tmux_set @dad_idle_controller_last_fingerprint "$(tmux_get @dad_son_fingerprint)"
  tmux_set @dad_idle_action_sent_at "$(date -Is)"
  tmux_set @dad_idle_controller_degraded_mode "$mode_label"
}

submit_plan_approval_to_son() {
  reason="$1"
  pane_text="$(tmux -S "$socket" capture-pane -t "$son_pane" -p -S -80 2>/dev/null || true)"
  tail_text="$(printf '%s\n' "$pane_text" | tail -24)"
  if printf '%s\n' "$tail_text" | grep -Eiq '^[[:space:]│┃]*::[[:space:]]*(Thinking(\.\.\.|…)|Responding|Running|Building|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing|Compacting)([[:space:][:punct:]]|$)|^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Run|Read|Edit|Search|Write|Apply|Thinking|Responding|Running|Building|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing|Compacting)|^[[:space:]│┃]*◆[[:space:]]+(Run|Read|Edit|Search|Write|Apply|Thinking)|^[[:space:]│┃]*Tool Use'; then
    tmux_set @dad_failure_signature stale_plan_approval_ui_during_active_son
    tmux_set @dad_idle_controller_status waiting:active_son_plan_approval_stale
    return 2
  fi
  if ! printf '%s\n' "$pane_text" | grep -Eiq 'a:approve|\[a\]pprove|q:quit plan|Waiting on plan approval'; then
    tmux_set @dad_idle_controller_status waiting:plan_approval_ui_not_visible
    return 2
  fi
  if ! "$submit" --socket "$socket" --window "$window" --target "$son_pane" --expect-command grok --mode key --literal-key a; then
    tmux_set @dad_idle_controller_last_action failed_son_plan_approval
    tmux_set @dad_idle_controller_last_reason "$reason"
    return 1
  fi
  approved=false
  for _ in 1 2 3 4 5 6 7 8; do
    interruptible_sleep 1
    pane_text="$(tmux -S "$socket" capture-pane -t "$son_pane" -p -S -60 2>/dev/null || true)"
    tail_text="$(printf '%s\n' "$pane_text" | tail -24)"
    if printf '%s\n' "$tail_text" | grep -Eiq '^[[:space:]│┃]*::[[:space:]]*(Thinking(\.\.\.|…)|Responding|Running|Building|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing)([[:space:][:punct:]]|$)|^[[:space:]│┃]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Run|Read|Edit|Search|Write|Apply|Thinking|Responding|Running|Building|Reading|Searching|Editing|Writing|Applying|Compiling|Testing|Installing|Fetching|Executing|Analyzing)|^[[:space:]│┃]*◆[[:space:]]+(Run|Read|Edit|Search|Write|Apply|Thinking)'; then
      approved=true
      break
    fi
    if ! printf '%s\n' "$tail_text" | grep -Eiq 'a:approve|\[a\]pprove|q:quit plan|Waiting on plan approval'; then
      approved=true
      break
    fi
  done
  if [[ "$approved" != true ]]; then
    tmux_set @dad_idle_controller_last_action failed_son_plan_approval_pending
    tmux_set @dad_idle_controller_last_reason "$reason"
    tmux_set @dad_idle_controller_status failed:son_plan_approval_pending
    return 1
  fi
  tmux_set @dad_idle_controller_last_action direct_son_plan_approval
  tmux_set @dad_idle_controller_last_reason "$reason"
  tmux_set @dad_idle_action_sent_at "$(date -Is)"
  tmux_set @dad_last_plan_approved_at "$(date -Is)"
  count="$(tmux_get @dad_plan_approval_count)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  tmux_set @dad_plan_approval_count "$((count + 1))"
  mark_state_after_prompt
  return 0
}

submit_pending_paste() {
  pane="$1"
  action="$2"
  reason="$3"
  if ! pane_accepting_input "$pane"; then
    return 2
  fi
  if ! pending_pasted_prompt "$pane"; then
    return 1
  fi
  if ! "$submit" --socket "$socket" --window "$window" --target "$pane" --expect-command grok --mode submit-existing; then
    tmux_set @dad_idle_controller_last_action "failed_$action"
    tmux_set @dad_idle_controller_last_reason "$reason"
    return 1
  fi
  tmux_set @dad_idle_controller_last_action "$action"
  tmux_set @dad_idle_controller_last_reason "$reason"
  tmux_set @dad_idle_action_sent_at "$(date -Is)"
  emit_event "$(date -Is)" "$action" "$reason"
  log "action $action reason=$reason"
  return 0
}

submit_to_dad() {
  action="$1"
  reason="$2"
  if ! pane_accepting_input "$dad_pane"; then
    tmux_set @dad_idle_controller_status waiting:dad_busy
    return 2
  fi
  objective="$(objective_text)"
  prompt="$(cat <<EOF
DAD mechanical supervision SLA ($(date -Is)).

The external DAD idle controller detected: $reason

Window: $window
Son pane: $son_pane
Original objective:
$objective

Act immediately according to current <DAD_ROOT>/DAD.md and <DAD_SKILL>. If this is plan approval, review and approve/comment through the Son UI. If this is a completion or evidence claim, run the verifier/evidence contract. Submit any Son instruction with plain Enter.
EOF
)"
  if ! "$submit" --socket "$socket" --window "$window" --target "$dad_pane" --expect-command grok --mode text --text "$prompt"; then
    tmux_set @dad_idle_controller_last_action "failed_$action"
    tmux_set @dad_idle_controller_last_reason "$reason"
    return 1
  fi
  tmux_set @dad_idle_controller_last_action "$action"
  tmux_set @dad_idle_controller_last_reason "$reason"
  tmux_set @dad_idle_action_sent_at "$(date -Is)"
}
