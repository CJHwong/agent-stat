# How it works

Each of these is a decision that looks odd until you know what it stands on. Most of them
were measured, not assumed.

## One writer per file

Each machine writes its own events under `~/.local/state/agent-stat/hosts`.
The file name carries the host. The stream helper serves only files for its exact host.
It never forwards cached events from another machine.
The app uses `gethostname(2)` and the hook uses `uname -n` to identify the local host.
Both must produce the same host name for locality checks.

Each machine installs its own scripts. Neither events nor scripts require Syncthing.
The hook writes locally, so a failed network connection cannot delay an agent.

## The hook can never block an agent

Three things stand between a broken hook and a blocked tool call. The registered command
forces exit 0 with no `exec`. The installer refuses a script that does not parse, or that
has an apostrophe in a comment. And `scripts/test.sh` checks both scripts for both faults
before it builds. That combination is not caution for its own sake: a shell syntax error
once reached a real config, and exit code 2 from a hook means "block the tool call", so
every session that picked it up stopped working.

## A remote click needs a route

A tmux pane id is only unique inside one tmux server, and a folder name exists on both
machines, so acting locally on a session from another machine would land in the wrong
place. The panel refuses by default, and a route you write is the explicit exception. Two
facts from a real second machine shape the route: a non-interactive ssh has no `tmux` on
its `PATH`, and a select issued from a shell with no `TMUX` moves the client attached to
that machine, which is why the pane comes up in the tab you already have attached.

## The fold is deterministic

The panel's state depends only on the events seen, in order.
Reading the same records again does not change that state.
Session names also use Codex's saved index as metadata.
The app reuses parsed names while the index metadata stays unchanged.
It checks the inode, size, modification time, and change time before reuse.
An index with coarse timestamps receives a full read.
Name updates do not change the state, event time, or attention count.
This matters when a replaced file requires a read from the start.
A counter that increments on every read would count the same event twice.
Record positions also distinguish events that share a timestamp.
Clicks and dismissals save those positions, so a later event can restore attention within the same second.
Existing memory files remain readable.

## A remote stream resumes after a failure

An optional `events` command starts a helper over Secure Shell (SSH).
It is independent of the `tmux` command used for navigation.
The receiver stores remote files in its own `remote/<host>/hosts` cache.
It resumes each file from its raw byte length.
A SHA-256 digest of the last 4,096 bytes checks that the source still matches.
The helper withholds an incomplete trailing line until the writer completes it.
It closes each log after the read, so retained history cannot exhaust open file descriptors.
Unchanged logs with precise change timestamps skip the open and digest check.
Changed logs and logs with coarse timestamps receive full validation.

A failed stream shows the host as offline and retains its cached history.
Reconnect delays increase from one second to 30 seconds.
A stream with no heartbeat for 20 seconds also becomes offline.
During slow cached replay, compatible helpers send progress without marking the host connected.
The receiver requests these frames explicitly, so older receivers keep their existing protocol.
Request writes cannot block the watchdog. A helper that ignores shutdown receives a forced stop after one second.
The helper sends status every five seconds.
Status also carries names for known sessions from the local Codex indexes.
Status includes process identifiers and start times, so a reused identifier cannot revive a closed session.
Remote processes use the same 60-second grace period as local processes after they vanish.

## Work in flight counts whoever is doing it

A turn can finish while its subagents run on. That session is not waiting on you, so it
stays green and stays out of the badge until its last subagent stops. The count is starts
seen minus stops seen, so a subagent killed with its parent keeps its share of the count
until that session ends.

## A dot turns blue when you have seen it

Red means a session wants you and you have not dealt with it. Clicking the row deals with
it, so the dot turns blue and the badge stops counting it, and the session's next event
makes it red again. One meaning per colour, so a glance down the panel is enough.
