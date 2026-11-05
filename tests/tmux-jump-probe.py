#!/usr/bin/env python3
"""Check the Swift jump code against a real client and an isolated tmux split."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

REPOSITORY = Path(__file__).resolve().parents[1]
HARNESS = r"""
import Foundation

var session = Session(key: SessionKey(host: "peer", id: "ram"))
session.title = "Memory report"
session.launchCwd = CommandLine.arguments[2]
let routes = Routes.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
if CommandLine.arguments.count == 5 {
    let route = routes.route(for: "peer")!
    let clients = Jumper.runTmux(route.argv, TmuxTargeting.clients(pane: CommandLine.arguments[3]))
    precondition(clients.status == 0, "cannot list clients for the target pane")
    let tabs = [
        GhosttyTab(id: "target", windowId: "window", name: "tmux", cwd: "", tty: CommandLine.arguments[4]),
        GhosttyTab(id: "other", windowId: "window", name: "shell", cwd: "", tty: ""),
    ]
    precondition(TmuxTargeting.matchingClientTabs(in: clients.output, tabs: tabs).map(\.id) == ["target"],
                 "the real tmux client must identify its terminal tab")
    print("PASS real tmux client identifies the terminal tab")
    exit(0)
}
let outcome = Jumper.perform(Jumper.plan(for: session, routes: routes))
print(outcome.message ?? "ok")
"""


def exercise(root, tmux):
    source = root / "main.swift"
    source.write_text(HARNESS)
    binary = root / "jump-probe"
    names = [
        "Jump",
        "JumpRemote",
        "TmuxTargeting",
        "Session",
        "Record",
        "Routes",
        "Paths",
    ]
    subprocess.run(
        [
            "swiftc",
            "-o",
            str(binary),
            str(source),
            *[str(REPOSITORY / f"src/{name}.swift") for name in names],
        ],
        check=True,
    )
    routes = root / "routes.json"
    routes.write_text(json.dumps({"peer": {"tmux": tmux}}))

    def command(*arguments):
        return subprocess.check_output([*tmux, *arguments], text=True).strip()

    def jump():
        return subprocess.check_output([str(binary), str(routes), str(root)], text=True)

    command("new-session", "-d", "-s", "probe", "-c", str(root))
    target = command(
        "split-window", "-d", "-P", "-F#{pane_id}", "-t", "probe", "-c", str(root)
    )
    command("select-pane", "-t", target, "-T", "⠏ Memory report | operator")
    other = command(
        "new-window", "-d", "-P", "-F#{window_id}", "-t", "probe", "-c", str(root)
    )
    command("select-window", "-t", other)
    master, slave = os.openpty()
    client_terminal = os.ttyname(slave)
    environment = dict(os.environ, TERM="xterm-256color")
    environment.pop("TMUX", None)
    client = subprocess.Popen(
        [*tmux, "attach-session", "-t", "probe"],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=environment,
    )
    os.close(slave)
    try:
        deadline = time.monotonic() + 5
        while (
            command("display-message", "-p", "-t", "probe", "#{session_attached}")
            == "0"
        ):
            if time.monotonic() >= deadline:
                raise RuntimeError("the isolated tmux client did not attach")
            time.sleep(0.05)
        assert "selected the pane" in jump()
        assert command("display-message", "-p", "-t", "probe", "#{pane_id}") == target
        print("PASS real jump selects the target window and split pane")
        subprocess.run(
            [str(binary), str(routes), str(root), target, client_terminal], check=True
        )

        duplicate = command("split-window", "-d", "-P", "-F#{pane_id}", "-t", other)
        command("select-pane", "-t", duplicate, "-T", "Memory report")
        command("select-window", "-t", other)
        before = command("display-message", "-p", "-t", "probe", "#{pane_id}")
        assert "multiple panes" in jump()
        assert command("display-message", "-p", "-t", "probe", "#{pane_id}") == before
        print("PASS duplicate titles leave the active pane unchanged")

        command("select-pane", "-t", duplicate, "-T", "Memory report notes")
        command("select-pane", "-t", target, "-T", "Memory report notes")
        assert "no pane" in jump()
        assert command("display-message", "-p", "-t", "probe", "#{pane_id}") == before
        print("PASS partial titles leave the active pane unchanged")
    finally:
        client.terminate()
        client.wait(timeout=5)
        os.close(master)


def main():
    executable = shutil.which("tmux")
    if executable is None:
        print("SKIP: the jump probe requires tmux")
        return
    with tempfile.TemporaryDirectory(prefix="agent-stat-jump-") as directory:
        root = Path(directory)
        tmux = [executable, "-S", str(root / "socket"), "-f", "/dev/null"]
        try:
            exercise(root, tmux)
        finally:
            subprocess.run([*tmux, "kill-server"], check=False, capture_output=True)


if __name__ == "__main__":
    main()
