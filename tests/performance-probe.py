#!/usr/bin/env python3
"""Measure optimized readers against repeatable isolated histories and name indexes."""

import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPOSITORY = Path(__file__).resolve().parents[1]


def fixtures(root):
    events = root / "events"
    events.mkdir()
    for number in range(365):
        day = datetime.date(2025, 1, 1) + datetime.timedelta(days=number)
        (events / f"performance-{day}.jsonl").write_bytes(b"")
    with (events / "performance-2026-10-23.jsonl").open("w") as stream:
        for number in range(50000):
            stream.write(
                json.dumps(
                    {
                        "ts": 1792690000,
                        "event": "PostToolUse",
                        "agent": "codex",
                        "session": f"session-{number % 20}",
                        "cwd": "/workspace/project",
                    }
                )
                + "\n"
            )
    profile = root / "home/.codex"
    profile.mkdir(parents=True)
    with (profile / "session_index.jsonl").open("w") as stream:
        for number in range(1000):
            stream.write(
                json.dumps(
                    {
                        "id": f"session-{number}",
                        "thread_name": f"Session {number}",
                        "updated_at": "2026-10-23T00:00:00.123Z",
                    }
                )
                + "\n"
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--binary", type=Path, help="write the optimized benchmark binary here"
    )
    parser.add_argument(
        "--compare", type=Path, help="run a saved binary on the same fixtures"
    )
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="agent-stat-performance-") as folder:
        root = Path(folder)
        binary = (
            arguments.binary.resolve() if arguments.binary else root / "performance"
        )
        binary.parent.mkdir(parents=True, exist_ok=True)
        names = ["EventReader", "FileStamp", "Record", "CodexTitles"]
        subprocess.run(
            [
                "swiftc",
                "-O",
                "-o",
                str(binary),
                str(REPOSITORY / "tests/performance.swift"),
                *[str(REPOSITORY / f"src/{name}.swift") for name in names],
            ],
            check=True,
            timeout=60,
        )
        fixtures(root)
        environment = dict(os.environ)
        environment.pop("CODEX_HOME", None)
        if arguments.compare:
            print("Saved binary:", flush=True)
            subprocess.run(
                [str(arguments.compare.resolve()), str(root)],
                env=environment,
                check=True,
                timeout=60,
            )
        print("Current binary:", flush=True)
        subprocess.run(
            [str(binary), str(root)], env=environment, check=True, timeout=60
        )
    print("Temporary performance fixtures removed")


if __name__ == "__main__":
    main()
