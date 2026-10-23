#!/usr/bin/env python3
"""Check installer trust changes against disposable profile directories."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("installer", REPO / "install.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)


class InstallerTrustTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.profile = self.root / "codex"
        self.profile.mkdir()
        self.hooks = self.profile / "hooks.json"
        self.config = self.profile / "config.toml"
        self.own = self.handler("/old/agent-stat-hook.sh codex")
        self.other = self.handler("echo preserve")

    @staticmethod
    def handler(command):
        return {"type": "command", "command": command, "timeout": 3}

    def key(self, group, handler=0, hooks=None):
        return f"{hooks or self.hooks}:stop:{group}:{handler}"

    def state(self, group, handler=0, digest=None, enabled=True, hooks=None):
        if digest is None:
            digest = INSTALL.codex_trusted_hash("stop", None, self.other)
        key = self.key(group, handler, hooks)
        return (
            f'\n[hooks.state."{key}"]\n'
            f"enabled = {str(enabled).lower()}\n"
            f'trusted_hash = "{digest}"\n'
        )

    def seed(self, groups, states):
        self.hooks.write_text(json.dumps({"hooks": {"Stop": groups}}))
        self.config.write_text('model = "preserve"\n[hooks.state]\n' + states)

    def install(self):
        result = subprocess.run(
            [
                sys.executable,
                str(REPO / "install.py"),
                "--apply",
                "--claude-config",
                str(self.root / "claude"),
                "--codex-home",
                str(self.profile),
            ],
            env=dict(os.environ, AGENT_STAT_DIR=str(self.root / "events")),
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return tomllib.loads(self.config.read_text())["hooks"]["state"]

    def test_reordered_unrelated_group_retains_its_trust(self):
        self.seed(
            [{"hooks": [self.own]}, {"hooks": [self.other]}],
            self.state(0, digest="old-own") + self.state(1),
        )
        states = self.install()
        self.assertEqual(
            states[self.key(0)]["trusted_hash"],
            INSTALL.codex_trusted_hash("stop", None, self.other),
        )

    def test_mixed_group_retains_disabled_handler_state(self):
        self.seed(
            [{"matcher": "*", "hooks": [self.own, self.other]}],
            self.state(0, digest="old-own")
            + self.state(0, 1, digest="keep-disabled", enabled=False),
        )
        states = self.install()
        self.assertEqual(
            states[self.key(0)],
            {"enabled": False, "trusted_hash": "keep-disabled"},
        )

    def test_modified_handler_does_not_receive_a_fresh_hash(self):
        self.seed(
            [{"hooks": [self.own]}, {"hooks": [self.other]}],
            self.state(0, digest="old-own") + self.state(1, digest="stale-hash"),
        )
        states = self.install()
        self.assertEqual(states[self.key(0)]["trusted_hash"], "stale-hash")

    def test_untrusted_handler_does_not_inherit_previous_own_state(self):
        self.seed(
            [{"hooks": [self.own]}, {"hooks": [self.other]}],
            self.state(0, digest="old-own"),
        )
        states = self.install()
        self.assertNotIn(self.key(0), states)

    def test_other_profile_state_remains_unchanged(self):
        sibling = self.root / "other/hooks.json"
        original = self.state(0, digest="other-profile", enabled=False, hooks=sibling)
        self.seed([{"hooks": [self.own]}], self.state(0) + original)
        states = self.install()
        self.assertEqual(
            states[self.key(0, hooks=sibling)],
            {"enabled": False, "trusted_hash": "other-profile"},
        )
        self.assertIn(original, self.config.read_text())

    def test_repeated_install_preserves_hooks_and_states(self):
        self.seed(
            [{"hooks": [self.own]}, {"hooks": [self.other]}],
            self.state(0, digest="old-own") + self.state(1),
        )
        self.install()
        hooks = self.hooks.read_bytes()
        config = self.config.read_bytes()
        self.install()
        self.assertEqual(self.hooks.read_bytes(), hooks)
        self.assertEqual(self.config.read_bytes(), config)

    def test_duplicate_handlers_keep_their_separate_states(self):
        self.seed(
            [
                {"hooks": [self.own, self.other]},
                {"hooks": [self.other, self.own]},
            ],
            self.state(0, digest="old-own")
            + self.state(0, 1, digest="first", enabled=False)
            + self.state(1, digest="second")
            + self.state(1, 1, digest="duplicate-own"),
        )
        states = self.install()
        self.assertEqual(
            states[self.key(0)], {"enabled": False, "trusted_hash": "first"}
        )
        self.assertEqual(states[self.key(1)]["trusted_hash"], "second")
        handlers = json.loads(self.hooks.read_text())["hooks"]["Stop"]
        own_count = sum(
            "agent-stat" in handler["command"]
            for group in handlers
            for handler in group["hooks"]
        )
        self.assertEqual(own_count, 1)

    def test_hooks_symlink_uses_canonical_state_keys(self):
        target = self.profile / "canonical.json"
        self.hooks.symlink_to(target)
        self.seed(
            [{"hooks": [self.own]}, {"hooks": [self.other]}],
            self.state(0, digest="old-own", hooks=target) + self.state(1, hooks=target),
        )
        states = self.install()
        self.assertEqual(
            states[self.key(0, hooks=target)]["trusted_hash"],
            INSTALL.codex_trusted_hash("stop", None, self.other),
        )

    def test_orphan_state_does_not_trust_an_unregistered_position(self):
        self.seed(
            [{"hooks": [self.own]}, {"hooks": [self.other]}],
            self.state(0, digest="old-own") + self.state(8, digest="orphan"),
        )
        states = self.install()
        self.assertNotIn(self.key(0), states)
        self.assertNotIn(self.key(8), states)


if __name__ == "__main__":
    unittest.main()
