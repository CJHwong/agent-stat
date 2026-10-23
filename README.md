# agent-stat

A macOS menu bar panel that shows what your Claude Code and Codex sessions are doing,
across machines.

It reads their hook systems. Neither tool is modified and neither is wrapped: the hooks
write, this app reads.

## Get it running

1. `bash build.sh`, then open `.build/AgentStat.app`. An icon appears in the menu bar.
2. `python3 install.py` prints what it would change. `python3 install.py --apply` does it.
3. Codex reads its hooks at session start, so start a new Codex session. Claude Code
   re-reads its settings at once.
4. Click the icon. Rows appear as your sessions report.

The installer merges its entries into `~/.claude/settings.json` and
`~/.codex/hooks.json`, leaves every other hook alone, backs up both files first, and
writes the trust entries Codex needs. To remove it later, delete the entries whose
command contains `agent-stat`.

Events and deployed scripts live in `~/.local/state/agent-stat`, outside synced folders.
Run the installer on each machine. Add an `events` command to a remote route to receive
events over Secure Shell (SSH). Event delivery and script deployment require no Syncthing.
See [the second machine guide](docs/guides.md#report-from-a-second-machine).

## Documentation

| Document | What is in it |
|---|---|
| [docs/guides.md](docs/guides.md) | Go to a session, hide a row, reach a session on another machine, close a run an orchestrator finished, report from a second machine. |
| [docs/reference.md](docs/reference.md) | What each colour means, what a row says, the shape of the events file, where the files live, the messages a click can print, and the timing constants. |
| [docs/how-it-works.md](docs/how-it-works.md) | Why one writer per file, why the hook cannot block an agent, why a remote click needs a route, and why the fold is deterministic. |

Tests and development aids are in [CLAUDE.md](CLAUDE.md).

## License

MIT. See [LICENSE](LICENSE).
