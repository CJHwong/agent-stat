# Terminal interface

The tmux interface is one Rust application.
It includes the sidebar, menus, search, shortcut sheet, command previews, recovery, snapshot monitor, and installer.
It requires no Python runtime and no running macOS panel.
It reads existing agent-stat events and adds no agent hooks.

## Build and install

The checked host is macOS with tmux 3.7c or later.
Floating panes require that tmux version.
Rust and Cargo are required to build the binary, but not to run a deployed copy.

1. Build from the repository root: `cargo build --release --locked --manifest-path tmux/Cargo.toml`.
2. Preview installation: `tmux/target/release/agent-stat-tmux install`.
3. Install or upgrade: `tmux/target/release/agent-stat-tmux install --apply --reload --restart`.
4. Press Ctrl+b, then Tab, to enable the sidebar in an existing session.

The installer deploys `~/.agents/tmux/agent-stat-tmux` and writes `~/.config/tmux/window-sidebar.conf`.
It preserves existing `.tmux.conf` content and adds one source line.
It prints the path of its private backup before it finishes.
`--restart` replaces sidebar processes and monitors while preserving content panes and their root process identifiers.
It removes the retired Python runtime and prototype binary after the replacement.
`--reload` alone updates bindings without replacing running sidebar processes.

The configuration enables mouse input, hides the status bar, and sets `escape-time` to 20 milliseconds.
It uses F1, right-click, Ctrl+b Tab, Ctrl+b /, Ctrl+b r, Ctrl+b f, Ctrl+b z, and Ctrl+b ?.
Check these bindings if your own configuration already uses them.
The native tmux prefix remains Ctrl+b.

Use `install --home DIR` for an isolated deployment directory.
Use `install --socket PATH` to reload or replace a specific tmux server.
Deploy separately on each machine. Use a binary built for that host's operating system and architecture.
A settings sync does not deploy the executable.

Agent colors are optional. To collect them, install the shared hooks separately with `python3 install.py --apply`.
That command also installs the macOS panel's stream helper. It is separate from the Rust terminal runtime.
Without recorded events, the sidebar still works and rows show no dots.

## Controls

| Control | Action |
|---|---|
| Click a row | Select its window or pane. |
| New | Open a window in the current content pane's folder. |
| Split | Choose a split direction. |
| Rename | Set a manual pane label. |
| F1, then `N` | Reset the pane label to its automatic title or command. |
| F1 or right-click | Open the pane menu. |
| Menu, then `f`, or Ctrl+b f | Show the full title, folder, and command. |
| Menu, then `s` | Show the status legend. |
| Ctrl+b / or / Search | Search titles, folders, and commands. |
| F1, then `u`, or Ctrl+b r | Preview saved conversations and commands. |
| Ctrl+b Tab | Toggle the sidebar. |
| Ctrl+b z | Zoom the content pane or restore its layout, including after a sidebar click. |
| Ctrl+b ? | Open the full shortcut list. Escape or `q` closes it. |

New windows receive a sidebar automatically in an enabled session.
New sessions receive it when first attached.
The New button prepares the sidebar before it starts the shell and selects the new window.
The shell starts at its final width, so its prompt does not redraw during sidebar setup.
When the last content pane exits, its sidebar closes with the window.
The previous adjacent window receives content focus. If none exists, the next window receives it.
Rows remain in numeric window order.
When the list exceeds the available height, `▲ More above` and `▼ More below` indicate hidden rows.
A row uses the pane title or running command. A manual label takes priority.
The second line shows the current folder name.
Windows with several content panes have a group heading and a row for each pane.
Borders show pane titles without the misleading pane number contributed by the sidebar.

The sidebar stays 28 columns wide.
Below 100 terminal columns, it becomes a three-column rail with a bold `▶` arrow centered horizontally and vertically.
The arrow uses the terminal's normal background.
Click the expander to open a floating list without narrowing shell panes.
Escape closes that list. Widening the window also closes it and restores the docked sidebar.

F1 guidance stays visible.
Ctrl+b shows a centered shortcut sheet while tmux waits for the next key.
The sheet leaves focus in the content pane, so ordinary tmux shortcuts still work.
The small sheet stays hidden while zoomed to preserve zoom on tmux 3.7c.
Ctrl+b ? remains available during zoom.

Shortcut detection uses a persistent tmux control connection that sends only client-state queries.
It does not wait for sidebar process scans or launch a helper interpreter.
`tmux list-clients` shows that observer as an additional control client for each enabled session.
It ignores terminal size and receives no pane output.
Hidden sidebars check their records every five seconds. Selecting a window wakes its sidebar immediately.
Controls reuse pane records. Text views reuse wrapped lines until their contents or width change.

## Native tmux shortcuts

Ctrl+b ? shows common default shortcuts, followed by your current tmux bindings.
Use native tmux for session management, scrollback, copying, layouts, resizing, and pane swaps.
The interface adds no wrappers or submenus for these operations.
Hide the sidebar with Ctrl+b Tab before native layout changes or pane swaps.
Show it again when the content layout is ready.

Configure activity, silence, and bell alerts through native tmux options in `.tmux.conf`.
The interface does not change these alert settings.
Place personal settings after the sidebar's source line when you want them to override its defaults.

## Status

| Color | Meaning |
|---|---|
| Green | Working, including a finished parent with live subagents. |
| Red | An unacknowledged permission request or finished response. |
| Orange | Failed. |
| Blue | Ready, or an acknowledged request or response. |
| Purple | Interrupted. |
| Gray | Closed. |
| No dot | No recorded agent status. |

An asterisk marks an unacknowledged request or response.
Viewing its content pane clears the marker and changes its dot to blue.
Acknowledging a permission request does not approve it. Its state remains waiting.
A new event can request attention again, including a notification with the same timestamp.
The color meanings follow the macOS panel. Terminal shades depend on the terminal palette.
The terminal keeps its acknowledgement separate from the macOS panel.
The reader checks the local host, process ancestry, and process start time.
A finished response does not prove task success.

## Recovery

F1 always includes Recover. Ctrl+b r also opens it.
The sidebar shows a Recover row only when saved conversations or commands can be recovered.
The monitor publishes availability about every 10 seconds, without checks in the drawing or scrolling paths.
The monitor records layouts, folders, labels, conversation identifiers, agent profiles, and exact foreground arguments about every 10 seconds.
It stores private V1 snapshots and reads snapshots created by the retired implementation.
Recovery opens `recovered-<session>` and skips conversations already running in the source session.
Claude and Codex use their native resume commands with the saved profile.
Claude's native session registry can supply recovery metadata without supplying status dots.

Other panes open terminals in their saved folders unless you select a saved command.
Commands start unchecked. The preview shows the command before you select it.
Press `c` for the next command, then Space to check or uncheck it.
You can also click a checkbox. Press `r`, or click Restore, to start recovery.
Escape closes the preview without starting anything.
The wheel, arrows, Page Up, and Page Down scroll the cached preview.
Restore checks running processes again before it starts programs.

A saved command can repeat its actions. Check it before you select it.
Commands still running in their original panes cannot be selected.
Commands with masked credentials, interactive shells, and snapshots without exact arguments cannot be rerun.
Commands without a saved process identifier and start time also remain unavailable.
Argument boundaries survive spaces, empty values, and shell punctuation.
Rerun uses the saved folder and the new terminal's environment.
Recovery does not restore process memory, shell aliases, or the previous process environment.

A fresh empty shell after a restart does not erase the last recoverable snapshot.
After a monitor sees recoverable work, later snapshots include deliberate closures.
It does not keep closed programs as permanent restore points.
The checks simulate restarts with isolated sessions; they do not reboot the host.

## Upgrade compatibility

A running agent can retain the old terminal hook command.
During migration, the installer replaces those old hook endpoints with empty files.
They contain no Python implementation and perform no terminal work.
This protects old callers from a missing-file error that could block a prompt.
The Rust monitor removes the guards after the recorded agent processes exit.
Fresh installations create no guards.

The shared agent-stat hooks, shared stream helper, and Swift application remain separate components.
The macOS app still builds with `bash build.sh` and opens with `open .build/AgentStat.app`.
Building the app does not require Cargo.

## Files and commands

| Path | Purpose |
|---|---|
| `~/.agents/tmux/agent-stat-tmux` | The terminal executable and installer. |
| `~/.config/tmux/window-sidebar.conf` | Generated bindings and hooks. |
| `~/.local/state/tmux-sidebar/sidebar.log` | Terminal errors. |
| `~/.local/state/tmux-sidebar/snapshots/` | Private recovery snapshots. |
| `~/.local/state/tmux-sidebar/backups/` | Installation backups. |
| `~/.local/state/agent-stat/hosts/` | Existing shared events. |

`AGENT_STAT_DIR` selects another event directory.
`TMUX_SIDEBAR_STATE_DIR` selects another directory for recovery and runtime state.
Snapshots and backup files use private permissions. Keep them out of Git.
Command masking covers known credential flags; it is not a general secret detector.

Inside tmux, `~/.agents/tmux/agent-stat-tmux --session NAME snapshot` saves a checkpoint and prints its JSON.
`plan` prints recovery eligibility. `restore` resumes eligible conversations.
`restore --rerun PANE` explicitly selects one stopped saved command. Repeat the flag for several commands.
Use `--socket PATH` outside tmux or when selecting another server.

## Development

```sh
cargo test --locked --manifest-path tmux/Cargo.toml -- --test-threads=2
cargo clippy --locked --manifest-path tmux/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path tmux/Cargo.toml --check
```

The native integration checks require tmux and rustc.
They use private homes, separate tmux servers, compiled worker fixtures, and pseudo terminals.
They cover real controls, prefix latency, Escape after scrolling, status acknowledgement, command boundaries, profiles, layouts, and upgrades.
The repository test gate runs the Rust checks when Cargo is available.
It skips terminal integration checks if tmux is unavailable.

| Source | Responsibility |
|---|---|
| `src/main.rs` | Command dispatch and background refresh. |
| `src/model.rs` | Pane metadata, grouping, and selection. |
| `src/events.rs` | Incremental shared events and status. |
| `src/commands.rs` | Exact arguments, command masking, and profile capture. |
| `src/actions.rs` | Layout, menus, editing, zoom, and overlays. |
| `src/ui.rs` | Sidebar, search, and text previews. |
| `src/prefix.rs` | Control connection and shortcut sheet. |
| `src/recovery.rs` | Private snapshots, eligibility, monitoring, and restore. |
| `src/recovery_ui.rs` | Cached recovery preview and explicit command selection. |
| `src/install.rs` | Deployment, replacement, backups, and compatibility cleanup. |
| `src/runtime.rs` | Private files, locks, and quoted commands. |
