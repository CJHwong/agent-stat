#!/usr/bin/env python3
"""Prove the agent-stat hooks fire from real Claude Code and real Codex runs.

This is the real-run gate for step 1, not a fixture test. It builds two throwaway
config trees under /tmp, installs the hooks into them, starts an actual agent in
each, and asserts on the records that land.

Why not a fixture: the two things that broke this design were the Codex trust
gate and the record shape. Neither shows up in a fixture.

It never touches ~/.claude or ~/.codex. Both are passed explicitly to the installer.

Usage: python3 tests/live-probe.py
"""

from __future__ import annotations

import argparse
import json
import os
import re

import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL = REPO / "install.py"
MAX_RECORD_BYTES = 4096
# Codex events the installer registers, so the probe can assert the trust count.
CODEX_EVENT_COUNT = 10
# The installer registers ten Codex events, plus StopFailure for Claude Code.
CLAUDE_EVENT_COUNT = 11


def build_tree() -> Path:
    root = Path(tempfile.mkdtemp(prefix="agent-stat-e2e-"))
    for name in ("claude", "codex", "events"):
        (root / name).mkdir(parents=True, exist_ok=True)

    # Codex needs credentials and a model config. Symlink auth so the secret is
    # never read into this process.
    auth = Path.home() / ".codex" / "auth.json"
    if auth.exists():
        (root / "codex" / "auth.json").symlink_to(auth)
    (root / "codex" / "config.toml").write_text(
        'model = "gpt-6-luna"\n'
        'model_reasoning_effort = "low"\n'
        'approval_policy = "never"\n'
        'sandbox_mode = "danger-full-access"\n'
    )
    return root


def run(cmd: list[str], env: dict, timeout: int) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        env=env,
        timeout=timeout,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )


def install(root: Path) -> str:
    env = dict(os.environ)
    env["AGENT_STAT_DIR"] = str(root / "events")
    proc = run(
        [
            sys.executable,
            str(INSTALL),
            "--apply",
            "--claude-config",
            str(root / "claude"),
            "--codex-home",
            str(root / "codex"),
        ],
        env,
        120,
    )
    print(proc.stdout)
    if proc.returncode != 0:
        raise SystemExit(f"installer failed:\n{proc.stderr}")
    return str(root / "events")


def run_claude(root: Path, events: str) -> int:
    env = dict(os.environ)
    env["AGENT_STAT_DIR"] = events
    env["CLAUDE_CONFIG_DIR"] = str(root / "claude")
    print("starting a real claude session...")
    proc = subprocess.Popen(
        ["claude", "-p", "Reply with the single word ok.", "--output-format", "text"],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    out, err = proc.communicate(timeout=240)
    print(f"  claude exit={proc.returncode} out={out.strip()[:60]!r}")
    if err.strip():
        print(f"  claude stderr: {err.strip().splitlines()[-1][:120]}")
    return proc.pid


def run_codex(root: Path, events: str) -> None:
    env = dict(os.environ)
    env["AGENT_STAT_DIR"] = events
    env["CODEX_HOME"] = str(root / "codex")
    print("starting a real codex session...")
    # No --dangerously-bypass-hook-trust here. Persisted trust must be enough,
    # or the installer does not work.
    proc = subprocess.Popen(
        [
            "codex",
            "exec",
            "--skip-git-repo-check",
            "Run this shell command: echo ok    Then reply with the single word ok.",
        ],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    out, err = proc.communicate(timeout=240)
    print(f"  codex exit={proc.returncode} out={out.strip()[:60]!r}")
    if proc.returncode != 0:
        tail = [line for line in err.strip().splitlines() if line.strip()][-6:]
        print("  codex stderr (last lines):")
        for line in tail:
            print(f"    {line[:160]}")


def load_records(events: str) -> list[dict]:
    records = []
    for path in sorted(Path(events, "hosts").glob("*.jsonl")):
        for line in path.read_text().splitlines():
            if line.strip():
                records.append(json.loads(line))
    return records


def check(records: list[dict], pid_sink: list[int]) -> list[str]:
    failures: list[str] = []

    for agent in ("claude", "codex"):
        mine = [r for r in records if r["agent"] == agent]
        if not mine:
            failures.append(f"{agent}: no records at all")
            continue
        events = [r["event"] for r in mine]
        print(f"  {agent}: {len(mine)} records, events={events}")
        for required in ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"):
            if required not in events:
                failures.append(f"{agent}: missing {required}")
        for record in mine:
            if not record.get("session"):
                failures.append(
                    f"{agent}: record without session_id: {record['event']}"
                )
            if not record.get("cwd"):
                failures.append(f"{agent}: record without cwd: {record['event']}")
            encoded = json.dumps(record).encode()
            if len(encoded) > MAX_RECORD_BYTES:
                failures.append(f"{agent}: record over {MAX_RECORD_BYTES} bytes")
            if record["agent_pid"] <= 0:
                failures.append(f"{agent}: bad agent_pid on {record['event']}")

        stop = [r for r in mine if r["event"] == "Stop"]
        if stop and not stop[-1].get("turn"):
            failures.append(f"{agent}: Stop without a turn id")

        first = mine[0]
        if first["event"] == "SessionStart" and not first.get("agent_start"):
            failures.append(f"{agent}: SessionStart without agent_start")

    # The hook's parent must be the agent process this probe started.
    observed = {r["agent_pid"] for r in records if r["agent"] == "claude"}
    if pid_sink and observed:
        print(
            f"  claude pid: probe spawned {pid_sink[0]}, hook recorded {sorted(observed)}"
        )
        if pid_sink[0] not in observed:
            failures.append(
                f"hook's PPID ({sorted(observed)}) is not the claude process "
                f"the probe started ({pid_sink[0]}); liveness tracking would be wrong"
            )

    codex_models = {r.get("model") for r in records if r["agent"] == "codex"}
    if codex_models == {None}:
        failures.append("codex: no record carried a model, expected one on every event")

    # The run-status half of the feature depends on tool events. The codex prompt
    # deliberately runs a shell command so those hooks are exercised for real.
    #
    # Codex sends no duration_ms, so the check is that both ends of the tool call
    # arrive and that a duration is derivable from their timestamps. Claude Code
    # does send duration_ms, but its tool events are covered by the standalone
    # payload capture, not here: a nested claude -p will not reliably run a tool.
    codex = [r for r in records if r["agent"] == "codex"]
    pre = [r for r in codex if r["event"] == "PreToolUse"]
    post = [r for r in codex if r["event"] == "PostToolUse"]
    if not pre:
        failures.append(
            "codex: no PreToolUse, so running-tool status would have nothing to show"
        )
    if not post:
        failures.append("codex: no PostToolUse")
    else:
        if not post[-1].get("tool"):
            failures.append("codex: PostToolUse without a tool name")
        if pre and post[-1]["ts"] < pre[-1]["ts"]:
            failures.append("codex: PostToolUse timestamp precedes PreToolUse")
        print(
            f"  codex dur_ms from payload: {post[-1].get('dur_ms')!r} "
            f"(None is expected; derive from timestamps instead)"
        )
    return failures


def state_keys(config: Path) -> set[str]:
    if not config.exists():
        return set()
    return set(re.findall(r'\[hooks\.state\."([^"]+)"\]', config.read_text()))


def installer_cycle(root: Path, before: set[str], after: set[str]) -> list[str]:
    """A second install must change nothing.

    The trust keys are pure indices, so a re-install that resolves them against the
    file it has already rewritten leaves the old entries behind. An orphan whose hash
    no longer matches marks the hook now sitting at that index as Modified, which
    stops that hook from running at all. That happened once, on a real config.
    """
    print("installer cycle")
    failures: list[str] = []
    if len(after) - len(before) != CODEX_EVENT_COUNT:
        failures.append(
            f"install added {len(after) - len(before)} trust entries, "
            f"expected {CODEX_EVENT_COUNT}"
        )

    install(root)
    again = state_keys(root / "codex" / "config.toml")
    if again != after:
        failures.append(
            f"a second install changed the trust state: {len(again)} entries, was {len(after)}"
        )

    hooks = json.loads((root / "codex" / "hooks.json").read_text()).get("hooks", {})
    ours = [
        h
        for g in hooks.values()
        for grp in g
        for h in grp.get("hooks", [])
        if "agent-stat-hook.sh" in str(h.get("command", ""))
    ]
    if len(ours) != CODEX_EVENT_COUNT:
        failures.append(
            f"a second install left {len(ours)} hook entries, expected once each"
        )

    settings = json.loads((root / "claude" / "settings.json").read_text()).get(
        "hooks", {}
    )
    ours = [
        h
        for g in settings.values()
        for grp in g
        for h in grp.get("hooks", [])
        if "agent-stat-hook.sh" in str(h.get("command", ""))
    ]
    if len(ours) != CLAUDE_EVENT_COUNT:
        failures.append(
            f"a second install left {len(ours)} claude hook entries, expected once each"
        )

    print(
        f"  {len(before)} trust entries before, {len(after)} after install, "
        f"{len(again)} after a second install"
    )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.parse_args()

    root = build_tree()
    print(f"isolated tree: {root}\n")
    codex_config = root / "codex" / "config.toml"
    before_install = state_keys(codex_config)
    events = install(root)
    after_install = state_keys(codex_config)

    started = time.time()
    claude_pid = run_claude(root, events)
    run_codex(root, events)

    records = load_records(events)
    print(f"\n{len(records)} records in {time.time() - started:.0f}s\n")

    failures = check(records, [claude_pid])
    print()
    failures += installer_cycle(root, before_install, after_install)

    if failures:
        print("\nFAIL")
        for item in failures:
            print(f"  - {item}")
        print(f"\nrecords kept at {events}")
        return 1

    print(
        "\nPASS. Both agents wrote records through their own hook systems, "
        "and a second install changed nothing."
    )
    print(f"records at {events}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
