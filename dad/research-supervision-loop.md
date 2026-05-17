# DAD Research Mapping

This memo maps current agent/recovery research into DAD implementation rules.

## Karpathy autoresearch

Source: https://github.com/karpathy/autoresearch and `program.md`.

Key pattern: keep a fixed harness, run a bounded experiment, measure one external metric, keep improvements, discard crashes/regressions, and continue indefinitely. For DAD this means a Son claim is not evidence. DAD needs an external-use harness and a keep/discard checkpoint policy based on observed artifact behavior, not prose.

## MAPE-K / Autonomic Computing

Source: IBM autonomic-computing architecture and MAPE-K literature.

Key pattern: Monitor, Analyze, Plan, Execute over shared Knowledge. For DAD this maps to watcher/event/evidence metadata as Knowledge, Son watcher/watchdog as Monitor, verifier/evidence gate as Analyze, frontier/corrective prompt as Plan, and tmux-submit to Son as Execute.

## Recovery-Oriented Computing / Microreboot / Crash-Only Recovery

Sources: Berkeley Recovery-Oriented Computing technical report and Candea/Fox microreboot/crash-only work.

Key pattern: failures are expected; recover bounded components into a known-good state instead of trying to reason inside the failed state. For DAD this means watchdog recovery should isolate the Dad pane, compact/clear bad memory, keep restart-intensity counters across prompt appearances, and never let one failed supervisor turn freeze the Son forever.

## Erlang/OTP Supervisors

Source: Erlang/OTP supervisor docs.

Key pattern: supervisors isolate worker failures, apply restart intensity limits, and escalate rather than spin forever. For DAD this means repeated Dad recoveries should be bounded and visible, but escalation must not become permanent worker starvation. `broken` is degraded supervision unless the user explicitly stops/closes the DAD.

## Voyager / Reflexion / SWE-agent / OSWorld

Sources: Voyager, Reflexion, SWE-agent, and OSWorld papers/sites.

Key pattern: agents improve through environment feedback, execution errors, self-verification, task-specific interfaces, and execution-based graders. For DAD this means the verifier must drive the artifact through its natural interface and assert observed action-effect state. Tests, static inspection, or model summaries support the decision but do not replace external-use evidence for user-facing software.

## Implementation Consequences

- DAD must distrust Son claims until fresh evidence passes a deterministic gate.
- DAD needs generic CLI/PTY user-simulator evidence now, with room for browser/API later.
- `@dad_state=broken` must not park the Son. The idle controller must provide degraded Son continuation when Dad cannot supervise normally.
- Watchdog must stay alive through recoverable broken states and must not reset recovery counters merely because a prompt appears; repeated restarts need an intensity ceiling and explicit repair/restart path.
- Evidence gates must reject empty transcripts, stale git state, assertion-free evidence, and launch-only checks with no user action/effect.
