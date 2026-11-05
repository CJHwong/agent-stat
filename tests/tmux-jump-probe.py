#!/usr/bin/env python3
"""Check the Swift jump code against a real client and an isolated tmux split."""

import json
import os
from pathlib import Path
from contextlib import contextmanager
import shutil
import subprocess
import tempfile
import time

REPOSITORY = Path(__file__).resolve().parents[1]
HARNESS = r"""
import Foundation

if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "batch" {
    let argv = [CommandLine.arguments[2], "-S", CommandLine.arguments[3]]
    let command = TmuxTargeting.selection(window: CommandLine.arguments[4], pane: CommandLine.arguments[5])
    let result = Jumper.runTmux(argv, command)
    print(result.status)
    print(result.output.contains(TmuxTargeting.windowSelected) ? "window selected" : "window failed")
    exit(0)
}
var session = Session(key: SessionKey(host: "peer", id: "ram"))
session.title = "Memory report"
session.launchCwd = CommandLine.arguments[2]
let routes = Routes.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
if CommandLine.arguments.count >= 6 {
    session.isLocal = CommandLine.arguments[3] == "local"
    session.tmuxSocket = CommandLine.arguments[4]
    session.tmuxPane = CommandLine.arguments[5] == "title" ? nil : CommandLine.arguments[5]
    if CommandLine.arguments.count == 7 { session.tty = CommandLine.arguments[6] }
    print(Jumper.perform(Jumper.plan(for: session, routes: routes)).message ?? "ok")
    exit(0)
}
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
if CommandLine.arguments.count == 4 { session.tmuxPane = CommandLine.arguments[3] }
let outcome = Jumper.perform(Jumper.plan(for: session, routes: routes))
print(outcome.message ?? "ok")
"""


@contextmanager
def attached_client(tmux, session):
    master, slave = os.openpty()
    environment = dict(os.environ, TERM="xterm-256color")
    environment.pop("TMUX", None)
    process = subprocess.Popen(
        [*tmux, "attach-session", "-t", session],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=environment,
    )
    os.close(slave)
    try:
        deadline = time.monotonic() + 5
        while (
            subprocess.check_output(
                [*tmux, "display-message", "-p", "-t", session, "#{session_attached}"],
                text=True,
            ).strip()
            == "0"
        ):
            if time.monotonic() >= deadline:
                raise RuntimeError("the isolated tmux client did not attach")
            time.sleep(0.05)
        yield
    finally:
        process.terminate()
        process.wait(timeout=5)
        os.close(master)


def linked_window_probe(root, tmux, binary, routes):
    subprocess.run(
        [*tmux, "new-session", "-d", "-s", "a-detached", "-c", str(root)], check=True
    )
    subprocess.run(
        [*tmux, "new-session", "-d", "-s", "z-attached", "-c", str(root)], check=True
    )
    pane = subprocess.check_output(
        [*tmux, "display-message", "-p", "-t", "a-detached:0", "#{pane_id}"], text=True
    ).strip()
    subprocess.run(
        [*tmux, "link-window", "-s", "a-detached:0", "-t", "z-attached:1"], check=True
    )
    with attached_client(tmux, "z-attached"):
        outcome = subprocess.check_output(
            [str(binary), str(routes), str(root), pane], text=True
        )
        assert "selected the pane" in outcome, outcome
        window = subprocess.check_output(
            [*tmux, "display-message", "-p", "-t", "z-attached", "#{window_index}"],
            text=True,
        ).strip()
        assert window == "1", "the linked window must select its attached session"
        print(
            "PASS linked windows select an attached session regardless of listing order"
        )


def batch_selection_probe(tmux, binary, target, other):
    def command(*arguments):
        return subprocess.check_output([*tmux, *arguments], text=True).strip()

    def select(window, pane):
        return subprocess.check_output(
            [str(binary), "batch", tmux[0], tmux[2], window, pane], text=True
        ).splitlines()

    command("select-window", "-t", other)
    before = command("display-message", "-p", "-t", "probe", "#{pane_id}")
    failed = select("@999999", target)
    assert failed[0] != "0" and failed[1] == "window failed", failed
    assert command("display-message", "-p", "-t", "probe", "#{pane_id}") == before
    failed = select(other, "%999999")
    assert failed[0] != "0" and failed[1] == "window selected", failed
    assert command("display-message", "-p", "-t", "probe", "#{pane_id}") == before
    print("PASS a batched selection stops on error and identifies the failed step")


def server_identity_probe(root, tmux, binary, routes):
    socket = root / "s2"
    second_server = [tmux[0], "-S", str(socket), "-f", "/dev/null"]

    def second(*arguments):
        return subprocess.check_output([*second_server, *arguments], text=True).strip()

    before = subprocess.check_output(
        [*tmux, "display-message", "-p", "-t", "probe", "#{pane_id}"], text=True
    ).strip()
    try:
        target = second(
            "new-session", "-d", "-P", "-F#{pane_id}", "-s", "second", "-c", str(root)
        )
        other = second(
            "split-window", "-P", "-F#{pane_id}", "-t", target, "-c", str(root)
        )
        second("select-pane", "-t", target, "-T", "Memory report")
        with attached_client(second_server, "second"):
            for mode in ["local", "remote"]:
                for pane in [target, "title"]:
                    second("select-pane", "-t", other)
                    outcome = subprocess.check_output(
                        [str(binary), str(routes), str(root), mode, str(socket), pane],
                        text=True,
                    )
                    assert "selected" in outcome, outcome
                    assert (
                        second("display-message", "-p", "-t", "second", "#{pane_id}")
                        == target
                    )
                print(
                    f"PASS {mode} identifier and title jumps use the recorded server socket"
                )
            second("select-pane", "-t", other)
            wrong_terminal = second("display-message", "-p", "-t", other, "#{pane_tty}")
            outcome = subprocess.check_output(
                [
                    str(binary),
                    str(routes),
                    str(root),
                    "local",
                    str(socket),
                    target,
                    wrong_terminal,
                ],
                text=True,
            )
            assert "another terminal" in outcome, outcome
            assert (
                second("display-message", "-p", "-t", "second", "#{pane_id}") == other
            )
            print("PASS a stale terminal identifier cannot select another session")
        after = subprocess.check_output(
            [*tmux, "display-message", "-p", "-t", "probe", "#{pane_id}"], text=True
        ).strip()
        assert before == after, "a second server must not change the first server"
        print("PASS colliding pane identifiers do not move the other server")
    finally:
        subprocess.run(
            [*second_server, "kill-server"], check=False, capture_output=True
        )


def exercise(root, tmux):
    source = root / "main.swift"
    source.write_text(HARNESS)
    binary = root / "jump-probe"
    names = [
        "Jump",
        "CommandRunner",
        "JumpRemote",
        "JumpLocal",
        "Liveness",
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
        with tempfile.TemporaryDirectory(
            prefix="agent-stat-remote-alias-"
        ) as alias_folder:
            alias = Path(alias_folder) / "quoted ' folder"
            alias.symlink_to(root)
            outcome = subprocess.check_output(
                [str(binary), str(routes), str(alias)], text=True
            )
            assert "selected the pane" in outcome, outcome
            print(
                "PASS remote folder aliases resolve on the target host with quoted paths"
            )
        subprocess.run(
            [str(binary), str(routes), str(root), target, client_terminal], check=True
        )

        duplicate = command(
            "split-window", "-d", "-P", "-F#{pane_id}", "-t", other, "-c", str(root)
        )
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
        batch_selection_probe(tmux, binary, target, other)
        linked_window_probe(root, tmux, binary, routes)
        server_identity_probe(root, tmux, binary, routes)
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
