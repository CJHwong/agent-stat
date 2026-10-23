# Reference

## What a row shows

Rows are grouped by the machine that wrote them, this machine first. Inside a group, rows
that need you sort to the top.

| State | Means |
|---|---|
| red | the session is waiting on you: a turn finished, or a permission prompt is open, and nothing is running under it |
| blue | the same, after you clicked a red row: it still wants you and you have seen it |
| orange | the turn failed. It also needs you and counts in the badge |
| purple | you interrupted it |
| green | working, with the running tool and its elapsed time. The dot pulses |
| grey | closed, or a process that vanished without an end record |

Red carries one meaning and no other, so a glance down the panel finds every row that
wants you. Orange is the second colour that needs you: a failure counts in the badge and
stays until you click it or hide it. Clicking it stops the count but does not turn it
blue, so the row still says the turn failed. Work in flight counts whoever is doing it: a
turn that finished while its subagents run on stays green, keeps pulsing, and stays out
of the badge until its last subagent stops. A session that vanished without an end record
is waiting on nobody, so it takes the same grey as a clean end and stays out of the count.

## What a row says

| Row | Text |
|---|---|
| idle turn, nothing under it | its last message |
| idle turn, 2 subagents running | `2 subagents, turn finished` |
| tool in flight, 1 subagent | `Bash, 6s (1 subagent)` |
| no tool, subagents running | `2 subagents` |
| any other state with subagents | its own text, then the count in parentheses |
| a session with a captured name | its folder, then that name in parentheses |
| a local row with no name, one matching tab | its folder, then that tab's name |
| a local row whose folder matches several tabs | its folder, then `3 tabs`; the click asks which |

A subagent or an in-process teammate is not a session you can go back to, so it never
gets a row of its own, and its tool calls are not recorded: they belong to the parent's
row, and on a busy machine they were most of the file. The start and the stop are
recorded, two lines per subagent, which is what keeps a parent row fresh and lets it
count what is running under it.

## The events file

One JSON record per line, one file per host per day:

```json
{"ts":1792217767,"event":"Stop","agent":"claude","agent_pid":47158,"session":"a1b2","cwd":"/work/api","tool":"Bash"}
```

`ts` and `event` are the only fields a row needs. Other fields are optional.
An older build on another machine can write a smaller record.
The reader skips a record that cannot decode and continues with the file.
The file name carries the host, because only that machine writes it.

Claude Code can send `session_title` in a hook payload.
For Codex, the hook reads `thread_name` from the active profile's `session_index.jsonl`.
It matches the exact session identifier and uses the latest valid matching name.
`CODEX_HOME` selects the profile. If unset, the hook uses `~/.codex`.
Names created after startup and later renames appear on the next hook event.
The app also reads names every five seconds from `~/.codex*/session_index.jsonl` and `CODEX_HOME`.
The remote helper sends these names with its existing five-second status update.
This fills names for quiet sessions and detects renames without a new hook event.
If profiles contain the same session, the newest valid `updated_at` selects its name.
Profiles that share an index through a symbolic link read that index once.
The receiver caches names beside the remote logs in `titles.json`.
Name updates preserve session status, event timestamps, and attention counts.
The hook limits indexed names to 200 characters and replaces line breaks with spaces.
If the index is missing or unreadable, the hook still writes the event without a name.

## Where things live

| Path | What |
|---|---|
| `~/.local/state/agent-stat/bin/agent-stat-hook.sh` | The hook every agent event calls. Each host installs its own copy. |
| `~/.local/state/agent-stat/bin/agent-stat-run-end.sh` | The end bridge an orchestrator calls. |
| `~/.local/state/agent-stat/bin/stream-events.py` | The helper that streams this host's events and process status. |
| `~/.local/state/agent-stat/hosts/<host>-<date>.jsonl` | Local events, one writer per file per day. |
| `~/.local/state/agent-stat/remote/<host>/hosts/` | The receiver's cache of that remote host's events. |
| `~/.config/agent-stat/routes.json` | Optional routes to other machines. |
| `~/.config/agent-stat/memory.json` | The rows you have hidden and the rows you have clicked. A restart keeps both. |
| `~/Library/Logs/agent-stat.log` | Startup lines, and why a click failed. |

## Commands and environment

| Name | What it does |
|---|---|
| `bash build.sh` | Builds `.build/AgentStat.app`. |
| `AGENT_STAT_DIR` | Point the app at another events directory. |
| `AGENT_STAT_ROUTES` | Point the app at another routes file. |
| `AGENT_STAT_MEMORY` | Point the app at another file for what you have dealt with. |
| `AGENT_STAT_SHOW_PANEL=1` | Show the panel at launch, instead of waiting for a click. |

Tests, probes and the other development aids are in [../CLAUDE.md](../CLAUDE.md).

## Remote routes

Routes use exact host names as keys. Each route can contain these independent fields:

| Field | What it does |
|---|---|
| `events` | An argument array that starts the remote stream helper. Optional. |
| `tmux` | An argument array that reaches remote tmux for navigation. Optional. |
| `tab` | A Ghostty tab title substring for navigation. Optional. |

An `events` command does not require a `tmux` command.
The app never derives one from the other.
The helper serves only its own host's files.
An offline connection retains its cached records and retries automatically.
The receiver resumes from the raw byte length and checks the last 4,096 bytes with SHA-256.
It waits for a complete line before it adds a record to the cache.

## What a click can print

| Case | Message |
|---|---|
| selected on this machine | nothing, the tab is on screen |
| no route for that host | `that session is on <host>, not on this machine` |
| that session reports no pane | `that session reports no tmux pane on <host>` |
| cannot run tmux there | `cannot reach tmux on <host>` |
| the pane is gone | `pane <pane> is gone on <host>` |
| no tab matched | `selected on <host>, no tab named <name> here` |

## How long things take

| Constant | Value | What it covers |
|---|---|---|
| `finishedGraceSeconds` | 10 | A row whose session reported an end stays visible this long, then clears. |
| `crashedGraceSeconds` | 60 | A local or connected remote row whose process vanished without an end record. |
| `visibleWindowSeconds` | 12 hours | After this a session leaves the panel even if it never reported an end. |

All three are constants at the top of `src/SessionStore.swift`.

| Stream timing | Seconds |
|---|---|
| Helper status interval | 5 |
| Heartbeat timeout | 20 |
| Reconnect delay | 1 to 30 |

Helper status includes process identifiers and start times.
An offline connection cannot confirm whether a remote process still runs.
