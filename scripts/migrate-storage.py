#!/usr/bin/env python3
"""Move AgentStat storage after both machines pass transport validation.

Dry run by default. Pause Syncthing on both machines before --apply.
The old hosts link remains until all hooks already in flight finish.
This maintenance command requires Python 3.11. The stream helper requires Python 3.9.
"""

from __future__ import annotations

import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import sys

if sys.version_info < (3, 11):
    raise SystemExit(
        "Migration requires Python 3.11 or later. "
        "Use a 3.11 interpreter, for example /opt/homebrew/bin/python3."
    )

import tomllib  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("agent_stat_install", REPO / "install.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)
SCRIPTS = ("agent-stat-hook.sh", "agent-stat-run-end.sh")
MARKER = "migration-complete.json"


class MigrationError(Exception):
    """Stop before overwriting storage or changing an unknown configuration."""


def atomic_swap(first: Path, second: Path) -> None:
    if sys.platform != "darwin":
        raise MigrationError("atomic migration requires macOS renamex_np")
    library = ctypes.CDLL(None, use_errno=True)
    operation = library.renamex_np
    operation.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    operation.restype = ctypes.c_int
    if operation(os.fsencode(first), os.fsencode(second), 2) != 0:
        raise MigrationError(
            f"atomic directory swap failed (errno {ctypes.get_errno()})"
        )


def config_paths(home: Path, pattern: str) -> list[Path]:
    paths = {path.resolve(strict=True) for path in home.glob(pattern) if path.is_file()}
    for path in paths:
        if not path.is_relative_to(home):
            raise MigrationError("a config profile points outside the selected home")
    return sorted(paths)


def replacements(old: Path, new: Path) -> dict[str, str]:
    sources = (
        str(old),
        "~/.agents/agent-stat",
        "$HOME/.agents/agent-stat",
        "${HOME}/.agents/agent-stat",
    )
    return {
        f"{source}/bin/{name}": str(new / "bin" / name)
        for source in sources
        for name in SCRIPTS
    }


def registered_handlers(document: dict):
    hooks = document.get("hooks", {})
    if not isinstance(hooks, dict):
        raise MigrationError("registered hooks must be an object")
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise MigrationError("registered hook groups must be lists")
        yield from group_handlers(event, groups)


def group_handlers(event: str, groups: list):
    for group_index, group in enumerate(groups):
        if not isinstance(group, dict) or not isinstance(group.get("hooks", []), list):
            raise MigrationError("registered hook group has an invalid shape")
        for handler_index, handler in enumerate(group.get("hooks", [])):
            if not isinstance(handler, dict):
                raise MigrationError("registered hook handler must be an object")
            yield event, group_index, handler_index, group, handler


def migrate_json(path: Path, changes: dict) -> tuple[dict, bytes | None, bytes]:
    original = path.read_bytes()
    document = json.loads(original)
    if not isinstance(document, dict):
        raise MigrationError("configuration JSON must be an object")
    changed = False
    for _, _, _, _, handler in registered_handlers(document):
        command = handler.get("command")
        if not isinstance(command, str):
            continue
        updated = replace_command(command, changes)
        changed |= updated != command
        handler["command"] = updated
    content = (
        (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode()
        if changed
        else None
    )
    return document, content, original


def replace_command(command: str, changes: dict) -> str:
    for previous, current in changes.items():
        command = command.replace(previous, current)
    return command


def trust_blocks(hooks_path: Path, document: dict, new: Path) -> dict[str, str]:
    blocks = {}
    for event, group_index, handler_index, group, handler in registered_handlers(
        document
    ):
        command = handler.get("command", "")
        if not isinstance(command, str) or not any(
            str(new / "bin" / name) in command for name in SCRIPTS
        ):
            continue
        label = INSTALL.CODEX_LABELS.get(event, event)
        matcher = None if label in INSTALL.CODEX_NO_MATCHER else group.get("matcher")
        digest = INSTALL.codex_trusted_hash(label, matcher, handler)
        key = f"{hooks_path}:{label}:{group_index}:{handler_index}"
        blocks[key] = INSTALL.state_block(
            hooks_path, label, group_index, handler_index, digest
        )
    return blocks


def migrate_toml(path: Path, updates: dict[str, str]) -> tuple[bytes | None, bytes]:
    original_bytes = path.read_bytes()
    original = original_bytes.decode()
    tomllib.loads(original)
    remaining = dict(updates)
    blocks = []
    for block in INSTALL.split_toml_blocks(original):
        header = INSTALL.STATE_HEADER.match(block[0].rstrip("\n"))
        key = header.group("key") if header else None
        blocks.append(remaining.pop(key) if key in remaining else "".join(block))
    updated = "".join(blocks) + "".join(remaining.values())
    tomllib.loads(updated)
    return (updated.encode() if updated != original else None), original_bytes


def completed(old: Path, new: Path) -> bool:
    marker = new / MARKER
    if not marker.is_file() or marker.is_symlink():
        return False
    state = json.loads(marker.read_text())
    return state == {"old": str(old), "new": str(new), "protocol": 1}


class Plan:
    def __init__(self, home: Path):
        self.home = home.resolve(strict=True)
        self.old = self.home / ".agents/agent-stat"
        self.new = self.home / ".local/state/agent-stat"
        self.host = os.uname().nodename.removesuffix(".local")
        self.edits: dict[Path, bytes] = {}
        self.originals: dict[Path, bytes] = {}
        self.config_count = 0
        self.trust_count = 0
        self.done = completed(self.old, self.new)
        if not self.done:
            self.preflight()

    def preflight(self) -> None:
        if not self.old.is_dir() or self.old.is_symlink():
            raise MigrationError("old storage must be a real directory")
        if self.new.exists() or self.new.is_symlink():
            raise MigrationError(
                "new storage already exists without a completed migration"
            )
        scripts = self.old / "bin"
        if not scripts.is_dir() or scripts.is_symlink():
            raise MigrationError("old scripts must be a real directory")
        hosts = self.old / "hosts"
        if not hosts.is_dir() or hosts.is_symlink():
            raise MigrationError("old hosts must be a real directory")
        if any(not path.is_file() or path.is_symlink() for path in hosts.iterdir()):
            raise MigrationError("old hosts must contain only regular files")
        if any(character in str(self.new) for character in "'\n\r"):
            raise MigrationError("storage path cannot contain quotes or line breaks")
        for script in (INSTALL.hook_script(), INSTALL.bridge_script()):
            INSTALL.preflight(script)
        if not (REPO / "scripts/stream-events.py").is_file():
            raise MigrationError("stream helper is missing")
        self.plan_configs()
        targets = list(self.edits) + [self.old / "bin" / name for name in SCRIPTS]
        if any(
            path.with_name(path.name + ".agent-stat-migration").exists()
            for path in targets
        ):
            raise MigrationError("a staging file from another migration already exists")

    def plan_configs(self) -> None:
        changes = replacements(self.old, self.new)
        paths = config_paths(self.home, ".claude*/settings.json")
        codex_paths = config_paths(self.home, ".codex*/hooks.json")
        trust = {}
        for path in sorted(set(paths + codex_paths)):
            document, content, original = migrate_json(path, changes)
            self.originals[path] = original
            if content is not None:
                self.edits[path] = content
            if path in codex_paths:
                trust.update(trust_blocks(path, document, self.new))
        for path in config_paths(self.home, ".codex*/config.toml"):
            content, original = migrate_toml(path, trust)
            self.originals[path] = original
            if content is not None:
                self.edits[path] = content
        self.config_count = len(set(paths + codex_paths))
        self.trust_count = len(trust)
        rhapsody = self.home / ".rhapsody/conf.yaml"
        if rhapsody.is_file():
            resolved = rhapsody.resolve(strict=True)
            if not resolved.is_relative_to(self.home):
                raise MigrationError("Rhapsody config points outside the selected home")
            original_bytes = resolved.read_bytes()
            self.originals[resolved] = original_bytes
            original = original_bytes.decode()
            updated = replace_command(original, changes)
            if updated != original:
                self.edits[resolved] = updated.encode()

    def apply(self) -> None:
        if self.done:
            return
        if sys.platform != "darwin" or not hasattr(ctypes.CDLL(None), "renamex_np"):
            raise MigrationError("atomic migration requires macOS renamex_np")
        self.assert_unchanged()
        self.new.mkdir(parents=True, mode=0o700)
        os.chmod(self.new, 0o700)
        archive = self.new / "archive"
        archive.mkdir(mode=0o700)
        shutil.copytree(self.old, archive / "pre-migration", symlinks=True)
        self.backup_configs(archive)
        for script in (
            INSTALL.hook_script(),
            INSTALL.bridge_script(),
            REPO / "scripts/stream-events.py",
        ):
            INSTALL.deploy_script(script, self.new, True)
        (self.new / "hosts").symlink_to(self.new / "hosts")
        atomic_swap(self.old / "hosts", self.new / "hosts")
        self.write_launchers()
        self.archive_remote(archive)
        self.assert_unchanged()
        for path, content in self.edits.items():
            if path.read_bytes() != self.originals[path]:
                raise MigrationError(
                    "a config changed after preflight; backups remain in the new archive"
                )
            atomic_write(path, content)
        marker = (
            json.dumps({"old": str(self.old), "new": str(self.new), "protocol": 1})
            + "\n"
        )
        atomic_write(self.new / MARKER, marker.encode(), 0o600)

    def assert_unchanged(self) -> None:
        if any(
            path.read_bytes() != content for path, content in self.originals.items()
        ):
            raise MigrationError("a config changed after preflight; repeat the dry run")

    def backup_configs(self, archive: Path) -> None:
        for path in self.edits:
            destination = archive / "config" / path.relative_to(self.home)
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            destination.write_bytes(self.originals[path])
            os.chmod(destination, 0o600)

    def write_launchers(self) -> None:
        for name in SCRIPTS:
            content = (
                "#!/bin/sh\n"
                f"export AGENT_STAT_DIR={shlex.quote(str(self.new))}\n"
                f'exec {shlex.quote(str(self.new / "bin" / name))} "$@"\n'
            )
            atomic_write(self.old / "bin" / name, content.encode(), 0o755)

    def archive_remote(self, archive: Path) -> None:
        hosts = self.new / "hosts"
        os.chmod(hosts, 0o700)
        pattern = re.compile(re.escape(self.host) + r"-\d{4}-\d{2}-\d{2}\.jsonl\Z")
        remote = archive / "remote-hosts"
        remote.mkdir(mode=0o700)
        for path in hosts.iterdir():
            os.chmod(path, 0o600)
            if not pattern.fullmatch(path.name):
                path.rename(remote / path.name)

    def report(self) -> None:
        if self.done:
            print(f"Migration already complete: {self.new}")
            return
        print(f"Source: {self.old}")
        print(f"Destination: {self.new}")
        print(f"Profiles checked: {self.config_count}")
        print(f"Config files to update: {len(self.edits)}")
        print(f"Exact Codex trust keys: {self.trust_count}")


def atomic_write(path: Path, content: bytes, mode: int | None = None) -> None:
    selected_mode = mode if mode is not None else stat.S_IMODE(path.stat().st_mode)
    staging = path.with_name(path.name + ".agent-stat-migration")
    descriptor = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL, selected_mode)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(staging, selected_mode)
        os.replace(staging, path)
    finally:
        if staging.exists():
            staging.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--apply", action="store_true")
    arguments = parser.parse_args()
    try:
        plan = Plan(arguments.home)
        plan.report()
        if arguments.apply:
            plan.apply()
            if plan.done:
                return 0
            print(
                "Migration complete. Leave the old hosts link until in-flight hooks finish."
            )
        elif not plan.done:
            print(
                "Dry run. No files changed. Pause Syncthing on both machines before --apply."
            )
    except (MigrationError, OSError, ValueError) as error:
        message = (
            str(error) if isinstance(error, MigrationError) else type(error).__name__
        )
        print(
            f"Migration failed: {message}. No further changes attempted.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
