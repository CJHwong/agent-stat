#!/usr/bin/env python3
"""Measure navigation command costs without saving session or terminal contents."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "probe", REPO / "tests/tmux-jump-probe.py"
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
HARNESS = r"""
import Foundation
var samples: [(String, Double)] = []
func measure(_ label: String, count: Int = 20, _ body: () -> Void) {
    body()
    var durations: [Double] = []
    var totals: [String: [Double]] = [:]
    var counts: [String: Int] = [:]
    for _ in 0..<count {
        samples = []
        let start = ProcessInfo.processInfo.systemUptime
        body()
        durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        var iteration: [String: Double] = [:]
        for (operation, elapsed) in samples {
            iteration[operation, default: 0] += elapsed
            counts[operation, default: 0] += 1
        }
        for (operation, elapsed) in iteration { totals[operation, default: []].append(elapsed) }
    }
    let sorted = durations.sorted()
    let result: [String: Any] = ["operation": label, "samples": count,
        "median_ms": sorted[count / 2], "p95_ms": sorted[Int(ceil(Double(count) * 0.95)) - 1],
        "commands_per_sample": counts.mapValues { Double($0) / Double(count) },
        "command_median_ms": totals.mapValues { $0.sorted()[$0.count / 2] }]
    print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
}
let root = CommandLine.arguments[1]
let pane = CommandLine.arguments[2]
let terminal = CommandLine.arguments[3]
let pid = Int(CommandLine.arguments[4])!
let argv = [CommandLine.arguments[5], "-S", root + "/s"]
let route = try! Routes.decode(JSONSerialization.data(withJSONObject: ["peer": ["tmux": argv]])).route(for: "peer")!
measure("empty_command", count: 100) { precondition(Jumper.runTmux(["/usr/bin/true"], []).status == 0) }
measure("output_256KiB", count: 10) {
    let result = Jumper.runTmux(["/bin/dd"], ["if=/dev/zero", "bs=262144", "count=1"])
    precondition(result.status == 0)
}
measure("process_identity_1000") { for _ in 0..<1000 { precondition(processIsAlive(Int32(pid))) } }
measure("ghostty_enumeration") { _ = Jumper.ghosttyTabs() }
measure("remote_identifier") { _ = Jumper.performRoute(host: "peer", route: route, pane: pane, folder: root + "/workspace", title: nil) }
measure("remote_title") { _ = Jumper.performRoute(host: "peer", route: route, pane: nil, folder: root + "/workspace", title: "Synthetic target") }
measure("remote_title_alias") { _ = Jumper.performRoute(host: "peer", route: route, pane: nil, folder: root + "/alias", title: "Synthetic target") }
measure("remote_missing_pane") { _ = Jumper.performRoute(host: "peer", route: route, pane: "%999999", folder: root, title: nil) }
var session = Session(key: SessionKey(host: "local", id: "synthetic"))
session.isLocal = true
session.tmuxPane = pane
session.launchCwd = root + "/workspace"
session.tty = terminal
session.agentPid = pid
SOCKET_ASSIGNMENT
measure("local_identifier") { _ = Jumper.perform(Jumper.plan(for: session)) }
LOCAL_TITLE
"""


def compile_probe(root, version):
    directory = root / version
    directory.mkdir()
    names = [
        "Jump",
        "JumpRemote",
        "Liveness",
        "TmuxTargeting",
        "Session",
        "Record",
        "Routes",
        "Paths",
    ]
    if version == "current":
        names += ["CommandRunner", "JumpLocal"]
    for name in names:
        source = (
            (REPO / f"src/{name}.swift").read_text()
            if version == "current"
            else subprocess.check_output(
                ["git", "show", f"{arguments.baseline}:src/{name}.swift"], text=True
            )
        )
        if name == "Jump":
            source = source.replace("app.activate()", "_ = app")
        target = "CommandRunner" if version == "current" else "Jump"
        if name == target:
            needle = "timeout: TimeInterval = 10) -> Result {"
            assert source.count(needle) == 1
            source = source.replace(
                needle,
                needle
                + """
        let sampleStart = ProcessInfo.processInfo.systemUptime
        defer {
            let operation = path == "/usr/bin/osascript" ? "osascript" : (arguments.first(where: { ["list-panes", "list-clients", "select-window", "select-pane", "run-shell"].contains($0) }) ?? URL(fileURLWithPath: path).lastPathComponent)
            samples.append((operation, (ProcessInfo.processInfo.systemUptime - sampleStart) * 1000))
        }
""",
            )
        (directory / f"{name}.swift").write_text(source)
    harness = HARNESS.replace(
        "SOCKET_ASSIGNMENT",
        'session.tmuxSocket = root + "/s"' if version == "current" else "",
    )
    harness = harness.replace(
        "LOCAL_TITLE",
        """session.tmuxPane = nil
session.title = "Synthetic target"
measure("local_title") { _ = Jumper.perform(Jumper.plan(for: session)) }"""
        if version == "current"
        else "",
    )
    (directory / "main.swift").write_text(harness)
    binary = directory / "measure"
    subprocess.run(
        ["swiftc", "-O", "-o", str(binary), *map(str, directory.glob("*.swift"))],
        check=True,
        timeout=90,
    )
    return binary


def main():
    global arguments
    parser = argparse.ArgumentParser(
        description="Measure navigation commands with isolated synthetic sessions."
    )
    parser.add_argument("--baseline", help="compare a previous Git revision")
    parser.add_argument("--output", type=Path, help="save measurements as JSON")
    parser.add_argument(
        "--ssh",
        action="store_true",
        help="also measure read-only calls through the configured SSH route",
    )
    arguments = parser.parse_args()
    results = {}
    with tempfile.TemporaryDirectory(prefix="agent-stat-performance-") as folder:
        root = Path(folder).resolve()
        (root / "workspace").mkdir()
        (root / "alias").symlink_to(root / "workspace", target_is_directory=True)
        tmux = [shutil.which("tmux"), "-S", str(root / "s"), "-f", "/dev/null"]

        def command(*args):
            return subprocess.check_output([*tmux, *args], text=True).strip()

        try:
            pane = command(
                "new-session",
                "-d",
                "-P",
                "-F#{pane_id}",
                "-s",
                "synthetic",
                "-c",
                str(root / "workspace"),
                "/bin/sh",
            )
            command(
                "split-window", "-t", pane, "-c", str(root / "workspace"), "/bin/sh"
            )
            command("select-pane", "-t", pane, "-T", "Synthetic target")
            terminal, pid = command(
                "display-message", "-p", "-t", pane, "#{pane_tty},#{pane_pid}"
            ).split(",")
            with probe.attached_client(tmux, "synthetic"):
                for version in (
                    ["baseline", "current"] if arguments.baseline else ["current"]
                ):
                    binary = compile_probe(root, version)
                    env = dict(os.environ, TMUX=str(root / "s") + ",1,0")
                    completed = subprocess.run(
                        [str(binary), str(root), pane, terminal, pid, tmux[0]],
                        env=env,
                        text=True,
                        capture_output=True,
                        check=True,
                        timeout=120,
                    )
                    results[version] = [
                        json.loads(line) for line in completed.stdout.splitlines()
                    ]
                    print(json.dumps({version: results[version]}, indent=2), flush=True)
        finally:
            subprocess.run([*tmux, "kill-server"], capture_output=True)
    if arguments.ssh:
        routes = json.loads(
            (Path.home() / ".config/agent-stat/routes.json").read_text()
        )
        argv = next(
            route["tmux"]
            for route in routes.values()
            if any(Path(arg).name == "ssh" for arg in route.get("tmux", []))
        )
        timings = []
        for _ in range(10):
            start = time.monotonic()
            subprocess.run(
                [*argv, "list-panes", "-a", "'-F#{pane_id}'"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                check=True,
                timeout=15,
            )
            timings.append((time.monotonic() - start) * 1000)
        results["configured_ssh_read_only"] = {
            "samples": len(timings),
            "median_ms": statistics.median(timings),
            "p95_ms": sorted(timings)[-1],
        }
        print(
            json.dumps(
                {"configured_ssh_read_only": results["configured_ssh_read_only"]},
                indent=2,
            )
        )
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
