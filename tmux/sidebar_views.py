"""Search and recovery views for the tmux sidebar."""

import curses
from dataclasses import replace
import subprocess
import time
import textwrap


def filter_entries(ui, socket_path, entries, query):
    terms = query.casefold().split()
    panes = [entry for entry in entries if not entry.group]
    if not terms:
        return panes
    return [entry for entry in panes if matches(ui, socket_path, entry, terms)]


def matches(ui, socket_path, entry, terms):
    label = f"{entry.index} {entry.title} {entry.folder}".casefold()
    if all(term in label for term in terms):
        return True
    command = ui.full_command(socket_path, entry.pane_id).casefold()
    return all(term in label + " " + command for term in terms)


def render_search(screen, ui, socket_path, session):
    curses.set_escdelay(25)
    ui.setup_colors()
    curses.curs_set(0)
    screen.keypad(True)
    screen.timeout(150)
    query = ""
    selected = 0
    updated = 0
    entries = []
    while True:
        if time.monotonic() - updated >= 1:
            entries = ui.sidebar_entries(socket_path, session)
            updated = time.monotonic()
        results = filter_entries(ui, socket_path, entries, query)
        selected = min(selected, max(0, len(results) - 1))
        draw_search(screen, ui, results, query, selected)
        try:
            key = screen.get_wch()
        except curses.error:
            continue
        if key == "\x1b":
            return
        if key in ("\n", "\r", curses.KEY_ENTER) and results:
            ui.select_entry(socket_path, results[selected])
            return
        if key == curses.KEY_DOWN:
            selected = min(selected + 1, max(0, len(results) - 1))
        elif key == curses.KEY_UP:
            selected = max(0, selected - 1)
        elif key in ("\x7f", "\b", curses.KEY_BACKSPACE):
            query = query[:-1]
            selected = 0
        elif isinstance(key, str) and key.isprintable():
            query += key
            selected = 0


def draw_search(screen, ui, results, query, selected):
    height, width = screen.getmaxyx()
    screen.erase()
    if height < 7 or width < 20:
        screen.addnstr(0, 0, "Enlarge to search", max(1, width - 1))
        screen.refresh()
        return
    screen.addnstr(0, 1, "/ " + query, width - 2, curses.A_BOLD)
    screen.addnstr(
        1,
        1,
        f"{len(results)} matches (title, folder, command)",
        width - 2,
        curses.A_DIM,
    )
    capacity = max(1, (height - 4) // 3)
    offset = max(0, selected - capacity + 1)
    for index in range(offset, min(len(results), offset + capacity)):
        ui.draw_entry(
            screen,
            replace(results[index], active=index == selected),
            3 + (index - offset) * 3,
            width,
        )
    if not results:
        screen.addnstr(3, 1, "No matches", width - 2)
    screen.addnstr(
        height - 1,
        1,
        "Arrows: Select  Enter: Open  Esc: Cancel",
        width - 2,
        curses.A_DIM,
    )
    screen.refresh()


def recovery_lines(
    ui,
    snapshot,
    active,
    candidates=None,
    selected=None,
    current=None,
    width=100,
    targets=None,
):
    candidates = set(candidates or ())
    selected = set(selected or ())
    lines = [f"Restore into: recovered-{snapshot['session']}", ""]
    for window in snapshot["windows"]:
        for pane in window["panes"]:
            if pane["sidebar"]:
                continue
            agent = pane.get("agent", {})
            title = pane.get("label") or pane.get("title") or window["name"]
            lines.append(f"{window['index']}  {ui.clean_text(title)}")
            if agent.get("session_id") in active:
                lines.append("   Already running: keep the current conversation")
            elif ui.agents.resume_command(agent):
                lines.append(f"   Resume {agent['agent']}: {agent['session_id']}")
            else:
                lines.append(
                    "   Rerun the selected command"
                    if pane.get("pane_id") in selected
                    else "   Open a terminal in the saved folder"
                )
                if pane.get("command"):
                    lines.extend(
                        textwrap.wrap(
                            "   Saved command: " + pane["command"],
                            width=max(20, width - 2),
                            subsequent_indent="      ",
                        )
                    )
                if pane.get("pane_id") in candidates:
                    marker = "[x]" if pane["pane_id"] in selected else "[ ]"
                    pointer = ">" if pane["pane_id"] == current else " "
                    if targets is not None:
                        targets[len(lines)] = pane["pane_id"]
                    lines.append(f" {pointer} {marker} Rerun saved command")
                else:
                    lines.append(
                        "   Rerun unavailable (still running, masked, or no exact arguments)"
                    )
            lines.extend(["   Folder: " + pane["cwd"], ""])
    return lines


def render_recovery(screen, ui, socket_path, session):
    curses.set_escdelay(25)
    curses.curs_set(0)
    screen.keypad(True)
    screen.timeout(-1)
    curses.mousemask(curses.ALL_MOUSE_EVENTS)
    curses.mouseinterval(0)
    offset = 0
    error = ""
    selected_commands = set()
    current_command = 0
    follow_command = True
    while True:
        try:
            snapshot, active, eligible = ui.agents.recovery_plan(socket_path, session)
            candidates = ui.agents.replay_candidates(socket_path, snapshot)
            candidate_ids = [pane["pane_id"] for pane in candidates]
            selected_commands.intersection_update(candidate_ids)
            current_command = min(current_command, max(0, len(candidate_ids) - 1))
            current = candidate_ids[current_command] if candidate_ids else None
            targets = {}
            lines = recovery_lines(
                ui,
                snapshot,
                active,
                candidate_ids,
                selected_commands,
                current,
                screen.getmaxyx()[1],
                targets=targets,
            )
            if not eligible and not candidates:
                message = "No stopped conversations or saved commands are available."
                lines = [
                    message,
                    "Running programs stay in their existing windows.",
                    "",
                ] + lines
                targets = {row + 3: pane for row, pane in targets.items()}
        except RuntimeError as failure:
            lines, eligible, candidate_ids, targets = [str(failure)], [], [], {}
        height, width = screen.getmaxyx()
        capacity = max(1, height - 5)
        if follow_command:
            target = next(
                (index for index, line in enumerate(lines) if line.startswith(" > ")),
                None,
            )
            if target is not None and not offset <= target < offset + capacity:
                offset = max(0, target - capacity + 1)
            follow_command = False
        offset = min(offset, max(0, len(lines) - capacity))
        screen.erase()
        screen.addnstr(0, 1, "RECOVERY PREVIEW", max(1, width - 2), curses.A_BOLD)
        for row, line in enumerate(lines[offset : offset + capacity], 2):
            screen.addnstr(row, 1, line, max(1, width - 2))
        count = len(eligible) + len(selected_commands)
        hint = (
            f"r: Restore {len(eligible)} conversations, {len(selected_commands)} commands  Esc: Cancel"
            if count
            else "Restore unavailable  Esc: Close"
        )
        screen.addnstr(
            height - 2,
            1,
            "Click checkbox or Space: Toggle  c: Next  Arrows: Scroll"
            if candidate_ids
            else "Arrows: Scroll  Esc: Close",
            max(1, width - 2),
            curses.A_DIM,
        )
        screen.addnstr(height - 1, 1, error or hint, max(1, width - 2), curses.A_BOLD)
        screen.refresh()
        key = screen.getch()
        if key == curses.KEY_MOUSE:
            event = ui.mouse_event()
            if event and event[2] == "left":
                row = event[0]
                pane_id = targets.get(offset + row - 2)
                if pane_id:
                    selected_commands.symmetric_difference_update({pane_id})
                    continue
                if row == height - 1:
                    key = ord("r")
        if key in (27, ord("q")):
            return
        if key == curses.KEY_DOWN:
            offset += 1
        elif key == curses.KEY_UP:
            offset = max(0, offset - 1)
        elif key == curses.KEY_NPAGE:
            offset += capacity
        elif key == curses.KEY_PPAGE:
            offset = max(0, offset - capacity)
        elif key == ord("c") and candidate_ids:
            current_command = (current_command + 1) % len(candidate_ids)
            follow_command = True
        elif key == ord(" ") and candidate_ids:
            pane_id = candidate_ids[current_command]
            selected_commands.symmetric_difference_update({pane_id})
        elif key == ord("r") and not count:
            error = "Nothing selected or available to restore. Esc closes this preview."
        elif key == ord("r") and count:
            try:
                if selected_commands:
                    recovered = ui.agents.restore_snapshot(
                        socket_path, session, selected_commands=selected_commands
                    )
                else:
                    recovered = ui.agents.restore_snapshot(socket_path, session)
                if recovered:
                    ui.change_sidebars(socket_path, "enable", recovered)
                return
            except (RuntimeError, OSError, subprocess.CalledProcessError) as failure:
                error = str(failure)
