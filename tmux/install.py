#!/usr/bin/env python3
"""Deploy the optional terminal interface. Print the plan unless --apply is set."""

import argparse
from datetime import datetime, timezone
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
SCRIPTS = (
    "window-sidebar.py",
    "sidebar_agents.py",
    "agent_stat_reader.py",
    "sidebar_views.py",
    "process_commands.py",
)


def render_config(destination, python):
    command = shlex.join([str(python), str(destination / "window-sidebar.py")])
    # Tmux parses a double-quoted command before passing it to the shell.
    command = command.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")
    return (
        (SOURCE / "sidebar.conf.in").read_text().replace("@SIDEBAR_COMMAND@", command)
    )


def install(home, python, apply=False, reload=False):
    destination = home / ".agents/tmux"
    config = home / ".config/tmux/window-sidebar.conf"
    main_config = home / ".tmux.conf"
    rendered = render_config(destination, python)
    source_line = (
        "source-file "
        + '"'
        + str(config).replace("\\", "\\\\").replace('"', '\\"')
        + '"'
    )
    existing = main_config.read_text() if main_config.exists() else ""
    source_present = (
        source_line in existing
        or "source-file ~/.config/tmux/window-sidebar.conf" in existing
    )
    print("Deploy scripts: " + str(destination))
    print("Write configuration: " + str(config))
    print("Keep existing agent-stat hooks; add no status hooks.")
    if not apply:
        print("Dry run. Add --apply to install.")
        return
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    backup = home / ".local/state/tmux-sidebar/backups" / stamp
    backup.mkdir(parents=True, mode=0o700)
    for filename in [destination / name for name in SCRIPTS] + [config, main_config]:
        if filename.exists():
            shutil.copy2(filename, backup / filename.name)
    destination.mkdir(parents=True, exist_ok=True)
    config.parent.mkdir(parents=True, exist_ok=True)
    for name in SCRIPTS:
        shutil.copy2(SOURCE / name, destination / name)
    config.write_text(rendered)
    if not source_present:
        main_config.write_text(existing.rstrip() + "\n\n" + source_line + "\n")
    print("Backup: " + str(backup))
    if reload:
        subprocess.run(["tmux", "source-file", str(config)], check=True)
    print("Installed. Existing sidebar processes load updates after a sidebar restart.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--reload",
        action="store_true",
        help="Reload bindings on the default tmux server",
    )
    parser.add_argument(
        "--home",
        type=Path,
        default=Path.home(),
        help="Use another home directory for an isolated install",
    )
    parser.add_argument("--python", type=Path, default=Path(sys.executable))
    arguments = parser.parse_args()
    install(
        arguments.home.expanduser().resolve(),
        arguments.python.resolve(),
        arguments.apply,
        arguments.reload,
    )


if __name__ == "__main__":
    main()
