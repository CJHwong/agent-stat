#!/usr/bin/env python3
"""Check split focus in an owned Ghostty window, then close the test window."""

from pathlib import Path
import json
import shlex
import shutil
import subprocess
import tempfile
import time

REPOSITORY = Path(__file__).resolve().parents[1]


def script(source):
    return subprocess.check_output(
        ["/usr/bin/osascript", "-e", source], text=True
    ).strip()


def local_tmux_probe(binary, root):
    tmux = shutil.which("tmux")
    if tmux is None:
        print("SKIP the desktop tmux check requires tmux")
        return
    socket = root / "s"
    command = [tmux, "-S", str(socket), "-f", "/dev/null"]
    window = None
    try:
        pane = subprocess.check_output(
            [
                *command,
                "new-session",
                "-d",
                "-P",
                "-F#{pane_id}",
                "-s",
                "synthetic",
                "-c",
                str(root),
                "/bin/sh",
            ],
            text=True,
        ).strip()
        subprocess.run(
            [*command, "split-window", "-t", pane, "-c", str(root), "/bin/sh"],
            check=True,
        )
        client_command = json.dumps(
            shlex.join([*command, "attach-session", "-t", "synthetic"])
        )
        created = script(f"""tell application "Ghostty"
set previousWindow to id of front window
set settings to new surface configuration from {{command:{client_command}, initial working directory:"/tmp"}}
set testWindow to new window with configuration settings
return previousWindow & "," & id of testWindow
end tell""")
        previous, window = created.split(",")
        deadline = time.monotonic() + 5
        while (
            subprocess.check_output(
                [
                    *command,
                    "display-message",
                    "-p",
                    "-t",
                    "synthetic",
                    "#{session_attached}",
                ],
                text=True,
            ).strip()
            == "0"
        ):
            if time.monotonic() >= deadline:
                raise RuntimeError("Ghostty did not attach the synthetic client")
            time.sleep(0.05)
        identity = subprocess.check_output(
            [*command, "display-message", "-p", "-t", pane, "#{pane_pid},#{pane_tty}"],
            text=True,
        ).strip()
        pid, terminal = identity.split(",")
        script(
            f'tell application "Ghostty" to activate window (first window whose id is "{previous}")'
        )
        subprocess.run(
            [str(binary), "local", str(socket), pane, pid, terminal, str(root)],
            check=True,
        )
        selected = script('tell application "Ghostty" to return id of front window')
        assert selected == window, (
            "the jump must raise the window containing the tmux client"
        )
        active = subprocess.check_output(
            [*command, "display-message", "-p", "-t", "synthetic", "#{pane_id}"],
            text=True,
        ).strip()
        assert active == pane, "the jump must select the requested tmux split"
        print("PASS a verified local session selects its tmux split and Ghostty window")
    finally:
        if window is not None:
            script(f'''tell application "Ghostty"
close window (first window whose id is "{window}")
activate window (first window whose id is "{previous}")
end tell''')
        subprocess.run([*command, "kill-server"], check=False, capture_output=True)


def main():
    with tempfile.TemporaryDirectory(prefix="agent-stat-surface-") as folder:
        root = Path(folder)
        source = root / "main.swift"
        source.write_text("""import Foundation
if CommandLine.arguments.count == 6 && CommandLine.arguments[1] == "stale" {
    let tab = GhosttyTab(id: CommandLine.arguments[3], windowId: CommandLine.arguments[2],
                         name: "Synthetic split", cwd: "/tmp", tty: CommandLine.arguments[4],
                         surfaceID: CommandLine.arguments[5])
    precondition(!Jumper.performGhostty(tab: tab).succeeded, "a closed surface must not select its replacement")
    exit(0)
}
if CommandLine.arguments.count == 7 {
    var session = Session(key: SessionKey(host: "local", id: "synthetic"))
    session.isLocal = true
    session.tmuxSocket = CommandLine.arguments[2]
    session.tmuxPane = CommandLine.arguments[3]
    session.agentPid = Int(CommandLine.arguments[4])
    session.tty = CommandLine.arguments[5]
    session.launchCwd = CommandLine.arguments[6]
    let outcome = Jumper.perform(Jumper.plan(for: session))
    precondition(outcome.succeeded, outcome.message ?? "")
    exit(0)
}
let tab = GhosttyTab(id: CommandLine.arguments[2], windowId: CommandLine.arguments[1],
                     name: "Synthetic split", cwd: "/tmp", tty: CommandLine.arguments[3],
                     surfaceID: CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : nil)
let outcome = Jumper.performGhostty(tab: tab)
precondition(outcome.message == nil, outcome.message ?? "")
""")
        names = [
            "Jump",
            "JumpRemote",
            "JumpLocal",
            "Liveness",
            "CommandRunner",
            "TmuxTargeting",
            "Session",
            "Record",
            "Routes",
            "Paths",
        ]
        binary = root / "surface-probe"
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
        created = script("""tell application "Ghostty"
set previousWindow to id of front window
set settings to new surface configuration from {command:"/bin/sh", initial working directory:"/tmp"}
set testWindow to new window with configuration settings
try
    set primarySurface to terminal 1 of testWindow
    set secondarySurface to split primarySurface direction right with configuration settings
    focus primarySurface
    return previousWindow & "," & id of testWindow & "," & id of selected tab of testWindow & "," & tty of secondarySurface & "," & id of secondarySurface
on error errorMessage
    close window testWindow
    error errorMessage
end try
end tell""")
        previous, window, tab, terminal, surface = created.split(",")
        try:
            subprocess.run([str(binary), window, tab, terminal, surface], check=True)
            focused = script(f'''tell application "Ghostty"
set testWindow to first window whose id is "{window}"
return tty of focused terminal of selected tab of testWindow
end tell''')
            assert focused == terminal, (
                "the jump leaves focus in the wrong Ghostty split"
            )
            print("PASS the target Ghostty split receives keyboard focus")
            primary = script(f'''tell application "Ghostty"
set testWindow to first window whose id is "{window}"
set primarySurface to first terminal of testWindow
close (first terminal of testWindow whose id is "{surface}")
set settings to new surface configuration from {{command:"/bin/sh", initial working directory:"/tmp"}}
split primarySurface direction right with configuration settings
focus primarySurface
return tty of primarySurface
end tell''')
            subprocess.run(
                [str(binary), "stale", window, tab, terminal, surface], check=True
            )
            focused = script(f'''tell application "Ghostty"
set testWindow to first window whose id is "{window}"
return tty of focused terminal of selected tab of testWindow
end tell''')
            assert focused == primary, "a stale picker cannot focus a replacement split"
            print("PASS a closed Ghostty surface cannot redirect a stale choice")
        finally:
            script(f'''tell application "Ghostty"
close window (first window whose id is "{window}")
activate window (first window whose id is "{previous}")
end tell''')

        local_tmux_probe(binary, root)


if __name__ == "__main__":
    main()
