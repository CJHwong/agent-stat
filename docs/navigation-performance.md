# Navigation performance

Measured on macOS on 2026-11-05, before and after the six performance fixes.
The initial measurements cover the working navigation changes and the committed baseline, `bf05b78`.

## Results after fixes

Each row compares medians before and after the fixes.
The command counts exclude Ghostty focus for the remote rows.
Those rows use the isolated local server through the route implementation, without network delay.

| Operation | Before | After | Commands before | Commands after |
| --- | ---: | ---: | ---: | ---: |
| Complete local jump by pane | 665 ms | 531 ms | | |
| Complete local jump by title | 1,093 ms | 551 ms | | |
| Empty command | 12.9 ms | 1.39 ms | 1 | 1 |
| Read 256 KiB | 213.1 ms | 1.75 ms | 1 | 1 |
| Remote pane identifier | 48.5 ms | 9.93 ms | 3 | 2 |
| Remote title | 95.2 ms | 15.20 ms | 5 | 3 |
| Remote title with folder alias | 142.6 ms | 25.79 ms | 7 | 4 |
| Local identifier without a matching Ghostty client | 435.7 ms | 326.2 ms | 7 | 5 |
| Local title without a matching Ghostty client | 894.3 ms | 329.8 ms | 9 | 6 |

The 95th percentile after the fixes is 559 ms for complete pane jumps and 639 ms for complete title jumps.
The complete probes repeat the same target after warmup and check the resulting pane and window.
Ghostty enumeration still costs about 300 ms on this desktop.
Its cost remains part of every complete jump.

All six fixes are implemented:

1. Remote title jumps reuse the pane details from their first listing.
2. Remote folder resolution runs at most once per jump, including failed resolution.
3. Local title jumps reuse one Ghostty snapshot; final focus still checks the stable surface identifier.
4. Pane listings include the terminal field, with the folder last to preserve commas and empty fields.
5. The command runner uses kernel events for output, process exit, and deadline waits.
6. One tmux call selects the window and pane; a progress marker preserves separate failure messages.

Snapshots and folder results remain within one jump.
The next jump reads fresh state.
The process ownership checks remain enabled.

Regression tests cover large output, continuous output, closed output, command counts, shell quoting, and selection failures.
Real tmux checks confirm that a failed window selection stops the batch before pane selection.
The full gate passes 561 Swift checks, 86 Python tests, and both Rust suites.
The app build also passes.
An earlier native terminal run exceeded its 250 ms help-close limit.
That test passed alone, and the next complete suite passed.

The following sections preserve the initial measurements.

## Method

The Swift probes use optimized builds and synthetic sessions in isolated tmux servers.
Each operation has one warmup, then 20 measured samples unless specified below.
The 95th percentile uses the nearest rank.
The probes count external commands and measure elapsed time around each command.
They save command types, not session names, terminal contents, or host names.

The complete local probes use a temporary Ghostty window with an attached tmux client.
They check successful results, the selected pane, and the front window.
The split probe also checks the focused terminal.
Each probe closes its window and stops its isolated server.

The remote command probes run against an isolated local server through the route implementation.
They measure command counts and local execution cost, without network delay or Ghostty focus.
A separate probe measures ten read-only calls through the configured SSH transport.
SSH means Secure Shell.

These measurements run on a working desktop, without control of other system activity.
They do not measure cold application startup, denied permissions, or human delay in a picker.
They do not establish a performance budget for every possible navigation branch.

## Complete local operations

| Operation | Median | 95th percentile |
| --- | ---: | ---: |
| Jump by pane identifier, including Ghostty focus | 665 ms | 702 ms |
| Jump by title, including Ghostty focus | 1,093 ms | 1,356 ms |
| Focus an existing Ghostty split | 178 ms | 215 ms |

The title probe uses a Ghostty client whose folder matches the session folder.
The complete probes use production source without instrumentation.
The process remains alive throughout each sample.
The probes repeat the same target after warmup; they do not reset focus before each sample.

## Components and command counts

| Operation | Median | 95th percentile | External commands |
| --- | ---: | ---: | ---: |
| Empty command, 100 samples | 12.9 ms | 13.6 ms | 1 |
| Read 256 KiB, 10 samples | 213.1 ms | 217.5 ms | 1 |
| Check process identity 1,000 times | 8.43 ms | 10.81 ms | 0 |
| Enumerate Ghostty surfaces | 313.9 ms | 331.4 ms | 1 |
| Remote pane identifier, canonical folder | 48.5 ms | 50.2 ms | 3 |
| Remote title, canonical folder | 95.2 ms | 101.9 ms | 5 |
| Remote title, folder alias | 142.6 ms | 148.8 ms | 7 |
| Remote missing pane | 23.9 ms | 25.5 ms | 1 |
| Local identifier, ending without a matching Ghostty client | 435.7 ms | 461.9 ms | 7 |
| Local title, ending without a matching Ghostty client | 894.3 ms | 946.1 ms | 9 |
| Configured SSH read-only call, 10 samples | 58.8 ms | 73.7 ms | 1 |

The instrumented local probes attach through a synthetic terminal outside Ghostty.
They exercise pane selection and live Ghostty enumeration, then return a missing-client failure.
They suppress application activation in their temporary source copies.
They do not represent a successful complete jump; the complete probes above provide that measurement.

The remote identifier path uses one listing and two selection commands.
The title path uses three listings and two selection commands.
The alias path adds two identical folder-resolution commands for its single candidate.
Each command becomes a separate SSH call when the route uses SSH.
The measured SSH delay must not be treated as a fixed cost on other networks.

## Confirmed waste

1. The title path reads pane details twice during one remote jump.
   Reuse those details within that jump, with explicit handling of selection failure.
2. The alias path resolves the same folder twice for one candidate.
   Resolve the folder once per jump and reuse its result across candidates.
3. The local title path enumerates Ghostty before and after pane selection.
   Check whether one snapshot can serve both steps without weakening surface identity checks.
4. The local path reads pane details and pane terminals in separate listings.
   A single listing could provide both, with tests for empty fields and commas in paths.
5. The command runner sleeps 10 ms after each output chunk.
   Replace fixed sleeps with event waits and immediate draining of available output.
6. The selection path starts separate commands for the window and pane.
   Check tmux command sequencing and failure behavior before combining them.

The process identity check costs about 0.0084 ms per call without a recorded start time.
Its cost does not justify removing an ownership check.
Checks with a recorded start time also format and compare the timestamp; that variant is not measured here.

The runner improves empty-command time from 68.7 ms in the baseline to 12.9 ms.
However, its 256 KiB read regresses from 72.4 ms to 213.1 ms.
The output loop reads at most 16 KiB before each fixed sleep.
This loop adds delay proportional to output size.
These results support a runner fix, while preserving deadlines and descendant cleanup.

## Background readers

The existing reader benchmark uses 50,000 events, 365 empty files, and 1,000 synthetic names.
It reports the median of three runs.

| Operation | Median |
| --- | ---: |
| Read the event history | 306.7 ms |
| Poll unchanged events once, derived from 100 polls | 3.05 ms |
| Read unchanged names once, derived from 30 reads | 0.51 ms |

Source inspection shows that Ghostty enumeration runs only while the panel is open, at most once per 30 seconds.
Navigation performs additional live reads when the user clicks.
This pass does not measure total application processor use or memory use.

## Evidence and repeat runs

The raw results and synthetic probes reside under the local state directory:
`agent-stat/audits/2026-11-05-navigation/performance/`.
Run `measure.py`, `focus.py`, and `full.py` from the repository root.
The scripts require Swift, tmux, Ghostty, and existing Automation permission.
The main probe also requires the configured SSH route.
It writes its results under `/tmp/agent-stat-performance/`; create that directory before a repeat run.

Run `python3 tests/performance-probe.py` to repeat the background reader benchmark.
Run `python3 tests/navigation-performance-probe.py --output /tmp/navigation-performance.json` to repeat component measurements.
Add `--ssh` for read-only measurements through the configured SSH route.
Add `--baseline bf05b78` to compare the committed baseline.
The complete local probes and raw before-and-after results remain in the local audit directory.
