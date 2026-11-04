# Shared renderer and memory measurements

The shared renderer serves all enabled windows through one process per tmux server.
Each sidebar is an empty tmux pane. It runs no command.
The service shares event reads and process scans. It sends a frame only when that frame changes.
Each pane retains its selection state.
Mouse and keyboard bindings send events through a private Unix socket.
The service uses the existing drawing code and action handlers.
Popups run separately so they cannot block the other sidebars.

Install the shared renderer with:

```sh
cargo build --release --locked --manifest-path tmux/Cargo.toml
tmux/target/release/agent-stat-tmux install --shared --apply --reload --restart
```

Keep `--shared` on subsequent upgrades.
To return to separate renderers, run the same installer without `--shared`.
The installer backs up the binary and configuration. It preserves content processes.

New windows receive empty sidebars automatically.
Several sessions share the same renderer process.
Input and layout actions restart a stopped service. The recovery monitor also checks it about every ten seconds.

## Office measurements

The initial drawing experiment ran on the office Mac with tmux 3.8 on November 5, 2026.
These measurements precede the addition of mouse and keyboard input.
Each case used a separate server, empty event storage, and the same release executable.
Each window contained one sleeping command and one sidebar at 28 columns.
The probe waited two seconds before a ten-second sample period.
Memory values show the median of the samples, in mebibytes (MiB).

| Windows | Separate renderer processes | Shared renderer process | Separate tmux server | Shared tmux server |
|---|---:|---:|---:|---:|
| 1 | 4.45 | 5.30 | 2.83 | 4.00 |
| 8 | 43.53 | 5.33 | 4.06 | 4.16 |
| 32 | 174.08 | 4.70 | 4.72 | 4.12 |

Renderer memory sums each process's resident set size (RSS).
Shared library pages can appear in several processes. These sums do not measure unique physical memory.
Residency changes with system load. The lower shared result at 32 windows does not imply that more windows reduce allocations.
Fresh processes also differ from the existing office processes, which showed about 3.8 MiB each.
The production recovery monitor is outside these measurements.

A second eight-window run checked the final build with a five-second sample period.
Separate renderers used 30.47 MiB. The shared renderer used 4.14 MiB.
Their tmux servers used 3.30 MiB and 3.36 MiB, respectively.
All drawing checks passed again. The repeated run confirms the reduction despite changes in residency.

The probe checked content in every sidebar, a rename in every sidebar, the narrow arrow, and content after resizing.
The shared case passed these checks at all three window counts.
The current renderer also passed.

With input enabled and live events, the complete renderer used 6.95 MiB for eight windows after the office checks.
This value is one resident sample after interactive checks. It is not a comparison with the earlier empty-event samples.

## Checks and measurement limits

The native terminal suite checks shared mouse input, keyboard navigation, menus, search, repeated clicks, grouping, zoom, and narrow-window overlays.
It also checks new windows, two attached sessions, service restart, upgrade, rollback, and unchanged content processes.
The control tests include a monitor that inherits `TMUX` and `TMUX_PANE` from a hook.
The shortcut observer clears those variables before it attaches to the requested session.
A real terminal check passed mouse selection and keyboard navigation on the office server, which runs tmux 3.7c.

The shared renderer polls at 150 milliseconds. Inactive production renderers poll at five seconds.
The rename probe waits for every sidebar. Its delay is not a comparison of equal refresh schedules.
The probe reports processor time for the renderer processes and the server.
It excludes short-lived `tmux` and `ps` children. Use those processor results only as partial measurements.
The empty event storage does not represent a full day of live agent events.

## Repeat the memory measurements

1. Build the release executable.

   ```sh
   cargo build --release --locked --manifest-path tmux/Cargo.toml
   ```

2. Run the probe from the repository root.

   ```sh
   python3 tests/shared-render-probe.py --binary tmux/target/release/agent-stat-tmux --windows 1 8 32 --seconds 10
   ```

The probe creates separate servers and removes them after each case.
It does not install the executable or change the live tmux configuration.
