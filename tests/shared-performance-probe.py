#!/usr/bin/env python3
"""Compare shared renderer costs with a saved binary in isolated tmux servers."""

import argparse
import collections
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import subprocess
import tempfile
import time

FIXTURE = runpy.run_path(str(Path(__file__).with_name("shared-render-probe.py")))


def process_seconds(pid):
    value = subprocess.check_output(
        ["/bin/ps", "-p", str(pid), "-o", "time="], text=True
    ).strip()
    return FIXTURE["cpu_seconds"](value)


def stop_workers(children):
    for child in children:
        if child.returncode is None:
            child.terminate()
    cpu = 0.0
    for child in children:
        if child.returncode is not None:
            continue
        _, status, usage = os.wait4(child.pid, 0)
        child.returncode = os.waitstatus_to_exitcode(status)
        cpu += usage.ru_utime + usage.ru_stime
    return cpu


def sample(root, binary, windows, seconds, label):
    socket = str(root / "socket")
    real_tmux = shutil.which("tmux")
    if real_tmux is None:
        raise RuntimeError("tmux is required")
    proxy = root / "bin"
    proxy.mkdir()
    calls = root / "calls.log"
    wrapper = proxy / "tmux"
    wrapper.write_text(
        '#!/bin/sh\nprintf "%s\\n" "$*" >> "$AUDIT_CALLS"\nexec '
        + shlex.quote(real_tmux)
        + ' "$@"\n'
    )
    wrapper.chmod(0o700)
    environment = dict(os.environ)
    environment.update(
        HOME=str(root),
        AGENT_STAT_DIR=str(root / "events"),
        TMUX_SIDEBAR_STATE_DIR=str(root / "state"),
        AUDIT_CALLS=str(calls),
        PATH=str(proxy) + os.pathsep + os.environ["PATH"],
    )
    environment.pop("TMUX", None)
    environment.pop("TMUX_PANE", None)

    def tmux(*arguments):
        return subprocess.check_output(
            [real_tmux, "-S", socket, *arguments], env=environment, text=True
        ).rstrip("\n")

    workers = []
    started = None
    try:
        sidebars, content = FIXTURE["setup"](tmux, binary, socket, windows, "shared")
        tmux("set-option", "-g", "@window_sidebar_shared", "1")
        started = time.monotonic()
        with (root / "workers.log").open("w+") as log:
            for action in ("shared-serve", "monitor"):
                workers.append(
                    subprocess.Popen(
                        [binary, "--socket", socket, "--session", "probe", action],
                        env=environment,
                        stdout=log,
                        stderr=log,
                    )
                )
            FIXTURE["check_frames"](tmux, sidebars, content, workers[0], log)
            result = idle_sample(tmux, workers, calls, seconds)
        result.update(label=label, windows=windows)
        return result
    finally:
        cpu = stop_workers(workers)
        lifetime = time.monotonic() - started if started is not None else 0
        subprocess.run(
            [real_tmux, "-S", socket, "kill-server"], capture_output=True, check=False
        )
        if started is not None and "result" in locals():
            result["worker_lifetime_seconds"] = round(lifetime, 2)
            result["worker_cpu_percent_including_children"] = round(
                100 * cpu / lifetime, 2
            )


def idle_sample(tmux, workers, calls, seconds):
    time.sleep(2)
    offset = calls.stat().st_size
    server = int(tmux("display-message", "-p", "#{pid}"))
    before = process_seconds(server)
    started = time.monotonic()
    time.sleep(seconds)
    elapsed = time.monotonic() - started
    after = process_seconds(server)
    for child in workers:
        if child.poll() is not None:
            raise RuntimeError("A measured worker exited")
    with calls.open() as log:
        log.seek(offset)
        commands = log.read().splitlines()
    counts = collections.Counter(
        command.split()[2] for command in commands if len(command.split()) >= 3
    )
    return {
        "sample_seconds": round(elapsed, 2),
        "tmux_subprocesses": dict(counts),
        "tmux_launches_per_second": round(len(commands) / elapsed, 2),
        "server_cpu_percent": round(100 * (after - before) / elapsed, 2),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--windows", type=int, nargs="+", default=[8, 32])
    parser.add_argument("--seconds", type=float, default=10)
    arguments = parser.parse_args()
    if arguments.seconds <= 0 or any(count <= 0 for count in arguments.windows):
        parser.error("Window counts and sample duration must be positive")
    binaries = [("current", arguments.binary.resolve(strict=True))]
    if arguments.baseline is not None:
        binaries.insert(0, ("baseline", arguments.baseline.resolve(strict=True)))
    for windows in arguments.windows:
        for label, binary in binaries:
            with tempfile.TemporaryDirectory(
                prefix="shared-performance-", dir="/tmp"
            ) as folder:
                print(
                    json.dumps(
                        sample(
                            Path(folder), str(binary), windows, arguments.seconds, label
                        )
                    ),
                    flush=True,
                )


if __name__ == "__main__":
    main()
