# boink

**A timeout for every monitor an agent ever creates — outside Claude.**

`boink` is a harness-agnostic port of
[`claude-boink`](https://github.com/fcecin/claude-boink). The original relied on
Claude Code's built-in `CronCreate`/`CronDelete` tools; this version replaces
that with a tiny cross-platform CLI that drives the **real OS scheduler** — so
it works in any agent harness that can run a shell command, even one with no
Cron/periodic capability of its own.

The moment an agent creates a monitor — a background build, a poll loop, a CI
watch, or just a turn ending in *"I'll check back when it's done"* — it runs
`boink arm`, and a contentless prompt saying `BOINK` starts arriving every five
minutes, and keeps arriving until nothing is being waited on.

## Why

Monitors exit on a predicate the agent guessed at: a `grep` filter, an `until`
loop, a poll checking one status string. When the guess is wrong — process
crashed, log rotated, filter can never match, monitor timed out — the result is
**silence**, which is indistinguishable from *"still running, going fine."*
Agents wait in that silence for hours.

A BOINK is the machine equivalent of *"and?" "what's up?" "it's been 7 hours,
wtf is your demented monitor doing"*. It fires on wall-clock time and nothing
else, so a broken predicate can't starve it.

## How

```
boink arm --tag "deploy-watch"          # register a monitor; arms the scheduler
```

The CLI runs on the machine, outside the harness:

| OS | Scheduler backend | Persistence |
|---|---|---|
| Linux | `cron` (user crontab) | survives reboot |
| macOS | `launchd` (LaunchAgent) | survives reboot |
| Windows | Task Scheduler (`Register-ScheduledTask`) | survives reboot |
| anywhere | `boink daemon` self-loop | foreground fallback |

Every interval, the scheduler runs `boink tick`. If live monitors are
registered, `tick` appends a `BOINK` line to `~/.boink/boink.log` and runs every
executable in `~/.boink/hooks/`. Three ways to turn that into a prompt in your
harness:

1. **`boink watch`** as a background task — new `BOINK` lines wake you.
2. **Poll** `boink status` / `boink log` at turn boundaries.
3. **A hook** in `~/.boink/hooks/` that writes to your harness's own channel.

Each arrival: never answer from memory → re-observe with a fresh command → diff
against the last BOINK → classify **PROGRESSING / DONE / STALLED / DEAD /
MONITOR-BROKEN** → sweep → recount and `boink off` at zero.

`DONE` and `MONITOR-BROKEN` are the point: in both, the notification that should
have arrived is itself what's broken.

**The sweep** reaps what a session accumulates — finished shells, timed-out
monitors, idle agents, stale task entries, orphaned scheduled jobs. It's
load-bearing, not tidiness: a dead monitor still counts, so without it the
refcount never reaches zero and the BOINK never disarms. Cardinal rule is
**harvest before reap** — a finished shell holds the result you were waiting
for. Nothing that isn't yours, is still running, or is unharvested gets reaped
automatically.

Full protocol in [SKILL.md](SKILL.md).

## Install

### Linux / macOS / Git Bash

```sh
git clone https://github.com/fcecin/boink.git ~/boink
~/boink/install.sh                     # symlinks `boink` into ~/.local/bin
```

`install.sh [install|status|uninstall] [--prefix DIR]` — idempotent.

### Windows

```powershell
git clone https://github.com/fcecin/boink.git "$HOME\boink"
& "$HOME\boink\install.ps1" -AddPath   # copies boink.cmd/boink.ps1 to ~/.local/bin
```

`install.ps1 [install|status|uninstall] [-Prefix DIR] [-AddPath]`.

## Usage

```
boink arm --tag "gh-actions-build" --interval 300   # arm (default 5 min)
boink status                                        # state + scheduler + last BOINK
boink sweep                                         # list live monitors
boink disarm "gh-actions-build"                     # reap a finished monitor
boink off                                           # disarm all + remove scheduler
```

See `boink help` and [SKILL.md](SKILL.md) for the full protocol.

## Tested on real OSes

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs on
`ubuntu-latest`, `macos-latest`, and `windows-latest` and exercises the **real**
scheduler on each — a real `cron` job fires on Linux, a real `launchd`
LaunchAgent fires on macOS, and a real Task Scheduler task fires on Windows —
then asserts a BOINK event actually landed in the log and fired the hook. It
also exercises the `daemon` fallback and the full state machine on every OS.

## License

This is free and unencumbered software released into the public domain —
[Unlicense](UNLICENSE). The `BOINK` idea and original `claude-boink` are
MIT-licensed (c) 2026 fcecin; this port reimplements them from scratch.
