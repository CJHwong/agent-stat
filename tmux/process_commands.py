"""Capture foreground arguments without treating display text as shell code."""

import ctypes
import logging
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import sys


def redact_command(command):
    command = "".join(character for character in command if character.isprintable())
    command = re.sub(
        r"(?i)(--?(?:password|passwd|token|api[-_]?key|secret|authorization)(?:=|\s+))([\'\"][^\'\"]*[\'\"]|\S+)",
        r"\1[hidden]",
        command,
    )
    command = re.sub(
        r"(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY)[A-Z0-9_]*=)([\'\"][^\'\"]*[\'\"]|\S+)",
        r"\1[hidden]",
        command,
    )
    return re.sub(r"https?://[^/\s]+:[^/\s]+@", "https://[hidden]@", command)


def parse_procargs(contents):
    count = struct.unpack_from("i", contents)[0]
    if not 0 < count <= 4096:
        raise ValueError("Invalid process argument count")
    start = contents.index(b"\0", 4) + 1
    while start < len(contents) and contents[start] == 0:
        start += 1
    arguments = contents[start:].split(b"\0", count)[:count]
    if len(arguments) != count:
        raise ValueError("Incomplete process argument list")
    return [os.fsdecode(argument) for argument in arguments]


def process_arguments(pid):
    if sys.platform != "darwin":
        return (
            Path(f"/proc/{pid}/cmdline").read_bytes().rstrip(b"\0").decode().split("\0")
        )
    library = ctypes.CDLL(None, use_errno=True)
    query = (ctypes.c_int * 3)(
        1, 49, int(pid)
    )  # KERN_PROCARGS2 keeps argument boundaries.
    size = ctypes.c_size_t()
    if library.sysctl(query, 3, None, ctypes.byref(size), None, 0):
        raise OSError(ctypes.get_errno(), "Cannot read process argument size")
    buffer = ctypes.create_string_buffer(size.value)
    if library.sysctl(query, 3, buffer, ctypes.byref(size), None, 0):
        raise OSError(ctypes.get_errno(), "Cannot read process arguments")
    return parse_procargs(buffer.raw[: size.value])


def foreground_process(socket_path, pane_id):
    tty, root_pid = subprocess.check_output(
        [
            "tmux",
            "-S",
            socket_path,
            "display-message",
            "-p",
            "-t",
            pane_id,
            "#{pane_tty} #{pane_pid}",
        ],
        text=True,
    ).split()
    result = subprocess.run(
        [
            "/bin/ps",
            "-t",
            tty,
            "-o",
            "pid=",
            "-o",
            "pgid=",
            "-o",
            "tpgid=",
            "-o",
            "command=",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    processes = [line.strip().split(None, 3) for line in result.stdout.splitlines()]
    foreground = [
        fields for fields in processes if len(fields) == 4 and fields[1] == fields[2]
    ]
    chosen = next((fields for fields in foreground if fields[0] == fields[2]), None)
    chosen = chosen or next(
        (fields for fields in processes if len(fields) == 4 and fields[0] == root_pid),
        None,
    )
    return chosen


def replay_arguments(pane):
    arguments = pane.get("command_argv", [])
    if pane.get("sidebar") or pane.get("agent", {}).get("session_id"):
        return []
    if (
        not isinstance(arguments, list)
        or not arguments
        or not all(isinstance(argument, str) for argument in arguments)
    ):
        return []
    executable = Path(arguments[0]).name.lstrip("-")
    if executable in ("bash", "zsh", "sh", "fish", "dash", "claude", "codex"):
        return []
    command = shlex.join(arguments)
    return arguments if command == redact_command(command) else []


def capture_command(socket_path, pane_id):
    chosen = foreground_process(socket_path, pane_id)
    if not chosen:
        return {"command": "[process exited]", "command_argv": []}
    try:
        arguments = process_arguments(int(chosen[0]))
    except (OSError, ValueError, struct.error):
        logging.info("Exact arguments unavailable for pane %s", pane_id)
        return {"command": redact_command(chosen[3]), "command_argv": []}
    display = redact_command(shlex.join(arguments))
    pane = {"command_argv": arguments}
    start = subprocess.check_output(
        ["/bin/ps", "-p", chosen[0], "-o", "lstart="], text=True
    ).strip()
    return {
        "command": display,
        "command_argv": replay_arguments(pane),
        "command_pid": int(chosen[0]),
        "command_start": " ".join(start.split()),
    }
