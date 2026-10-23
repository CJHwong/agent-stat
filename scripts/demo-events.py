#!/usr/bin/env python3
"""Write a synthetic events tree so the panel can be exercised without real agents.

Real runs only produce a session at a time, and they end. This covers every state
at once, plus a second machine, which is what the panel has to render.

Usage: python3 scripts/demo-events.py /tmp/as-demo
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time
from pathlib import Path

NOW = int(time.time())

# The app checks whether a local session's pid is a live process, and says
# "process gone" when it is not. The fixture therefore has to name a pid that is
# really alive, or every row lies. pid 1 is launchd, which always is. Sessions on
# the other machine are never probed, so their pid does not matter.
LIVE_PID = 1


def local_host() -> str:
    name = socket.gethostname()
    return name[: -len(".local")] if name.endswith(".local") else name


def rec(
    ts: int, event: str, agent: str, pid: int, session: str, cwd: str, **extra
) -> dict:
    row = {
        "v": 1,
        "ts": ts,
        "agent": agent,
        "agent_pid": pid,
        "agent_start": "Thu Oct 16 17:02:11 2026",
        "event": event,
        "session": session,
        "cwd": cwd,
        "turn": None,
        "model": None,
        "tool": None,
        "dur_ms": None,
        "message": None,
        # The app jumps back to the terminal by folder, so the fixture names
        # the terminal it pretends to run in.
        "term": "ghostty",
        "tmux": None,
    }
    row.update(extra)
    return row


def build(host: str) -> list[dict]:
    rows: list[dict] = []
    add = rows.append

    # Claude mid tool call. Twelve seconds into a Bash command.
    add(
        rec(
            NOW - 600,
            "SessionStart",
            "claude",
            LIVE_PID,
            "c1",
            "/Users/you/work/api",
            # The name Claude Code gives a session, which the panel shows in place of the
            # folder when it has one.
            title="Builder Workshop",
        )
    )
    add(
        rec(
            NOW - 590,
            "UserPromptSubmit",
            "claude",
            LIVE_PID,
            "c1",
            "/Users/you/work/api",
            turn="a1b2c3d4",
        )
    )
    add(
        rec(
            NOW - 12,
            "PreToolUse",
            "claude",
            LIVE_PID,
            "c1",
            "/Users/you/work/api",
            turn="a1b2c3d4",
            tool="Bash",
        )
    )

    # Codex finished its turn two minutes ago.
    add(
        rec(
            NOW - 900,
            "SessionStart",
            "codex",
            LIVE_PID,
            "x1",
            "/Users/you/work/web",
            model="gpt-6-luna",
        )
    )
    add(
        rec(
            NOW - 300,
            "UserPromptSubmit",
            "codex",
            LIVE_PID,
            "x1",
            "/Users/you/work/web",
            model="gpt-6-luna",
            turn="01a14446",
        )
    )
    add(
        rec(
            NOW - 130,
            "PreToolUse",
            "codex",
            LIVE_PID,
            "x1",
            "/Users/you/work/web",
            model="gpt-6-luna",
            tool="Bash",
        )
    )
    add(
        rec(
            NOW - 126,
            "PostToolUse",
            "codex",
            LIVE_PID,
            "x1",
            "/Users/you/work/web",
            model="gpt-6-luna",
            tool="Bash",
        )
    )
    add(
        rec(
            NOW - 120,
            "Stop",
            "codex",
            LIVE_PID,
            "x1",
            "/Users/you/work/web",
            model="gpt-6-luna",
            turn="01a14446",
            message="done, tests pass",
        )
    )

    # Claude blocked on a permission prompt.
    add(
        rec(
            NOW - 240,
            "SessionStart",
            "claude",
            LIVE_PID,
            "c2",
            "/Users/you/work/notes",
        )
    )
    add(
        rec(
            NOW - 200,
            "UserPromptSubmit",
            "claude",
            LIVE_PID,
            "c2",
            "/Users/you/work/notes",
            turn="ff00aa11",
        )
    )
    add(
        rec(
            NOW - 34,
            "PermissionRequest",
            "claude",
            LIVE_PID,
            "c2",
            "/Users/you/work/notes",
            turn="ff00aa11",
            tool="Bash",
        )
    )

    # Claude running a subagent, four minutes in.
    add(
        rec(
            NOW - 1500,
            "SessionStart",
            "claude",
            LIVE_PID,
            "c3",
            "/Users/you/work/skills",
        )
    )
    add(
        rec(
            NOW - 260,
            "UserPromptSubmit",
            "claude",
            LIVE_PID,
            "c3",
            "/Users/you/work/skills",
            turn="77aa22bb",
        )
    )
    add(
        rec(
            NOW - 250,
            "PreToolUse",
            "claude",
            LIVE_PID,
            "c3",
            "/Users/you/work/skills",
            turn="77aa22bb",
            tool="Agent",
        )
    )

    # A finished session, to show the grey row.
    add(
        rec(
            NOW - 7200,
            "SessionStart",
            "codex",
            LIVE_PID,
            "x2",
            "/Users/you/work/edi",
            model="gpt-6-luna",
        )
    )
    add(
        rec(
            NOW - 7100,
            "Stop",
            "codex",
            LIVE_PID,
            "x2",
            "/Users/you/work/edi",
            model="gpt-6-luna",
            turn="01a14000",
            message="migrated the spider, fixtures green",
        )
    )
    add(
        rec(
            NOW - 7090,
            "SessionEnd",
            "codex",
            LIVE_PID,
            "x2",
            "/Users/you/work/edi",
            reason="exit",
        )
    )
    return rows


def remote_rows() -> list[dict]:
    rows: list[dict] = []
    rows.append(
        rec(
            NOW - 2400,
            "SessionStart",
            "claude",
            88231,
            "r1",
            "/Users/you/Documents/Active Work",
            agent_start=None,
        )
    )
    rows.append(
        rec(
            NOW - 1080,
            "Stop",
            "claude",
            88231,
            "r1",
            "/Users/you/Documents/Active Work",
            message="waiting on your call",
        )
    )
    return rows


def write(directory: Path, host: str, rows: list[dict]) -> int:
    hosts = directory / "hosts"
    hosts.mkdir(parents=True, exist_ok=True)
    day = time.strftime("%Y-%m-%d")
    path = hosts / f"{host}-{day}.jsonl"
    with path.open("a") as fh:
        for row in rows:
            fh.write(json.dumps(row) + "\n")
    os.chmod(path, 0o600)
    return len(rows)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    directory = Path(sys.argv[1])
    host = local_host()
    total = write(directory, host, build(host))
    total += write(directory, "laptop", remote_rows())
    print(f"wrote {total} records to {directory} (local host {host})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
