# tmux sidebar

A persistent window list with agent status, search, and recovery.
Click a row to switch panes. Press F1 for actions.

The sidebar runs as one Rust binary. It needs no Python runtime or running macOS app.
The tutorial uses `--shared` to serve all enabled windows through one renderer per tmux server.
Keep that flag on upgrades. Agent status dots use the existing agent-stat hooks and are optional.

| What do you need? | Read this |
|---|---|
| Try the sidebar for the first time | [Your first sidebar session](docs/tutorial.md) |
| Upgrade, rename panes, change zoom, or recover work | [How-to guides](docs/how-to.md) |
| Look up keys, colors, requirements, or commands | [Reference](docs/reference.md) |
| Understand status, recovery, and layout behavior | [Explanation](docs/explanation.md) |
| Check renderer memory use and comparison limits | [Shared renderer measurements](docs/shared-render-experiment.md) |

The checked environment is macOS with tmux 3.7c or later.
Rust and Cargo are needed to build the binary, but not to run it.

For the macOS panel, see the [app build instructions](../README.md#build-and-run-the-macos-app).
