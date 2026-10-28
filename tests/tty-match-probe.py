#!/usr/bin/env python3
"""Compare how the live panel matches rows to Ghostty tabs, by folder and by tty.

Reads this machine's real event files and the running Ghostty, then reports per
session what a click would do today and what the tty would say. Nothing is
modified: no records are written and no tab is selected.

Run it before and after a change to the matching rules, and on a machine with
Ghostty 1.4.0 or later. An older Ghostty reports no tty, so every row falls back
to the folder and the second column is blank. That is correct, not a failure.
"""

import glob
import json
import os
from pathlib import Path
import subprocess

REPOSITORY = Path(__file__).resolve().parents[1]
APP = REPOSITORY / ".build/AgentStat.app/Contents/MacOS/AgentStat"
STATE = Path(os.environ.get("AGENT_STAT_DIR", Path.home() / ".local/state/agent-stat"))
FIELD = "\x1f"

# Every property is read under its own try, because one property a build does not
# implement fails the whole script otherwise, and that means no tabs at all.
TABS_SCRIPT = """
tell application "Ghostty"
    set fs to (ASCII character 31)
    set out to ""
    repeat with w in windows
        repeat with t in tabs of w
            repeat with term in terminals of t
                set tv to ""
                try
                    set tv to (tty of term) as text
                end try
                set pv to ""
                try
                    set pv to (pid of term) as text
                end try
                set out to out & (name of t) & fs & (working directory of term) & fs & tv & fs & pv & linefeed
            end repeat
        end repeat
    end repeat
    return out
end tell
"""


def ghostty_tabs():
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", TABS_SCRIPT], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit(f"Ghostty did not answer: {result.stderr.strip()[:200]}")
    tabs = []
    for line in result.stdout.splitlines():
        parts = line.split(FIELD)
        if len(parts) >= 4:
            tabs.append(
                {"name": parts[0], "cwd": parts[1], "tty": parts[2], "pid": parts[3]}
            )
    return tabs


def latest_history():
    files = sorted(glob.glob(str(STATE / "hosts" / "*.jsonl")))
    if not files:
        raise SystemExit(f"no event file under {STATE / 'hosts'}")
    return Path(files[-1])


def process_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def live_sessions(path):
    latest = {}
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            latest[record.get("session")] = record
    sessions = []
    for record in latest.values():
        pid = record.get("agent_pid") or 0
        if pid and process_alive(pid):
            sessions.append(record)
    return sessions


def tty_of(pid):
    result = subprocess.run(
        ["/bin/ps", "-o", "tty=", "-p", str(pid)], capture_output=True, text=True
    )
    value = result.stdout.strip()
    if not value or value == "??":
        return ""
    return value if value.startswith("/dev/") else f"/dev/{value}"


def plan(cwd, tty=""):
    """Ask the real planner, with and without the tty the record would carry."""
    arguments = [str(APP), "--plan-jump", cwd]
    if tty:
        arguments.append(tty)
    result = subprocess.run(arguments, capture_output=True, text=True)
    output = (result.stdout or result.stderr).strip()
    return output.splitlines()[0] if output else "(no output)"


def main():
    if not APP.exists():
        raise SystemExit(f"build the app first: {APP} is missing")
    tabs = ghostty_tabs()
    sessions = live_sessions(latest_history())
    print(f"ghostty terminals reporting a tty: {sum(1 for t in tabs if t['tty'])}")
    print(f"live sessions: {len(sessions)}")
    print()
    print(f"{'agent':8} {'pid':>7} {'tty':14}  folder plan / tty plan")
    folder = {"one": 0, "ask": 0, "none": 0}
    on_tty = {"one": 0, "ask": 0, "none": 0}
    for record in sorted(sessions, key=lambda r: r.get("cwd") or ""):
        pid = str(record.get("agent_pid"))
        cwd = record.get("cwd") or ""
        tty = tty_of(int(pid))
        without = plan(cwd)
        with_tty = plan(cwd, tty)
        tally(without, folder)
        tally(with_tty, on_tty)
        print(f"{record.get('agent'):8} {pid:>7} {tty:14}  {without[:72]}")
        if tty:
            print(f"{'':8} {'':>7} {'':14}  {with_tty[:72]}")
    print()
    for label, counts in (("folder plan", folder), ("tty plan", on_tty)):
        print(
            f"{label:12} {counts['one']}/{len(sessions)} one tab, "
            f"{counts['ask']} ask, {counts['none']} nothing"
        )


def tally(line, counts):
    if line.startswith("plan: 1 "):
        counts["one"] += 1
    elif "no tab found" in line:
        counts["none"] += 1
    else:
        counts["ask"] += 1


if __name__ == "__main__":
    main()
