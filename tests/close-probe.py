#!/usr/bin/env python3
"""Does closing a session clean up after itself?

When a terminal window closes, the agent gets a hangup. The question is whether
Claude Code and Codex get far enough to run their SessionEnd hook, or whether the
process just dies with nothing recorded.

This runs each agent under a real pty, waits for the session to start, then closes
the master side, which is what a closed terminal window does. Then it reports
whether SessionEnd arrived and whether the process died.

Run: python3 tests/close-probe.py
"""

from __future__ import annotations

import json
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL = REPO / "install.py"
START_TIMEOUT = 45
AFTER_CLOSE_TIMEOUT = 20


def build_tree(root: Path) -> None:
    for name in ("claude", "codex", "events"):
        (root / name).mkdir(parents=True, exist_ok=True)
    auth = Path.home() / ".codex" / "auth.json"
    if auth.exists():
        (root / "codex" / "auth.json").symlink_to(auth)
    (root / "codex" / "config.toml").write_text(
        'model = "gpt-6-luna"\n'
        'model_reasoning_effort = "low"\n'
        'approval_policy = "never"\n'
        'sandbox_mode = "danger-full-access"\n'
    )


def preseed_claude_trust(root: Path) -> None:
    """Mark the probe workspace trusted so the first run dialog never appears.

    Claude records this as projects[<path>].hasTrustDialogAccepted in the config
    dir's own .claude.json. Without it the session parks on a trust dialog and
    never starts, which is what sank the first two attempts. Only a minimal file
    is written; the real one is never read.
    """
    # The path must be canonical, or the key will not match. On macOS
    # /var/folders is reached through the /private/var symlink and Claude records
    # the resolved path.
    workdir = os.path.realpath(str(root / "claude-cwd"))
    Path(workdir).mkdir(exist_ok=True)
    store = root / "claude" / ".claude.json"
    store.write_text(
        json.dumps(
            {
                "hasCompletedOnboarding": True,
                "projects": {workdir: {"hasTrustDialogAccepted": True}},
            }
        )
    )
    print(f"  pre-trusted {workdir}")


def install(root: Path) -> Path:
    env = dict(os.environ)
    env["AGENT_STAT_DIR"] = str(root / "events")
    proc = subprocess.run(
        [
            sys.executable,
            str(INSTALL),
            "--apply",
            "--claude-config",
            str(root / "claude"),
            "--codex-home",
            str(root / "codex"),
        ],
        env=env,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"install failed:\n{proc.stdout}\n{proc.stderr}")
    return root / "events" / "hosts"


def records(hosts: Path) -> list[dict]:
    out: list[dict] = []
    if not hosts.exists():
        return out
    for path in hosts.glob("*.jsonl"):
        try:
            for line in path.read_text().splitlines():
                if line.strip():
                    out.append(json.loads(line))
        except (OSError, ValueError):
            continue
    return out


def wait_for(hosts: Path, event: str, timeout: int) -> dict | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        for row in records(hosts):
            if row.get("event") == event:
                return row
        time.sleep(0.3)
    return None


def spawn_in_pty(command: list[str], env: dict, cwd: str) -> tuple[int, int]:
    """Fork under a pty so the child owns the slave as its controlling terminal.

    That is what makes closing the master deliver a real hangup.
    """
    pid, master = pty.fork()
    if pid == 0:
        try:
            os.chdir(cwd)
            os.execvpe(command[0], command, env)
        except Exception:
            os._exit(127)
    import fcntl

    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    return pid, master


def drain(master: int, stop: list[bool], captured: list[bytes]) -> None:
    """Keep the pty buffer empty or the TUI blocks on a full buffer.

    Output is kept, not discarded. When a session refuses to start, that text is
    the only evidence of why.
    """
    while not stop[0]:
        try:
            ready, _, _ = select.select([master], [], [], 0.2)
            if ready:
                chunk = os.read(master, 65536)
                if not chunk:
                    break
                captured.append(chunk)
        except OSError:
            break


def show_output(captured: list[bytes], lines: int = 15) -> None:
    text = b"".join(captured).decode("utf-8", errors="replace")
    cleaned = [line for line in text.replace("\r", "\n").split("\n") if line.strip()]
    if not cleaned:
        print("  (the session produced no output at all)")
        return
    print("  --- session output, last lines ---")
    for line in cleaned[-lines:]:
        print(f"    {line[:150]}")


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def probe(name: str, command: list[str], root: Path, hosts: Path) -> bool:
    print(f"\n=== {name} ===")
    before = len(records(hosts))
    env = dict(os.environ)
    env["AGENT_STAT_DIR"] = str(root / "events")
    if name == "claude":
        env["CLAUDE_CONFIG_DIR"] = str(root / "claude")
        env.pop("CLAUDECODE", None)
    else:
        env["CODEX_HOME"] = str(root / "codex")

    workdir = str(root / f"{name}-cwd")
    Path(workdir).mkdir(exist_ok=True)

    pid, master = spawn_in_pty(command, env, workdir)
    print(f"  pid={pid} cwd={workdir}")

    import threading

    stop = [False]
    captured: list[bytes] = []
    reader = threading.Thread(target=drain, args=(master, stop, captured), daemon=True)
    reader.start()

    started = wait_for(hosts, "SessionStart", 3)
    if not started:
        # An interactive agent needs a nudge: a first run onboarding screen, a
        # trust dialog, or a session that does not begin until the first prompt.
        # Down then Enter picks "Yes, I trust this folder"; Enter alone picks the
        # default, which is "No, exit".
        schedule = [b"\r", b"\x1b[B\r", b"hi\r", b"\x1b[B\r", b"hi\r"]
        print("  nudging the session to start")
        opened = time.time()
        for keys in schedule:
            if started:
                break
            time.sleep(3)
            try:
                os.write(master, keys)
            except OSError:
                break
            started = wait_for(hosts, "SessionStart", 8)
        print(f"  nudged for {time.time() - opened:.0f}s")

    if not started:
        print(f"  no SessionStart at all. process alive: {alive(pid)}")
        show_output(captured)
        stop[0] = True
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        return False
    print(
        f"  SessionStart recorded, hook recorded agent_pid={started.get('agent_pid')}"
    )
    print(f"  hook pid matches the pty child: {started.get('agent_pid') == pid}")

    # Close the master. This is the terminal window closing.
    print("  closing the master side (terminal window closed)...")
    stop[0] = True
    try:
        os.close(master)
    except OSError:
        pass

    deadline = time.time() + AFTER_CLOSE_TIMEOUT
    ended: dict | None = None
    while time.time() < deadline:
        ended = next(
            (r for r in records(hosts) if r.get("event") == "SessionEnd"), None
        )
        if ended and len(records(hosts)) > before:
            break
        time.sleep(0.3)

    still_alive = alive(pid)
    print(
        f"  SessionEnd after close: {'YES, reason=' + repr(ended.get('reason')) if ended else 'NO'}"
    )
    print(f"  process still alive: {still_alive}")
    if not ended:
        show_output(captured)

    if still_alive:
        print("  the hangup alone did not kill it; sending SIGHUP explicitly")
        try:
            os.kill(pid, signal.SIGHUP)
        except OSError:
            pass
        time.sleep(3)
        print(f"  alive after explicit SIGHUP: {alive(pid)}")
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass

    return bool(ended)


def main() -> int:
    root = Path(tempfile.mkdtemp(prefix="agent-stat-close-"))
    print(f"isolated tree: {root}")
    build_tree(root)
    preseed_claude_trust(root)
    hosts = install(root)
    print(f"hooks installed, events at {hosts}")

    wanted = sys.argv[1:] or ["claude", "codex"]
    results: dict[str, bool] = {}
    if "claude" in wanted:
        results["claude"] = probe("claude", ["claude"], root, hosts)
    if "codex" in wanted:
        results["codex"] = probe("codex", ["codex"], root, hosts)

    print("\n=== verdict ===")
    for name, clean in results.items():
        if clean:
            print(
                f"  {name}: SessionEnd arrives on close, so the row clears itself "
                f"from the event stream alone"
            )
        else:
            print(
                f"  {name}: no SessionEnd on close, so the row depends on the "
                f"liveness reaper (sysctl) plus the grace period"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
