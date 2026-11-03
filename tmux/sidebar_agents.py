import argparse
from process_commands import capture_command, replay_arguments
from agent_stat_reader import EventReader, belongs_to_pane, process_table
import fcntl
from functools import lru_cache
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time

ROOT = Path(
    os.environ.get(
        "TMUX_SIDEBAR_STATE_DIR", str(Path.home() / ".local/state/tmux-sidebar")
    )
)
EVENTS = EventReader()
RANK = {
    "waiting": 0,
    "failed": 0,
    "done": 1,
    "working": 2,
    "idle": 3,
    "interrupted": 3,
    "closed": 4,
    "": 4,
}


def tmux(socket_path, *arguments):
    return subprocess.check_output(
        ["tmux", "-S", socket_path, *arguments], text=True
    ).rstrip("\n")


def session_name(socket_path, session):
    return (
        tmux(socket_path, "display-message", "-p", "-t", session, "#{session_name}")
        if session.startswith("$")
        else session
    )


def read_json(filename, fallback=None):
    try:
        return json.loads(filename.read_text())
    except FileNotFoundError:
        return fallback
    except (OSError, ValueError):
        logging.exception("Cannot read sidebar state: %s", filename)
        return fallback


def write_json(filename, record):
    filename.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(
        "w", dir=filename.parent, delete=False
    ) as temporary:
        json.dump(record, temporary)
        temporary.flush()
        os.fsync(temporary.fileno())
    os.replace(temporary.name, filename)


def namespace(socket_path, session):
    identity = hashlib.sha256(socket_path.encode()).hexdigest()[:12]
    safe_session = re.sub(r"[^a-zA-Z0-9_-]", "_", session)
    return identity + "-" + safe_session


def process_alive(pid):
    if not pid:
        return True
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


@lru_cache(maxsize=128)
def process_profile(pid, agent):
    variable = "CLAUDE_CONFIG_DIR" if agent == "claude" else "CODEX_HOME"
    result = subprocess.run(
        ["/bin/ps", "eww", "-p", str(pid), "-o", "command="],
        capture_output=True,
        text=True,
    )
    match = re.search(
        r"(?:^| )" + variable + r"=(.*?)(?= [A-Za-z_][A-Za-z0-9_]*=|$)", result.stdout
    )
    return (
        match.group(1)
        if match
        else str(Path.home() / (".claude" if agent == "claude" else ".codex"))
    )


def claude_registry(session):
    records = {}
    registry = Path.home() / ".claude/sessions"
    for filename in registry.glob("*.json"):
        record = read_json(filename, {})
        locator = record.get("tmux", "")
        if not locator.startswith(session + ":") or ".%" not in locator:
            continue
        pid = record.get("pid")
        try:
            os.kill(int(pid), 0)
        except (ValueError, TypeError, OSError):
            continue
        state = ""
        pane_id = "%" + locator.rsplit(".%", 1)[1]
        records[pane_id] = {
            "agent": "claude",
            "session_id": record.get("sessionId"),
            "state": state,
            "updated": record.get("statusUpdatedAt", 0) / 1000,
            "cwd": record.get("cwd"),
            "profile": process_profile(pid, "claude"),
            "pid": pid,
        }
    return records


def agent_states(socket_path, session):
    exists = subprocess.run(
        ["tmux", "-S", socket_path, "has-session", "-t", session],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if exists.returncode:
        return {}
    session = session_name(socket_path, session)
    records = claude_registry(session)
    panes = dict(
        row.split("\t")
        for row in tmux(
            socket_path,
            "list-panes",
            "-s",
            "-t",
            session,
            "-F",
            "#{pane_id}\t#{pane_pid}",
        ).splitlines()
    )
    processes = process_table()
    events = sorted(EVENTS.update().values(), key=lambda record: record["updated"])
    for record in events:
        pane_id = record.get("pane_id")
        if pane_id not in panes or not belongs_to_pane(
            record, int(panes[pane_id]), processes
        ):
            continue
        state = record["state"]
        if state == "done" and record["children"]:
            state = "working"
        records[pane_id] = {
            key: value for key, value in record.items() if key != "children"
        }
        records[pane_id]["state"] = state
        records[pane_id]["profile"] = process_profile(record["pid"], record["agent"])
    return records


def snapshot_path(socket_path, session):
    return (
        ROOT
        / "snapshots"
        / (namespace(socket_path, session_name(socket_path, session)) + ".json")
    )


def capture_snapshot(socket_path, session):
    session = session_name(socket_path, session)
    states = agent_states(socket_path, session)
    windows = []
    rows = tmux(
        socket_path,
        "list-windows",
        "-t",
        session,
        "-F",
        "#{window_id}\t#{window_index}\t#{window_name}\t#{window_layout}",
    ).splitlines()
    for row in rows:
        window_id, index, name, layout = row.split("\t")
        panes = []
        template = "#{pane_id}\t#{pane_current_path}\t#{@window_sidebar}\t#{pane_title}\t#{@window_sidebar_label}"
        for pane_row in tmux(
            socket_path, "list-panes", "-t", window_id, "-F", template
        ).splitlines():
            pane_id, cwd, role, title, label = pane_row.split("\t")
            if role in ("2", "3"):
                continue
            agent = states.get(pane_id, {})
            if agent.get("state") == "closed":
                agent = {}
            panes.append(
                {
                    "pane_id": pane_id,
                    "cwd": cwd,
                    "sidebar": role == "1",
                    "title": title,
                    "label": label,
                    "agent": agent,
                    **(capture_command(socket_path, pane_id) if not role else {}),
                }
            )
        windows.append(
            {"index": int(index), "name": name, "layout": layout, "panes": panes}
        )
    return {
        "version": 1,
        "session": session,
        "saved_at": time.time(),
        "windows": windows,
    }


def snapshot_has_recovery(snapshot):
    return any(
        (pane.get("agent", {}).get("session_id") or replay_arguments(pane))
        for window in snapshot["windows"]
        for pane in window["panes"]
    )


def save_snapshot(socket_path, session, force=False):
    snapshot = capture_snapshot(socket_path, session)
    if force or snapshot_has_recovery(snapshot):
        write_json(snapshot_path(socket_path, session), snapshot)
    return snapshot


def monitor(socket_path, session):
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = ROOT / (namespace(socket_path, session) + ".monitor.lock")
    with lock.open("a") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        seen_recovery = False
        while (
            subprocess.run(
                ["tmux", "-S", socket_path, "has-session", "-t", session],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            == 0
        ):
            snapshot = save_snapshot(socket_path, session, seen_recovery)
            seen_recovery = seen_recovery or snapshot_has_recovery(snapshot)
            time.sleep(10)


def start_monitor(socket_path, session):
    session = session_name(socket_path, session)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = ROOT / (namespace(socket_path, session) + ".monitor.lock")
    with lock.open("a") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
    command = [
        os.sys.executable,
        str(Path(__file__).resolve()),
        "monitor",
        "--socket",
        socket_path,
        "--session",
        session,
    ]
    subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def resume_command(record):
    agent = record.get("agent")
    session_id = record.get("session_id", "")
    if agent not in ("claude", "codex") or not re.fullmatch(
        r"[a-zA-Z0-9_-]+", session_id
    ):
        return None
    variable = "CLAUDE_CONFIG_DIR" if agent == "claude" else "CODEX_HOME"
    arguments = [
        "env",
        variable + "=" + record["profile"],
        agent,
        "--resume" if agent == "claude" else "resume",
        session_id,
    ]
    return shlex.join(arguments)


def recovery_plan(socket_path, session):
    snapshot = read_json(snapshot_path(socket_path, session))
    if not snapshot or snapshot.get("version") != 1:
        raise RuntimeError("No saved recovery snapshot exists for this session.")
    live_panes = set(
        tmux(socket_path, "list-panes", "-a", "-F", "#{pane_id}").splitlines()
    )
    active = {
        record.get("session_id")
        for pane_id, record in agent_states(socket_path, session).items()
        if pane_id in live_panes
        and record.get("state") != "closed"
        and process_alive(record.get("pid"))
    }
    eligible = [
        pane
        for window in snapshot["windows"]
        for pane in window["panes"]
        if pane.get("agent", {}).get("session_id") not in active
        and resume_command(pane.get("agent", {}))
    ]
    return snapshot, active, eligible


def replay_candidates(socket_path, snapshot):
    processes = process_table()
    panes = dict(
        row.split("\t")
        for row in tmux(
            socket_path, "list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}"
        ).splitlines()
    )
    candidates = []
    for window in snapshot["windows"]:
        for pane in window["panes"]:
            record = {
                "pid": pane.get("command_pid"),
                "start": pane.get("command_start"),
            }
            root = int(panes.get(pane["pane_id"], 0))
            if replay_arguments(pane) and not belongs_to_pane(record, root, processes):
                candidates.append(pane)
    return candidates


def restore_snapshot(socket_path, session, selected_commands=None):
    snapshot, active, eligible = recovery_plan(socket_path, session)
    selected_commands = set(selected_commands or ())
    candidates = (
        {pane["pane_id"] for pane in replay_candidates(socket_path, snapshot)}
        if selected_commands
        else set()
    )
    if not selected_commands <= candidates:
        raise RuntimeError(
            "A selected command is unavailable or still running. Refresh the preview."
        )
    if not eligible and not selected_commands:
        tmux(
            socket_path,
            "display-message",
            "No eligible conversations or selected commands. Nothing started.",
        )
        return None
    recovered = "recovered-" + snapshot["session"]
    if (
        subprocess.run(
            ["tmux", "-S", socket_path, "has-session", "-t", recovered],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    ):
        raise RuntimeError("The recovery session already exists: " + recovered)
    first_window = snapshot["windows"][0]
    first_cwd = first_window["panes"][0]["cwd"]
    tmux(socket_path, "new-session", "-d", "-s", recovered, "-c", first_cwd)
    first_id = tmux(
        socket_path, "display-message", "-p", "-t", recovered, "#{window_id}"
    )
    for index, window in enumerate(snapshot["windows"]):
        window_id = (
            first_id
            if index == 0
            else tmux(
                socket_path,
                "new-window",
                "-d",
                "-t",
                recovered,
                "-P",
                "-F",
                "#{window_id}",
                "-c",
                window["panes"][0]["cwd"],
            )
        )
        restore_window(socket_path, window_id, window, active, selected_commands)
    tmux(socket_path, "set-option", "-t", recovered, "@window_sidebar_enabled", "1")
    if tmux(socket_path, "list-clients", "-F", "#{client_name}"):
        tmux(socket_path, "switch-client", "-t", recovered)
    return recovered


def restore_window(socket_path, window_id, window, active, selected_commands):
    first_pane = tmux(
        socket_path, "display-message", "-p", "-t", window_id, "#{pane_id}"
    )
    new_panes = []
    for index, pane in enumerate(window["panes"]):
        pane_id = (
            first_pane
            if index == 0
            else tmux(
                socket_path,
                "split-window",
                "-d",
                "-h",
                "-t",
                new_panes[-1],
                "-c",
                pane["cwd"],
                "-P",
                "-F",
                "#{pane_id}",
            )
        )
        new_panes.append(pane_id)
        restore_pane(socket_path, pane_id, pane, active, selected_commands)
        tmux(socket_path, "select-layout", "-t", window_id, "tiled")
    tmux(socket_path, "rename-window", "-t", window_id, window["name"])
    tmux(socket_path, "select-layout", "-t", window_id, window["layout"])
    chosen = next(
        (index for index, pane in enumerate(window["panes"]) if not pane["sidebar"]), 0
    )
    tmux(socket_path, "select-pane", "-t", new_panes[chosen])


def restore_pane(socket_path, pane_id, pane, active, selected_commands):
    if pane["sidebar"]:
        helper = Path(__file__).with_name("window-sidebar.py")
        command = shlex.join(
            [os.sys.executable, str(helper), "--socket", socket_path, "render"]
        )
        tmux(socket_path, "set-option", "-p", "-t", pane_id, "@window_sidebar", "1")
        tmux(socket_path, "set-option", "-p", "-t", pane_id, "pane-border-format", "")
        tmux(socket_path, "respawn-pane", "-k", "-t", pane_id, command)
        return
    if pane.get("label"):
        tmux(
            socket_path,
            "set-option",
            "-p",
            "-t",
            pane_id,
            "@window_sidebar_label",
            pane["label"],
        )
    agent = pane.get("agent", {})
    command = resume_command(agent)
    if command and agent["session_id"] not in active:
        tmux(
            socket_path, "respawn-pane", "-k", "-t", pane_id, "-c", pane["cwd"], command
        )
        active.add(agent["session_id"])

    elif pane["pane_id"] in (selected_commands or ()):
        arguments = replay_arguments(pane)
        if arguments:
            tmux(
                socket_path,
                "respawn-pane",
                "-k",
                "-t",
                pane_id,
                "-c",
                pane["cwd"],
                shlex.join(arguments),
            )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("hook", "monitor", "snapshot", "recover"))
    parser.add_argument("--agent", choices=("claude", "codex"))
    parser.add_argument("--socket")
    parser.add_argument("--session")
    arguments = parser.parse_args()
    if arguments.action == "hook":
        return  # Old clients can retain the removed hook until their next launch.
    elif arguments.action == "monitor":
        monitor(arguments.socket, arguments.session)
    elif arguments.action == "snapshot":
        save_snapshot(arguments.socket, arguments.session, True)
    else:
        restore_snapshot(arguments.socket, arguments.session)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError):
        logging.exception("Agent state or recovery operation failed")
        raise SystemExit(1)
