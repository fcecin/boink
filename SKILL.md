---
name: boink
description: "ALWAYS ACTIVE, no invocation needed. Whenever you create a semantic monitor (a background shell, a poll loop, a CI/build/deploy watch, or any turn ending in 'I'll check back when X'), arm a recurring BOINK with `boink arm` — a contentless prompt injected every 5 minutes while the session is idle and a monitor is still live. Each BOINK forces a fresh evidence-based status check and sweeps the dead shells, monitors, agents, task entries and scheduled jobs a session accumulates. Catches monitors that silently died, filters that can never match, and conditions met an hour ago. Disarms (`boink off`) when no live monitors remain."
---

# BOINK

Passive ability. Nobody asks for it; you arm it yourself.

> Create a semantic monitor → `boink arm`. No live monitors left → `boink off`.

BOINK is harness-agnostic. It replaces the Claude Code `CronCreate("BOINK")`
pattern with a small cross-platform CLI (`boink`) that talks to the real OS
scheduler — **cron** on Linux, **launchd** on macOS, **Task Scheduler** on
Windows, or a self-loop `boink daemon` as a universal fallback. You never need
the harness to have its own Cron/periodic capability.

## Why

Monitors exit on a predicate you guessed at while thinking about the happy path.
When the guess is wrong — process crashed, log rotated, filter can never match,
monitor timed out, condition impossible from the start — the result is
**silence**, and silence is indistinguishable from "still running, going fine."
Agents wait in that silence for hours.

A BOINK is the user leaning over and saying *"and?" "what's up?" "it's been 7
hours, wtf is your demented monitor doing"*. It fires on wall-clock time and
nothing else, so a broken predicate cannot starve it.

> Never let the liveness of your monitoring depend on the correctness of your
> monitor.

## How a BOINK reaches you (no harness Cron needed)

`boink` runs on the machine, outside the harness. The OS scheduler invokes
`boink tick` every N minutes; if (and only if) live monitors are registered,
`tick` appends a `BOINK` line to `~/.boink/boink.log` and runs every executable
in `~/.boink/hooks/`. Delivering that event to the agent is the harness's one
job, and any of these three works:

1. **Watch the log** — run `boink watch` as a background task; new `BOINK` lines
   appear on its output and wake you like any other background output.
2. **Poll at turn boundaries** — before finishing any turn, run `boink status`
   or `boink log` and treat an unexamined `BOINK` line as your wake-up.
3. **Install a hook** — drop an executable into `~/.boink/hooks/` that writes to
   the harness's own notification channel (a watched file, a FIFO, a socket).
   See `hooks/on-boink.example`.

The scheduler never cares whether your monitor is correct. That is the point.

## Arm

One scheduler per session, not one per monitor. Register each live monitor, then
the scheduler follows automatically.

```sh
boink arm --tag "deploy-watch" --interval 300
```

(`--interval` is in seconds; `300` is the default. On cron, minutes are the
finest granularity, so `300s` maps to `2-59/5 * * * *` — same 5 minutes,
avoids the `:00`/`:30` pileup.)

A **semantic monitor** is any wait that outlives the turn: a background shell, a
poll loop, a CI/deploy/build watch — including a turn that merely ends in "I'll
check back when…" with no tool armed at all. That last one strands agents
hardest, because nothing exists to remind you.

`boink status` shows the scheduler, the interval, the live-monitor list, and the
last BOINK.

## On each BOINK

**1. Never answer from memory.** If your answer could have been written before
the BOINK arrived, you skipped the protocol.

**2. Re-observe.** `boink status` and your own task/background inventory first —
*is my monitor even alive?* Then the thing itself:

```bash
ps -p "$PID" -o pid,etime,stat,%cpu,cmd
tail -n 30 run.log
stat -c '%y %s' run.log       # unchanged across 3 BOINKs = tailing a corpse
gh run view "$RUN_ID"
```

**3. Diff against the last BOINK.** The signal is the delta, not the state.

**4. Classify — one word, no hedging.**

| | |
|---|---|
| **PROGRESSING** | Motion since last BOINK. Cite the number. |
| **DONE** | Already finished; the monitor missed it. Stop waiting. |
| **STALLED** | Alive, not moving. Say how many BOINKs. |
| **DEAD** | Gone. Report exit status and log tail. |
| **MONITOR-BROKEN** | Watched thing is fine, the watcher isn't. Re-arm *corrected*, never identical. |

**DONE** and **MONITOR-BROKEN** are why this exists — in both, the notification
that should have arrived is itself the broken thing.

**5. Sweep** (below).

**6. Recount live monitors.** Zero → `boink off`. A dead monitor still shows in
`boink status`; count corpses and it never disarms. Reap them explicitly with
`boink disarm <tag>`.

Report in one line, with a number in it:

> BOINK — DONE. `run.log:4610` reads `FINISHED exit=0`, 11 min ago; the filter wanted `elapsed_steps=` and never matched. Swept 2 shells, 1 dead monitor. Zero live — `boink off`.

**Escalate.** Three no-change BOINKs → say STALLED and state a hypothesis. Four+
→ stop waiting, surface it with a recommendation. "Wait a bit longer" is
reasonable every single time and catastrophic in aggregate.

## The sweep

Sessions silt up: shells finished but never collected, monitors timed out, agents
idle after delivering, task entries stale, scheduled jobs outliving their
subject. Step 2 already enumerates all of it — reap on the way through.

**Harvest before reap.** A finished background shell is the result you waited
for, and usually the DONE signal itself. Read its output *first*, then reap it.
(Never read a subagent's full transcript file — it will flood your context.)

| Reap | With |
|---|---|
| Background shell, monitor, agent | your harness's stop/reap for that task |
| Task entry | mark completed (real work) or deleted (created in error) |
| Scheduled job | `boink disarm <tag>`, or `boink off` at zero |
| Your own temp files | `rm` on paths you created |

**Never auto-reap** anything that isn't yours, is still running, is unharvested,
or lives outside your scratchpad — report it and ask. No `pkill` by pattern: a
bare `pkill node` takes out the user's editor and dev server. In doubt, leave it.
A stray corpse costs one line of noise; a wrong kill destroys the run.

The sweep is secondary. A BOINK reporting tidy housekeeping while omitting
whether the build is alive has failed.

## Commands

```
boink arm [--tag NAME] [--interval SECS]   register a live monitor, arm scheduler
boink disarm TAG... | --all                reap finished monitors
boink sweep                                list live monitors (never auto-reaps)
boink status                               state + scheduler + last BOINK
boink tick                                 emit a BOINK event if monitors live
boink off                                  disarm all + remove the scheduler
boink daemon                               foreground self-loop (fallback)
boink watch                                tail the BOINK event log
boink scheduler install|remove|status|backend
```

## Limits

- **On-disk, durable** — unlike an in-harness Cron, state lives in `~/.boink/`
  and survives a session restart. Reap it when you're done.
- **Idle-only delivery is on you** — the scheduler fires unconditionally; the
  hook/watch/poll is what turns a fired `tick` into a prompt in *your* harness.
- **Costs tokens.** For long waits, `--interval 900` or `1800` buys the same
  protection cheaper — the value is unconditional recurrence, not frequency.

`boink arm` now · `boink sweep` sweep now · `boink off` disarm and stand down.
