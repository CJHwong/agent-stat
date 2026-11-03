import importlib.util
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sidebar_views as views

spec = importlib.util.spec_from_file_location(
    "sidebar", Path(__file__).resolve().parents[1] / "window-sidebar.py"
)
ui = importlib.util.module_from_spec(spec)
sys.modules["sidebar"] = ui
spec.loader.exec_module(ui)
entries = [
    ui.Entry("@1", "%1", "1", "PII Training", "research", False),
    ui.Entry("@2", "%2", "2", "Worker", "backend", False),
]
with patch.object(
    ui,
    "full_command",
    side_effect=lambda socket, pane: (
        "python train.py --epochs 20" if pane == "%1" else "uv run worker.py"
    ),
):
    assert views.filter_entries(ui, "socket", entries, "TRAINING") == [entries[0]]
    assert views.filter_entries(ui, "socket", entries, "backend worker.py") == [
        entries[1]
    ]
    assert views.filter_entries(ui, "socket", entries, "--epochs 20") == [entries[0]]
    assert views.filter_entries(ui, "socket", entries, "no match") == []
    assert views.filter_entries(ui, "socket", entries, "") == entries

snapshot = {
    "session": "source",
    "windows": [
        {
            "index": 1,
            "name": "Saved",
            "panes": [
                {"sidebar": True},
                {
                    "sidebar": False,
                    "title": "Resume me",
                    "cwd": "/work",
                    "agent": {
                        "agent": "claude",
                        "session_id": "saved-id",
                        "profile": "/profile",
                    },
                },
                {
                    "sidebar": False,
                    "title": "Keep me",
                    "cwd": "/work",
                    "agent": {
                        "agent": "codex",
                        "session_id": "live-id",
                        "profile": "/profile",
                    },
                },
                {"sidebar": False, "title": "Shell", "cwd": "/work", "agent": {}},
            ],
        }
    ],
}
lines = "\n".join(views.recovery_lines(ui, snapshot, {"live-id"}))
assert "Resume claude: saved-id" in lines
assert "Already running" in lines and "Open a terminal in the saved folder" in lines
assert all(title in lines for title in ["Resume me", "Keep me", "Shell"])


class CancelScreen:
    def keypad(self, enabled):
        pass

    def timeout(self, milliseconds):
        self.wait = milliseconds

    def getmaxyx(self):
        return 30, 100

    def erase(self):
        pass

    def addnstr(self, *arguments):
        pass

    def refresh(self):
        pass

    def getch(self):
        return -1 if getattr(self, "wait", -1) == 25 else 27


with (
    patch.object(views.curses, "curs_set"),
    patch.object(views.curses, "mousemask"),
    patch.object(views.curses, "mouseinterval"),
    patch.object(ui.agents, "replay_candidates", return_value=[]),
    patch.object(
        ui.agents,
        "recovery_plan",
        return_value=(snapshot, {"live-id"}, [snapshot["windows"][0]["panes"][1]]),
    ),
    patch.object(ui.agents, "restore_snapshot") as restore,
):
    views.render_recovery(CancelScreen(), ui, "socket", "source")
    restore.assert_not_called()
print(
    "PASS: title, folder and command search; full recovery list; duplicate labels; cancel starts nothing"
)


class RestoreScreen(CancelScreen):
    def getch(self):
        return ord("r")


with (
    patch.object(views.curses, "curs_set"),
    patch.object(views.curses, "mousemask"),
    patch.object(views.curses, "mouseinterval"),
    patch.object(ui.agents, "replay_candidates", return_value=[]),
    patch.object(
        ui.agents,
        "recovery_plan",
        return_value=(snapshot, set(), [snapshot["windows"][0]["panes"][1]]),
    ),
    patch.object(
        ui.agents, "restore_snapshot", return_value="recovered-source"
    ) as restore,
    patch.object(ui, "change_sidebars") as enable,
):
    views.render_recovery(RestoreScreen(), ui, "socket", "source")
    restore.assert_called_once_with("socket", "source")
    enable.assert_called_once_with("socket", "enable", "recovered-source")
print("PASS: explicit Restore action calls recovery and enables its sidebar")

command_pane = {
    "sidebar": False,
    "pane_id": "%saved",
    "title": "Worker",
    "cwd": "/work",
    "agent": {},
    "command": 'python worker.py --name "two words"',
    "command_argv": ["python", "worker.py", "--name", "two words"],
}
command_snapshot = {
    "session": "source",
    "windows": [{"index": 1, "name": "Worker", "panes": [command_pane]}],
}
preview = "\n".join(
    views.recovery_lines(ui, command_snapshot, set(), {"%saved"}, set(), "%saved", 60)
)
assert "[ ] Rerun saved command" in preview and "Saved command:" in preview


class CommandScreen(CancelScreen):
    def __init__(self):
        self.keys = iter([ord(" "), ord("r")])

    def getch(self):
        return -1 if getattr(self, "wait", -1) == 25 else next(self.keys)


with (
    patch.object(views.curses, "curs_set"),
    patch.object(views.curses, "mousemask"),
    patch.object(views.curses, "mouseinterval"),
    patch.object(
        ui.agents, "recovery_plan", return_value=(command_snapshot, set(), [])
    ),
    patch.object(ui.agents, "replay_candidates", return_value=[command_pane]),
    patch.object(
        ui.agents, "restore_snapshot", return_value="recovered-source"
    ) as restore,
    patch.object(ui, "change_sidebars"),
):
    views.render_recovery(CommandScreen(), ui, "socket", "source")
    restore.assert_called_once_with("socket", "source", selected_commands={"%saved"})
print(
    "PASS: command selection starts unchecked and Space plus Restore submits only selected commands"
)

targets = {}
views.recovery_lines(
    ui, command_snapshot, set(), {"%saved"}, set(), "%saved", 100, targets
)
click_row = next(iter(targets)) + 2


class MouseScreen(CancelScreen):
    def __init__(self):
        self.keys = iter([views.curses.KEY_MOUSE, views.curses.KEY_MOUSE])

    def getch(self):
        return -1 if getattr(self, "wait", -1) == 25 else next(self.keys)


with (
    patch.object(views.curses, "curs_set"),
    patch.object(views.curses, "mousemask"),
    patch.object(views.curses, "mouseinterval"),
    patch.object(
        ui.agents, "recovery_plan", return_value=(command_snapshot, set(), [])
    ),
    patch.object(ui.agents, "replay_candidates", return_value=[command_pane]),
    patch.object(
        views, "recovery_mouse", side_effect=[(click_row, 5, "left"), (29, 5, "left")]
    ),
    patch.object(
        ui.agents, "restore_snapshot", return_value="recovered-source"
    ) as restore,
    patch.object(ui, "change_sidebars"),
):
    views.render_recovery(MouseScreen(), ui, "socket", "source")
    restore.assert_called_once_with("socket", "source", selected_commands={"%saved"})
print("PASS: checkbox click selects a command and footer click starts its recovery")


class ScrollScreen(CancelScreen):
    def __init__(self):
        self.keys = iter([views.curses.KEY_MOUSE] * 100 + [27])

    def getch(self):
        return -1 if getattr(self, "wait", -1) == 25 else next(self.keys)


with (
    patch.object(views.curses, "curs_set"),
    patch.object(views.curses, "mousemask"),
    patch.object(views.curses, "mouseinterval"),
    patch.object(
        ui.agents, "recovery_plan", return_value=(snapshot, {"live-id"}, [])
    ) as plan,
    patch.object(ui.agents, "replay_candidates", return_value=[]) as candidates,
    patch.object(
        views,
        "recovery_mouse",
        side_effect=[(5, 10, "down")] * 50 + [(5, 10, "up")] * 50,
    ),
):
    views.render_recovery(ScrollScreen(), ui, "socket", "source")
    plan.assert_called_once()
    candidates.assert_called_once()
with patch.object(
    views.curses, "getmouse", return_value=(0, 5, 10, 0, views.curses.BUTTON4_PRESSED)
):
    assert views.recovery_mouse()[2] == "up"
if getattr(views.curses, "BUTTON5_PRESSED", 0):
    with patch.object(
        views.curses,
        "getmouse",
        return_value=(0, 5, 10, 0, views.curses.BUTTON5_PRESSED),
    ):
        assert views.recovery_mouse()[2] == "down"
print("PASS: wheel input scrolls and 100 queued events do not repeat process scans")

assert views.decode_recovery_sequence(b"[M" + bytes([97, 42, 42])) == (
    views.curses.KEY_MOUSE,
    (9, 9, "down"),
)
assert views.decode_recovery_sequence(b"[M" + bytes([96, 42, 42])) == (
    views.curses.KEY_MOUSE,
    (9, 9, "up"),
)
assert views.decode_recovery_sequence(b"[<65;10;10M") == (
    views.curses.KEY_MOUSE,
    (9, 9, "down"),
)
assert views.decode_recovery_sequence(b"[<0;10;10m")[1] is None
assert views.decode_recovery_sequence(b"OB")[0] == views.curses.KEY_DOWN
print("PASS: native and SGR wheel protocols, releases, and application-mode arrows")


class ByteScreen(CancelScreen):
    def __init__(self, values):
        self.values = iter(values)

    def getch(self):
        return next(self.values, -1)


assert views.recovery_key(ByteScreen(b"\x1b[M" + bytes([97, 42, 42]))) == (
    views.curses.KEY_MOUSE,
    (9, 9, "down"),
)
assert views.recovery_key(ByteScreen(b"\x1b[<64;10;10M")) == (
    views.curses.KEY_MOUSE,
    (9, 9, "up"),
)
assert views.recovery_key(ByteScreen([27])) == (27, None)
print("PASS: raw wheel byte streams complete without an extra delay")
