# Tutorial: your first sidebar session

Build the sidebar, open a session, and try switching between panes.
You need macOS, tmux 3.7c or later, Rust, and Cargo.
Start in the repository root, in a terminal outside tmux.

## 1. Build the binary

```sh
cargo build --release --locked --manifest-path tmux/Cargo.toml
```

The binary appears at `tmux/target/release/agent-stat-tmux`.

## 2. Inspect the installation

```sh
tmux/target/release/agent-stat-tmux install
```

This preview prints the executable and configuration paths without changing files.
Installation enables the mouse and hides the native status bar; see [configuration defaults](reference.md#configuration-defaults).

## 3. Install the sidebar

```sh
tmux/target/release/agent-stat-tmux install --shared --apply --reload --restart
```

The installer prints a backup path and preserves running content processes.
The `--shared` flag selects one renderer for all enabled windows and sessions on this tmux server.
Keep the flag when you upgrade.

## 4. Open a session and split a pane

```sh
tmux new-session -s sidebar-tour
```

The sidebar appears on the left. Press F1, then `%`, to split the shell into two panes.
Click each shell pane. Auto zoom enlarges the selected pane and keeps the other visible.

## 5. Name a pane and find it

1. Click a shell pane. Press F1, then `p`.
2. Enter `Tour` as its name and press Enter. Its sidebar row now shows that name.
3. Press Ctrl+b, release it, then press `/`.
4. Type `Tour` and press Enter to select the matching pane.

F1 opens the action menu. Ctrl+b, followed by `?`, shows the shortcut list.

## 6. Detach and return

Press Ctrl+b, then `d`, to detach. Your shells remain running.
Return with:

```sh
tmux attach-session -t sidebar-tour
```

Next, use the [how-to guides](how-to.md) for a specific task or the [reference](reference.md) to look up a control.
