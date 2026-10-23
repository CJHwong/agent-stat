#!/usr/bin/env python3
"""Check automatic names with a real Codex process and an isolated profile."""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time

REPOSITORY = Path(__file__).resolve().parents[1]


def install(root):
    profile = root / "profile"
    profile.mkdir()
    (root / "workspace").mkdir()
    authentication = Path.home() / ".codex/auth.json"
    if not authentication.is_file():
        raise RuntimeError("Codex authentication is unavailable")
    (profile / "auth.json").symlink_to(authentication)
    (profile / "config.toml").write_text(
        'model = "gpt-6-luna"\n'
        'model_reasoning_effort = "low"\n'
        'approval_policy = "never"\n'
        'sandbox_mode = "danger-full-access"\n'
    )
    environment = dict(
        os.environ, CODEX_HOME=str(profile), AGENT_STAT_DIR=str(root / "events")
    )
    subprocess.run(
        [
            sys.executable,
            str(REPOSITORY / "install.py"),
            "--apply",
            "--claude-config",
            str(root / "claude"),
            "--codex-home",
            str(profile),
        ],
        env=environment,
        capture_output=True,
        text=True,
        check=True,
        timeout=15,
    )
    return environment


def read_output(process, messages):
    for line in process.stdout:
        messages.put(json.loads(line))
    messages.put(None)


def set_name(profile, session, title):
    with (profile / "session_index.jsonl").open("a") as index:
        index.write(json.dumps({"id": session, "thread_name": title}) + "\n")


def run_codex(root, environment):
    process = subprocess.Popen(
        [
            "codex",
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--cd",
            str(root / "workspace"),
            "Run this shell command once: sleep 1; printf ok. Then reply with ok.",
        ],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=(root / "stderr.log").open("w"),
        text=True,
    )
    messages = queue.Queue()
    reader = threading.Thread(target=read_output, args=(process, messages), daemon=True)
    reader.start()
    session = None
    renamed = False
    deadline = time.monotonic() + 120
    try:
        while time.monotonic() < deadline:
            message = messages.get(timeout=max(0.1, deadline - time.monotonic()))
            if message is None:
                break
            if message.get("type") == "thread.started":
                session = message["thread_id"]
                set_name(root / "profile", session, "AgentStat title probe")
            if (
                message.get("type") == "item.completed"
                and message.get("item", {}).get("type") == "command_execution"
            ):
                assert session is not None
                set_name(root / "profile", session, "AgentStat renamed probe")
                renamed = True
        else:
            raise RuntimeError("Codex title probe timed out")
        process.wait(timeout=5)
        if process.returncode != 0:
            raise RuntimeError((root / "stderr.log").read_text())
        assert session is not None and renamed, "Codex did not report the test command"
        return session
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        process.stdout.close()
        reader.join(timeout=2)


def main():
    with tempfile.TemporaryDirectory(prefix="agent-stat-codex-title-") as directory:
        root = Path(directory)
        environment = install(root)
        session = run_codex(root, environment)
        records = [
            json.loads(line)
            for path in (root / "events/hosts").glob("*.jsonl")
            for line in path.read_text().splitlines()
        ]
        matching = [record for record in records if record.get("session") == session]
        assert matching, "real Codex hooks wrote no records"
        assert any(
            record.get("title") == "AgentStat title probe" for record in matching
        )
        assert any(
            record.get("title") == "AgentStat renamed probe" for record in matching
        )
        stops = [record for record in matching if record["event"] == "Stop"]
        assert stops and stops[-1]["title"] == "AgentStat renamed probe"
        print("PASS real Codex: hooks capture late index names and subsequent renames")
        print(
            "PASS isolated CODEX_HOME and persisted hook trust work without a trust bypass"
        )
    print("Temporary profile and event files removed")


if __name__ == "__main__":
    main()
