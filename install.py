#!/usr/bin/env python3
"""Install the agent-stat hooks into Claude Code and Codex.

Dry run by default. Pass --apply to write. --claude-config DIR and --codex-home DIR
point the install at another config tree, which is how the probes stay off a real
one.

It merges the hook entries into the two config files, deploys the
scripts into local storage, and writes the Codex trust entries that
make Codex run them. Removing them again is a hand edit; the entries are marked
with the token below.

Each machine keeps its own logs. SSH streams remote events. Standard library only.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Marks our entries so a re-run can find and replace exactly them. It matches the
# old agent-status name too, so a rename cleans up after itself.
HOOK_TOKEN = "agent-stat"

CLAUDE_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Notification",
    "Stop",
    "StopFailure",
    "SubagentStart",
    "SubagentStop",
    "SessionEnd",
]

CODEX_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Stop",
    "SubagentStart",
    "SubagentStop",
    "Interrupt",
    "SessionEnd",
]

# Codex normalizes event names to these labels in its trust state keys.
CODEX_LABELS = {
    "PreToolUse": "pre_tool_use",
    "PermissionRequest": "permission_request",
    "PostToolUse": "post_tool_use",
    "SessionStart": "session_start",
    "UserPromptSubmit": "user_prompt_submit",
    "SubagentStart": "subagent_start",
    "SubagentStop": "subagent_stop",
    "Stop": "stop",
    "Interrupt": "interrupt",
    "SessionEnd": "session_end",
}

# Codex drops the matcher from these events before hashing.
CODEX_NO_MATCHER = {"user_prompt_submit", "stop", "interrupt"}
CODEX_DEFAULT_ACL = 2500

HOOK_TIMEOUT_SECONDS = 3


# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------


def repo_dir() -> Path:
    return Path(__file__).resolve().parent


def hook_script() -> Path:
    return repo_dir() / "hooks" / "agent-stat-hook.sh"


def bridge_script() -> Path:
    """The end bridge an orchestrator calls, not a hook. Nothing registers it."""
    return repo_dir() / "hooks" / "agent-stat-run-end.sh"


def events_dir() -> Path:
    override = os.environ.get("AGENT_STAT_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".local" / "state" / "agent-stat"


# --------------------------------------------------------------------------
# codex trust hashing
#
# Codex registers a hook for execution only when its stored trusted_hash matches
# a fresh hash of the normalized hook. A stale or absent hash means the hook
# silently does not run. So the installer writes both the hook and the hash.
#
# The hash covers the event label, the matcher, and the whole normalized handler
# (type, command, timeout, async, and friends). It does NOT cover the group or
# handler index, nor the config file path. The state KEY does carry the index,
# so the installer must merge the hooks first, then find the index it landed on.
# --------------------------------------------------------------------------


def codex_normalized_timeout(label: str, raw: int | None) -> int:
    if label in ("session_end", "interrupt"):
        return min(max(raw if raw is not None else 1, 1), 3)
    return max(raw if raw is not None else 600, 1)


def codex_trusted_hash(label: str, matcher: str | None, hook: dict) -> str:
    acl = hook.get("additionalContextLimit")
    if acl == CODEX_DEFAULT_ACL:
        acl = None
    handler = {
        "type": "command",
        "command": hook["command"],
        "commandWindows": hook.get("commandWindows"),
        "timeout": codex_normalized_timeout(label, hook.get("timeout")),
        "async": hook.get("async", False),
        "statusMessage": hook.get("statusMessage"),
        "additionalContextLimit": acl,
    }
    handler = {k: v for k, v in handler.items() if v is not None}
    identity = {"event_name": label, "hooks": [handler]}
    if matcher is not None:
        identity["matcher"] = matcher
    serialized = json.dumps(
        identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )
    return "sha256:" + hashlib.sha256(serialized.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------
# file editing
# --------------------------------------------------------------------------


def backup(path: Path, stamp: str) -> Path | None:
    if not path.exists():
        return None
    target = path.with_name(path.name + f".bak-{stamp}")
    shutil.copy2(path, target)
    return target


def read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open() as fh:
        text = fh.read().strip()
    return json.loads(text) if text else {}


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def hook_command(script: Path, agent: str) -> str:
    """The command string registered in both config files.

    Three properties, each of which was broken once and each of which has a test:

    1. No exec, and the exit code is forced to 0. A hook that exits non-zero
       blocks the tool call it runs for, so the wrapper must be structurally
       unable to return anything but success, whatever the script does.
    2. The agent pid is passed in explicitly. Without exec there is an extra
       shell between the agent and the hook, so the hook's own PPID would be that
       throwaway shell and liveness tracking would mark every session dead.
    3. A missing script is silent. These config files sync to other machines
       where this repo may not exist, and a bare absolute path there would spray
       a hook error into every session on that machine.
    """
    path = f"'{script}'"
    return f"[ -x {path} ] && AGENT_HOOK_AGENT_PID=$PPID {path} {agent}; exit 0"


def preflight(script: Path) -> None:
    """Refuse to install a script that cannot be trusted to behave.

    This check exists because a shell syntax error in the hook once reached a real
    config and blocked every tool call in every session that picked it up. Exit
    code 2 from a hook means "block the tool", and a syntax error exits 2 before a
    single line of the script runs.
    """
    if "'" in str(script):
        raise SystemExit(f"script path contains a single quote, refusing: {script}")

    parsed = subprocess.run(["sh", "-n", str(script)], capture_output=True, text=True)
    if parsed.returncode != 0:
        raise SystemExit(
            f"{script.name} does not parse, refusing to install it.\n"
            f"  sh -n says: {parsed.stderr.strip()}\n"
            "  A syntax error exits 2 before a single line runs, and in a hook that\n"
            "  blocks every tool call in the session."
        )

    for number, line in enumerate(script.read_text().splitlines(), 1):
        if line.lstrip().startswith("#") and "'" in line:
            raise SystemExit(
                f"apostrophe in a comment at line {number} of {script.name}, refusing to install.\n"
                "  In the hook, the jq program is one single-quoted string, so one\n"
                "  apostrophe in a comment ends it early and breaks the whole script.\n"
                "  Every script in hooks/ therefore keeps its comments apostrophe-free."
            )


def deploy_script(script: Path, target: Path, apply: bool) -> Path:
    """Deploy scripts on each machine so hooks do not depend on this checkout."""
    destination = target / "bin" / script.name
    if apply:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(script, destination)
        os.chmod(destination, 0o755)
        # The old host cache lived here and travelled between machines, which
        # made the other machine write records under this one's name.
        stale = target / "host"
        if stale.exists():
            stale.unlink()
    return destination


def is_our_group(group: dict) -> bool:
    return any(HOOK_TOKEN in str(h.get("command", "")) for h in group.get("hooks", []))


def strip_our_groups(hooks: dict) -> None:
    """Remove our handler everywhere, then drop groups left empty."""
    for event in list(hooks.keys()):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept = []
        for group in groups:
            if not isinstance(group, dict):
                kept.append(group)
                continue
            group["hooks"] = [
                h
                for h in group.get("hooks", [])
                if HOOK_TOKEN not in str(h.get("command", ""))
            ]
            if group["hooks"]:
                kept.append(group)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)


def install_into_settings(
    path: Path, events: list[str], agent: str, deployed: Path
) -> dict:
    """Merge our hook into a JSON settings file. Returns the new document."""
    data = read_json(path)
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise SystemExit(f"{path}: 'hooks' is not an object, refusing to touch it")
    strip_our_groups(hooks)
    command = hook_command(deployed, agent)
    for event in events:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise SystemExit(
                f"{path}: hooks.{event} is not a list, refusing to touch it"
            )
        groups.append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": command,
                        "timeout": HOOK_TIMEOUT_SECONDS,
                    }
                ]
            }
        )
    return data


def find_group_index(hooks: dict, event: str) -> int:
    groups = hooks.get(event, [])
    for index, group in enumerate(groups):
        if isinstance(group, dict) and is_our_group(group):
            return index
    raise SystemExit(f"internal error: our group vanished from {event}")


STATE_HEADER = re.compile(r'^\[hooks\.state\."(?P<key>[^"]+)"\]\s*$')


def split_toml_blocks(text: str) -> list[list[str]]:
    """Split a TOML file into blocks. Each block starts at a [table] header."""
    blocks: list[list[str]] = []
    current: list[str] | None = None
    for line in text.splitlines(keepends=True):
        if line.lstrip().startswith("["):
            if current is not None:
                blocks.append(current)
            current = [line]
        elif current is None:
            current = [line]
        else:
            current.append(line)
    if current is not None:
        blocks.append(current)
    return blocks


def group_handler_positions(path: Path, label: str, groups: list):
    """Identify unrelated handlers without their mutable group and handler indices."""
    for group_index, group in enumerate(groups):
        if not isinstance(group, dict):
            continue
        for handler_index, handler in enumerate(group.get("hooks", [])):
            if HOOK_TOKEN in str(handler.get("command", "")):
                continue
            key = f"{path}:{label}:{group_index}:{handler_index}"
            identity = json.dumps(
                [label, group.get("matcher"), handler], sort_keys=True
            )
            yield key, identity


def handler_positions(path: Path, document: dict) -> dict[str, str]:
    positions = {}
    for event, groups in document.get("hooks", {}).items():
        if isinstance(groups, list):
            positions.update(
                group_handler_positions(path, CODEX_LABELS.get(event, event), groups)
            )
    return positions


def trust_relocations(path: Path, previous: dict, updated: dict) -> dict[str, str]:
    destinations: dict[str, list[str]] = {}
    for key, identity in handler_positions(path, updated).items():
        destinations.setdefault(identity, []).append(key)
    relocated = {}
    for key, identity in handler_positions(path, previous).items():
        matches = destinations.get(identity)
        if matches:
            relocated[key] = matches.pop(0)
    return relocated


def remap_state_blocks(text: str, path: Path, previous: dict, updated: dict) -> str:
    """Move existing trust with its handler; never grant trust to another handler."""
    relocations = trust_relocations(path, previous, updated)
    kept: list[list[str]] = []
    for block in split_toml_blocks(text):
        header = STATE_HEADER.match(block[0].rstrip("\n"))
        key = header.group("key") if header else ""
        if key.rsplit(":", 3)[0] != str(path):
            kept.append(block)
            continue
        destination = relocations.get(key)
        if destination:
            block[0] = block[0].replace(key, destination, 1)
            kept.append(block)
    return "".join("".join(b) for b in kept)


def state_block(
    codex_hooks_path: Path, label: str, gi: int, hi: int, digest: str
) -> str:
    key = f"{codex_hooks_path}:{label}:{gi}:{hi}"
    return f'\n[hooks.state."{key}"]\nenabled = true\ntrusted_hash = "{digest}"\n'


# --------------------------------------------------------------------------
# the job
# --------------------------------------------------------------------------


def config_dir(flag: str, default: str) -> Path:
    """A config root, from the flag only.

    Deliberately does NOT follow CLAUDE_CONFIG_DIR or CODEX_HOME: a stray variable
    would silently install into a different config tree. The flags exist for the
    probes, which install into a throwaway tree so they never touch a real one.
    """
    args = sys.argv[1:]
    if flag in args:
        at = args.index(flag)
        if at + 1 >= len(args):
            raise SystemExit(f"{flag} wants a directory")
        return Path(args[at + 1]).expanduser()
    return Path.home() / default


def main() -> int:
    apply = "--apply" in sys.argv[1:]
    taken = {"--apply", "--claude-config", "--codex-home"}
    unknown = [a for a in sys.argv[1:] if a not in taken]
    for flag in ("--claude-config", "--codex-home"):
        if flag in sys.argv[1:]:
            at = sys.argv.index(flag)
            if at + 1 < len(sys.argv) and sys.argv[at + 1] not in taken:
                unknown = [a for a in unknown if a != sys.argv[at + 1]]
    if unknown:
        raise SystemExit(f"unknown argument: {' '.join(unknown)}")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    script = hook_script()
    bridge = bridge_script()
    for path in (script, bridge):
        if not path.exists():
            raise SystemExit(f"script missing: {path}")
        preflight(path)
        if not os.access(path, os.X_OK):
            raise SystemExit(f"script is not executable, run chmod +x: {path}")

    target = events_dir()
    claude_path = config_dir("--claude-config", ".claude") / "settings.json"
    codex_home = config_dir("--codex-home", ".codex")
    codex_hooks = codex_home / "hooks.json"
    codex_config = codex_home / "config.toml"

    deployed = deploy_script(script, target, apply)
    deployed_bridge = deploy_script(bridge, target, apply)
    deployed_stream = deploy_script(
        repo_dir() / "scripts" / "stream-events.py", target, apply
    )

    print(f"hook script : {script}")
    print(f"end bridge  : {bridge}")
    print(f"events dir  : {target}")
    print(f"claude      : {claude_path}")
    print(f"codex       : {codex_hooks}")
    print(f"codex state : {codex_config}")
    print()

    if apply:
        target.mkdir(parents=True, exist_ok=True)
        os.chmod(target, 0o700)
        (target / "hosts").mkdir(parents=True, exist_ok=True)
        os.chmod(target / "hosts", 0o700)
    else:
        print(f"would create {target} (0700) with hosts/ and bin/")

    print(f"hook deployed: {deployed}")
    print(f"end bridge   : {deployed_bridge}")
    print(f"event stream : {deployed_stream}")

    previous_codex = read_json(codex_hooks)
    for label, path, events, agent in (
        ("claude settings", claude_path, CLAUDE_EVENTS, "claude"),
        ("codex hooks", codex_hooks, CODEX_EVENTS, "codex"),
    ):
        doc = install_into_settings(path, events, agent, deployed)
        print(f"{label}: {len(events)} hook entries for {agent}")
        if apply:
            b = backup(path, stamp)
            write_json(path, doc)
            if b:
                print(f"  backed up to {b.name}")

    if not apply:
        print(
            "codex trust: would write "
            f"{len(CODEX_EVENTS)} trusted entries keyed on "
            f"{os.path.realpath(codex_hooks)}"
        )
        print()
        print("dry run. nothing written. re-run with --apply")
        return 0

    preflight(deployed)
    with open(codex_hooks) as fh:
        codex_doc = json.load(fh)
    canonical = Path(os.path.realpath(codex_hooks))
    text = codex_config.read_text() if codex_config.exists() else ""
    text = remap_state_blocks(text, canonical, previous_codex, codex_doc)
    text = text.rstrip("\n") + "\n"
    if "[hooks.state]" not in text:
        text = text.rstrip("\n") + "\n\n[hooks.state]\n"
    for event in CODEX_EVENTS:
        label = CODEX_LABELS[event]
        gi = find_group_index(codex_doc.get("hooks", {}), event)
        group = codex_doc["hooks"][event][gi]
        hook = group["hooks"][0]
        matcher = None if label in CODEX_NO_MATCHER else group.get("matcher")
        digest = codex_trusted_hash(label, matcher, hook)
        text += state_block(canonical, label, gi, 0, digest)
    b = backup(codex_config, stamp)
    codex_config.write_text(text)
    print(f"codex trust: {len(CODEX_EVENTS)} trusted entries under {canonical}")
    if b:
        print(f"  backed up to {b.name}")
    print()
    print("applied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
