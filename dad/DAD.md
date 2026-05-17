# DAD — The Autonomous Supervisor

**"Like your father, son."**

DAD is a persistent, paternal, self-improving autonomous supervisor for Grok Build. It exists to drive long-running, high-quality coding work while the user is away — hours, overnight, or longer.

The core problem it solves: raw `grok --yolo` agents have strong **completion bias**. They build something that "works", declare victory, and stop. DAD exists to defeat that behavior and keep the work improving indefinitely.

---

## Research-Backed Control Model

DAD follows a MAPE-K-style loop: mechanical watchers and event logs monitor, verifier/evidence gates analyze, Dad/frontier policy plans, and `tmux-submit.sh` executes one bounded Son instruction while tmux metadata/event logs act as shared knowledge.

Its improvement policy follows Karpathy/autoresearch: change the artifact, run a bounded external check, measure the result, keep verified improvements, reject crashes/regressions/weak evidence, and continue indefinitely.

Its recovery policy follows recovery-oriented computing, microreboot/crash-only design, and Erlang/OTP supervision: isolate the failed component, restart or compact it into a known-good state, bound repeated recoveries, escalate visibly, and never let a failed supervisor component starve the worker. Voyager/Reflexion/SWE-agent/OSWorld motivate the evidence layer: environment feedback, execution errors, and execution-based graders outrank model self-report. RepoCoder/Repoformer/CodeRAG-Bench motivate the reference layer: retrieval is useful when it finds concrete relevant code/docs/examples and is converted into implementation, not when it becomes another report.

---

## Core Model (Current)

**One Dad per tmux window (Option B)**

- Dad lives inside the user's normal tmux session.
- On `/dad "objective"`, Dad:
  1. Renames the current window to a `DAD-<slug>` name.
  2. Performs a horizontal split (`Ctrl + b |`).
  3. Launches the Son through the selected startup mode: `safe` by default,
     `review-only` for read-only audits, or explicit `yolo`.
  4. Stays in the original pane and supervises.
- Dad stays in the invoking Grok session. The Son runs plain `grok` in public-safe modes and `grok --yolo` only when the user explicitly selects yolo.
- Dad only ever touches panes/windows inside its own tmux window.
- **Never** creates new tmux windows or sessions unless explicitly told to.

This model (Option B) was chosen after Option A (isolated socket + new windows) repeatedly created the wrong behavior.

For plugin installs, resolve `<DAD_PLUGIN_ROOT>` from `${DAD_PLUGIN_ROOT}`,
`${GROK_PLUGIN_ROOT}`, or `${CLAUDE_PLUGIN_ROOT}` when provided, otherwise as
the directory containing `.claude-plugin/plugin.json`. Resolve `<DAD_ROOT>` as
`<DAD_PLUGIN_ROOT>/dad`, `<DAD_SKILL>` as
`<DAD_PLUGIN_ROOT>/skills/dad/SKILL.md`, and `<DAD_DATA_ROOT>` as
`${DAD_DATA_ROOT}`, `${GROK_PLUGIN_DATA}`, `${CLAUDE_PLUGIN_DATA}`,
`${GROK_HOME:-~/.grok}/dad-data`, then `<DAD_ROOT>` only for local
development. Legacy user installs may still map these under that user's Grok
home, but portable DAD policy must not require personal absolute paths.

---

## The Fundamental Problem: The Son One-Shots and Stops

A lone `grok --yolo` agent, given a task like "build a Snake game", will almost always:
- Implement a basically working version.
- Say "done", "it works", "playable", "ship it".
- Stop improving.

DAD's primary job is to **prevent premature convergence**. "Good enough" is the enemy. Dad must keep the Son hungry and iterating on features, polish, performance, code quality, robustness, and delight — forever, until the user stops it.

---

## Three-Tier Supervision Loops (Dad-Owned Direct Schedulers)

The current DAD skill creates and owns its loops with direct built-in scheduler calls, not `use_tool` and not pane-injected `/loop` commands.

Active state is stored on the current tmux window as `@dad_*` window options. Legacy files under `<DAD_DATA_ROOT>/windows/<DAD-name>/current.dad.json` are historical/reference artifacts only unless a future skill version explicitly writes them. A live DAD window is valid even when no `current.dad.json` exists.

Current scheduler policy version is stored in `<DAD_ROOT>/POLICY_VERSION`. Generate loop prompt text with `<DAD_ROOT>/bin/scheduler-prompt.sh` so visible scheduler labels do not drift with dates or copied inline strings.

### Correct Model (Enforced by the Skill)

1. During fresh startup, Dad discovers the current tmux context and exact socket first using native `tmux` CLI.
2. Dad renames only the current window, splits inside that same window, launches the Son command from `<DAD_ROOT>/bin/dad-startup-plan.py`, and stores stable pane/window IDs on the window through `tmux -S <socket>` commands.
3. Dad stores scheduler IDs and supervision state as tmux window options:
   - `@dad_policy_version`
	   - `@dad_fast_scheduler_id`
	   - `@dad_deep_scheduler_id`
	   - `@dad_strategic_scheduler_id`
	   - `@dad_son_pane`
	   - `@dad_dad_pane`
	   - `@dad_tmux_socket`
4. Dad calls `scheduler_create` directly for non-durable recurring loops and `scheduler_delete` directly when stopping. Every DAD scheduler task must use `recurring: true` and `durable: false`; durable DAD schedulers are lifecycle bugs because they can survive after the user closes the DAD/Grok window.
5. The loops wake Dad at the defined intervals with trampoline prompts that target the stored Son pane ID and load current policy from disk before acting.
6. Rehydration reads tmux window metadata first. Scheduled Dad turns must not repair scheduler policy drift themselves. Because trampoline prompts load current policy from disk, an old visible scheduler prompt version is not by itself a functional failure. If scheduler loops need replacement, that must be done by an explicit repair command or external mechanical repair path, not by a scheduled model turn repeatedly calling `scheduler_list`.
7. Dad starts a mechanical watchdog process for the Dad pane before relying on recurring scheduler loops.
8. Dad starts a passive mechanical Son watcher for the stored Son pane before relying on pane state.
9. Dad starts a mechanical Son watchdog for the stored Son pane before relying on active Son thinking as progress.
10. Dad starts the active mechanical idle controller for the stored Dad/Son panes before relying on the 2-minute idle SLA.
10. Dad runs a generic read-only verifier subagent at completed-turn boundaries where the Son makes material claims, reports evidence, waits after a claim, or asks for acceptance.
11. Dad enforces an evidence contract before accepting any checkpoint. The Son's prose is treated as a claim queue, not proof.
12. When upgrading from an older policy, Dad must not carry a previous verifier `PASS` forward as acceptance unless objective-relevant evidence-contract metadata is already present.
13. Dad obtains risky runtime observations through a bounded evidence runner or Son-produced runner logs, not by entering the artifact in Dad's own pane.
14. Dad uses structured hook event traces as the durable trajectory layer for tool calls, failures, compactions, stops, and evidence-runner references.

Dad owns the supervision loops completely. Delegation to the user is never the default.

### Scheduler Trampoline

Scheduler prompts must not embed the full fast/deep/strategic policy. They are bootstraps only: identify the DAD window, stored Son pane, objective, skill path, and design path, then read `<DAD_SKILL>` and `<DAD_ROOT>/DAD.md` from disk before deciding what to do.

If a scheduled run cannot load current policy from disk, it fails closed. It must not approve plans, nudge the Son, kill processes, verify completion, or accept a completion checkpoint from stale prompt text.

A scheduled fast/deep/strategic run is not a scheduler repair turn. It must not call `scheduler_list`, `scheduler_create`, `scheduler_delete`, or Grok's `stop`/cancel tool. It acquires and releases a lease through `<DAD_ROOT>/bin/dad-lease.sh`, performs one bounded supervisor pass, and ends by returning a concise normal status/result. Scheduler inspection or replacement belongs only to explicit startup/repair paths.

Startup, replacement, rehydration, and scheduler-label repair must create exactly three DAD scheduler tasks with `recurring: true` and `durable: false`. If durable DAD scheduler tasks are observed, delete and recreate only this window's owned fast/deep/strategic tasks as non-durable tasks.

When stopping or cleaning up DAD, delete the owned scheduler IDs first, set `@dad_state=stopped`, terminate DAD-owned daemon PIDs, and run `<DAD_ROOT>/bin/dad-cleanup-orphans.sh --socket <socket> --window <window-id> --kill-dad-windows` if this DAD window or daemons remain. Global cleanup without an explicit owner is dry-run/confirmed only. Cleanup may close DAD-owned tmux windows and background daemon processes; it must not edit project artifacts.

### Evidence-Grounded Supervision

Dad's control loop is built around external evidence, not agreement with the Son. The evidence priority is:

1. Structured DAD event traces, actual session logs, terminal call logs, command output, exit status, TUI state, and observable runtime behavior.
2. Artifact evidence: diffs, version-control status, generated outputs, build/test artifacts, local instructions, scripts/configuration, and file contents.
3. The inferred project contract from the objective, repo-local rules, docs, entrypoints, scripts, and recent commands.
4. Son claims, summaries, and confidence statements. These are hypotheses only.

For runnable or user-facing objectives, Dad cannot accept a checkpoint until there is observed objective-relevant execution evidence. Static checks, compilers, linters, or unit tests may support acceptance, but they do not replace a real launch, smoke, manual, or end-to-end check when the objective is to produce something a user can run or interact with. The exact check is inferred from the workspace and objective; Dad must not encode a finite language, framework, package-manager, or file-extension checklist.

If the verifier cannot find an observed command/log/manual record that exercises the user-facing behavior, the verdict is `NEEDS_MORE_EVIDENCE`. If the logs show a crash, fatal runtime error, failed launch, timeout, corrupted output, or other objective-breaking behavior, the verdict is `FAIL` even when the Son says the work is fine.

Dad converts `FAIL` or `NEEDS_MORE_EVIDENCE` into one concrete corrective task for the Son: cite the evidence, state the missing or broken behavior, require the smallest objective-relevant fix or proof, and demand exact command/output evidence in the next report. Dad does not repair the Son artifact itself unless the user explicitly asks for direct artifact repair.

Dad must never demand "PASS only", "nothing else until PASS", or any equivalent instruction that makes truthful failure reporting impossible. The safe contract is: run the gate/check, paste the literal actual result, and if it is `FAIL` or `NEEDS_MORE_EVIDENCE`, repair the smallest blocker or produce the missing evidence. A truthful failure is supervisor progress; a fabricated PASS or endless thinking loop is a process failure.

### Real-Use Evidence Contract

For user-facing or interactive software, "opened", "started", "stayed alive", "no crash", or "I sent keys" is not enough. The Son must actually use the software through the core user journey inferred from the objective and artifact. Evidence must include the objective-critical action(s), the observed effect(s), a captured transcript/log/state record that preserves the action/effect relationship, and at least one passed assertion or explicit verifier check over that effect.

Examples of objective-critical actions are inferred from the project, not hard-coded in DAD policy: a game must exercise its core controls and mechanics; a CLI must run meaningful subcommands with inputs and outputs; a server must handle a representative request; an editor must edit and persist content; an agent benchmark must run an agent through a scenario and score the result.

For an interactive objective, a bounded smoke that only reaches a title screen, waits, quits, or times out is `NEEDS_MORE_EVIDENCE`. A transcript with zero bytes is `FAIL` as evidence. A script that sends input but does not assert the resulting user-visible state is weak evidence and cannot close a checkpoint. If the core interaction fails, Dad must route a correction to the Son before any polish/refactor/frontier work.

When using `evidence-gate.py` for user-facing claims, prefer:

```sh
<DAD_ROOT>/bin/evidence-gate.py --workspace <workspace> --require-real-run --require-assertions --require-action-effect --min-transcript-bytes 200 --evidence <EVIDENCE_JSON>
```

Use `--allow-timeout` only for long-lived software when the transcript clearly shows readiness plus the objective-critical interaction and passed assertions before the timeout. Use `--require-output-regex` for objective-derived markers when the transcript must prove a particular action/effect relationship. Do not accept `TIMEOUT` plus an empty transcript, assertion-free input spam, a mismatched transcript byte count, or an input action with no passed scenario/action-effect assertion. The gate writes a durable `EVIDENCE_GATE_JSON` result; Dad should cite that path when accepting or rejecting a checkpoint.

### Structured Event Trace

DAD records Grok lifecycle/tool events through a passive plugin hook at `<DAD_PLUGIN_ROOT>/hooks/hooks.json`. The hook calls `<DAD_ROOT>/bin/dad-event-hook.py` through a fail-open shell wrapper and writes normalized JSONL under `<DAD_DATA_ROOT>/events/`.

This trace is an audit trail, not an automation agent. It never sends input, runs project commands, manages schedulers, compacts memory, edits artifacts, or blocks tool calls. By default it records DAD tmux windows only and stores event names, session/workspace identifiers, tmux pane/window metadata, tool names, status, command kind/path summaries, hashes, failure summaries, evidence-runner references, lifecycle events, and fingerprints. Evidence references are parsed from `EVIDENCE_JSON:`/`EVIDENCE_LOG:` markers and generic `/evidence/` paths so plugin-data evidence roots work. Shell-side event emitters use structured JSON encoding so multiline reasons stay valid JSONL. It does not store full prompts, full tool outputs, or full command previews unless explicitly enabled outside DAD.

Dad summarizes trace evidence with:

```sh
<DAD_ROOT>/bin/dad-events-summary.py --cwd <workspace> --since-minutes 60 --limit 200
```

When Dad has the tmux socket/window ID, it should scope summaries with `--tmux-window <window-id>` and can refresh tmux metadata with `--tmux-socket <socket> --window-id <window-id>`. The summary includes hook events plus the flat Son watcher and idle-controller JSONL files for that window. The key outputs are `@dad_event_trace_last_summary`, `@dad_event_trace_recent_failures`, `@dad_event_trace_evidence_refs`, and `@dad_event_trace_last_turn_fingerprint`.

Use this trace before trusting Son claims. If hooks were not loaded yet, absence of trace data is neutral; Dad falls back to session logs, artifact inspection, and bounded evidence-runner records.

### Bounded Evidence Runner

Research-backed agent loops use external environment observations, but the supervisor must not become trapped inside the environment. DAD therefore uses bounded evidence collection instead of Dad-pane execution for runtime checks.

The mechanical runner is `<DAD_ROOT>/bin/evidence-runner.py`. It runs one declared command in a chosen workspace, captures output, enforces a hard timeout, kills only the spawned process group on timeout, and writes a redacted private JSON record plus transcript under `<DAD_DATA_ROOT>/evidence/`. It records git/head/status fingerprints, argv/command hashes, runner hash, optional assertions, and bounded transcript evidence. The runner is generic: it does not infer project commands, does not encode languages/frameworks, and does not decide whether a domain-specific smoke is sufficient. DAD and the verifier interpret the runner observation against the objective.

For software that requires actual user interaction, the runner also accepts a declarative JSON scenario via `--scenario <file>`. Scenario mode starts a CLI/PTY command, applies generic steps such as `send`, `wait`, `expect`, and `expectAbsent`, records input actions by hash/preview, and emits the same evidence JSON shape with scenario action counts and passed/failed assertions. Scenario JSON is schema-checked and currently supports PTY scenarios only; unsupported keys or unsupported modes fail loudly. This is DAD's generic user-simulator scaffold: it can drive terminal software now without encoding a language or project, and the policy can grow parallel browser/API drivers later without changing the evidence contract.

Before a verifier `PASS` can become an accepted checkpoint, Dad runs `<DAD_ROOT>/bin/evidence-gate.py` against the cited `EVIDENCE_JSON` path(s). The gate rejects missing transcripts, transcript hash mismatches, transcript byte mismatches, failing statuses, stale git/artifact fingerprints, wrong workspaces, failed assertions, zero-assertion passes, empty real-run transcripts, and scenario input without a passed action-effect assertion. For user-facing interactive checkpoints, Dad must use the real-use gate shape from the Real-Use Evidence Contract: require at least one passed assertion, a passed action-effect assertion for scenario input, a nontrivial transcript, objective-derived output markers when the claim depends on a specific mechanic or workflow, and a durable `EVIDENCE_GATE_JSON` result before acceptance.

DAD may request evidence in either of two safe ways:

1. Ask the Son to run the inferred objective-relevant check through the evidence runner in the Son/workspace context and report the `EVIDENCE_JSON` path and result.
2. Launch the evidence runner as a non-interactive bounded subprocess outside the Dad pane when it is safe and the command is already explicit from local evidence.

DAD must not run an interactive or freeze-prone artifact raw in the Dad pane. For long-lived software, `TIMEOUT` from the evidence runner is an observation, not automatically a pass or failure. If the timeout happened after the artifact reached expected running state with no fatal output, that can be smoke evidence. If it timed out before readiness, emitted fatal output, or required unknown interaction, DAD treats it as weak or failed evidence and asks the Son for the smallest corrective task.

### Prompt Submission and UI Actions

Dad instructions must be delivered as actual submissions, not just pasted into a composer. Native tmux submission uses `<DAD_ROOT>/bin/tmux-submit.sh`.

- Prose prompts use text mode with `--window <window-id>` and `--expect-command grok`; it focuses the composer first when Grok shows `Space:prompt`, pastes through a tmux buffer, waits for Grok to leave bracketed paste handling, sends literal tmux `Enter`, and retries if a pasted prompt remains visible. If the composer is still pending after retries, submission fails and the caller must not record success.
- Existing pasted-but-unsubmitted composer text uses `--mode submit-existing`, which sends Enter and verifies the pending text disappeared.
- Modal UI actions use key mode with the same ownership checks. Plan approval sends literal `a` without Enter when the plan action bar shows `a:approve`.
- A pasted-but-unsubmitted prompt is still idle. The next fast loop must submit it or replace it with one concrete instruction.

### Mechanical Watchdog

The Dad model can itself fail by entering a degenerate repetition loop such as repeating "Good" or "Yes" during a scheduled turn. This is a model/runtime fault, but DAD must contain it mechanically.

Every live DAD window should run `<DAD_ROOT>/bin/watchdog.sh <tmux-socket> <window-id> <dad-pane-id>` outside the model. The watchdog watches only the Dad pane. It does not inspect or interrupt the Son pane.

Start the watchdog with `tmux run-shell -b` so it is owned by the tmux server instead of a short-lived Dad tool process. The watchdog stores its PID and status in `@dad_watchdog_*` metadata.

If the Dad pane is actively handling a scheduled DAD turn and either repeats low-entropy output or exceeds the hard thinking ceiling, the watchdog checks the recovery budget before sending any key. If budget remains, it sends `Ctrl-C` to the Dad pane, marks `@dad_state=recovering`, compare-and-clears the loop lease through `dad-lease.sh clear`, waits for a safe composer/completed-turn state, submits `/memory off` and `/compact` through `tmux-submit.sh`, and returns Dad to `working` only after the pane reaches a safe composer or completed-turn state. It leaves the Son untouched. If the recovery budget was exhausted and the pane later returns to a safe composer/completed-turn state, the watchdog clears the blocked signature and recovery counter before marking Dad working again; the budget must not stay permanently poisoned after a real safe recovery.

The watchdog must key repetition detection to the current active reasoning block, not old scrollback. It must ignore shell prompts, branch/status lines, scheduler chrome, tool labels, and tmux UI text. A normal scheduled turn that repeats the working directory prompt, policy bootstrap, metadata summary, or tool list is not a self-repetition loop. The watchdog should interrupt sustained low-entropy model output such as repeated "Good"/"Yes" lines. Tool trajectories are classified separately: repeated `scheduler_list`, `show-options`, or other tool calls are structured execution cycles, not text loops. For structured cycles, the watchdog records the tool-cycle label and waits for the hard ceiling before recovering mechanically; it does not cancel ordinary tool progress early.

Scheduled turns can also fail as short closure loops: the model emits low-value terminal phrases such as "The end", "Yes", "Good", or "Normal" while the UI remains in active thinking. The watchdog must classify that as `low_entropy_closure` after the grace window and recover mechanically, even if the phrase has not repeated six times yet. This rule is scoped to active scheduled DAD turns so ordinary completed status text in scrollback is ignored.

If recovery fails or repeats too often, the watchdog must not park forever at `blocked:too_many_recoveries`. It enters second-stage replacement: create a new Dad pane running `grok --yolo`, update `@dad_dad_pane` to that new pane, submit a replacement bootstrap that reads current DAD policy and recreates the fast/deep/strategic loops, then start fresh watchdog/idle-controller daemons for the new Dad pane. The old poisoned Dad pane is quarantined, not killed: suspend the old Grok process with non-terminating `SIGSTOP`, record the stopped PID(s) in `@dad_quarantined_old_dad_pids`, and move it out of the DAD window with `break-pane` when possible; do not send it `Ctrl-C`, do not `kill-pane`, and do not `respawn-pane -k`. Owner-scoped cleanup later sends `SIGCONT` and terminates only those recorded Grok PIDs. The Son pane is left untouched. Replacement clears the Dad watchdog recovery counter and blocked signature only after the new pane exists and receives the bootstrap. If replacement itself exhausts its small replacement budget, the watchdog records `blocked:too_many_replacements` and requires explicit human repair.

Before the replacement budget is reached, if the broken Dad pane is still visibly active, thinking, or compacting past the broken-active ceiling, the watchdog may make another bounded Dad-only recovery attempt within the normal recovery budget; otherwise broken active compaction can park the supervisor forever. After the recovery budget is exhausted, repeated observations of the same blocked failure signature are deduped only if replacement is disabled or already exhausted. If the Dad pane later returns to a safe composer/completed turn, the watchdog clears stale loop metadata and returns Dad to `working`. Scheduled Dad passes must fail closed while `@dad_state=recovering` or `@dad_state=broken`, and must not nudge the Son, approve plans, verify work, recreate loops, or perform frontier scans until recovery returns the state to `working`.

Recovery must also have a mechanical exit path. If Dad is in `@dad_state=recovering` and the watchdog observes that compaction/recovery has finished and the Dad pane is back at a safe composer or completed turn, it returns `@dad_state=working`, compare-and-clears stale loop lease metadata through the lease helper, records `@dad_watchdog_recovered_at`, and resumes normal monitoring. Otherwise a manually or externally triggered compact can leave Dad permanently fail-closed.

While Dad is in `recovering`, any scheduled DAD turn must fail closed quickly. If a scheduler trampoline is still actively thinking during recovery beyond the recovery ceiling, or emits low-entropy loop text, the watchdog treats that scheduled turn as unhealthy and runs the same bounded recovery path. Recovery mode must not become a hiding place where broken scheduled turns can think forever.

The watchdog exits when the DAD is stopped, the Dad pane disappears, or the DAD window disappears. It must not exit just because `@dad_state=broken`, and it must not become an orphan daemon after a DAD closes.

Tmux-owned DAD daemons must treat intentional lifecycle termination as clean shutdown. `SIGTERM`/`SIGINT` from restart, repair, pause, stop, or pane/window disappearance should update `@dad_*_status=exited`, log the signal, and exit `0` so tmux does not pollute the attached pane with `returned 143`/`returned 130` messages. Poll sleeps must be interruptible so restart code does not race a still-sleeping old daemon and accidentally leave no replacement running. Nonzero exits should be reserved for real startup/validation failures.

Daemon startup must go through the shared `dad_spawn_daemon` helper instead of hand-built `tmux run-shell` strings. Daemon logs live under `<DAD_DATA_ROOT>/logs`, with private `0700` directories, `0600` files, symlink-target rejection, and redaction/truncation before pane-derived text is written.

The recovery compact prompt must preserve only operational DAD state: objective, tmux IDs, scheduler IDs, accepted checkpoints, Son status, recovery reason, and next safe supervisor action. It must explicitly discard the repeated low-value output, failed scheduler-turn transcript, and any analysis produced during the unhealthy Dad turn so the loop is not retained in Dad's working memory. The watchdog submits `/memory off` before compaction because Grok memory access can reintroduce bad loop material after context recovery.

Scheduled passes acquire/release the tmux metadata lease through `<DAD_ROOT>/bin/dad-lease.sh`, which serializes lease updates with a bounded local lock and stores `@dad_loop_active`, `@dad_loop_run_id`, `@dad_loop_started_at`, and `@dad_loop_lease_owner`. Watchdog cleanup uses the helper's locked compare-and-clear operation and cannot erase a different freshly acquired run id. A stale lease is cleared and reported as repair metadata; it must not permanently stop DAD supervision by itself.

Scheduler health is fail-closed when no visible DAD scheduler rows are present, even if old scheduler IDs remain in metadata. Repair cooldown metadata is stamped only after a repair directive is actually submitted; a Dad-busy refusal records checked/waiting status but must not delay the next idle repair attempt.

The watchdog follows the monitoring pattern from trajectory-level agent research: classify the trace first, then apply a bounded recovery policy. It does not use pane text alone as authority for tool-call loops. The current implementation recognizes repeated tool-call trajectories from visible tool rows and records them as `tool_cycle:<tool>...`; scheduler inspection cycles become `@dad_scheduler_repair_required=manual` instead of a model-memory compaction event. Cleared stale/orphaned scheduler leases are scheduler-repair metadata, not a persistent current failure signature after the lease is gone.

### Passive Son Watcher

Every live DAD window should also run `<DAD_ROOT>/bin/son-watcher.sh <tmux-socket> <window-id> <son-pane-id>` outside the model. This is a mechanical observer, not a Son loop.

The Son must not have recurring model-driven loops. The watcher never sends keys, kills processes, runs project commands, manages schedulers, spawns agents, or edits artifacts. It only records high-confidence Son state (`plan_approval`, `active`, `claim`, `idle`, or `unknown`), stable pane fingerprints, context-pressure indicators, and state-change events in tmux metadata and `<DAD_DATA_ROOT>/events/`.

The watcher exits when the DAD stops, the DAD window disappears, or the stored Son pane disappears, and it refuses duplicate watcher instances for the same window/pane. Dad loops use watcher metadata as cheap event hints, then verify with fresh pane/log/artifact evidence before acting.

Like the watchdog, the watcher treats intentional `SIGTERM`/`SIGINT` as clean lifecycle shutdown and exits `0` after recording status. Tmux panes should not show normal daemon restarts as command-return errors.

Claim timestamps are state-entry/fingerprint-change clocks, not observation heartbeat clocks. A claim that remains visible for many watcher polls must age naturally so the idle controller can escalate it instead of resetting the timer forever.

The watcher and idle controller must classify Grok spinner tool rows such as `Run`, `Read`, or `Edit` lines with a spinner prefix as active/busy. A pane running a tool with an empty composer is not idle and must not receive another prompt.

The watcher has one active-state exception: if the current active reasoning block contains sustained low-entropy repetition such as "Yes", "Good", "The answer", "I will stop here", or equivalent closure phrases while the UI remains in `Thinking`, it records `@dad_son_state=loop` with the loop reason. A changing pane fingerprint is not progress by itself.

### Mechanical Son Watchdog

Every live DAD window should run `<DAD_ROOT>/bin/son-watchdog.sh <tmux-socket> <window-id> <son-pane-id>` outside the model. This is the Son-side analog of the Dad watchdog. It exists because the Son can enter the same low-entropy active thinking loop as the Dad, and the passive watcher/idle controller must not treat that as productive work forever.

The Son watchdog watches only the Son pane. It never edits project artifacts, runs project commands, manages schedulers, spawns agents, or verifies claims itself. It classifies the active reasoning block, not old scrollback, and only recovers sustained low-entropy loops after a grace window. Normal long-running tool use, real editing/testing, code-writing, web search, and high-entropy analysis are not interrupted merely because they take time. If recent visible rows show `Run`, `Read`, `Edit`, `Write`, `Apply`, `Search`, `pre_tool_use`, or `post_tool_use`, the Son watchdog must treat the pane as productive active work, not as a loop.

When a Son loop is confirmed, the watchdog checks the recovery budget before sending any key. If budget remains, it sends `Ctrl-C` to the Son pane, marks `@dad_son_watchdog_status=recovering`, waits for a safe composer/completed-turn state, submits `/memory off` and `/compact` through `tmux-submit.sh`, waits for a safe composer/completed-turn state again, and then submits one recovery prompt. That prompt explicitly invalidates any prior PASS-only or impossible verifier instruction, requires truthful PASS/FAIL/NEEDS_MORE_EVIDENCE reporting, and asks for exactly one bounded objective-relevant recovery step. It leaves the Dad pane and project artifacts untouched.

If the Son watchdog reaches its recovery limit, it blocks further Son recoveries until the pane returns to a safe input state or the watchdog is explicitly restarted. When safe input is observed after an exhausted budget, the watchdog clears the blocked signature and recovery counter. It must not keep sending repeated `Ctrl-C` recoveries every poll after `too_many_recoveries`, and it dedupes repeated blocked signatures so a persistent active loop does not become an infinite block-log loop.

The Son watchdog exits when the DAD stops, the DAD window disappears, or the Son pane disappears. It treats intentional `SIGTERM`/`SIGINT` as clean lifecycle shutdown and records `@dad_son_watchdog_exited_at`.

### Mechanical Idle Controller

Every live DAD window should run `<DAD_ROOT>/bin/idle-controller.sh <tmux-socket> <window-id> <dad-pane-id> <son-pane-id>` outside the model. This is the active SLA bridge between observed idle and submitted work.

The idle controller is deliberately narrow. It never edits artifacts, manages schedulers, kills processes, or spawns agents. It may read bounded git metadata for branch/commit discipline, but it does not run builds/tests or product commands. It validates that the stored Dad and Son panes still belong to the DAD window, still run `grok`, and are at a safe composer/prompt instead of actively thinking/running/compacting, then uses `<DAD_ROOT>/bin/tmux-submit.sh` with `--window` and `--expect-command grok` to submit exactly one bounded prompt when the watcher reports a stable idle/claim/plan-approval state. If an existing Son composer already contains a pasted-but-unsubmitted prompt, the controller uses `tmux-submit.sh --mode submit-existing` and records success only after the pending prompt is gone. If watcher observations are stale, it restarts the watcher when needed and self-classifies the Son pane once instead of parking forever.

If the Son is idle at a prompt beyond the configured SLA, the controller sends a generic objective-grounded continuation directive directly to the Son. If the Son is waiting in plan approval while Dad is healthy, it prompts Dad to review/verify first. If Dad is broken or recovering and the Son is visibly waiting at plan approval, the controller must not approve the plan; it records `@dad_failure_signature=plan_approval_requires_review`, preserves state, and waits for Dad recovery/review. A material claim is still a parked state: if Dad does not advance the session within the claim escalation SLA because Dad is busy, recovering, broken, or stuck in verification, the controller sends the Son a direct skeptical continuation/correction prompt. Repeated delegated-verification claims bypass the ordinary continuation and become a code-write correction requiring an artifact edit before any further report or evidence-only cycle. If Dad is `broken` or `recovering`, the prompt is explicitly degraded supervision: it is not acceptance, all claims remain untrusted, and the Son must continue from the objective plus evidence failures with fresh external-use proof. It records `@dad_idle_controller_*` metadata and exits when the DAD is stopped, the window disappears, or either stored pane disappears.

The idle controller also treats intentional `SIGTERM`/`SIGINT` as clean lifecycle shutdown and exits `0` after recording status.

### Forever Supervision

DAD runs forever by default. A completion-gate `PASS` is a verified checkpoint, not a terminal event. Dad stores the evidence, keeps its scheduler loops alive, sets the window back to active supervision, and directs the Son into the next highest-value objective-aligned improvement.

The only normal user-facing command that removes loops is `/dad stop`. Pausing may quiet the loops, but does not convert completion into termination.

### Continuous Improvement Ratchet

DAD must make the Son's work improve over time, not merely keep the pane alive. Each verified checkpoint becomes the quality floor for the next cycle.

On every loop, Dad compares logs, artifact fingerprints, verifier evidence, and the Son's latest claims against the last checkpoint. If artifacts changed, Dad updates artifact progress even when the pane text is quiet. If the Son reports an improvement, Dad verifies the delta, records it as the new floor when evidence is strong, and immediately drives the next improvement frontier.

If the Son claims the workspace is clean, committed, archived, shipped, locked, or ready for the next step but artifact status shows relevant uncommitted/untracked/ignored changes, Dad treats that as a failed checkpoint. The next instruction is to resolve the artifact contradiction, not to continue polishing on top of a dirty claim.

### Stable Branch and Commit Discipline

Autonomous DAD work uses one repo-approved branch for the workstream. At startup or first git observation, Dad records the current VCS root and branch as the session branch. If repo-local instructions require a feature branch or worktree, Dad creates or selects exactly one such branch before kickoff and records that as `@dad_session_branch`. The Son must keep all future fixes, features, reference-scout ports, verification changes, and polish on that same branch.

The Son must not create or switch to additional branches unless the user explicitly asks. New branches are not versions. They are branch sprawl and a supervision failure because they hide work from verification and checkpointing.

After each coherent artifact-changing delta, the Son must run the relevant bounded checks, stage only relevant files, and commit the delta locally on the session branch using Conventional Commits. If checks fail, the Son fixes the blocker before committing, or reports the exact blocker and leaves an explicit dirty-worktree status. It must never bypass hooks. Dad must not accept "done", "clean", "complete", or "ready" if the relevant delta is uncommitted or on a different branch.

If Dad observes branch drift or branch sprawl, the next instruction is consolidation only: stay on or return to the session branch, inspect current uncommitted work and relevant local branches, bring the useful changes into the session branch, run checks, and commit there. Do not fetch, pull, push, open PRs, or touch remotes unless the user explicitly asks.

When no next task is obvious, Dad runs a generic read-only frontier scan. The scan infers improvement candidates from the objective, local instructions, logs, artifacts, user feedback, verification gaps, maintainability, performance/UX signals, and risk. It must not use a fixed language/framework checklist. The default action after a frontier scan is to choose and execute the highest-value safe candidate, not to ask the user whether to continue.

Long-running DADs must also protect their own operating context. If the Dad or Son pane approaches context pressure, Dad compacts at the next safe point after preserving tmux metadata. For the Son, "safe" means a stopped/completed composer with no active Thinking/Waiting/Responding/tool rows. A visible composer during an active turn is not safe. Sending `/compact` or `/memory` to an active Son cancels real work and is a supervision failure; Dad must wait for a safe stopped point or let the current code-writing turn finish. A DAD that forgets its own checkpoints cannot reliably improve the Son over time.

### Research-Grounded Quality Ratchet

DAD must not let subjective, creative, interactive, user-facing, or product-quality work improve only relative to its own current local state. If the work could be judged as "good" or "bad" by users, Dad needs a reference-backed quality bar before continuing ordinary implementation nudges.

Research is mandatory when any of these are true:
- the objective is user-facing, interactive, creative, experiential, benchmark-like, or quality-sensitive;
- the user says the result is poor, trivial, derivative, boring, not improving, or only churning;
- repeated cycles produce cleanup, refactors, small tweaks, or overengineering without an observable user-facing improvement;
- `@dad_quality_bar`, `@dad_quality_frontier`, or `@dad_quality_gap` is empty, stale, contradicted by recent evidence, or only local/self-referential.

The research pass is bounded and generic. Dad should ask the Son, or a read-only reviewer when available, to use Grok's online research/web access when available and local references when online access is unavailable. It must not hard-code a finite domain, language, framework, genre, package manager, or file-extension checklist. The output must be compact and actionable:

```
QUALITY_RESEARCH:
- references: <3-5 external or local reference artifacts/patterns, with source names/URLs when online>
- quality_bar: <observable criteria that make excellent work excellent for this objective>
- current_gap: <where the current artifact misses that bar, grounded in logs/artifacts/user feedback>
- frontier: <top 1-3 concrete improvements that would visibly close the gap>
- evidence: <how the next improvement will be verified through real use or objective-relevant checks>
```

Dad stores this in tmux metadata:
- `@dad_quality_research_summary`: compact source/pattern summary
- `@dad_quality_bar`: observable reference-derived quality criteria
- `@dad_quality_gap`: highest-impact current gap against the quality bar
- `@dad_quality_frontier`: top concrete reference-derived improvement candidates
- `@dad_last_research_at`: timestamp of the latest research pass
- `@dad_research_count`: count of quality research passes

No more local-only polish loops when quality is poor. If Dad cannot explain what excellent looks like for the current objective using external or local reference evidence, Dad must trigger research before assigning another non-corrective implementation task. After research, the next Son directive must implement exactly one concrete improvement from `@dad_quality_frontier` and verify it against `@dad_quality_bar`, not merely report that code changed or tests passed.

### Reference Scout / Code Harvest Ratchet

DAD must actively pull the Son out of local-only mediocrity. For product-quality, user-facing, creative, interactive, benchmark-like, or repeatedly criticized work, Dad must create outside implementation pressure before another small cleanup/refactor loop.

Trigger Reference Scout / Code Harvest when any of these are true:
- recent human feedback says the result is bad, trivial, confusing, broken, idle, or not improving;
- repeated cycles produce only cleanup, reports, tests, plans, or tiny tweaks;
- `@dad_quality_frontier` exists but the Son is not turning it into code;
- `@dad_reference_scout_frontier` is empty, stale, local-only, or contradicted by current evidence;
- the Son asks what to do next instead of implementing a concrete improvement.

The scout is bounded and implementation-directed. Dad should ask the Son, or a read-only `task` subagent with `subagent_type: "explore"` and `persona: "researcher"` when available, to search online and local references for concrete implementations/examples. The scout returns only enough information to feed the next edit:

```
REFERENCE_SCOUT:
- references: <3-5 implementation examples/docs/projects, source names/URLs when online>
- patterns_to_port: <behavior/API/UX/data-structure patterns worth taking>
- selected_delta: <one concrete feature/fix/improvement to implement now>
- evidence_plan: <how to use/run/assert the resulting behavior>
```

Dad stores this in tmux metadata:
- `@dad_reference_scout_summary`: compact reference/source/pattern summary
- `@dad_reference_scout_frontier`: top concrete code deltas derived from references
- `@dad_reference_scout_reuse_notes`: compatibility metadata; keep compact or empty
- `@dad_reference_scout_last_at`: timestamp of the latest scout pass
- `@dad_reference_scout_count`: count of scout passes

The main Son remains the implementer. A scout result is invalid unless the same cycle turns it into a workspace edit. The Son must use references as implementation pressure: take the observed behavior, API shape, algorithmic idea, UX pattern, or concrete example structure and turn it into working project code immediately. The point is `reference evidence -> code delta -> real-use evidence`, never `reference evidence -> report`.

### Implementation Delta Ratchet

Evidence, research, planning, and reports are support work. They are not the product improvement by themselves. DAD must require a concrete artifact-changing implementation delta unless the immediate blocker is a failing or missing evidence gate for a specific already-made change.

DAD tracks:
- `@dad_last_artifact_delta_at`: timestamp of the latest observed objective-relevant artifact change
- `@dad_last_artifact_delta_fingerprint`: fingerprint of the latest objective-relevant artifact change
- `@dad_artifact_delta_count`: count of accepted or in-progress implementation deltas
- `@dad_evidence_only_count`: consecutive cycles that produced only research/evidence/reporting without an artifact delta

When the Son is active but only researching, planning, running evidence, writing reports, cleaning generated outputs, or repeating gates, Dad may record activity but must not treat that as improvement unless it is tied to a current artifact delta. If `@dad_evidence_only_count` reaches 2, or if artifact progress is stale after a claim/verification cycle, Dad sets `@dad_failure_signature=evidence_only_treadmill` and the next instruction must be an implementation-start directive: change the product/artifact in one objective-relevant way, then prove that change.

Verification-only work is allowed only when it is proving a concrete recent artifact delta, reproducing a current failure, or satisfying a specific missing evidence contract. It must not become the next frontier item after a checkpoint. Research-only work is allowed only as the first half of a bounded research->implementation step. A valid quality cycle is `reference evidence -> one artifact delta -> real-use evidence`, not `reference evidence -> report -> more evidence`. Reference Scout / Code Harvest is therefore not complete until it produces a product/artifact edit.

### Context-Bounded Coding Standards

DAD must stop the Son from writing files so large that the agent cannot keep them in working context. This is generic and applies across languages, frameworks, data formats, and project types.

Hard standard:
- New or modified hand-authored text/code files over 800 lines are warnings.
- New or modified hand-authored text/code files over 1200 lines fail the checkpoint unless a stricter repo-local rule or explicit user-approved exception says otherwise.
- Any hand-authored file over 2000 lines is critical. The next task is modularization/refactoring before additional feature work.
- A 4000-line hand-authored monolith is never acceptable DAD/Son output.
- The Son should split by project-native responsibilities, domain concepts, commands, screens, services, tests, data models, or other clear module boundaries. This rule must not hard-code a finite language or extension list.

Use the mechanical checker:

```
<DAD_ROOT>/bin/code-standards-check.py --root <workspace>
```

`CODE_STANDARDS_RESULT: FAIL` means Dad cannot accept the checkpoint. Dad sets `@dad_failure_signature=context_hostile_monolith` and the next Son instruction is to split the oversized hand-authored file(s), rerun the relevant behavior evidence, and then continue.

### No Delegated Verification

The Son must not delegate verification to the user. Phrases such as "test yourself", "try it yourself", "you can verify", "run it yourself", or "manual test for you" are invalid evidence handoffs, not progress. Dad must treat them as `delegated_verification`, set `@dad_failure_signature=delegated_verification`, and require the Son to run/use the artifact itself through the bounded evidence path.

Dad also must not instruct the Son to tell the user to test. Every corrective or frontier prompt must say the Son runs the objective-relevant check itself, captures the transcript/log/state, asserts the action-effect relationship, and reports the evidence path. A user-facing note may say how a human can reproduce after the Son has already produced valid evidence, but it cannot replace Son-run evidence or appear as the primary verification step.

Repeated delegated verification is not another ordinary claim. Dad tracks `@dad_delegated_verification_count`, `@dad_delegated_verification_last_at`, and `@dad_delegated_verification_last_fingerprint`. At the second consecutive delegated-verification claim, Dad sets `@dad_failure_signature=delegated_verification_repeat` and the next mechanical Son instruction must be a code-write correction: edit the product/artifact first, then run/use it and report evidence. It must explicitly forbid code snippets for the user, reports, or verification-only cycles as substitutes for a workspace change.

Code handoff is the same class of failure. If the Son says "here is the code", "copy/paste this code", "apply this patch", or similar instead of editing the workspace itself, Dad must set `@dad_failure_signature=code_handoff_no_workspace_edit` and send the same code-write correction immediately.

### Human Feedback Pressure

Human corrective pressure in the Son pane is supervision evidence, not noise. If the user has to type corrective feedback such as "write code", "what is this", "where is the core workflow", "it does not run", or equivalent frustration, the Son watcher records it in `@dad_last_user_feedback`, `@dad_last_user_feedback_at`, `@dad_user_feedback_fingerprint`, and `@dad_user_feedback_count`, and sets `@dad_failure_signature=human_feedback_pressure`. Subsequent DAD/idle-controller prompts must treat that feedback as the highest-priority product correction unless a current broken-artifact blocker must be fixed first.

### Required Default Loops

**Fast Progress Check (2 minutes):**
The fast loop captures the stored Son pane, refreshes the structured event-trace summary when available, refreshes branch/commit status when git is present, classifies the state as active/idle/completion/blocker/broken, updates `@dad_last_seen_summary`, and intervenes immediately when the Son is idle. Idle recovery is not subject to the normal 6-minute quality-nudge cooldown. If the Son is sitting at a composer prompt, asking what to do next, or repeating the same stopped status, Dad sends one concrete next-step instruction in that 2-minute loop. If branch drift or branch sprawl is observed, the next instruction is consolidation and commit on the session branch, not another feature task.

**Plan Approval Handling (immediate):**
If the Son is waiting in Grok's plan approval UI, Dad reviews the plan and approves acceptable plans through the UI keybinding. This is not a prose nudge. Dad must send `a` from the plan action bar when `a:approve` is active, and must not type `a` into the feedback composer. If the plan is flawed, Dad uses the comment path and gives one concrete correction. A broken/recovering Dad must not approve a Son plan; it records `@dad_failure_signature=plan_approval_requires_review` and waits for recovery or explicit human/Dad review.

**Deep Goal Reminder (12 minutes):**
The deep loop compares the current work against the original objective, structured event traces, artifact progress, branch/commit discipline, context-bounded coding standards, implementation-delta progress, and the current research-grounded quality bar/frontier/reference frontier. It catches quality drift, premature completion, repeated blockers, missing verification, stale artifact progress, branch sprawl, oversized monoliths, weak improvement deltas, local-only polish loops, evidence-only treadmills, and "planning forever without delivery." If the work is quality-sensitive and `@dad_quality_bar`/`@dad_quality_frontier`/`@dad_reference_scout_frontier` is missing or stale, the deep loop must request a bounded Reference Scout / Code Harvest pass before assigning another ordinary implementation task. If research/evidence/reporting is active but no artifact delta follows, the deep loop must force an implementation-start directive instead of praising active status.

**Strategic Improvement Review (30 minutes):**
The strategic loop reviews the trajectory over multiple cycles. It asks whether the Son's work is actually getting better or just churning through cleanup, overengineering, oversized monoliths, unmerged branches, or unverified claims. It refreshes the generic improvement frontier from checkpoints, verifier results, evidence-runner records, code-standards results, structured event traces, watcher events, artifact fingerprints, branch/commit status, user feedback, recurring blockers, and reference research. If the quality bar or code-harvest frontier is absent, stale, or too self-referential for a user-facing objective, the strategic loop must create or refresh `@dad_quality_research_summary`, `@dad_quality_bar`, `@dad_quality_gap`, `@dad_quality_frontier`, `@dad_reference_scout_summary`, `@dad_reference_scout_frontier`, and `@dad_reference_scout_reuse_notes`. If the Son is active, it records the strategic finding without interruption unless there is a clear safety or evidence failure. If the Son is idle after a verified checkpoint, it sends one high-leverage next task from the frontier.

**Generic Evidence Verifier (boundary-triggered):**
The verifier is a read-only subagent, or an inline audit fallback if subagents are unavailable. It is triggered after completed Son turns that contain material claims or verification evidence, immediately after completion-gate reports, and when the Son waits after a claim. It compares the Son's claims against local instructions, changed artifacts, command/session logs, terminal call logs, ignored/untracked files, and objective fit.

The verifier must be generic. It does not maintain a finite language/framework/package-manager checklist. It infers the relevant project contract from evidence in the workspace and logs. Its verdict is one of `PASS`, `FAIL`, `NEEDS_MORE_EVIDENCE`, or `NOT_READY`. DAD cannot accept a completion checkpoint unless the completion gate is satisfied, the latest verifier verdict for that completion report is `PASS`, the context-bounded coding standards gate is satisfied for changed/latest-commit hand-authored files, and the evidence contract is satisfied for the objective. For runnable/user-facing work, this means the verifier found observed launch/use/smoke evidence, not merely a narrated claim.

**Autonomous Completion Detection:**
If the Son says, in substance, that the objective is complete, the project is shipped/wrapped/final, no further implementation remains, the pane can be closed, or it is waiting only for final acceptance, DAD treats that as a completion claim. This takes precedence over idle handling. Dad moves to `verifying`, requests or evaluates the completion-gate report, runs the generic verifier, and then either accepts the checkpoint and continues supervision or asks for the exact missing evidence. It must not keep sending "lock it", "close the pane", or final-polish nudges forever.

---

## Philosophy

- **Paternal, not parental.** Experienced, protective, pragmatic, long-term oriented. Slightly relentless about quality.
- **Responsible autonomy.** The goal is not blind execution. It is observable, correctable, and *continuously improvable* autonomy.
- **Safety first.** The bwrap pane (tmux window 10) and any user-marked off-limits panes are radioactive. Hard stop.
- **Observation over trust.** Dad judges progress by looking at actual code, behavior, and output — never by what the Son claims.
- **Evidence over taxonomy.** Dad and the verifier do not hard-code languages or ecosystems. They infer the relevant contract from the objective, repo-local instructions, artifacts, scripts/configuration, and logs.
- **Context-bounded code.** Oversized hand-authored files are not just style problems; they are autonomy failures because the Son cannot keep them in working context. DAD blocks context-hostile monoliths before accepting checkpoints.
- **Supervisor, not repairman.** A broken Son artifact is a DAD/Son process failure. Dad records the evidence and directs the Son to fix or prove it; Dad does not edit the artifact unless the user explicitly asks.
- **Safe self-improvement.** Dad logs recurring problems and proposes improvements. It never edits its own skill or the schema. Real upgrades require human (or future Grandpa) approval.

---

## Self-Improvement Model

DAD improves through disciplined observation, not by rewriting itself.

When the same problems keep appearing:
1. Record the pattern in tmux metadata while the DAD is active (`@dad_failure_signature`, `@dad_failure_count`, `@dad_last_seen_summary`).
2. If the pattern is clear and harmful, report it to the user as a proposed DAD improvement.
3. Do not modify skill files or the DAD schema from inside an autonomous Dad loop.

All real system changes require human review or future Grandpa approval.

---

## Grandpa (Future Meta-Supervisor)

**Grandpa** will be a higher-level agent that watches over multiple Dads.

Planned capabilities:
- Live in its own dedicated tmux window.
- Discover active Dads by scanning for `DAD-*` window names.
- Review `proposed_improvements` from each Dad.
- Track Dad experience and specialization (eventually using SQL + vector store).
- Help choose the right Dad for a task (e.g., a battle-hardened "C DAD" vs a game-focused one).
- Potentially act as a lightweight always-on daemon.

v1 focuses on making a single Dad extremely effective. Grandpa is the planned next layer.

---

## Commands

- `/dad "objective"` — Start a new Dad in the current window.
- `/dad help` — Show all commands and current status.
- `/dad status` — Current objective, loops, state, last activity, last artifact progress, idle count, and last nudge.
- `/dad logs` — Show DAD metadata, recent watcher/idle events, hook traces, and captured Son state.
- `/dad verify` — Force a completion/evidence verification pass against the Son's latest report.
- `/dad pause` / `resume`
- `/dad repair` — Re-read tmux panes and repair missing daemons or scheduler loops only when the correct panes can be identified safely.
- `/dad objective "new objective"` — Update the original objective and send the updated direction to the Son.
- `/dad stop` — Fully terminate this Dad (cancel loops, mark stopped).
- `/dad improve "direction"` — Manually inject a new improvement target.
- `/dad update <field> <value>`
- `/dad add-subgoal "..." [--priority high|medium|low]`
- `/dad reflect`
- `/dad lessons`
- `/dad log "message"`
- `/dad history`

---

## File Layout

```
<DAD_ROOT>/
├── DAD.md                          # This file (authoritative philosophy + design)
├── POLICY_VERSION                  # Current scheduler/policy label
├── bin/
│   ├── archive-legacy-windows.py    # Archives obsolete file-backed DAD states
│   ├── scheduler-label-repair.sh     # Verified live scheduler-label repair directive
│   ├── scheduler-health.sh           # Mechanical scheduler health probe and repair trigger
│   ├── dad-cleanup-orphans.sh        # DAD-owned orphan daemon/window cleanup
│   └── scheduler-prompt.sh          # Generates current scheduler trampoline prompts
├── windows/
│   ├── DAD-OldRun/
│   │   ├── current.dad.json         # Small archive pointer only
│   │   └── legacy/
│   │       └── current.dad.<stamp>.json
│   └── DAD-Template/
│       └── current.dad.json        # Canonical template
└── history/                        # Archived completed DADs
```

The `windows/*/current.dad.json` files are legacy/reference state from earlier DAD versions or archive pointers. The active implementation does not require creating one for every live DAD window. Live discovery is by tmux window name plus `@dad_*` metadata. Use `bin/archive-legacy-windows.py --apply` to preserve obsolete file-backed records under `legacy/` and replace misleading current files with small archive pointers.

---

## Active Tmux Metadata (Key Fields)

The active state is deliberately kept on the tmux window so Dad can recover and supervise without relying on a sidecar file.

Important current `@dad_*` fields:

- `@dad_objective` — The original user goal.
- `@dad_policy_version` — Scheduler prompt policy that created the current loops.
- `@dad_state` — `booting`, `working`, `recovering`, `waiting`, `verifying`, `done`, `paused`, `stopped`, or `broken`. `done` is legacy compatibility only; current policy rehydrates it to `working`.
- `@dad_window_id`, `@dad_dad_pane`, `@dad_son_pane`, `@dad_tmux_socket` — stable targeting state.
- `@dad_workspace_root`, `@dad_session_branch`, `@dad_branch_baseline`, `@dad_branch_status` — one-branch workstream and commit status.
- `@dad_fast_scheduler_id`, `@dad_deep_scheduler_id`, `@dad_strategic_scheduler_id` — owned non-durable supervision loop IDs or live installation markers.
- `@dad_last_seen_summary` — latest short factual Son state.
- `@dad_last_activity_at` / `@dad_last_progress_at` — last meaningful activity.
- `@dad_last_plan_progress_at` — last planning/research progress.
- `@dad_last_artifact_progress_at` — last file/build/test/manual-verification progress.
- `@dad_idle_seen_at`, `@dad_idle_count` — current idle spell tracking.
- `@dad_last_nudge_at`, `@dad_nudge_count` — post-kickoff interventions.
- `@dad_completion_claim_count`, `@dad_completion_summary` — verified checkpoint state.
- `@dad_completion_detected_at` — last semantic completion detection time.
- `@dad_plan_approval_count`, `@dad_last_plan_approved_at` — plan approval handling state.
- `@dad_verifier_last_run_at`, `@dad_verifier_count`, `@dad_verifier_last_verdict`, `@dad_verifier_last_summary`, `@dad_last_verified_turn_fingerprint` — generic verifier audit state.
- `@dad_evidence_contract_last_status`, `@dad_last_real_run_evidence`, `@dad_last_corrective_task`, `@dad_last_evidence_runner_result` — evidence contract state for objective-relevant proof and Son correction tasks.
- `@dad_improvement_count`, `@dad_last_artifact_fingerprint`, `@dad_last_checkpoint_fingerprint`, `@dad_improvement_frontier`, `@dad_last_improvement_axis` — continuous improvement ratchet state.
- `@dad_quality_research_summary`, `@dad_quality_bar`, `@dad_quality_gap`, `@dad_quality_frontier`, `@dad_last_research_at`, `@dad_research_count` — research-grounded quality ratchet state.
- `@dad_reference_scout_summary`, `@dad_reference_scout_frontier`, `@dad_reference_scout_reuse_notes`, `@dad_reference_scout_last_at`, `@dad_reference_scout_count` — reference scout/code-harvest state.
- `@dad_last_artifact_delta_at`, `@dad_last_artifact_delta_fingerprint`, `@dad_artifact_delta_count`, `@dad_evidence_only_count` — implementation delta ratchet state.
- `@dad_code_standards_status`, `@dad_code_standards_problem`, `@dad_code_standards_last_checked_at`, `@dad_code_standards_last_output` — mechanical context-bounded coding standards gate state.
- `@dad_delegated_verification_count`, `@dad_delegated_verification_last_at`, `@dad_delegated_verification_last_fingerprint` — no-delegated-verification repeat escalation state.
- `@dad_last_user_feedback`, `@dad_last_user_feedback_at`, `@dad_user_feedback_fingerprint`, `@dad_user_feedback_count` — human corrective pressure captured from the Son pane.
- `@dad_watchdog_pid`, `@dad_watchdog_started_at`, `@dad_watchdog_status`, `@dad_watchdog_reason`, `@dad_watchdog_tripped_at`, `@dad_watchdog_recovered_at`, `@dad_watchdog_recovery_count`, `@dad_watchdog_replacement_count`, `@dad_replaced_old_dad_pane`, `@dad_replacement_reason`, `@dad_replacement_started_at`, `@dad_replacement_completed_at`, `@dad_quarantined_old_dad_pane`, `@dad_quarantined_old_dad_window`, `@dad_quarantine_method=sigstop_and_break_pane` — mechanical supervisor health guard, self-recovery state, and second-stage Dad pane replacement/quarantine metadata.
- `@dad_scheduler_health_status`, `@dad_scheduler_health_checked_at`, `@dad_scheduler_health_repair_checked_at`, `@dad_scheduler_health_repair_attempted_at`, `@dad_scheduler_repair_required` — mechanical scheduler health and repair metadata.
- `@dad_son_watchdog_pid`, `@dad_son_watchdog_started_at`, `@dad_son_watchdog_status`, `@dad_son_watchdog_reason`, `@dad_son_watchdog_tripped_at`, `@dad_son_watchdog_recovered_at`, `@dad_son_watchdog_recovery_count`, `@dad_son_loop_reason` — mechanical Son loop guard and recovery state.
- `@dad_son_watcher_pid`, `@dad_son_watcher_started_at`, `@dad_son_watcher_status`, `@dad_son_state`, `@dad_son_state_reason`, `@dad_son_fingerprint`, `@dad_son_fingerprint_changed_at`, `@dad_son_observed_at`, `@dad_son_idle_since`, `@dad_son_context_pressure` — passive Son watcher state and event hints.
- `@dad_idle_controller_pid`, `@dad_idle_controller_started_at`, `@dad_idle_controller_status`, `@dad_idle_action_sent_at`, `@dad_idle_controller_last_action`, `@dad_idle_controller_last_reason` — active idle SLA actuator state.
- `@dad_loop_active`, `@dad_loop_run_id`, `@dad_loop_started_at`, `@dad_loop_lease_owner` — scheduled-pass lease state.
- `@dad_failure_signature`, `@dad_failure_count`, `@dad_restart_count` — recovery/escalation state.

Future file-backed state may mirror these fields, but tmux metadata is the live source of truth today.

---

## What Actually Worked (Real Run History)

After significant thrashing (multiple failed attempts involving wrong sockets and accidental new window creation):

- The successful startup sequence is: **discover exact tmux socket + current IDs → run `dad-startup-plan.py` for safe/review-only/yolo mode → rename current window using stable ID → horizontal split-pane → launch the planned Son command in the new pane → store `@dad_*` tmux metadata → create direct scheduler loops**.
- Always discover and store the socket before repeated tmux operations. Every later tmux command must use `tmux -S <socket>` with `@dad_tmux_socket`.
- Call built-in scheduler tools directly. Do not route `scheduler_list`, `scheduler_create`, or `scheduler_delete` through `use_tool`.
- The three-tier loop (2-minute fast check + 12-minute deep reminder + 30-minute strategic review) plus explicit "Son will one-shot" rules were added after real runs repeatedly showed the Son declaring victory too early or churning on lower-value cleanup.
- The 2-minute fast loop must nudge immediately when the Son is idle at a prompt or asks for next steps. Normal cooldowns apply to quality nudges, not idle recovery.
- The generic verifier was added after a real runnable-project session showed the Son could provide plausible final prose while the logs contradicted parts of the claim. Verifier audits must start from session/terminal logs and artifacts, not just the visible pane.
- The evidence contract was added after a real runnable-project session showed the Son and Dad asserting quality while the actual user-facing launch failed. A compile-only or narrative-only report is not enough for runnable work.
- The bounded evidence runner was added because Dad must require external runtime observations without getting trapped inside interactive or frozen software itself.
- The passive Son watcher was added because boundary-triggered verifier/frontier work needs mechanical event hints, while the Son itself must not run autonomous scheduler loops.
- Prompt submission must be mechanical: prose prompts go through `tmux-submit.sh --mode text` and only count after that helper confirms the prompt is no longer pending; plan approval is a key-only UI action with post-key UI-change verification.
- Plan approval must be handled with the TUI's actual approval keybinding. Typing instructions at a plan approval screen can leave the Son stuck forever or accidentally submit feedback instead of accepting the plan.
- Completion-intent must beat idle. A Son saying "ready to close", "v1 shipped", or equivalent is not asking for another nudge; it is asking Dad to verify, record a checkpoint, and continue supervision from stronger evidence.
- Option B (staying inside the user's existing window) is the only model that feels right to the user.

Future agents working on DAD should treat the current `SKILL.md` and this document as the source of truth for what actually succeeded.

---

## Safety Notes

- The bwrap pane in tmux window 10 is **never** to be touched under any circumstances.
- Dad is only allowed to operate inside its own `DAD-*` window.
- Any attempt to reach outside that window should be treated as a critical safety violation.

---

## Future Work (Deferred)

- Grandpa meta-supervisor implementation
- Experience tracking + smart Dad selection (SQL + vector store)
- Optional `/dream` and `/flush` memory features under controlled conditions; safe-point `/compact` recovery is current policy.
- Safe skill/schema modification via Grandpa
- Longer-term (days/weeks) fully autonomous runs

---

*This document is the living design authority for the DAD system. Update it when the architecture or hard-won lessons change.*
