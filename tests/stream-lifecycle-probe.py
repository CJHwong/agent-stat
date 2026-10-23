#!/usr/bin/env python3
"""Check stream cleanup with stalled and uncooperative helper processes."""

import argparse
import datetime
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

REPOSITORY = Path(__file__).resolve().parents[1]
HELPER = """import json,os,pathlib,signal,sys,time
if sys.argv[2] == "ignore": signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
if sys.argv[2] == "progress":
    request=json.loads(sys.stdin.readline())
    assert request["progress"] is True
    print(json.dumps({"type":"hello","protocol":1,"host":"lifecycle"}),flush=True)
    for _ in range(48):
        print(json.dumps({"type":"progress","time":int(time.time())}),flush=True)
        time.sleep(.5)
    print(json.dumps({"type":"status","time":int(time.time()),"alive":{}}),flush=True)
time.sleep(60)
"""


def alive(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="],
        capture_output=True,
        text=True,
        check=False,
    )
    return bool(result.stdout.strip()) and "Z" not in result.stdout


def scenario(binary, root, name, history):
    cache = root / name
    cache.mkdir()
    for number in range(history):
        day = datetime.date(2023, 1, 1) + datetime.timedelta(days=number)
        (cache / f"lifecycle-{day}.jsonl").write_bytes(b"")
    pidfile = root / f"{name}.pid"
    pid = None
    try:
        result = subprocess.run(
            [
                str(binary),
                str(cache),
                "26" if name == "progress" else "1",
                sys.executable,
                "-c",
                HELPER,
                str(pidfile),
                name,
            ],
            capture_output=True,
            text=True,
            timeout=35 if name == "progress" else 8,
        )
        result.check_returncode()
        pid = int(pidfile.read_text())
        assert not alive(pid), f"{name}: helper remains alive after stop"
        if name == "progress":
            states = result.stdout.splitlines()
            assert "offline" not in states, f"progress caused a reconnect: {states}"
            assert states == ["catching up", "connected"], (
                f"unexpected progress state: {states}"
            )
            print(
                "PASS slow replay: progress keeps the watchdog alive without marking connected early",
                flush=True,
            )
        print(f"PASS {name}: stream stops its helper", flush=True)
    finally:
        if pid is None and pidfile.exists():
            pid = int(pidfile.read_text())
        if pid is not None and alive(pid):
            os.kill(pid, signal.SIGKILL)
            for _ in range(100):
                if not alive(pid):
                    break
                time.sleep(0.01)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--quick", action="store_true", help="skip the 24-second watchdog check"
    )
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="agent-stat-lifecycle-") as folder:
        root = Path(folder)
        binary = root / "stream-lifecycle"
        names = [
            "RemoteStream",
            "RemoteCache",
            "EventReader",
            "FileStamp",
            "Record",
            "Paths",
        ]
        subprocess.run(
            [
                "swiftc",
                "-o",
                str(binary),
                str(REPOSITORY / "tests/stream-lifecycle.swift"),
                *[str(REPOSITORY / f"src/{name}.swift") for name in names],
            ],
            check=True,
            timeout=60,
        )
        scenario(binary, root, "stalled", 1024)
        scenario(binary, root, "ignore", 0)
        if not arguments.quick:
            scenario(binary, root, "progress", 0)
    print("Temporary lifecycle files and helpers removed")


if __name__ == "__main__":
    main()
