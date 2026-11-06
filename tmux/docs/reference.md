# Reference

For procedures, see the [how-to guides](how-to.md). For a first session, use the [tutorial](tutorial.md).

## Requirements

| Component | Requirement |
|---|---|
| Checked host | macOS with tmux 3.7c or later; floating panes require that tmux version. |
| Build | Rust and Cargo. |
| Deployed sidebar | One Rust binary; no Python runtime or running macOS panel. |
| Optional status hooks | Python 3.11 or later and `jq` for the separate shared hook installation. |

The macOS panel builds separately with `bash build.sh`; it does not require Cargo.

Use `install --shared --apply --reload --restart` to share one renderer across the server.
See the [shared renderer and memory measurements](shared-render-experiment.md) for controls, recovery, and measured memory use.

## Controls

Ctrl+b means the default tmux prefix: press it, release it, then press the next key.
If you use another prefix, substitute it for Ctrl+b.

| Control | Result |
|---|---|
| Click a sidebar row | Select its window or pane. |
| New, Split, Rename | Create a window, choose a split direction, or name a pane. |
| F1 or right-click | Open Actions. Escape closes the menu. |
| Ctrl+b / or sidebar Search | Search titles, folders, and commands. |
| Ctrl+b f | Show the full title, folder, and command. |
| Ctrl+b r | Open the recovery preview. |
| `s` in recovery | Save all current windows and replace this session's latest snapshot. |
| `r` in recovery | Restore all eligible saved conversations and commands. |
| Ctrl+b Tab | Toggle the sidebar. |
| Ctrl+b z | Toggle full zoom for the content pane. |
| Ctrl+b ? | Show shortcuts. Escape or `q` closes the list. |
| Ctrl+b alone | Show the centered next-key sheet; it stays hidden during full zoom. |

### F1 menu keys

Separators group creation, layout, naming, information, and closing actions.
Items without a direct key remain selectable with the mouse or arrow keys.

| Key | Action |
|---|---|
| `c` | New window in the current content folder. |
| `%` | Split side by side. |
| `"` | Split above and below. |
| `a` | Toggle Auto zoom. |
| `z` | Toggle full zoom. |
| `p` | Rename pane. |
| `w` | Rename window. |
| No direct key | Reset pane name. |
| `/` | Search windows and panes. |
| `f` | View full command. |
| `s` | Explain status colors. |
| `r` | Recover saved work. |
| `d` | Detach. |
| `x` | Close pane, after confirmation. |
| No direct key | Close window, after confirmation. |

## Rows and layout

Rows stay in numeric window order. A manual label takes priority over the pane title or running command.
The second line shows the folder name. Windows with several content panes have a group heading and individual pane rows.
`▲ More above` and `▼ More below` mark entries outside the visible list.
When the last content pane exits, the sidebar closes that window and focuses a neighboring window's content pane.
It chooses the previous window, or the next window if no previous window exists.

| Setting | Default behavior |
|---|---|
| Sidebar width | 28 columns. |
| Narrow terminal | Below 100 columns, a three-column rail replaces the sidebar. |
| Rail arrow | Centered `▶`; clicking opens an overlay without narrowing content panes. |
| Overlay dismissal | Escape closes it. Widening the terminal restores the docked list. |
| Auto zoom | Enabled; about 85% of the available width or height, subject to native split limits. |
| Auto zoom setting | Saved per window and included in recovery snapshots. |
| Auto zoom dimming | On tmux 3.8 or later, inactive content panes use 50% dimming. The sidebar retains normal brightness. |
| Border label | `Auto zoom: on` or `Auto zoom: off`; compact labels are `Zoom:on` and `Zoom:off`. |
| Border toggle target | The top-right pane's border on tmux 3.7c and 3.8. |
| Disable auto zoom | Restore normal brightness and the base layout if the same panes remain. |

## Status colors

| Color | Meaning |
|---|---|
| Green | Working, including a finished parent with live subagents. |
| Red | A permission request or finished response needs attention. |
| Orange | Failed. |
| Blue | Ready, or a request or response you have viewed. |
| Purple | Interrupted. |
| Gray | Closed. |
| No dot | No recorded agent status. |

An asterisk marks attention. Selecting the content pane clears it and changes its dot to blue.
Viewing a permission request does not approve it.
A new event can request attention again, including one with the same timestamp.
Colors follow the macOS panel's meanings; terminal shades depend on the palette. A finished response does not prove task success.

## Recovery limits

Snapshots record layouts, folders, labels, auto zoom settings, conversation identifiers, profiles, and exact foreground arguments about every ten seconds.
The sidebar shows Recover only when saved work is available; F1 and Ctrl+b r remain available.
Restore checks running processes again and skips conversations already running in the source session.
Claude's native session registry can provide recovery metadata without supplying status dots.

Restore all skips commands that remain running, contain masked credentials, or represent interactive shells.
Snapshots without exact arguments, a process identifier, or a process start time cannot supply a rerunnable command.
Argument boundaries preserve spaces, empty values, and shell punctuation.
Rerun uses the saved folder and the new terminal's environment.
Recovery does not restore process memory, shell aliases, or the previous environment.
Command masking covers known credential flags; it is not a general secret detector.

## Configuration defaults

The installer adds one source line to `~/.tmux.conf` and preserves its other content.
Generated configuration enables the mouse, hides the status bar, enables top pane titles, and sets `escape-time` to 20 milliseconds.
It installs the bindings listed above. It leaves native activity, silence, and bell alerts unchanged.
New attached sessions and windows in enabled sessions receive sidebars automatically.
An intentionally hidden sidebar stays hidden on reattachment.
An empty `default-command` receives the shell launcher; existing custom commands take priority.

## Installer flags

Run `tmux/target/release/agent-stat-tmux install [FLAGS]` from the repository root.

| Flag | Effect |
|---|---|
| None | Print the plan without writes. |
| `--apply` | Install the binary and configuration, with a private backup. |
| `--shared` | Use one renderer for all enabled windows and sessions on a server. Keep this flag on upgrades. |
| `--reload` | Reload bindings on a running server; requires `--apply`. |
| `--restart` | Reload and replace sidebar processes and monitors; preserve content processes. Requires `--apply`. |
| `--home DIR` | Choose an installation home. |
| `--socket PATH` | Choose the tmux server for reload or replacement. |

## Runtime commands

Inside tmux, use `~/.agents/tmux/agent-stat-tmux --session NAME ACTION`.
Outside tmux, or for another server, also supply `--socket PATH`.

| Action | Result |
|---|---|
| `snapshot` | Save a checkpoint and print its JSON. |
| `plan` | Print recovery eligibility. |
| `restore` | Resume eligible saved conversations. |
| `restore --rerun PANE` | Also rerun the selected stopped command. Repeat `--rerun` for several commands. |

## Files and environment

| Path | Purpose |
|---|---|
| `~/.agents/tmux/agent-stat-tmux` | Executable and installer. |
| `~/.config/tmux/window-sidebar.conf` | Generated bindings and hooks. |
| `~/.local/state/tmux-sidebar/sidebar.log` | Errors. |
| `~/.local/state/tmux-sidebar/snapshots/` | Private recovery snapshots. |
| `~/.local/state/tmux-sidebar/backups/` | Installation backups. |
| `~/.local/state/agent-stat/hosts/` | Shared status events. |
| `/tmp/agent-stat-tmux-<user-id>/shared-<hash>.*` | Private shared socket, service identity, and locks for each server. |

`AGENT_STAT_DIR` overrides the events directory. `TMUX_SIDEBAR_STATE_DIR` overrides recovery, logs, and other runtime state.
The shared socket and its locks stay in the private temporary directory shown above.
This keeps the socket path within the macOS length limit.
Snapshots use format V1 and retain compatibility with the retired implementation. Snapshots and backups use private permissions; keep them out of Git.

## Development

Run these commands from the repository root:

```sh
cargo test --locked --manifest-path tmux/Cargo.toml -- --test-threads=2
cargo clippy --locked --manifest-path tmux/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path tmux/Cargo.toml --check
```

Integration checks require tmux and rustc. They use private homes, separate servers, compiled worker fixtures, and pseudo terminals.
They cover controls, latency, scrolling, status, arguments, profiles, layouts, recovery, and upgrades.
The [repository test gate](../../CLAUDE.md#commands) runs Rust checks when Cargo is available and skips terminal integration checks without tmux.

| Source | Responsibility |
|---|---|
| [main.rs](../src/main.rs), [ui.rs](../src/ui.rs) | Dispatch, background refresh, sidebar, search, and previews. |
| [model.rs](../src/model.rs), [events.rs](../src/events.rs) | Pane metadata, grouping, selection, and shared status. |
| [shared.rs](../src/shared.rs), [shared_input.rs](../src/shared_input.rs) | One renderer per server, pane state, socket input, and binding fallbacks. |
| [commands.rs](../src/commands.rs) | Exact arguments, masking, and profile capture. |
| [actions.rs](../src/actions.rs), [focus.rs](../src/focus.rs) | Menus, layouts, editing, overlays, and zoom. |
| [prefix.rs](../src/prefix.rs) | Control connection and shortcut sheet. |
| [recovery.rs](../src/recovery.rs), [recovery_ui.rs](../src/recovery_ui.rs) | Snapshots, eligibility, preview, and restore. |
| [install.rs](../src/install.rs), [runtime.rs](../src/runtime.rs) | Deployment, compatibility, private files, locks, and quoting. |
