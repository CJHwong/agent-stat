# Terminal interface

This component adds a persistent tmux sidebar to agent-stat.
It reads the existing local event files. The macOS panel can stay closed.
It adds no Claude or Codex hooks.

## Install

The supported host is macOS with Python 3.11 or later and tmux 3.7c or later.
The sidebar uses floating panes. Older tmux versions do not provide this layout.

1. Install the shared hooks on each host: `python3 install.py --apply` from the repository root.
2. Check the terminal install: `python3 tmux/install.py`.
3. Apply the terminal install: `python3 tmux/install.py --apply --reload`.
4. Attach to tmux. Press Ctrl+B, then Tab, to show or hide the sidebar.

The terminal installer backs up existing files before each apply.
It preserves existing `.tmux.conf` content and adds one configuration source.
It sets mouse support, hides the status bar, and installs F1 and right-click menus.
It also uses Ctrl+B Tab and Ctrl+B /.
Check these bindings if your own configuration already uses them.

An existing sidebar process retains its loaded code after an update.
Toggle the sidebar off and on to load the deployed update.
The terminal installer does not restart your programs.

Run the installer separately on each machine.
Settings synchronization does not deploy scripts.
Use `--home DIR` for an isolated installation test.
Use `--python PATH` to select a stable Python interpreter.

## Controls

| Control | Action |
|---|---|
| Click a sidebar row | Select that window or pane. |
| F1 | Open the menu for the current pane. |
| Right-click | Open the menu for the clicked row or shell pane. |
| Menu, then `f` | Show the full title, folder, and command. |
| Menu, then `s` | Show the status legend. |
| Ctrl+B, then `/` | Search titles, folder names, and commands. |
| `/ Search` | Open the same search overlay. |
| Recover | Preview saved conversations and terminals. |
| Ctrl+B, then Tab | Show or hide the sidebar. |

Search uses arrow keys and Enter. Escape closes it.
Recovery uses arrows to scroll.
Press `c` to select the next available saved command. Press Space to check or uncheck it.
Commands start unchecked. The preview shows their saved arguments before you choose them.
Press `r` to restore eligible conversations and checked commands.
Escape closes the preview without starting recovery.

The sidebar stays 28 columns wide.
Below 100 terminal columns it becomes a narrow rail.
Click the rail to open a floating sidebar without resizing shell panes.
Windows remain in numeric order.
The F1 hint stays visible, and Ctrl+B shows the shortcut sheet.

## Status

| Color | Meaning |
|---|---|
| Green | Working, including a finished turn with live subagents. |
| Red | Waiting, or a response you have not viewed. |
| Orange | Failed. |
| Blue | Ready, viewed response, or no recorded activity. |
| Purple | Interrupted. |
| Gray | Closed. |

An asterisk marks an unread response.
Selecting its window clears the marker and changes the response dot to blue.
Unread acknowledgement belongs to this terminal interface.
It does not change acknowledgement in the macOS panel.

The reader uses this host's agent-stat history and checks process identity.
History from a previous hostname does not supply current status.
Sessions without current-host events stay blue until they report another event.
The sidebar does not infer task success from a finished response.

## Recovery

The monitor saves window layouts, folders, labels, conversation identifiers, agent profiles, and foreground commands.
Recovery opens a separate `recovered-<session>` session.
It skips conversations already running in the source session.
Claude and Codex use their native conversation resume commands.

Other panes open terminals in their saved folders unless you select a saved command for rerun.
The monitor reads exact process arguments from macOS and stores their boundaries separately from display text.
It does not reconstruct a shell command from `ps` display text.
The full-command preview reads the live process. Recovery reads the saved snapshot.

The preview excludes commands that still run in the original pane.
Commands with masked credential flags cannot be selected for rerun.
An older snapshot without exact arguments opens a terminal instead.
Interactive shells also open fresh terminals.
Rerun uses the saved folder and arguments with the new terminal's environment.
It does not restore the previous process environment, shell aliases, or temporary files.
Selecting a command can repeat its actions. Check the preview before you press `r`.

Recovery does not preserve process memory or work in progress.
The tests exercise a simulated restart with temporary sessions and a fake agent.
They do not reboot the host.

## Files

| Path | Purpose |
|---|---|
| `~/.agents/tmux/` | Deployed Python scripts. |
| `~/.config/tmux/window-sidebar.conf` | Generated tmux bindings and hooks. |
| `~/.config/tmux/window-sidebar.log` | Sidebar error log. |
| `~/.local/state/tmux-sidebar/` | Private recovery snapshots, locks, previews, and installation backups. |
| `~/.local/state/agent-stat/hosts/` | Existing shared event source. |

`AGENT_STAT_DIR` selects another event directory.
`TMUX_SIDEBAR_STATE_DIR` selects another recovery directory.
Snapshots use private file permissions. Keep them out of Git.
The command preview masks known credential flags; it is not a general secret detector.

## Development

Run `python3 tmux/tests/run.py` from the repository root.
The recovery check creates a separate tmux server and a fake agent.
It does not act on existing sessions.
The root test gate includes these checks before it builds the macOS app.

| Source | Responsibility |
|---|---|
| `window-sidebar.py` | Layout, selection, menus, command previews, and bindings. |
| `agent_stat_reader.py` | Incremental event reads, status transitions, and process identity. |
| `sidebar_agents.py` | Conversation metadata, snapshots, and recovery. |
| `sidebar_views.py` | Search and recovery overlays. |
| `process_commands.py` | Exact argument capture, command masking, and rerun eligibility. |
| `sidebar.conf.in` | Configuration template without machine-specific paths. |
| `install.py` | Script deployment and configuration generation. |
