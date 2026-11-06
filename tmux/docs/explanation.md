# Explanation

For instructions, use the [tutorial](tutorial.md) or [how-to guides](how-to.md).
This page explains the design and its limits.

## Why status hooks are optional

The sidebar manages tmux panes independently of agent status.
The macOS panel and sidebar read the same agent-stat events, so the terminal installer adds no agent hooks.
Without those events, navigation and recovery still work; rows have no status dot.

The status reader checks the host, process ancestry, and process start time before matching a record to a pane.
The terminal tracks viewed responses separately from the macOS panel.
Acknowledging attention in one interface does not acknowledge it in the other.

## Why windows share a renderer

With `--shared`, one service draws the sidebars for all enabled windows and sessions on a tmux server.
Each sidebar is an empty tmux pane with no renderer process of its own.
The service shares process scans and event reads. Each pane keeps its own selection state.

Mouse and keyboard bindings send events through a private Unix socket.
The service reuses the existing drawing code and actions.
Menus, search, and floating views open when needed. They do not block the service.
Recovery monitors and their control clients remain separate from the renderer.

The shared service checks pane records about every 150 milliseconds and scans processes about once per second.
It reads process ancestry globally, then reads command details only for content processes and their descendants.
It shares unchanged session rows and skips frame construction until rows or pane dimensions change.
It sends output only when a pane's frame changes.
Left clicks check current pane dimensions because layout hooks can resize a pane between refreshes.
Input and layout actions restart a stopped service. Recovery monitors also check it about every ten seconds.
Monitors use their control connections to detect session closure. If an observer stops, its monitor resumes polling.

Keep `--shared` in installation and upgrade commands.
Omitting the flag selects a separate renderer for each window.
See the [renderer measurements](shared-render-experiment.md) for measured memory use and comparison limits.

## Why shells start after layout preparation

A shell can print its prompt before tmux finishes adding the sidebar.
A later resize can leave repeated prompts. The shell launcher prepares the layout before starting the login shell.
It also sets a new split's terminal dimensions before that shell prints.
Existing custom `default-command` settings take priority.

The layout code prepares inactive windows before selection when window sizing is automatic.
That keeps the sidebar from stretching during a switch. Manual sizing and the native sizing policy remain intact.
Auto zoom uses native resizing, saves the base layout, and keeps other panes visible.
If the pane set changes, the next focus change records a new base layout.

## Why recovery cannot preserve a running process

Snapshots describe how to reopen work. They do not save the memory of a running process.
Claude and Codex conversations can resume through those tools' own commands and saved profiles.
Other programs need their saved arguments, folder, and a new process environment.
That is why command reruns require an explicit selection in the preview.

## Why a closed program does not stay recoverable

The monitor saves about every ten seconds while the sidebar runs.
A fresh empty shell after a restart does not erase the last recoverable snapshot.
Internal sidebar helpers do not count as recoverable work during startup.
Once the monitor sees recoverable work, later snapshots follow the session's current state, including deliberate closures.
A closed window therefore disappears from later snapshots. Recovery is a recent session snapshot, not an archive of every closed program.
Tests stop and restart isolated tmux servers. They check snapshot preservation while a startup helper runs.

## Why an extra tmux client appears

A persistent control client detects the prefix key. It ignores terminal size and receives no pane output.
It appears in `tmux list-clients` for each enabled session.
Input handling reuses pane records and wrapped text instead of scanning processes for every key or scroll event.
With separate renderers, inactive windows check their records every five seconds; selecting a window wakes its renderer immediately.
The shared service uses the refresh schedule described above.

## Why an upgrade can leave empty hook files

A running agent can retain an old Python hook command.
The installer removes retired Python terminal files and prototype binaries after replacement.
Migration leaves empty compatibility endpoints so that old callers do not fail and block a prompt.
They run no Python implementation. The Rust monitor removes them after the recorded agent processes exit.
Fresh installations create no compatibility guards. Shared hooks, the stream helper, and the macOS app remain separate components.
