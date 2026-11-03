"""Read this host's agent-stat events without adding hooks or writing events."""

import json
import logging
import os
from pathlib import Path
import socket
import subprocess


class EventReader:
    def __init__(self, root=None, host=None):
        self.root = Path(
            root
            or os.environ.get(
                "AGENT_STAT_DIR", str(Path.home() / ".local/state/agent-stat")
            )
        )
        self.host = host or socket.gethostname().removesuffix(".local")
        self.positions = {}
        self.sessions = {}

    def update(self):
        files = sorted((self.root / "hosts").glob(self.host + "-????-??-??.jsonl"))
        for filename in files:
            try:
                self.read_file(filename)
            except OSError:
                logging.exception("Cannot read agent-stat events: %s", filename)
        return self.sessions

    def read_file(self, filename):
        metadata = filename.stat()
        inode, offset = self.positions.get(filename, (metadata.st_ino, 0))
        if inode != metadata.st_ino or metadata.st_size < offset:
            self.positions.clear()
            self.sessions.clear()
            return self.update()
        with filename.open("rb") as stream:
            stream.seek(offset)
            for line in stream:
                if not line.endswith(b"\n"):
                    break
                offset += len(line)
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if isinstance(record, dict):
                    record["_position"] = filename.name + ":" + str(offset)
                    self.apply(record)
        self.positions[filename] = (metadata.st_ino, offset)

    def apply(self, record):
        session_id = record.get("session")
        if not session_id:
            return
        session = self.sessions.setdefault(
            session_id, {"state": "idle", "children": set(), "updated": 0}
        )
        event = record.get("event")
        child = record.get("agent_id")
        if child:
            if event == "SubagentStart":
                session["children"].add(child)
            elif event == "SubagentStop":
                session["children"].discard(child)
                if not session["children"] and session["state"] == "done":
                    session["completion"] = record.get(
                        "_position", str(record.get("ts", 0))
                    )
            return
        fields = {
            "agent": "agent",
            "agent_pid": "pid",
            "agent_start": "start",
            "tmux": "pane_id",
            "cwd": "cwd",
        }
        for source, target in fields.items():
            if record.get(source):
                session[target] = record[source]
        session["session_id"] = session_id
        session["updated"] = max(session["updated"], record.get("ts", 0))
        states = {
            "SessionStart": "idle",
            "UserPromptSubmit": "working",
            "PreToolUse": "working",
            "PermissionRequest": "waiting",
            "Stop": "done",
            "StopFailure": "failed",
            "Interrupt": "interrupted",
            "SessionEnd": "closed",
            "RunEnd": "closed",
        }
        if event == "PostToolUse" and session["state"] == "waiting":
            session["state"] = "working"
        elif event in ("SessionEnd", "RunEnd") and session["state"] == "failed":
            return
        elif (
            event in ("SessionEnd", "RunEnd")
            and session.get("agent") == "codex"
            and session["state"] in ("working", "waiting")
        ):
            session["state"] = "failed"
        elif event in states:
            session["state"] = states[event]
        if event == "Stop":
            session["completion"] = record.get("_position", str(record.get("ts", 0)))


def process_table():
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,lstart="],
        capture_output=True,
        text=True,
        check=True,
    )
    processes = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3:
            processes[int(fields[0])] = (int(fields[1]), " ".join(fields[2].split()))
    return processes


def belongs_to_pane(record, pane_pid, processes):
    pid = record.get("pid")
    if pid not in processes:
        return False
    if record.get("start") and " ".join(record["start"].split()) != processes[pid][1]:
        return False
    visited = set()
    while pid in processes and pid not in visited:
        if pid == pane_pid:
            return True
        visited.add(pid)
        pid = processes[pid][0]
    return False
