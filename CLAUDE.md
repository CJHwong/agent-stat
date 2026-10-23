# agent-stat, notes for an agent working in this repo

`README.md` is for a person who wants to use the panel. This file is for an agent
changing the code. Keep that split.

## Commands

| Command | What it does |
|---|---|
| `bash scripts/test.sh` | The unit tests, then the app build. Run it before you claim anything. |
| `python3 -m unittest discover -s tests -p 'test_stream_events.py'` | Tests the stream helper with isolated event files. |
| `python3 tests/stream-probe.py` | Tests the actual Swift connection with a separate local writer. |
| `python3 tests/stream-probe.py --ssh <peer>` | Runs the same checks with isolated source files on a second machine. |
| `python3 tests/stream-lifecycle-probe.py` | Checks blocked input, forced helper shutdown, and slow replay against the real watchdog. |
| `python3 tests/codex-title-probe.py` | Checks name capture and renames through real Codex hooks in an isolated profile. |
| `python3 tests/startup-probe.py` | Checks actual app startup with an isolated remote cache and saved row memory. |
| `python3 tests/performance-probe.py` | Measures history reads, idle polls, and repeated name reads in isolated files. Use `--binary <path>` to save a build, then `--compare <path>` to compare it with the current code. |
| `python3 scripts/migrate-storage.py` | Checks existing storage and profiles without changes. Requires Python 3.11 or later. |
| `python3 install.py` | Dry run of the hook install. |
| `python3 install.py --apply` | Deploy the hooks and stream helper locally, merge the config entries, write the Codex trust hashes. Run on each host. |
| `python3 tests/live-probe.py` | A real `claude` and a real `codex` against throwaway config trees. Points `HOME` at a temp tree. |
| `python3 tests/close-probe.py [claude\|codex]` | What a closed session reports, under a real pty. |
| `python3 scripts/demo-events.py /tmp/demo` | A synthetic events tree covering every state, plus a second machine. |
| `.build/AgentStat.app/Contents/MacOS/AgentStat --render out.png` | Draw the panel to a PNG. The system material does not draw offscreen, so it comes out opaque. |
| `.build/AgentStat.app/Contents/MacOS/AgentStat --plan-jump <folder>` | Print what a click would do, without touching anything. |

## Rules that are not style

1. **The hook must exit 0 and never hang.** Exit code 2 from a hook means "block
   the tool call", so a hook that fails takes the whole agent down with it, and the
   registered timeout is 3 seconds.
2. **No apostrophe in a comment in `hooks/*.sh`.** The hook's jq program is one
   single-quoted string, so one apostrophe in a comment ends it early and makes the
   file unparseable. `scripts/test.sh` checks for this before it builds.
3. **One writer per file in the events directory, and never truncate.** Each host
   writes its own history. The stream helper serves only that host's files.
   The file name carries the host. Remote caches belong to the receiver.
4. **The app and the hook must agree on the host name byte for byte.** The app calls
   `gethostname(2)`; the hook prints `uname -n`. Every locality rule is a string
   compare between them, so a difference silently turns this machine into a remote
   one. A test runs `uname -n` and compares.
5. **Everything the panel hands to tmux must survive a shell.** A route runs the
   command through ssh, and ssh hands the other end to a shell. A space splits an
   argument and a leading `#` starts a comment; both were measured, and a test now
   refuses any argument a shell would break.
6. **A route's program must be startable.** `Process` wants a file, not a name, so
   a bare `ssh` was read as `/ssh` and no route ran. Bare names go through
   `/usr/bin/env`.
7. **Keep AgentStat storage outside synced folders.** The default is
   `~/.local/state/agent-stat`. It holds local events, deployed scripts, and remote
   caches. Routes and row acknowledgements remain in `~/.config/agent-stat`.
8. **A second Claude config tree needs the same entries by hand.** The installer
   only knows `~/.claude`. Another config tree carries the same registered entries
   pointing at the same deployed script, and sessions running under a tree that is
   missed stop reporting. Change both in the same act.

## Linting

The commit gate is `.pre-commit-config.yaml`, installed once with `prek install`, which
writes `.git/hooks/pre-commit`, `.git/hooks/pre-push` and `.git/hooks/commit-msg`. Run the whole gate by hand
with `prek run --all-files`, and never bypass it.

| Hook | What it covers |
|---|---|
| `ruff check`, `ruff format` | The Python files. |
| `shellcheck -x` | The shell scripts, following sources. |
| `hook scripts parse, with no apostrophe in a comment` | The two scripts in `hooks/`, through `scripts/guard-hooks.sh`. |
| `swiftlint --strict` | The Swift sources and tests, configured by `.swiftlint.yml` and `tests/.swiftlint.yml`. |
| `commitlint` | The commit message, at the commit-msg stage, judged by `@commitlint/config-conventional` through `.commitlintrc.yaml`. The convention is `type(scope): subject` in lower case, with a `[why]` and a `[how]` body. |
| The hygiene hooks | Trailing whitespace, end of file, mixed line endings, JSON validity, merge conflicts, large files, private keys. |
| The pre-push stage | `scripts/test.sh`, so a push carries passing tests and a building app. |

`scripts/test.sh` also runs the stream and migration tests. Python 3.11 or later is required for migration tests.
It also checks blocked helper input and forced shutdown. The full lifecycle probe additionally checks the real watchdog delay.
Use isolated event folders
and separate writer processes for a real stream probe before migrating live storage.

Two formatters are deliberately not in the gate. `swift-format` would rewrite every
Swift file to a two space indent, and `shfmt` expands the compact failure guards the
shell scripts use. Their lint halves are in: `shellcheck` and `swiftlint` both report
nothing here.

## Layout

| Path | What it is |
|---|---|
| `src/` | The app. `Session` and `SessionStore` are the model and hold no SwiftUI, no file access and no timers, so the tests drive them directly. |
| `src/main.swift` | The menu bar item, the panel window, the 1 second tick, and the two development flags. |
| `hooks/` | Two shell scripts: the hook every agent event calls, and the bridge an orchestrator calls when a run ends. |
| `install.py` | Deploys the scripts and merges the two config files. |
| `scripts/` | The test gate and the demo event generator. |
| `tests/` | The unit tests, and two probes that drive real agents. |
| `docs/` | The guides, the reference and the reasons, for a person using the panel. `README.md` is the short version and points at them. |

## Deploying a change

The deployed copy is what runs. Editing `hooks/` changes nothing until
`python3 install.py --apply`. The app changes after a relaunch.
Run the installer on each machine. It deploys scripts under
`~/.local/state/agent-stat/bin`, including `stream-events.py`.
Synced agent settings can reference the same absolute path on each machine.
They do not deploy the script at that path.

Remote routes have an optional `events` argument array, separate from `tmux`.
The app starts that command to receive events. It never derives the stream command
from the navigation command. Remote caches live under
`~/.local/state/agent-stat/remote/<host>/hosts`.

Before moving live files, validate the stream in isolated folders on both machines.
Retain old history. Keep a compatibility launcher for active sessions that retain
the old hook command. Update every profile and orchestrator end bridge caller.
