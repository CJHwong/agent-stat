#!/usr/bin/env python3
"""Stream local event logs over standard input and output."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import sys
import time

PROTOCOL = 1
CHUNK_SIZE = 65536
TAIL_SIZE = 4096
SESSION_AGE = 12 * 3600


class StreamError(Exception):
    """Reject a source or cursor that cannot preserve event history."""


def host_name() -> str:
    return socket.gethostname().removesuffix(".local")


def file_pattern(host: str) -> re.Pattern:
    return re.compile(re.escape(host) + r"-\d{4}-\d{2}-\d{2}\.jsonl\Z")


def read_request(host: str) -> tuple[dict, bool]:
    line = sys.stdin.buffer.readline(1024 * 1024 + 1)
    if len(line) > 1024 * 1024 or not line.endswith(b"\n"):
        raise StreamError("request must be a complete JSON line below 1 MiB")
    try:
        request = json.loads(line)
    except (ValueError, UnicodeDecodeError):
        raise StreamError("request contains invalid JSON") from None
    if not isinstance(request, dict):
        raise StreamError("request must be an object")
    if type(request.get("protocol")) is not int or request["protocol"] != PROTOCOL:
        raise StreamError("unsupported protocol")
    offsets = request.get("offsets", {})
    if not isinstance(offsets, dict):
        raise StreamError("offsets must be an object")
    for filename, cursor in offsets.items():
        validate_request_cursor(host, filename, cursor)
    progress = request.get("progress", False)
    if type(progress) is not bool:
        raise StreamError("progress must be a boolean")
    return offsets, progress


def validate_request_cursor(host: str, filename: str, cursor: object) -> None:
    if not file_pattern(host).fullmatch(filename):
        raise StreamError("request contains a foreign or invalid filename")
    if not isinstance(cursor, dict):
        raise StreamError("cursor must be an object")
    offset = cursor.get("offset")
    if type(offset) is not int or offset < 0:
        raise StreamError("cursor offset must be a nonnegative integer")
    digest = cursor.get("tail")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise StreamError("cursor tail must be a SHA256 hex digest")


def emit(frame: dict) -> None:
    print(json.dumps(frame, separators=(",", ":")), flush=True)


def tail_digest(stream, offset: int) -> str:
    previous = os.pread(
        stream.fileno(), min(offset, TAIL_SIZE), max(0, offset - TAIL_SIZE)
    )
    return hashlib.sha256(previous).hexdigest()


def read_chunk(stream, limit: int) -> bytes:
    lines = []
    length = 0
    while length < CHUNK_SIZE and stream.tell() < limit:
        position = stream.tell()
        line = stream.readline(min(CHUNK_SIZE + 1, limit - position))
        if len(line) > CHUNK_SIZE:
            raise StreamError("source record exceeds 64 KiB")
        if not line.endswith(b"\n") or length + len(line) > CHUNK_SIZE:
            stream.seek(position)
            break
        lines.append(line)
        length += len(line)
    return b"".join(lines)


def parse_record(line: bytes) -> dict:
    try:
        record = json.loads(line)
    except (ValueError, UnicodeDecodeError):
        raise StreamError("source contains invalid JSON") from None
    if not isinstance(record, dict):
        raise StreamError("source record must be an object")
    return record


def remember_sessions(content: bytes, sessions: dict) -> None:
    for line in content.splitlines():
        record = parse_record(line)
        remember_session(record, sessions)


def remember_session(record: dict, sessions: dict) -> None:
    session = record.get("session")
    timestamp = record.get("ts")
    if not isinstance(session, str) or not session:
        return
    if type(timestamp) not in (int, float):
        return
    if not math.isfinite(timestamp):
        return
    previous = sessions.get(session, {})
    if previous and previous["ts"] > timestamp:
        return
    if record.get("agent_id"):
        if previous:
            previous["ts"] = timestamp
        return
    if record.get("event") == "RunEnd" and not previous:
        return
    pid = record.get("agent_pid")
    if type(pid) is not int or pid <= 0:
        pid = previous.get("agent_pid")
    started = record.get("agent_start")
    if started is None and pid == previous.get("agent_pid"):
        started = previous.get("agent_start")
    sessions[session] = {"ts": timestamp, "agent_pid": pid, "agent_start": started}


def source_signature(info: os.stat_result) -> tuple:
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


class LogCursor:
    def __init__(self, path: Path, resume: dict | None, sessions: dict, progress=None):
        self.path = path
        self.offset = 0
        self.tail = hashlib.sha256(b"").hexdigest()
        self.checked_signature = None
        with self.open() as stream:
            self.identity = os.fstat(stream.fileno())
            if resume:
                self.restore(stream, resume, sessions, progress)

    def open(self):
        descriptor = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        stream = os.fdopen(descriptor, "rb")
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            stream.close()
            raise StreamError("source is not a regular file")
        return stream

    def restore(self, stream, resume: dict, sessions: dict, progress=None) -> None:
        offset = resume["offset"]
        if offset > self.identity.st_size:
            raise StreamError("source is shorter than the saved cursor")
        stream.seek(max(0, offset - 1))
        if offset and stream.read(1) != b"\n":
            raise StreamError("cursor is not at a newline boundary")
        if tail_digest(stream, offset) != resume["tail"]:
            raise StreamError("source does not match the saved cursor")
        stream.seek(0)
        while stream.tell() < offset:
            line = stream.readline(CHUNK_SIZE + 1)
            if len(line) > CHUNK_SIZE or not line.endswith(b"\n"):
                raise StreamError("source contains an invalid historical record")
            remember_sessions(line, sessions)
            if progress is not None:
                progress()
        self.offset = offset
        self.tail = resume["tail"]

    def validate(self, stream) -> os.stat_result:
        current = os.fstat(stream.fileno())
        identity = (self.identity.st_dev, self.identity.st_ino)
        if (current.st_dev, current.st_ino) != identity:
            raise StreamError("source file was replaced")
        if not stat.S_ISREG(current.st_mode) or current.st_size < self.offset:
            raise StreamError("source file was truncated or changed type")
        if tail_digest(stream, self.offset) != self.tail:
            raise StreamError("source content changed before the cursor")
        return current

    def send_pending(self, sessions: dict) -> None:
        observed = os.stat(self.path, follow_symlinks=False)
        # Whole-second change times cannot distinguish rewrites within that second.
        if observed.st_ctime_ns % 1_000_000_000 and (
            source_signature(observed) == self.checked_signature
        ):
            return
        # Daily history stays available without retaining a descriptor for every day.
        with self.open() as stream:
            observed = self.validate(stream)
            stream.seek(self.offset)
            limit = observed.st_size
            while content := read_chunk(stream, limit):
                remember_sessions(content, sessions)
                emit(
                    {
                        "type": "chunk",
                        "file": self.path.name,
                        "offset": self.offset,
                        "content": base64.b64encode(content).decode("ascii"),
                    }
                )
                self.offset += len(content)
                self.tail = tail_digest(stream, self.offset)
            # Save the pre-read snapshot so a concurrent append stays pending.
            self.checked_signature = source_signature(observed)


def source_paths(directory: Path, host: str) -> list[Path]:
    hosts = directory / "hosts"
    if directory.is_symlink() or hosts.is_symlink():
        raise StreamError("source directory must not be a symbolic link")
    if not hosts.exists():
        return []
    matches = sorted(
        path for path in hosts.iterdir() if file_pattern(host).fullmatch(path.name)
    )
    if any(path.is_symlink() for path in matches):
        raise StreamError("source log must not be a symbolic link")
    return matches


def process_snapshot() -> dict:
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,stat=,lstart="],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        raise StreamError("cannot read the process list") from None
    processes = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and "Z" not in fields[1]:
            processes[int(fields[0])] = " ".join(fields[2].split())
    return processes


def session_alive(record: dict, processes: dict) -> bool:
    pid = record.get("agent_pid")
    if type(pid) is not int or pid not in processes:
        return False
    started = record.get("agent_start")
    if started is None:
        return True
    return isinstance(started, str) and " ".join(started.split()) == processes[pid]


_FALLBACK_TITLES: dict[str, str] = {}


def codex_titles(sessions: dict, quiet: set[str]) -> dict:
    profiles = set(Path.home().glob(".codex*"))
    if os.environ.get("CODEX_HOME"):
        profiles.add(Path(os.environ["CODEX_HOME"]))
    titles = {}
    visited = set()
    for profile in sorted(profiles):
        try:
            path = (profile / "session_index.jsonl").resolve()
        except (OSError, RuntimeError):
            continue
        if path in visited:
            continue
        visited.add(path)
        for session, name in read_titles(path, sessions).items():
            if session not in titles or name[1] >= titles[session][1]:
                titles[session] = name
    for session in sessions:
        if session in titles or session not in quiet:
            continue
        for profile in sorted(profiles):
            title = rollout_title(profile, session)
            if title:
                titles[session] = (title, float("-inf"))
                break
    return {session: name[0] for session, name in titles.items()}


def rollout_title(profile: Path, session: str) -> str | None:
    """The first user message, when the index has no name for the session.

    Codex names a thread from the first prompt. An older session can miss the
    index entry; the rollout still holds the prompt, so this is the same name the
    UI would have shown. The answer is cached for the life of the helper.
    """
    cached = _FALLBACK_TITLES.get(session)
    if cached is not None:
        return cached
    pattern = f"sessions/*/*/*/rollout-*{session}*.jsonl"
    for path in sorted(profile.glob(pattern)):
        try:
            with path.open(encoding="utf-8") as stream:
                for line in stream:
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(entry, dict):
                        continue
                    payload = entry.get("payload")
                    if not isinstance(payload, dict) or payload.get("role") != "user":
                        continue
                    content = payload.get("content")
                    text = ""
                    if isinstance(content, list):
                        text = " ".join(
                            part.get("text", "")
                            for part in content
                            if isinstance(part, dict)
                            and isinstance(part.get("text"), str)
                        )
                    elif isinstance(payload.get("message"), str):
                        text = payload["message"]
                    text = re.sub(r"[\n\r\t]+", " ", text).strip()
                    if text:
                        _FALLBACK_TITLES[session] = text[:200]
                        return _FALLBACK_TITLES[session]
        except (OSError, UnicodeError):
            continue
    return None


def name_timestamp(value: object) -> float:
    if not isinstance(value, str):
        return float("-inf")
    try:
        updated = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if updated.tzinfo is None:
            updated = updated.replace(tzinfo=timezone.utc)
        return updated.timestamp()
    except (ValueError, OverflowError):
        return float("-inf")


def read_titles(path: Path, sessions: dict) -> dict:
    try:
        if not path.is_file():
            return {}
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return {}
    titles = {}
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        session, title = entry.get("id"), entry.get("thread_name")
        if not isinstance(session, str) or session not in sessions:
            continue
        if not isinstance(title, str) or not title:
            continue
        titles[session] = (
            re.sub(r"[\n\r\t]+", " ", title)[:200],
            name_timestamp(entry.get("updated_at")),
        )
    return titles


def emit_status(sessions: dict) -> None:
    now = time.time()
    processes = process_snapshot()
    recent = {
        session: row
        for session, row in sessions.items()
        if row["ts"] >= now - SESSION_AGE
    }
    alive = {session: session_alive(row, processes) for session, row in recent.items()}
    emit(
        {
            "type": "status",
            "time": int(now),
            "alive": alive,
            "titles": codex_titles(
                sessions, {session for session in sessions if session not in recent}
            ),
        }
    )


def run(directory: Path, host: str, interval: float, heartbeat: float) -> None:
    offsets, progress_requested = read_request(host)
    sources = {}
    sessions = {}
    emit({"type": "hello", "protocol": PROTOCOL, "host": host})
    next_progress = time.monotonic() + min(2, heartbeat)

    def report_progress():
        nonlocal next_progress
        now = time.monotonic()
        if now < next_progress:
            return
        # Rebuilding cached metadata must not trip the receiver watchdog.
        emit({"type": "progress", "time": int(time.time())})
        next_progress = now + min(2, heartbeat)

    next_heartbeat = 0
    while True:
        paths = source_paths(directory, host)
        names = {path.name for path in paths}
        if (set(offsets) | set(sources)) - names:
            raise StreamError("a source log is missing")
        for path in paths:
            if path.name not in sources:
                sources[path.name] = LogCursor(
                    path,
                    offsets.get(path.name),
                    sessions,
                    report_progress if progress_requested else None,
                )
            sources[path.name].send_pending(sessions)
        if time.monotonic() >= next_heartbeat:
            emit_status(sessions)
            next_heartbeat = time.monotonic() + heartbeat
        time.sleep(interval)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--directory", type=Path, default=Path.home() / ".local/state/agent-stat"
    )
    parser.add_argument("--host", default=host_name())
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--heartbeat", type=float, default=5)
    arguments = parser.parse_args()
    if (
        not arguments.host
        or "/" in arguments.host
        or min(arguments.interval, arguments.heartbeat) <= 0
    ):
        parser.error("host must be a name and intervals must be positive")
    try:
        run(
            arguments.directory, arguments.host, arguments.interval, arguments.heartbeat
        )
    except BrokenPipeError:
        return 0
    except (StreamError, OSError) as error:
        message = (
            str(error)
            if isinstance(error, StreamError)
            else "cannot read the source logs"
        )
        print(f"stream-events: {message}", file=sys.stderr)
        emit({"type": "error", "error": message})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
