# How-to guides

Use these guides for a specific task. For a first installation, follow the [tutorial](tutorial.md).

- [Upgrade the sidebar](#upgrade-the-sidebar)
- [Install on another machine](#install-on-another-machine)
- [Show a missing sidebar](#show-a-missing-sidebar)
- [Rename a pane or window](#rename-a-pane-or-window)
- [Change zoom and pane sizes](#change-zoom-and-pane-sizes)
- [Recover saved work](#recover-saved-work)
- [Enable agent status dots](#enable-agent-status-dots)
- [Keep personal tmux settings](#keep-personal-tmux-settings)

## Upgrade the sidebar

From the updated repository root, run:

```sh
cargo build --release --locked --manifest-path tmux/Cargo.toml
tmux/target/release/agent-stat-tmux install --apply --reload --restart
```

The installer replaces sidebar processes and monitors while preserving content panes and their processes.
It prints the backup path. See the [installer flags](reference.md#installer-flags) for other deployment options.

## Install on another machine

1. Connect to that machine and obtain a copy of this repository.
2. Check the [host and build requirements](reference.md#requirements).
3. Run the tutorial's build and installation commands on that machine.
4. Start tmux there and check that the sidebar appears.

An existing binary must match the destination's operating system and architecture.
Settings sync does not install the executable. Each sidebar reads that machine's local events.

## Show a missing sidebar

Inside tmux, press Ctrl+b, then Tab, to show a hidden sidebar.
If the bindings are not loaded:

1. Press Ctrl+b, then `:`, to open the tmux command prompt.
2. Enter `source-file ~/.config/tmux/window-sidebar.conf` and press Enter.
3. If the sidebar remains hidden, press Ctrl+b, then Tab.

If the terminal still shows an old frame, enter `refresh-client` at the same command prompt.
The error log is `~/.local/state/tmux-sidebar/sidebar.log`.

## Rename a pane or window

1. Select the pane you want to name.
2. Press F1, then `p` for Rename pane or `w` for Rename window.
3. Enter the name and press Enter.

To restore an automatic pane title, select **Reset pane name** in F1.
Use Ctrl+b, then `f`, to view the full title, folder, and command.

## Change zoom and pane sizes

1. Open F1 and press `a` to toggle Auto zoom for the current window.
2. When enabled, click a pane to enlarge it. The top-right border label also toggles this setting.
3. For full zoom, press Ctrl+b, then `z`. Repeat to return to the split view.

Turn auto zoom off before setting manual pane sizes. Drag a content border to resize panes.
Before native layout changes or pane swaps, hide the sidebar with Ctrl+b, then Tab. Show it again afterward.

## Recover saved work

A saved command can repeat its actions. Review its arguments before selecting it.

1. Press Ctrl+b, then `r`, or choose **Recover saved work** from F1.
2. Review the preview. Supported Claude and Codex conversations use their native resume commands.
3. To rerun a saved command, press `c` to reach it, then Space to select it. You can also click its checkbox.
4. Press `r`, or click **Restore**, to create `recovered-<session>`.

Other panes open shells in their saved folders. Commands start unselected.
Restore requires a resumable conversation or a selected eligible command.
Escape cancels without starting programs. The wheel, arrows, Page Up, and Page Down scroll the preview.
See [recovery limits](reference.md#recovery-limits) if a command cannot be selected.
See [snapshot behavior](explanation.md#why-a-closed-program-does-not-stay-recoverable) to understand when recovery becomes available.

## Enable agent status dots

The sidebar works without status hooks. To add dots, use Python 3.11 or later and `jq` on the reporting machine.

1. From the repository root, run `python3 install.py` to preview the shared hook installation.
2. Run `python3 install.py --apply` to install those hooks.
3. Start new Codex sessions. Claude Code reloads its settings automatically.
4. Check the sidebar after an agent reports an event.

This installs the shared hooks and stream helper. It does not build or start the macOS panel.
The terminal installer adds no duplicate agent hooks. See the [status colors](reference.md#status-colors).

## Keep personal tmux settings

Place personal settings after the sidebar's source line in `~/.tmux.conf` so they take priority.
The installer rewrites `~/.config/tmux/window-sidebar.conf`; keep personal changes in `~/.tmux.conf`.
Native tmux handles sessions, copying, scrollback, layouts, resizing, and pane swaps.
Configure activity, silence, and bell alerts with native options. See the [configuration defaults](reference.md#configuration-defaults).
