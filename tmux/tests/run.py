#!/usr/bin/env python3
"""Run the terminal checks without changing an existing tmux server."""

from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

for filename in sorted((ROOT / "tests").glob("check_*.py")):
    if filename.name == "check_recovery.py" and not shutil.which("tmux"):
        print("SKIP: recovery integration check requires tmux")
        continue
    subprocess.run(
        [sys.executable, str(filename), str(ROOT / "sidebar_agents.py")], check=True
    )
subprocess.run(
    [
        sys.executable,
        "-m",
        "unittest",
        "discover",
        "-s",
        str(ROOT / "tests"),
        "-p",
        "test_*.py",
    ],
    check=True,
)
