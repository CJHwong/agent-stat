#!/usr/bin/env python3
import argparse
import curses
from dataclasses import dataclass
import fcntl
import logging
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import tempfile

import sidebar_agents as agents
import sidebar_views as views
from process_commands import capture_command

WIDTH = 28
RAIL_WIDTH = 2
COLLAPSE_BELOW = 100
SHORTCUTS = (
    "c       New window",
    "%       Split left/right",
    '"       Split above/below',
    "h j k l Move to pane",
    "z       Zoom pane",
    "d       Detach safely",
    "Tab     Toggle sidebar",
    "/       Find pane",
    "?       All shortcuts",
    "Esc     Cancel",
)


@dataclass(frozen=True)
class Entry:
    window_id: str
    pane_id: str
    index: str
    title: str
    folder: str
    active: bool
    child: bool = False
    group: bool = False
    state: str = ""
    unread: bool = False

    @property
    def height(self):
        return 1 if self.group else 3


def tmux(socket_path, *arguments):
    return subprocess.check_output(
        ["tmux", "-S", socket_path, *arguments], text=True
    ).rstrip("\n")


def pane_rows(socket_path, session):
    template = "#{window_id}\t#{window_index}\t#{window_name}\t#{window_active}\t#{pane_id}\t#{pane_current_path}\t#{@window_sidebar}\t#{pane_title}\t#{pane_active}\t#{host}\t#{pane_current_command}\t#{pane_last}\t#{@window_sidebar_target}\t#{@window_sidebar_label}\t#{@window_sidebar_window_label}\t#{@window_sidebar_seen}"
    output = tmux(socket_path, "list-panes", "-s", "-t", session, "-F", template)
    return [line.split("\t") for line in output.splitlines()]


def clean_text(value):
    return "".join(character for character in value if character.isprintable())


def window_title(program, pane_title, hostname, folder):
    title = pane_title.strip().lstrip("✳✶✻✽✢* ")
    if not title or title in (hostname, hostname.split(".")[0], folder):
        title = program
    return clean_text(title)


def pane_priority(fields):
    return fields[8] == "1", fields[11] == "1", fields[4] == fields[12]


_COMMAND_CACHE = {}


def full_command(socket_path, pane_id):
    key = socket_path, pane_id
    updated, command = _COMMAND_CACHE.get(key, (0, ""))
    if time.monotonic() - updated < 2:
        return command
    command = capture_command(socket_path, pane_id)["command"]
    _COMMAND_CACHE[key] = time.monotonic(), command
    return command


def preview_text(socket_path, entry, contents, title):
    folder = agents.ROOT / "previews"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile("w", dir=folder, delete=False) as preview:
        preview.write(contents + "\n\nPress q to close.\n")
    try:
        command = shlex.join(["/usr/bin/less", "-R", preview.name])
        client = tmux(
            socket_path, "display-message", "-p", "-t", entry.pane_id, "#{client_name}"
        )
        tmux(
            socket_path,
            "display-popup",
            "-c",
            client,
            "-E",
            "-w",
            "90%",
            "-h",
            "50%",
            "-T",
            title,
            command,
        )
    finally:
        Path(preview.name).unlink(missing_ok=True)


def preview_command(socket_path, entry):
    folder = tmux(
        socket_path,
        "display-message",
        "-p",
        "-t",
        entry.pane_id,
        "#{pane_current_path}",
    )
    contents = f"Title: {entry.title}\nFolder: {folder}\n\nCommand:\n{full_command(socket_path, entry.pane_id)}"
    preview_text(socket_path, entry, contents, "Full title and command")


def preview_legend(socket_path, entry):
    contents = (
        "STATUS COLORS\n\n"
        "\x1b[38;5;78m●\x1b[0m Green: Working\n"
        "\x1b[38;5;203m●\x1b[0m Red: Waiting or unread response\n"
        "\x1b[38;5;208m●\x1b[0m Orange: Failed\n"
        "\x1b[38;5;75m●\x1b[0m Blue: Ready, viewed response, or no recorded activity\n"
        "\x1b[38;5;141m●\x1b[0m Purple: Interrupted\n"
        "\x1b[38;5;244m●\x1b[0m Gray: Closed\n\n"
        "* Unread response. Select the window to clear it.\n"
        "Right-click a sidebar row for its actions.\n"
        "Click / Search, or press Ctrl+B then / to find a pane.\n"
        "Press f in the menu to see its full title and command."
    )
    preview_text(socket_path, entry, contents, "Sidebar help")


def pane_entry(fields, chosen_pane, child, socket_path):
    title = fields[13] or window_title(fields[10], fields[7], fields[9], fields[5])
    if not fields[13] and title == fields[10]:
        command = full_command(socket_path, fields[4])
        program, separator, arguments = command.partition(" ")
        title = Path(program).name + separator + arguments
    folder = clean_text(Path(fields[5]).name) or "/"
    active = fields[3] == "1" and fields[4] == chosen_pane
    return Entry(fields[0], fields[4], fields[1], title, folder, active, child)


def window_entries(panes, socket_path):
    chosen = max(panes, key=pane_priority)
    if len(panes) == 1:
        return [pane_entry(chosen, chosen[4], False, socket_path)]
    folder = clean_text(Path(chosen[5]).name) or "/"
    heading = Entry(
        chosen[0],
        chosen[4],
        chosen[1],
        (chosen[14] or f"{folder} ({len(panes)} panes)"),
        "",
        chosen[3] == "1",
        group=True,
    )
    return [heading] + [
        pane_entry(pane, chosen[4], True, socket_path) for pane in panes
    ]


_STATE_CACHE = {}


def cached_states(socket_path, session):
    key = socket_path, session
    updated, records = _STATE_CACHE.get(key, (0, {}))
    if time.monotonic() - updated >= 1:
        records = agents.agent_states(socket_path, session)
        _STATE_CACHE[key] = time.monotonic(), records
    return records


def status_entry(socket_path, entry, record, fields):
    state = record.get("state", "")
    completion = record.get("completion", "")
    seen = fields[15] if len(fields) > 15 else ""
    unread = state == "done" and bool(completion) and seen != completion
    if unread and fields[3] == "1" and not entry.group:
        tmux(
            socket_path,
            "set-option",
            "-p",
            "-t",
            entry.pane_id,
            "@window_sidebar_seen",
            completion,
        )
        unread = False
    if state == "done" and not unread:
        state = "idle"
    return Entry(
        **{**entry.__dict__, "state": state, "unread": unread and not entry.group}
    )


def sidebar_entries(socket_path, session):
    windows = {}
    for fields in pane_rows(socket_path, session):
        if fields[6]:
            continue
        windows.setdefault(fields[0], []).append(fields)
    groups = [window_entries(panes, socket_path) for panes in windows.values()]
    states = cached_states(socket_path, session)
    metadata = {fields[4]: fields for panes in windows.values() for fields in panes}
    groups = [
        [
            status_entry(
                socket_path,
                entry,
                states.get(entry.pane_id, {}),
                metadata[entry.pane_id],
            )
            for entry in group
        ]
        for group in groups
    ]
    groups.sort(key=lambda group: int(group[0].index))
    return [entry for group in groups for entry in group]


def sidebar_panes(socket_path, session):
    return [
        (fields[0], fields[4])
        for fields in pane_rows(socket_path, session)
        if fields[6] == "1"
    ]


def render_command(socket_path, overlay=False, help_only=False):
    arguments = [sys.executable, str(Path(__file__).resolve()), "--socket", socket_path]
    if overlay:
        arguments.append("--overlay")
    if help_only:
        arguments.append("--prefix-help")
    return shlex.join(arguments + ["render"])


def create_sidebar(socket_path, window_id, width):
    pane_id = tmux(
        socket_path,
        "split-window",
        "-d",
        "-b",
        "-f",
        "-h",
        "-l",
        str(width),
        "-t",
        window_id,
        "-P",
        "-F",
        "#{pane_id}",
        render_command(socket_path),
    )
    tmux(socket_path, "set-option", "-p", "-t", pane_id, "@window_sidebar", "1")
    tmux(
        socket_path,
        "set-option",
        "-w",
        "-t",
        window_id,
        "@window_sidebar_pane",
        pane_id,
    )
    tmux(socket_path, "select-pane", "-t", pane_id, "-T", "Windows")
    tmux(socket_path, "set-option", "-p", "-t", pane_id, "pane-border-format", "")
    return pane_id


def ensure_sidebars(socket_path, session):
    if (
        tmux(
            socket_path,
            "display-message",
            "-p",
            "-t",
            session,
            "#{@window_sidebar_enabled}",
        )
        != "1"
    ):
        return
    existing = dict(sidebar_panes(socket_path, session))
    rows = tmux(
        socket_path, "list-windows", "-t", session, "-F", "#{window_id} #{window_width}"
    ).splitlines()
    for row in rows:
        window_id, window_width = row.split()
        width = WIDTH if int(window_width) >= COLLAPSE_BELOW else RAIL_WIDTH
        pane_id = existing.get(window_id) or create_sidebar(
            socket_path, window_id, width
        )
        current = tmux(
            socket_path, "display-message", "-p", "-t", pane_id, "#{pane_width}"
        )
        if int(current) != width:
            tmux(socket_path, "resize-pane", "-t", pane_id, "-x", str(width))


def disable_sidebars(socket_path, session):
    tmux(socket_path, "set-option", "-t", session, "@window_sidebar_enabled", "0")
    for window_id, pane_id in sidebar_panes(socket_path, session):
        tmux(socket_path, "kill-pane", "-t", pane_id)


def change_sidebars(socket_path, action, session):
    exists = subprocess.run(
        ["tmux", "-S", socket_path, "has-session", "-t", session],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if exists.returncode:
        return
    with open(socket_path + ".window-sidebar.lock", "a") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        if action == "attach":
            initialized = tmux(
                socket_path,
                "display-message",
                "-p",
                "-t",
                session,
                "#{@window_sidebar_initialized}",
            )
            action = "ensure" if initialized else "enable"
        if action == "toggle":
            enabled = tmux(
                socket_path,
                "display-message",
                "-p",
                "-t",
                session,
                "#{@window_sidebar_enabled}",
            )
            if enabled == "1":
                disable_sidebars(socket_path, session)
                return
        if action != "ensure":
            tmux(
                socket_path,
                "set-option",
                "-t",
                session,
                "@window_sidebar_initialized",
                "1",
            )
            tmux(
                socket_path, "set-option", "-t", session, "@window_sidebar_enabled", "1"
            )
        ensure_sidebars(socket_path, session)
        if (
            tmux(
                socket_path,
                "display-message",
                "-p",
                "-t",
                session,
                "#{@window_sidebar_enabled}",
            )
            == "1"
        ):
            agents.start_monitor(socket_path, session)


def prefix_active(socket_path, session):
    states = tmux(
        socket_path,
        "list-clients",
        "-t",
        session,
        "-F",
        "#{client_prefix}:#{client_key_table}",
    )
    return any(
        state.startswith("1:") or state.endswith(":prefix")
        for state in states.splitlines()
    )


STATUS_PAIRS = {
    "working": 1,
    "waiting": 2,
    "done": 2,
    "failed": 3,
    "idle": 4,
    "interrupted": 5,
    "closed": 6,
}


def setup_colors():
    if not curses.has_colors():
        return
    curses.start_color()
    background = curses.COLOR_BLACK
    try:
        curses.use_default_colors()
        background = -1
    except curses.error:
        logging.info("Terminal requires an explicit background color")
    colors = (
        (78, 203, 208, 75, 141, 244) if curses.COLORS >= 256 else (2, 1, 3, 4, 5, 7)
    )
    for pair, color in enumerate(colors, 1):
        curses.init_pair(pair, color, background)
        curses.init_pair(
            pair + 6, -1 if background == -1 else curses.COLOR_WHITE, color
        )


def draw_entry(screen, entry, line, width):
    label = f" {entry.index:>2}   {entry.title}"
    if entry.child:
        label = ("   >  " if entry.active else "      ") + entry.title
    style = curses.A_BOLD if entry.group else curses.A_NORMAL
    if entry.active and not entry.group:
        style |= curses.A_REVERSE
    label_width = width - 2 if entry.unread else width - 1
    screen.addnstr(line, 0, label.ljust(width - 1), label_width, style)
    if entry.unread:
        screen.addnstr(line, width - 2, "*", 1, curses.A_BOLD)
    if not entry.group:
        pair = STATUS_PAIRS.get(entry.state, STATUS_PAIRS["idle"])
        indicator_style = curses.A_BOLD
        if entry.active:
            pair += 6
            indicator_style |= curses.A_REVERSE
        screen.addnstr(line, 4, "●", 1, curses.color_pair(pair) | indicator_style)
        screen.addnstr(line + 1, 6, entry.folder, width - 7, curses.A_DIM)


def visible_entries(entries, selected, capacity):
    offset = selected
    used = entries[selected].height
    while offset > 0 and used + entries[offset - 1].height <= capacity:
        offset -= 1
        used += entries[offset].height
    return offset


def draw_help(screen, start, width):
    screen.addnstr(start, 1, "NEXT KEY", width - 2, curses.A_BOLD)
    for line, shortcut in enumerate(SHORTCUTS, start + 1):
        screen.addnstr(line, 1, shortcut, width - 2)


def draw_sidebar(screen, entries, selected, armed, overlay):
    height, width = screen.getmaxyx()
    screen.erase()
    if height < 7 or width < 7:
        screen.addnstr(1, 0, ">", max(1, width - 1), curses.A_BOLD)
        screen.refresh()
        return {}
    help_height = len(SHORTCUTS) + 2 if armed and height >= 20 else 0
    limit = height - 5 - help_height
    screen.addnstr(0, 1, "WINDOWS", width - 2, curses.A_BOLD)
    screen.addnstr(1, 1, "+ New  Split  Rename", width - 2, curses.A_DIM)
    offset = visible_entries(entries, selected, max(3, limit - 3))
    hits = {}
    line = 3
    for index in range(offset, len(entries)):
        if line + entries[index].height > limit:
            break
        draw_entry(screen, entries[index], line, width)
        hits.update(
            {
                row: index
                for row in range(line, line + (1 if entries[index].group else 2))
            }
        )
        line += entries[index].height
    if help_height:
        draw_help(screen, height - 5 - help_height, width)
    screen.addnstr(height - 4, 1, "Recover", width - 2, curses.A_DIM)
    screen.addnstr(height - 3, 1, "/ Search", width - 2, curses.A_DIM)
    screen.addnstr(height - 2, 1, "F1: Menu", width - 2, curses.A_DIM)
    hint = "Esc: Close overlay" if overlay else "Ctrl+B: Shortcuts"
    screen.addnstr(height - 1, 1, hint, width - 2, curses.A_DIM)
    screen.refresh()
    return hits


def select_entry(socket_path, entry):
    tmux(socket_path, "select-window", "-t", entry.window_id)
    tmux(socket_path, "select-pane", "-t", entry.pane_id)


def mouse_event():
    try:
        device_id, column, row, depth, buttons = curses.getmouse()
    except curses.error:
        return None
    if buttons & (curses.BUTTON3_PRESSED | curses.BUTTON3_CLICKED):
        return row, column, "right"
    if buttons & (curses.BUTTON1_RELEASED | curses.BUTTON1_CLICKED):
        return row, column, "left"
    return None


def open_overlay(socket_path, pane_id, help_only=False):
    session = tmux(socket_path, "display-message", "-p", "-t", pane_id, "#{session_id}")
    chosen = next(
        (
            entry
            for entry in sidebar_entries(socket_path, session)
            if entry.active and not entry.group
        ),
        None,
    )
    if chosen:
        tmux(
            socket_path,
            "set-option",
            "-w",
            "-t",
            pane_id,
            "@window_sidebar_target",
            chosen.pane_id,
        )
    options = ["-d"] if help_only else []
    window_width, window_height = tmux(
        socket_path,
        "display-message",
        "-p",
        "-t",
        pane_id,
        "#{window_width} #{window_height}",
    ).split()
    width = min(WIDTH, max(1, int(window_width) - 2))
    height = max(1, int(window_height) - 2)
    if help_only:
        height = min(height, len(SHORTCUTS) + 3)
    overlay = tmux(
        socket_path,
        "new-pane",
        *options,
        "-t",
        pane_id,
        "-x",
        str(width),
        "-y",
        str(height),
        "-X",
        "0",
        "-Y",
        "0",
        "-P",
        "-F",
        "#{pane_id}",
        render_command(socket_path, True, help_only),
    )
    tmux(
        socket_path,
        "set-option",
        "-p",
        "-t",
        overlay,
        "@window_sidebar",
        "3" if help_only else "2",
    )
    tmux(socket_path, "select-pane", "-t", overlay, "-T", "Windows")
    tmux(socket_path, "set-option", "-p", "-t", overlay, "pane-border-format", "")


def focused_entry(entries):
    return next(
        (entry for entry in entries if entry.active and not entry.group), entries[0]
    )


def open_view(socket_path, entry, session, action):
    client = tmux(
        socket_path, "display-message", "-p", "-t", entry.pane_id, "#{client_name}"
    )
    command = shlex.join(
        [
            sys.executable,
            str(Path(__file__).resolve()),
            "--socket",
            socket_path,
            action,
            session,
        ]
    )
    title = "Find window or pane" if action == "search-ui" else "Recovery preview"
    tmux(
        socket_path,
        "display-popup",
        "-c",
        client,
        "-E",
        "-w",
        "85%",
        "-h",
        "75%",
        "-T",
        title,
        command,
    )


def sidebar_action(socket_path, session, action, entry):
    if action == "new":
        folder = tmux(
            socket_path,
            "display-message",
            "-p",
            "-t",
            entry.pane_id,
            "#{pane_current_path}",
        )
        tmux(socket_path, "new-window", "-t", session, "-c", folder)
    elif action == "rename":
        client = tmux(
            socket_path, "display-message", "-p", "-t", entry.pane_id, "#{client_name}"
        )
        tmux(
            socket_path,
            "command-prompt",
            "-t",
            client,
            "-I",
            entry.title,
            "-p",
            "Pane name:",
            f"set-option -p -t {entry.pane_id} @window_sidebar_label '%%'",
        )
    elif action == "split":
        pane_menu(socket_path, entry, split_only=True)
    elif action == "command":
        preview_command(socket_path, entry)
    elif action == "legend":
        preview_legend(socket_path, entry)
    elif action == "recover":
        open_view(socket_path, entry, session, "recovery-ui")
    elif action == "search":
        open_view(socket_path, entry, session, "search-ui")
    else:
        pane_menu(socket_path, entry)


def pane_menu(socket_path, entry, split_only=False):
    folder = tmux(
        socket_path,
        "display-message",
        "-p",
        "-t",
        entry.pane_id,
        "#{pane_current_path}",
    )
    horizontal = shlex.join(["split-window", "-h", "-t", entry.pane_id, "-c", folder])
    vertical = shlex.join(["split-window", "-v", "-t", entry.pane_id, "-c", folder])
    items = ["Split left/right", "v", horizontal, "Split above/below", "h", vertical]
    if not split_only:
        items += menu_items(socket_path, entry)
    tmux(
        socket_path,
        "display-menu",
        "-t",
        entry.pane_id,
        "-T",
        "Window and pane controls",
        "-x",
        "C",
        "-y",
        "C",
        *items,
    )


def menu_items(socket_path, entry):
    session = tmux(
        socket_path, "display-message", "-p", "-t", entry.pane_id, "#{session_name}"
    )
    preview = shlex.join(
        [
            sys.executable,
            str(Path(__file__).resolve()),
            "--socket",
            socket_path,
            "--pane",
            entry.pane_id,
            "command",
            session,
        ]
    )
    legend = shlex.join(
        [
            sys.executable,
            str(Path(__file__).resolve()),
            "--socket",
            socket_path,
            "--pane",
            entry.pane_id,
            "legend",
            session,
        ]
    )
    search = shlex.join(
        [
            sys.executable,
            str(Path(__file__).resolve()),
            "--socket",
            socket_path,
            "search",
            session,
        ]
    )
    pane, window = entry.pane_id, entry.window_id
    return [
        "Full title and command",
        "f",
        "run-shell -b " + shlex.quote(preview),
        "Status color legend",
        "s",
        "run-shell -b " + shlex.quote(legend),
        "Find window or pane",
        "/",
        "run-shell -b " + shlex.quote(search),
        "New window",
        "c",
        "new-window",
        "Rename pane",
        "r",
        f"command-prompt -p 'Pane name:' \"set-option -p -t {pane} @window_sidebar_label '%%'\"",
        "Rename window",
        "R",
        f"command-prompt -p 'Window name:' \"rename-window -t {window} '%%'; set-option -w -t {window} @window_sidebar_window_label '%%'\"",
        "Zoom pane",
        "z",
        f"resize-pane -Z -t {pane}",
        "Move window left",
        "<",
        f"swap-window -s {window} -t :-1",
        "Move window right",
        ">",
        f"swap-window -s {window} -t :+1",
        "Move pane to new window",
        "b",
        f"break-pane -s {pane}; if-shell -F -t {window} '#{{==:#{{window_panes}},1}}' 'kill-window -t {window}'",
        "Close pane",
        "x",
        f"confirm-before -p 'Close this pane and its process? (y/n)' 'kill-pane -t {pane}'",
        "Close window",
        "X",
        f"confirm-before -p 'Close this window and its processes? (y/n)' 'kill-window -t {window}'",
        "Next window",
        "n",
        "next-window",
        "Previous window",
        "p",
        "previous-window",
        "Toggle mouse",
        "m",
        "set-option -g mouse",
        "Detach safely",
        "d",
        "detach-client",
        "Close menu",
        "q",
        "",
    ]


def handle_key(
    socket_path, key, selected, entries, hits, pane_id, collapsed, height, session
):
    if key == ord("/"):
        sidebar_action(socket_path, session, "search", focused_entry(entries))
        return selected, False
    if key in (curses.KEY_DOWN, ord("j")):
        return min(selected + 1, len(entries) - 1), False
    if key in (curses.KEY_UP, ord("k")):
        return max(selected - 1, 0), False
    if key == curses.KEY_MOUSE:
        event = mouse_event()
        if event is None:
            return selected, False
        row, column, button = event
        return handle_click(
            socket_path,
            selected,
            entries,
            hits,
            pane_id,
            collapsed,
            height,
            session,
            row,
            column,
            button,
        )
    if key not in (10, 13, curses.KEY_ENTER):
        return selected, False
    select_entry(socket_path, entries[selected])
    return selected, True


def handle_click(
    socket_path,
    selected,
    entries,
    hits,
    pane_id,
    collapsed,
    height,
    session,
    row,
    column,
    button,
):
    if collapsed:
        open_overlay(socket_path, pane_id)
        return selected, False
    if row in hits:
        selected = hits[row]
        if button == "right":
            pane_menu(socket_path, entries[selected])
            return selected, False
        select_entry(socket_path, entries[selected])
        return selected, True
    action = None
    if row == 1:
        action = "new" if column < 7 else "split" if column < 14 else "rename"
    if row == height - 4:
        action = "recover"
    if row == height - 3:
        action = "search"
    if row == height - 2:
        action = "menu"
    if action:
        sidebar_action(socket_path, session, action, focused_entry(entries))
    return selected, False


def dock_overlay(socket_path, pane_id):
    width = tmux(socket_path, "display-message", "-p", "-t", pane_id, "#{window_width}")
    if int(width) < COLLAPSE_BELOW:
        return False
    target = tmux(
        socket_path,
        "display-message",
        "-p",
        "-t",
        pane_id,
        "#{@window_sidebar_target}\t#{@window_sidebar_label}\t#{@window_sidebar_window_label}",
    )
    if target:
        tmux(socket_path, "select-pane", "-t", target)
    return True


def render_sidebar(screen, socket_path, overlay):
    setup_colors()
    curses.curs_set(0)
    curses.mousemask(curses.ALL_MOUSE_EVENTS)
    curses.mouseinterval(0)
    screen.keypad(True)
    pane_id = os.environ["TMUX_PANE"]
    session = tmux(socket_path, "display-message", "-p", "-t", pane_id, "#{session_id}")
    window_id = tmux(
        socket_path, "display-message", "-p", "-t", pane_id, "#{window_id}"
    )
    selected = 0
    previous_active = None
    previous_armed = False
    while True:
        if overlay and dock_overlay(socket_path, pane_id):
            return
        entries = sidebar_entries(socket_path, session)
        if not entries:
            return
        current_active = next(
            (entry.pane_id for entry in entries if entry.active and not entry.group),
            None,
        )
        if current_active != previous_active:
            selected = next(
                (
                    index
                    for index, entry in enumerate(entries)
                    if entry.pane_id == current_active and not entry.group
                ),
                0,
            )
            previous_active = current_active
        selected = min(selected, len(entries) - 1)
        screen.timeout(
            200
            if any(entry.active and entry.window_id == window_id for entry in entries)
            else 1000
        )
        try:
            armed = prefix_active(socket_path, session)
            collapsed = screen.getmaxyx()[1] < 7
            if collapsed and armed and not previous_armed:
                open_overlay(socket_path, pane_id, True)
            previous_armed = armed
            hits = draw_sidebar(screen, entries, selected, armed, overlay)
            key = screen.getch()
            if overlay and key in (27, ord("q")):
                chosen = next(
                    (entry for entry in entries if entry.active and not entry.group),
                    entries[0],
                )
                select_entry(socket_path, chosen)
                return
            selected, activated = handle_key(
                socket_path,
                key,
                selected,
                entries,
                hits,
                pane_id,
                collapsed,
                screen.getmaxyx()[0],
                session,
            )
            if overlay and activated:
                return
        except curses.error:
            logging.exception("Terminal changed during sidebar input or redraw")
            screen.clearok(True)
        except subprocess.CalledProcessError:
            logging.exception("Sidebar action failed; retaining the sidebar")


def render_prefix_help(screen, socket_path):
    curses.curs_set(0)
    screen.timeout(100)
    session = tmux(
        socket_path,
        "display-message",
        "-p",
        "-t",
        os.environ["TMUX_PANE"],
        "#{session_id}",
    )
    while prefix_active(socket_path, session):
        screen.erase()
        draw_help(screen, 0, screen.getmaxyx()[1])
        screen.refresh()
        screen.getch()


def main():
    logging.basicConfig(
        filename=str(Path.home() / ".config/tmux/window-sidebar.log"),
        level=logging.ERROR,
    )
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--pane")
    parser.add_argument("--overlay", action="store_true")
    parser.add_argument("--prefix-help", action="store_true")
    parser.add_argument(
        "action",
        choices=(
            "render",
            "enable",
            "ensure",
            "attach",
            "toggle",
            "menu",
            "new",
            "split",
            "rename",
            "recover",
            "command",
            "legend",
            "search",
            "search-ui",
            "recovery-ui",
        ),
    )
    parser.add_argument("session", nargs="?")
    arguments = parser.parse_args()
    if arguments.prefix_help:
        curses.wrapper(render_prefix_help, arguments.socket)
        return
    if arguments.action == "render":
        curses.wrapper(render_sidebar, arguments.socket, arguments.overlay)
        return
    if not arguments.session:
        parser.error("A session is required for this action.")
    if arguments.action in ("search-ui", "recovery-ui"):
        render = (
            views.render_search
            if arguments.action == "search-ui"
            else views.render_recovery
        )
        curses.wrapper(
            render, sys.modules[__name__], arguments.socket, arguments.session
        )
        return
    if arguments.action in (
        "menu",
        "new",
        "split",
        "rename",
        "recover",
        "command",
        "legend",
        "search",
    ):
        entries = sidebar_entries(arguments.socket, arguments.session)
        chosen = next(
            (
                entry
                for entry in entries
                if entry.pane_id == arguments.pane and not entry.group
            ),
            focused_entry(entries),
        )
        sidebar_action(arguments.socket, arguments.session, arguments.action, chosen)
        return
    change_sidebars(arguments.socket, arguments.action, arguments.session)


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, curses.error, OSError) as error:
        logging.exception("Window sidebar failed")
        print("Window sidebar failed: " + str(error), file=sys.stderr)
        sys.exit(1)
