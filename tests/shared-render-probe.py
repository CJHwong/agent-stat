#!/usr/bin/env python3
"""Compare sidebar processes with shared drawing in isolated tmux servers."""

import argparse
import json
import os
from pathlib import Path
import shlex
import statistics
import subprocess
import tempfile
import time


def command(arguments, *, environment=None):
    return subprocess.check_output(arguments, env=environment, text=True).rstrip("\n")


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(description)


def cpu_seconds(value):
    fields = value.split(":")
    return sum(float(field) * 60**index for index, field in enumerate(reversed(fields)))


def processes(identifiers):
    rows = command(["ps", "-axo", "pid=,rss=,time="])
    selected = [
        row.split() for row in rows.splitlines() if row.split()[0] in identifiers
    ]
    assert len(selected) == len(identifiers), "A measured process exited"
    return {
        "rss_kib": sum(int(row[1]) for row in selected),
        "cpu_seconds": sum(cpu_seconds(row[2]) for row in selected),
    }


def setup(tmux, binary, socket, windows, mode):
    tmux(
        "-f",
        "/dev/null",
        "new-session",
        "-d",
        "-s",
        "probe",
        "-x",
        "120",
        "-y",
        "40",
        "sleep 300",
    )
    tmux("set-option", "-g", "status", "off")
    sidebars = []
    content = []
    for index in range(windows):
        if index:
            tmux("new-window", "-d", "-t", "probe:", "sleep 300")
        target = f"probe:{index}"
        content.append(tmux("display-message", "-p", "-t", target, "#{pane_id}"))
        tmux(
            "set-option",
            "-p",
            "-t",
            content[-1],
            "@window_sidebar_label",
            "probe-original",
        )
        shell = (
            shlex.join([binary, "--socket", socket, "--session", "probe", "render"])
            if mode == "baseline"
            else ""
        )
        sidebars.append(
            tmux(
                "split-window",
                "-d",
                "-b",
                "-h",
                "-l",
                "28",
                "-t",
                target,
                "-P",
                "-F",
                "#{pane_id}",
                shell,
            )
        )
        tmux("set-option", "-p", "-t", sidebars[-1], "@window_sidebar", "1")
        if mode == "shared":
            tmux("set-option", "-p", "-t", sidebars[-1], "@shared_sidebar", "1")
    return sidebars, content


def check_frames(tmux, sidebars, content, service, log):
    def capture(pane):
        if service is not None and service.poll() is not None:
            log.seek(0)
            raise AssertionError(log.read())
        return tmux("capture-pane", "-p", "-t", pane)

    wait_for(
        lambda: all("probe-original" in capture(pane) for pane in sidebars),
        "Every sidebar draws content",
    )
    started = time.monotonic()
    tmux("set-option", "-p", "-t", content[0], "@window_sidebar_label", "probe-renamed")
    wait_for(
        lambda: all("probe-renamed" in capture(pane) for pane in sidebars),
        "Every sidebar redraws after a rename",
    )
    redraw_seconds = time.monotonic() - started
    tmux("resize-pane", "-t", sidebars[0], "-x", "3")
    wait_for(lambda: "▶" in capture(sidebars[0]), "A narrow sidebar draws its arrow")
    tmux("resize-pane", "-t", sidebars[0], "-x", "28")
    wait_for(
        lambda: "probe-renamed" in capture(sidebars[0]),
        "A resized sidebar restores its content",
    )
    return redraw_seconds


def measure(tmux, sidebars, service, seconds):
    renderers = (
        {str(service.pid)}
        if service
        else {
            tmux("display-message", "-p", "-t", pane, "#{pane_pid}")
            for pane in sidebars
        }
    )
    server = {tmux("display-message", "-p", "#{pid}")}
    time.sleep(2)
    before = processes(renderers | server)
    started = time.monotonic()
    samples = []
    while time.monotonic() - started < seconds:
        samples.append((processes(renderers), processes(server)))
        time.sleep(0.5)
    after = processes(renderers | server)
    return {
        "renderer_processes": len(renderers),
        "renderer_rss_mib": round(
            statistics.median(sample[0]["rss_kib"] for sample in samples) / 1024, 2
        ),
        "tmux_rss_mib": round(
            statistics.median(sample[1]["rss_kib"] for sample in samples) / 1024, 2
        ),
        "sampled_process_cpu_percent": round(
            100
            * (after["cpu_seconds"] - before["cpu_seconds"])
            / (time.monotonic() - started),
            2,
        ),
    }


def isolated_probe(root, binary, windows, mode, seconds):
    socket = str(root / "socket")
    environment = dict(os.environ)
    environment.update(
        AGENT_STAT_DIR=str(root / "events"),
        TMUX_SIDEBAR_STATE_DIR=str(root / "state"),
    )
    environment.pop("TMUX", None)
    environment.pop("TMUX_PANE", None)

    def tmux(*arguments):
        return command(["tmux", "-S", socket, *arguments], environment=environment)

    service = None
    with (root / "service.log").open("w+") as log:
        try:
            sidebars, content = setup(tmux, binary, socket, windows, mode)
            if mode == "shared":
                service = subprocess.Popen(
                    [binary, "--socket", socket, "--session", "probe", "shared-serve"],
                    env=environment,
                    stdout=log,
                    stderr=log,
                )
            redraw_seconds = check_frames(tmux, sidebars, content, service, log)
            return {
                "mode": mode,
                "windows": windows,
                **measure(tmux, sidebars, service, seconds),
                "redraw_seconds": round(redraw_seconds, 3),
                "checks": "all panes draw, rename redraws, narrow pane draws, resize restores",
            }
        finally:
            if service is not None:
                service.terminate()
                service.wait(timeout=10)
            subprocess.run(
                ["tmux", "-S", socket, "kill-server"], capture_output=True, check=False
            )


def run_probe(binary, windows, mode, seconds):
    with tempfile.TemporaryDirectory(prefix="shared-render-") as folder:
        result = isolated_probe(Path(folder), binary, windows, mode, seconds)
        print(json.dumps(result), flush=True)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--windows", type=int, nargs="+", default=[1, 8, 32])
    parser.add_argument("--seconds", type=float, default=10)
    arguments = parser.parse_args()
    if arguments.seconds <= 0 or any(count <= 0 for count in arguments.windows):
        parser.error("Window counts and sample duration must be positive")
    binary = str(arguments.binary.resolve(strict=True))
    for count in arguments.windows:
        for mode in ("baseline", "shared"):
            run_probe(binary, count, mode, arguments.seconds)


if __name__ == "__main__":
    main()
