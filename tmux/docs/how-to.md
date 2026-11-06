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
tmux/target/release/agent-stat-tmux install --shared --apply --reload --restart
```

The installer replaces sidebar processes and monitors while preserving content panes and their processes.
It prints the backup path. See the [installer flags](reference.md#installer-flags) for other deployment options.

The command keeps one shared renderer for all enabled windows and sessions.
Keep `--shared` on later upgrades. Omit it to return to separate renderers.
See the [shared renderer](shared-render-experiment.md) for memory measurements and restart behavior.

## Install on another machine

1. Connect to that machine and obtain a copy of this repository.
2. Check the [host and build requirements](reference.md#requirements).
3. Run the tutorial's build and installation commands on that machine.
4. Start tmux there and check that the sidebar appears.

An existing binary must match the destination's operating system and architecture.
Settings sync does not install the executable. The renderer reads that machine's local events.

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
On tmux 3.8 or later, auto zoom also dims inactive content panes. Turn it off to restore normal brightness.
Before native layout changes or pane swaps, hide the sidebar with Ctrl+b, then Tab. Show it again afterward.

## Recover saved work

Restore all reruns eligible saved commands. Review the action list before restoring.

1. Press Ctrl+b, then `r`, or choose **Recover saved work** from F1.
2. Check the source session, destination session, and saved window names in the preview.
3. Review each pane's action: resume an agent, rerun a command, keep running, or open a shell.
4. Press `r`, or click **Restore all**, to create `recovered-<session>`.

Press `s` or click **Save snapshot** to save all current windows and refresh the preview.
Saving replaces the latest snapshot for this session. Save before stopping the tmux server.
The preview shows **Snapshot saved.** after a successful save.

Restore creates a separate session with all saved windows. It keeps their names and pane layouts.
If `recovered-<session>` exists, Restore uses the next unused suffix, such as `recovered-<session>-2`.
The preview shows the chosen destination. Existing recovery sessions stay in place.
You cannot select one destination window. Each saved window becomes a window in the recovered session.

Restore all includes every eligible stopped conversation and command. Other panes open shells in their saved folders.
There are no command checkboxes or selection shortcuts in the preview.
Escape cancels without starting programs. The wheel, arrows, Page Up, and Page Down scroll the preview.
See [recovery limits](reference.md#recovery-limits) if a command cannot be restored.
See [snapshot behavior](explanation.md#why-a-closed-program-does-not-stay-recoverable) to understand when recovery becomes available.

## Keep agent launch settings during recovery

Recovery saves each agent's profile, explicit model, and effort setting.
It also saves an explicit Codex `--no-daemon` flag.
Recovery captures external launchers from the agent's ancestors inside its tmux pane.
This supports persistent launchers for both Claude and Codex.
Codex recovery checks for one foreground Codex process, even when its launcher leads the process group.
A launcher must name the agent in its arguments. A `--` separator identifies forwarded agent arguments when present.
Recovery keeps the launcher prefix and replaces old resume arguments with the saved conversation ID.
This supports wrappers without rules for a specific provider or shell alias.
Aliases expand before the program starts, so recovery saves their effective external launcher, not the alias name.
Shell-only wrappers that disappear through `exec`, or hide the agent from their arguments, cannot be reconstructed this way.
Shell aliases do not need to exist in the new tmux server.
Older snapshots lack these launch settings. Save a new snapshot while the agents run.

For Codex, disable automatic daemon use in each profile's `config.toml`:

```toml
[features]
daemon_auto_start = false
```

Add the key to the existing `[features]` section if it exists.
Alternatively, run `codex features disable daemon_auto_start` with the profile's `CODEX_HOME`.
This setting prevents automatic daemon starts. Codex can still reuse an existing daemon.
Use explicit `--no-daemon` when a daemon is already running.
Existing Codex processes keep their current mode.
You do not need to restart tmux.
You can also use `codex --no-daemon` or `codex --no-daemon resume <session-id>` explicitly.

Codex's shared daemon can report a different client's pane in hooks.
Recovery rejects that process association instead of guessing which conversation belongs to a pane.
When hooks do not identify Codex, recovery checks the current terminal title against the profile's native name index.
The name must match exactly one conversation with matching transcript metadata. Use `/rename` to give conversations distinct names.
This fallback keeps the existing launch mode. It does not add `--no-daemon`.
Recovery can also repair older snapshots that retain the current conversation name in their saved terminal title.
It does not trust the launch command's ID after an in-app conversation switch.
Duplicate names and missing index records prevent this fallback.
The preview marks Codex panes with no verified ID instead of claiming to resume them.
A snapshot without a verified conversation ID cannot resume that conversation.
See the [Codex hook issue](https://github.com/openai/codex/issues/48500).

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
