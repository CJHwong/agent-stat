import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(tempfile.mkdtemp(prefix="sidebar-recovery-"))
os.environ["TMUX_SIDEBAR_STATE_DIR"] = str(root / "state")
probe = root / "launched.json"
os.environ["SIDEBAR_RECOVERY_PROBE"] = str(probe)
agent_binary = root / "bin/claude"
agent_binary.parent.mkdir()
agent_binary.write_text(
    "#!"
    + sys.executable
    + '\nimport json,os,sys,time\nfrom pathlib import Path\nPath(os.environ["SIDEBAR_RECOVERY_PROBE"]).write_text(json.dumps({"arguments":sys.argv[1:],"profile":os.environ.get("CLAUDE_CONFIG_DIR")}))\ntime.sleep(120)\n'
)
agent_binary.chmod(0o700)
os.environ["PATH"] = str(agent_binary.parent) + os.pathsep + os.environ["PATH"]
os.environ["AGENT_STAT_DIR"] = str(root / "events")
module_path = Path(sys.argv[1])
sys.path.insert(0, str(module_path.parent))
spec = importlib.util.spec_from_file_location("sidebar_agents_check", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
socket_name = "sidebar-recovery-check-" + str(os.getpid())


def tmux(*arguments):
    return subprocess.check_output(
        ["tmux", "-L", socket_name, *arguments], text=True
    ).rstrip("\n")


try:
    tmux(
        "-f",
        "/dev/null",
        "new-session",
        "-d",
        "-s",
        "source",
        "-x",
        "120",
        "-y",
        "40",
        "sleep 120",
    )
    tmux("set-option", "-g", "default-shell", "/bin/sh")
    tmux("new-session", "-d", "-s", "keep", "sleep 120")
    socket_path = tmux("display-message", "-p", "#{socket_path}")
    server_pid = tmux("display-message", "-p", "#{pid}")
    pane = tmux("display-message", "-p", "-t", "source", "#{pane_id}")
    tmux(
        "split-window", "-d", "-h", "-l", "30", "-t", pane, "-c", str(root), "sleep 120"
    )
    profile = root / "profile"
    profile.mkdir()
    environment = os.environ.copy()
    environment.update(
        TMUX=socket_path + "," + server_pid + ",0",
        TMUX_PANE=pane,
        CLAUDE_CONFIG_DIR=str(profile),
    )
    session_id = "12345678-1234-1234-1234-123456789012"
    module.process_profile = lambda pid, agent: str(profile)
    event_file = root / "events" / "hosts" / (module.EVENTS.host + "-2026-11-03.jsonl")
    event_file.parent.mkdir(parents=True)
    agent_pid = int(tmux("display-message", "-p", "-t", pane, "#{pane_pid}"))
    for event, state in (
        ("SessionStart", "idle"),
        ("PermissionRequest", "waiting"),
        ("UserPromptSubmit", "working"),
        ("Stop", "done"),
    ):
        payload = {"hook_event_name": event, "session_id": session_id, "cwd": str(root)}
        with event_file.open("a") as stream:
            stream.write(
                json.dumps(
                    {
                        "event": event,
                        "session": session_id,
                        "agent": "claude",
                        "agent_pid": agent_pid,
                        "tmux": pane,
                        "cwd": str(root),
                        "ts": time.time(),
                    }
                )
                + "\n"
            )
        assert module.agent_states(socket_path, "source")[pane]["state"] == state
    snapshot = module.save_snapshot(socket_path, "source", True)
    assert snapshot["windows"][0]["panes"][0]["agent"]["profile"] == str(profile)
    assert module.restore_snapshot(socket_path, "source") is None, (
        "Active conversations must not start twice"
    )
    tmux("kill-session", "-t", "source")
    recovered = module.restore_snapshot(socket_path, "source")
    assert recovered == "recovered-source"
    deadline = time.monotonic() + 8
    while not probe.exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert probe.exists(), "The recovered agent starts"
    launched = json.loads(probe.read_text())
    assert launched["arguments"] == ["--resume", session_id]
    assert launched["profile"] == str(profile), "Recovery preserves the agent profile"
    panes = tmux(
        "list-panes", "-t", recovered, "-F", "#{pane_width} #{pane_height}"
    ).splitlines()
    assert len(panes) == 2, "Recovery restores split panes"
    geometry = [list(map(int, line.split())) for line in panes]
    assert geometry[0][1] == geometry[1][1] and geometry[0][0] > geometry[1][0], (
        "Recovery preserves split direction and proportions"
    )
    print(
        "PASS: agent-stat states, private snapshots, duplicate prevention, conversation resume, profile, and split layout."
    )
finally:
    subprocess.run(
        ["tmux", "-L", socket_name, "kill-server"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
