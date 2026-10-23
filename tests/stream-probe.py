#!/usr/bin/env python3
"""Run the Swift transport against separate local or SSH source processes."""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import queue
import re
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/stream-events.py"
SSH_OPTIONS = [
    "-T",
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=6",
    "-o",
    "ClearAllForwardings=yes",
]
WRITER = r"""
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
(root / "source/hosts").mkdir(parents=True, exist_ok=True)
agent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(180)"])
try:
    for line in sys.stdin:
        command = json.loads(line)
        action = command["action"]
        if action == "append":
            with (root / "source/hosts" / command["file"]).open("ab") as stream:
                stream.write(command["text"].encode())
        elif action == "title":
            profile = root / ".codex"
            profile.mkdir(exist_ok=True)
            (profile / "session_index.jsonl").write_text(json.dumps({"id": "live", "thread_name": command["title"]}) + "\n")
        elif action == "helper":
            (root / "helper.py").write_text(command["text"])
        elif action == "disconnect":
            (root / "blocked").touch()
            os.kill(int((root / "helper.pid").read_text()), signal.SIGTERM)
        elif action == "release":
            (root / "blocked").unlink(missing_ok=True)
        elif action == "replace":
            (root / "source/hosts" / command["file"]).write_text(command["text"])
        elif action == "agent-exit":
            agent.terminate()
            agent.wait(timeout=5)
        elif action == "stop":
            break
        print(json.dumps({"ok": True, "pid": agent.pid}), flush=True)
finally:
    if agent.poll() is None:
        agent.terminate()
        agent.wait(timeout=5)
    pidfile = root / "helper.pid"
    if pidfile.exists():
        helper_pid = int(pidfile.read_text())
        try:
            os.kill(helper_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            status = subprocess.run(["ps", "-p", str(helper_pid), "-o", "stat="],
                                    capture_output=True, text=True, timeout=2)
            if not status.stdout.strip():
                break
            time.sleep(.05)
        else:
            raise RuntimeError("helper process remains after cleanup")
print(json.dumps({"ok": True, "cleanup": True}), flush=True)
"""
WRAPPER = r"""
import os, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
while (root / "blocked").exists():
    time.sleep(.05)
(root / "helper.pid").write_text(str(os.getpid()))
os.environ["HOME"] = str(root)
os.environ.pop("CODEX_HOME", None)
os.execv(sys.executable, [sys.executable, "-u", str(root / "helper.py"),
    "--directory", str(root / "source"), "--host", sys.argv[2],
    "--interval", ".05", "--heartbeat", ".2"])
"""


class JsonProcess:
    def __init__(self, argv):
        self.process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.messages = queue.Queue()
        self.history = []
        threading.Thread(target=self.read, daemon=True).start()
        threading.Thread(target=self.read_errors, daemon=True).start()

    def read_errors(self):
        for line in self.process.stderr:
            print(line, end="", file=sys.stderr, flush=True)

    def read(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except ValueError:
                self.messages.put({"invalid_output": line})
        self.messages.put({"process_exit": True})

    def next(self, timeout=10):
        try:
            message = self.messages.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError("process produced no result before timeout") from None
        self.history.append(message)
        return message

    def wait(self, predicate, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.next(timeout=max(0.01, deadline - time.monotonic()))
            if message.get("process_exit"):
                raise AssertionError("process exited before the expected result")
            if predicate(message):
                return message
        raise AssertionError("expected result did not arrive")

    def command(self, **fields):
        self.process.stdin.write(json.dumps(fields) + "\n")
        self.process.stdin.flush()
        result = self.next()
        if result.get("ok") is not True:
            raise AssertionError(f"writer failed: {result}")
        return result

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.killpg(self.process.pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        raise AssertionError("probe process group remains after cleanup")


class Source:
    def __init__(self, directory, ssh=None):
        self.ssh = ssh
        self.directory = str(directory)
        self.host = socket.gethostname().removesuffix(".local")
        if ssh:
            hostname = run_captured(["ssh", *SSH_OPTIONS, ssh, "uname -n"])
            self.host = hostname.stdout.strip().removesuffix(".local")
            result = run_captured(
                ["ssh", *SSH_OPTIONS, ssh, "mktemp -d /tmp/agent-stat-probe.XXXXXXXX"]
            )
            self.directory = result.stdout.strip()
            if not re.fullmatch(r"/tmp/agent-stat-probe\.[A-Za-z0-9]+", self.directory):
                raise AssertionError("SSH returned an invalid temporary directory")
        self.writer = JsonProcess(
            self.argv(["python3", "-u", "-c", WRITER, self.directory])
        )
        result = self.writer.command(action="helper", text=HELPER.read_text())
        self.pid = result["pid"]

    def argv(self, arguments):
        if self.ssh:
            return ["ssh", *SSH_OPTIONS, self.ssh, shlex.join(arguments)]
        return arguments

    def helper(self, host):
        return self.argv(["python3", "-u", "-c", WRAPPER, self.directory, host])

    def command(self, **fields):
        return self.writer.command(**fields)

    def append(self, filename, text):
        self.command(action="append", file=filename, text=text)

    def close(self):
        try:
            result = self.command(action="stop")
            assert result.get("cleanup") is True
        finally:
            self.writer.close()
        if self.ssh:
            run_captured(
                [
                    "ssh",
                    *SSH_OPTIONS,
                    self.ssh,
                    shlex.join(["rm", "-r", "--", self.directory]),
                ]
            )


def run_captured(argv):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=15)
    if result.returncode:
        print(result.stdout, end="", flush=True)
        print(result.stderr, end="", file=sys.stderr, flush=True)
        result.check_returncode()
    return result


def event(session, kind="Stop", **fields):
    return (
        json.dumps(
            {"ts": int(time.time()), "event": kind, "session": session, **fields},
            ensure_ascii=False,
        )
        + "\n"
    )


def records(client):
    return Counter(
        (row["session"], row["event"])
        for message in client.history
        for row in message.get("records", [])
    )


def wait_record(client, session, kind="Stop"):
    client.wait(
        lambda message: any(
            row == {"session": session, "event": kind}
            for row in message.get("records", [])
        )
    )


def assert_record_absent(client, session):
    deadline = time.monotonic() + 0.6
    while time.monotonic() < deadline:
        client.wait(lambda message: message.get("state") == "connected", timeout=3)
        assert records(client)[(session, "Stop")] == 0


def start_client(binary, host, cache, source):
    return JsonProcess([str(binary), host, str(cache), "90", *source.helper(host)])


def probe(binary, ssh=None):
    label = f"SSH {ssh}" if ssh else "local"
    with tempfile.TemporaryDirectory(prefix="agent-stat-stream-probe-") as temporary:
        directory = Path(temporary)
        source = Source(directory / "remote", ssh)
        host = source.host
        clients = []
        try:
            cache = directory / "cache"
            filename = f"{host}-2026-10-23.jsonl"
            next_day = f"{host}-2026-10-24.jsonl"
            source.append(
                filename,
                event("live", agent="codex", agent_pid=source.pid, message="臺灣"),
            )
            client = start_client(binary, host, cache, source)
            clients.append(client)
            client.wait(lambda message: message.get("alive", {}).get("live") is True)
            assert records(client)[("live", "Stop")] == 1
            print(
                f"PASS {label}: independent writer delivers live UTF-8 records",
                flush=True,
            )

            for title in ("Quiet session", "Renamed quietly"):
                source.command(action="title", title=title)
                snapshot = client.wait(
                    lambda message: (
                        message.get("sessions", {}).get("live", {}).get("title")
                        == title
                    )
                )
                assert snapshot["sessions"]["live"]["state"] == "idle"
                assert records(client)[("live", "Stop")] == 1
            print(
                f"PASS {label}: names fill and rename without a new event", flush=True
            )

            source.command(action="disconnect")
            client.wait(lambda message: message.get("state") == "offline")
            source.append(filename, event("outage", agent_pid=source.pid))
            source.command(action="release")
            wait_record(client, "outage")
            client.wait(lambda message: message.get("state") == "connected")
            assert records(client)[("live", "Stop")] == 1
            assert records(client)[("outage", "Stop")] == 1
            print(
                f"PASS {label}: supervisor reconnects and replays the outage exactly once",
                flush=True,
            )

            partial = event("partial", agent_pid=source.pid)
            source.append(filename, partial[:-1])
            assert_record_absent(client, "partial")
            source.append(filename, "\n")
            wait_record(client, "partial")
            source.append(next_day, event("rotation", agent_pid=source.pid))
            wait_record(client, "rotation")
            source.append(next_day, event("live", "SubagentStart", agent_id="child"))
            client.wait(
                lambda message: (
                    message.get("sessions", {}).get("live", {}).get("subagents") == 1
                )
            )
            source.append(next_day, event("live", "SubagentStop", agent_id="child"))
            client.wait(
                lambda message: (
                    message.get("sessions", {}).get("live", {}).get("subagents") == 0
                )
            )
            print(
                f"PASS {label}: partial lines, daily rotation, and subagents reach the store",
                flush=True,
            )

            client.close()
            source.append(next_day, event("restart", agent_pid=source.pid))
            restarted = start_client(binary, host, cache, source)
            clients.append(restarted)
            first = restarted.wait(lambda message: message.get("state") == "cached")
            assert {"live", "outage", "partial", "rotation"} <= set(first["sessions"])
            wait_record(restarted, "restart")
            restarted.wait(
                lambda message: message.get("alive", {}).get("restart") is True
            )
            assert records(restarted)[("live", "Stop")] == 1
            assert records(restarted)[("restart", "Stop")] == 1
            print(
                f"PASS {label}: consumer restart rebuilds its store and resumes its cursor",
                flush=True,
            )

            source.command(action="agent-exit")
            restarted.wait(
                lambda message: message.get("alive", {}).get("live") is False
            )
            assert restarted.history[-1]["sessions"]["live"]["alive"] is False
            print(
                f"PASS {label}: source process exit reaches remote liveness", flush=True
            )

            source.command(action="disconnect")
            restarted.wait(lambda message: message.get("state") == "offline")
            source.command(action="replace", file=filename, text=event("changed"))
            source.command(action="release")
            restarted.wait(lambda message: message.get("state") == "catching up")
            restarted.wait(lambda message: message.get("state") == "offline")
            assert records(restarted)[("changed", "Stop")] == 0
            assert records(restarted)[("live", "Stop")] == 1
            print(
                f"PASS {label}: changed source fails offline without replacing cached history",
                flush=True,
            )
        finally:
            for client in clients:
                client.close()
            source.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ssh", metavar="HOST")
    arguments = parser.parse_args()
    binary = ROOT / ".build/stream-client"
    binary.parent.mkdir(exist_ok=True)
    names = [
        "RemoteStream",
        "RemoteCache",
        "CodexTitles",
        "EventReader",
        "FileStamp",
        "Paths",
        "Record",
        "Session",
        "SessionStore",
    ]
    subprocess.run(
        [
            "swiftc",
            "-o",
            str(binary),
            str(ROOT / "tests/stream-client.swift"),
            *[str(ROOT / f"src/{name}.swift") for name in names],
        ],
        check=True,
        timeout=60,
    )
    probe(binary, arguments.ssh)
    print(
        "PASS stream probe completed; temporary sources and processes removed",
        flush=True,
    )


if __name__ == "__main__":
    main()
