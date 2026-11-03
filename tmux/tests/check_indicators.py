import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import importlib.util

spec = importlib.util.spec_from_file_location(
    "sidebar", Path(__file__).resolve().parents[1] / "window-sidebar.py"
)
sidebar = importlib.util.module_from_spec(spec)
sys.modules["sidebar"] = sidebar
spec.loader.exec_module(sidebar)


class Screen:
    def __init__(self):
        self.calls = []

    def addnstr(self, *arguments):
        self.calls.append(arguments)


for state, pair in [
    ("working", 1),
    ("waiting", 2),
    ("done", 2),
    ("failed", 3),
    ("idle", 4),
    ("interrupted", 5),
    ("closed", 6),
    ("", 4),
]:
    screen = Screen()
    entry = sidebar.Entry("@1", "%1", "1", "Title", "folder", False, state=state)
    with patch.object(
        sidebar.curses, "color_pair", side_effect=lambda number: number * 256
    ):
        sidebar.draw_entry(screen, entry, 2, 28)
    assert any(call[2] == "●" and call[4] & (pair * 256) for call in screen.calls), (
        state
    )
    assert screen.calls[-1][2] == "folder"
    assert screen.calls[-1][1] == 6
    assert screen.calls[0][2].startswith("  1   Title")
    assert entry.height == 3
with (
    patch.object(
        sidebar,
        "pane_rows",
        return_value=[
            ["@2", "", "", "", "%1", "", ""],
            ["@1", "", "", "", "%1", "", ""],
        ],
    ),
    patch.object(
        sidebar,
        "window_entries",
        side_effect=lambda panes, socket: [
            sidebar.Entry(
                panes[0][0],
                "%1",
                "2" if panes[0][0] == "@2" else "1",
                "Title",
                "folder",
                False,
            )
        ],
    ),
    patch.object(sidebar, "cached_states", return_value={}),
):
    assert [entry.index for entry in sidebar.sidebar_entries("socket", "session")] == [
        "1",
        "2",
    ]
print(
    "PASS: fixed numeric order, status colors, blue fallback, spaced labels, and folder-only second line"
)

for state, pair in [("working", 1), ("waiting", 2), ("idle", 4), ("", 4)]:
    screen = Screen()
    entry = sidebar.Entry("@1", "%1", "1", "Title", "folder", True, state=state)
    with patch.object(
        sidebar.curses, "color_pair", side_effect=lambda number: number * 256
    ):
        sidebar.draw_entry(screen, entry, 2, 28)
    dot = next(call for call in screen.calls if call[2] == "●")
    assert dot[4] & 0xFF00 == (pair + 6) * 256
    assert dot[4] & sidebar.curses.A_REVERSE
print("PASS: selected indicators use the selected background")

with (
    patch.object(sidebar.curses, "has_colors", return_value=True),
    patch.object(sidebar.curses, "start_color"),
    patch.object(sidebar.curses, "use_default_colors"),
    patch.object(sidebar.curses, "COLORS", 256, create=True),
    patch.object(sidebar.curses, "init_pair") as initialize,
):
    sidebar.setup_colors()
    assert all(
        call.args[1] == -1 for call in initialize.call_args_list if call.args[0] > 6
    )
print(
    "PASS: selected indicators reverse the theme default foreground into the background"
)

entry = sidebar.Entry("@1", "%1", "1", "A very long title", "folder", False)
fields = [""] * 16
record = {"state": "done", "completion": "event:1"}
with patch.object(sidebar, "tmux") as command:
    unread = sidebar.status_entry("socket", entry, record, fields)
    assert unread.unread and unread.state == "done"
    command.assert_not_called()
    fields[3] = "1"
    viewed = sidebar.status_entry("socket", entry, record, fields)
    assert not viewed.unread and viewed.state == "idle"
    assert command.call_args.args[-1] == "event:1"
fields[3] = "0"
fields[15] = "event:1"
assert not sidebar.status_entry("socket", entry, record, fields).unread
assert sidebar.status_entry(
    "socket", entry, {"state": "done", "completion": "event:2"}, fields
).unread
screen = Screen()
with patch.object(sidebar.curses, "color_pair", return_value=0):
    sidebar.draw_entry(screen, unread, 2, 28)
assert any(call[2] == "*" for call in screen.calls)
with (
    patch.object(sidebar, "tmux", return_value="/full/folder"),
    patch.object(
        sidebar, "full_command", return_value="python script.py --option value"
    ),
    patch.object(sidebar, "preview_text") as preview,
):
    sidebar.preview_command("socket", entry)
    contents = preview.call_args.args[2]
    assert entry.title in contents and "python script.py --option value" in contents
    sidebar.preview_legend("socket", entry)
    assert "Unread response" in preview.call_args.args[2]
    items = sidebar.menu_items("socket", entry)
    assert "Full title and command" in items and "Status color legend" in items
print(
    "PASS: unread marker, acknowledge, repeat completion, full preview, and F1 legend"
)


class FooterScreen(Screen):
    def getmaxyx(self):
        return 30, 28

    def erase(self):
        pass

    def refresh(self):
        pass


screen = FooterScreen()
with patch.object(sidebar.curses, "color_pair", return_value=0):
    sidebar.draw_sidebar(screen, [entry], 0, False, False)
assert any(call[0] == 26 and call[2] == "Recover" for call in screen.calls)
assert any(call[0] == 27 and call[2] == "/ Search" for call in screen.calls)
with patch.object(sidebar, "sidebar_action") as action:
    sidebar.handle_click(
        "socket", 0, [entry], {}, "%sidebar", False, 30, "source", 26, 20, "left"
    )
    assert action.call_args.args[2] == "recover"
print("PASS: Recover and Search render and click on separate rows")
