"""Exercise selected command rerun on a separate tmux server."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sidebar_agents as agents

server = "command-recovery-check-" + str(os.getpid())


def tmux(*arguments):
    return subprocess.check_output(
        ["tmux", "-L", server, *arguments], text=True
    ).strip()


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    agents.ROOT = root / "state"
    marker = root / "arguments.json"
    script = root / "worker with spaces.py"
    script.write_text(
        'import json,sys,time,os\nfrom pathlib import Path\nPath(sys.argv[1]).write_text(json.dumps({"arguments":sys.argv[2:],"cwd":os.getcwd()}))\ntime.sleep(60)\n'
    )
    arguments = [
        sys.executable,
        str(script),
        str(marker),
        "two words",
        "; touch nope",
        "",
    ]
    try:
        tmux(
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "-s",
            "source",
            "-c",
            directory,
            shlex.join(arguments),
        )
        tmux("new-session", "-d", "-s", "keep", "sleep 60")
        socket = tmux("display-message", "-p", "#{socket_path}")
        deadline = time.monotonic() + 3
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert marker.exists()
        snapshot = agents.save_snapshot(socket, "source", True)
        session_id = tmux("display-message", "-p", "-t", "source", "#{session_id}")
        assert agents.snapshot_path(socket, session_id) == agents.snapshot_path(
            socket, "source"
        )
        assert agents.capture_snapshot(socket, session_id)["session"] == "source"
        pane = snapshot["windows"][0]["panes"][0]
        assert pane["command_argv"] == arguments
        assert agents.replay_candidates(socket, snapshot) == [], (
            "Running commands must not start twice"
        )
        tmux("kill-session", "-t", "source")
        marker.unlink()
        assert agents.restore_snapshot(socket, "source") is None
        assert not marker.exists(), "Default recovery must not rerun commands"
        recovered = agents.restore_snapshot(
            socket, "source", selected_commands={pane["pane_id"]}
        )
        assert recovered == "recovered-source"
        deadline = time.monotonic() + 3
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        launched = json.loads(marker.read_text())
        assert launched["arguments"] == ["two words", "; touch nope", ""]
        assert Path(launched["cwd"]).samefile(directory)
        assert not (root / "nope").exists(), (
            "Arguments must not become shell instructions"
        )
        print(
            "PASS: exact command capture, running-command exclusion, explicit rerun, folder, and literal arguments"
        )
    finally:
        subprocess.run(["tmux", "-L", server, "kill-server"], capture_output=True)
