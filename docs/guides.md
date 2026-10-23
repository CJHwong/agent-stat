# Guides

Tasks, one at a time. Each one ends with what you should see.

## Go to a session

Click a row and the panel takes you back to that session's terminal tab.

| Case | What happens |
|---|---|
| tmux session | Jumps to the exact pane. The hook captures `TMUX_PANE`, so this is exact. |
| one Ghostty tab in that folder | Selects that tab and raises the window. |
| several tabs in that folder | Lists them by name and you pick. |
| no tab in that folder | Raises Ghostty and says so. |
| another machine, with a route | Selects the pane there over ssh, then brings the matching tab forward. |
| another machine, no route | Says so, and moves nothing. |

A row names the session, in parentheses after its folder, when the agent reports a name
for it, on either machine. A click matches on that name inside the session's own folder
first, which is what separates two sessions sharing a folder. With no name to go on, or no
match inside that folder, it matches the folder and counts the tabs when several could be
it. Rows from another machine name no tab, and neither does a session in tmux, which jumps
to its pane instead.

The first click may raise a macOS prompt asking to let the panel control Ghostty. That
is the automation permission, and the tab switch needs it.

Clicking a row also acknowledges it: its dot turns blue and it stops counting toward the
badge until that session reports another event. That is remembered across restarts, so a
row you have seen does not come back red.

## Hide a row

The `x` at the end of a row hides it. The record stays in the events file, so the history
is whole and nothing is deleted, and a hidden row also stops counting toward the badge.

The row stays hidden while that session works, and comes back when it asks for you: a
finished turn, a permission prompt, a failure, or a notification. A tool call and a
subagent start and stop move the row's clock but ask for nothing, so they leave the row
hidden. Hiding a busy row is safe for the same reason.

Hiding a row and clicking one are both written to `~/.config/agent-stat/memory.json`, so
a restart keeps them. A hidden row still returns the moment its session asks for you
again, and a blue row turns red again the same way, which is what keeps either from
outliving the session it was about.

## Reach a session on another machine

A route says how to run tmux on that machine, so a click can select the pane there. Write
one per machine in `~/.config/agent-stat/routes.json`, from `routes.example.json` in this
repo:

```json
{
  "laptop": {
    "tmux": [
      "ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
      "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no",
      "-o", "ControlPersist=no", "-o", "ControlPath=~/.local/state/agent-stat/ssh-%C",
      "laptop", "/opt/homebrew/bin/tmux"
    ],
    "tab": "laptop"
  }
}
```

- The key is the host name the events file carries, matched as written, never by prefix.
- `tmux` is the argument array that reaches tmux there. The panel appends the tmux subcommand, so
  the last element is tmux itself. An empty list means tmux on this machine.
- `tab` is a Ghostty tab title substring to bring forward. Leave it out and the click
  still selects on the other machine, then says where.

A route file is read on every click, so navigation changes take effect at once.
It lives outside synced folders because its tab names belong to this machine.
An optional `events` command receives remote status independently of navigation.
See the second machine guide below.

Two things measured on a real second machine, both of which the example above handles: a
non-interactive ssh has no `tmux` on its `PATH`, so the absolute path is required; and a
select from a shell with no `TMUX` moves the client attached to that machine, so the pane
comes up in the tab you already have attached.

## Close a run an orchestrator finished

An orchestrator that runs an agent per turn and tears the pane down after each turn
leaves a row behind, because an interactive Codex reports no end for a session killed
that way. The orchestrator knows when the run is over, so give it one line to run when a
run finishes, passing the id of the agent session it just ran:

```
[ -n "$RUN_SESSION_ID" ] && ~/.local/state/agent-stat/bin/agent-stat-run-end.sh "$RUN_SESSION_ID"
```

The guard is there because a run event is not the only one an orchestrator raises: a
budget warning carries no session at all. The panel folds that record into `ended`, and
the row clears after ten seconds.

## Start it at login

Right click the icon and choose Start at login, which carries a checkmark while it is on. The same
switch is under System Settings, then General, then Login Items, if you prefer it there,
and that is where macOS may ask you to approve the entry.

Any build works, but a copy outside the repository is tidier, since the folder you build
in can move. The switch registers the bundle you are running, so an app you move later has
to be registered again from its new place.

A panel started this way has no shell behind it, and that environment has no Homebrew on
its `PATH` (measured: `/usr/bin:/bin:/usr/sbin:/sbin`). Two things follow from that. tmux
is looked up by absolute path as well as through the shell, so clicking a tmux session
still jumps. And a route names its own command absolutely, which the example above
already does.

Quit it with a right click on the icon, or `killall AgentStat`.

## Report from a second machine

1. Copy the repository to the second machine. Run `python3 install.py --apply` there.
2. Install hooks for each additional Claude or Codex profile that you use.
3. Add an `events` command to that host's route on the receiving machine.
4. Relaunch the receiving app. Check that it receives events from the second machine.

For example:

```json
{
  "laptop": {
    "events": [
      "ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
      "-o", "ClearAllForwardings=yes", "-o", "ServerAliveInterval=5",
      "-o", "ServerAliveCountMax=3", "-o", "ControlMaster=auto",
      "-o", "ControlPersist=no", "-o", "ControlPath=~/.local/state/agent-stat/ssh-%C",
      "laptop",
      "python3 .local/state/agent-stat/bin/stream-events.py"
    ]
  }
}
```

The route key must match the host name in that machine's event files exactly.
The final command runs from the remote home directory.
If remote Python is elsewhere, use its absolute path.
Add the `tmux` and `tab` fields from the navigation example if you also want remote clicks.
The app never derives the event command from those fields.

The examples share one Secure Shell (SSH) connection through the same `ControlPath`.
The event stream creates the connection. Each click opens a command channel on it.
If the stream is unavailable, a click opens a direct connection.
The socket lives outside synced folders and closes with the stream.
`%C` gives each server and remote user a separate socket name.

Each host writes events locally under `~/.local/state/agent-stat`.
Each host also installs its own scripts there, including `bin/stream-events.py`.
Synced settings can reference the same deployment path on each machine.
Run the installer on each machine to create the programs at that path.
Neither event delivery nor script deployment requires Syncthing.

The receiver caches remote events under `~/.local/state/agent-stat/remote/<host>/hosts`.
If the connection fails, the host shows offline and its cached history remains available.
The app reconnects and resumes from its saved byte position.
It checks the source bytes before it resumes, and waits for complete lines.
Remote status also checks process identifiers and start times.
A vanished remote process gets the same 60-second grace period as a local process.

## Move existing storage

Validate the transport before changing live storage on either machine.

1. Use separate test folders and a separate writer process on each machine.
2. Check new records, partial lines, daily file rotation, disconnection, and recovery.
3. Check that a vanished remote process clears after the grace period.
4. After all checks pass, retain the old history and move storage outside synced folders.
5. Update every agent profile and orchestrator end bridge caller on both machines.
6. Keep a compatibility launcher at the old script path for active sessions.
7. Check that both machines write to the new directory and the receiver receives remote events.

Active sessions can retain their old hook command until they restart.
The compatibility launcher must forward that command to the new local deployment.

The macOS migration script requires Python 3.11 or later.
Run `python3 scripts/migrate-storage.py` on each machine to check the plan without changes.
Pause sync for AgentStat and the affected settings on both machines before `--apply`.
The script retains history and configuration backups under `archive/` in the new directory.
It updates registered profiles, Codex trust entries, and the Rhapsody end bridge caller.
It swaps the directories atomically so open writers keep their file handles.
After in-flight hooks finish, remove the old `hosts` symbolic link and restore sync.
Keep the old script launchers until active sessions stop using their cached commands.
