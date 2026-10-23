#!/usr/bin/env python3
"""Check migration against disposable homes and real writer processes."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/migrate-storage.py"
SPEC = importlib.util.spec_from_file_location("migration", SCRIPT)
MIGRATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MIGRATION)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.old = self.home / ".agents/agent-stat"
        self.new = self.home / ".local/state/agent-stat"
        self.host = os.uname().nodename.removesuffix(".local")
        (self.old / "hosts").mkdir(parents=True)
        (self.old / "bin").mkdir()
        for name in MIGRATION.SCRIPTS:
            shutil.copy2(REPO / "hooks" / name, self.old / "bin" / name)
        self.local_name = f"{self.host}-2026-10-23.jsonl"
        self.local = self.old / "hosts" / self.local_name
        self.local.write_bytes(b'{"session":"local"}\n')
        (self.old / "hosts/foreign-2026-10-23.jsonl").write_bytes(
            b'{"session":"remote"}\n'
        )
        self.claude = self.write_json(".claude/settings.json", self.hooks("claude"))
        self.codex = self.write_json(".codex/hooks.json", self.hooks("codex"))
        self.codex_config = self.home / ".codex/config.toml"
        self.codex_config.write_text(
            'model = "unchanged"\n\n[features]\nhooks = true\n'
        )

    def hooks(self, agent):
        return {
            "unrelated": {"command": str(self.old / "bin/agent-stat-hook.sh")},
            "hooks": {
                "Stop": [
                    {
                        "hooks": [
                            {
                                "type": "command",
                                "command": "echo unrelated",
                                "timeout": 3,
                            }
                        ]
                    },
                    {
                        "matcher": "*",
                        "hooks": [
                            {
                                "type": "command",
                                "command": MIGRATION.INSTALL.hook_command(
                                    self.old / "bin/agent-stat-hook.sh", agent
                                ),
                                "timeout": 3,
                            },
                            {
                                "type": "command",
                                "command": "echo keep this too",
                                "timeout": 3,
                            },
                        ],
                    },
                ]
            },
        }

    def write_json(self, relative, document):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document))
        return path

    def execute(self, apply=False, success=True):
        command = [sys.executable, str(SCRIPT), "--home", str(self.home)]
        if apply:
            command.append("--apply")
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result

    def tree(self):
        return {
            str(path.relative_to(self.home)): path.read_bytes()
            for path in self.home.rglob("*")
            if path.is_file()
        }

    def test_default_dry_run_does_not_change_files(self):
        before = self.tree()
        result = self.execute()
        self.assertIn("Dry run", result.stdout)
        self.assertFalse(self.new.exists())
        self.assertEqual(self.tree(), before)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS atomic swap")
    def test_migration_preserves_backup_history_permissions_and_profiles(self):
        original = self.tree()
        self.execute(apply=True)
        self.assertTrue((self.old / "hosts").is_symlink())
        self.assertEqual((self.old / "hosts").resolve(), self.new / "hosts")
        self.assertEqual(
            (self.new / "hosts" / self.local_name).read_bytes(), self.local.read_bytes()
        )
        self.assertFalse((self.new / "hosts/foreign-2026-10-23.jsonl").exists())
        self.assertEqual(
            (self.new / "archive/remote-hosts/foreign-2026-10-23.jsonl").read_bytes(),
            b'{"session":"remote"}\n',
        )
        for relative, content in original.items():
            source = Path(relative)
            if str(source).startswith(".agents/agent-stat/"):
                backup = (
                    self.new
                    / "archive/pre-migration"
                    / source.relative_to(".agents/agent-stat")
                )
            else:
                backup = self.new / "archive/config" / source
            self.assertEqual(backup.read_bytes(), content)
        self.assertEqual(self.new.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.local.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.new / "hosts").stat().st_mode & 0o777, 0o700)
        self.assertTrue((self.new / "bin/stream-events.py").is_file())
        document = json.loads(self.claude.read_text())
        self.assertEqual(
            document["unrelated"]["command"], str(self.old / "bin/agent-stat-hook.sh")
        )
        groups = document["hooks"]["Stop"]
        self.assertEqual(groups[0]["hooks"][0]["command"], "echo unrelated")
        self.assertEqual(groups[1]["hooks"][1]["command"], "echo keep this too")
        self.assertIn(
            str(self.new / "bin/agent-stat-hook.sh"), groups[1]["hooks"][0]["command"]
        )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS atomic swap")
    def test_open_descriptor_and_old_and_new_paths_share_one_inode(self):
        writer_code = """
import pathlib, sys
old = pathlib.Path(sys.argv[1])
new = pathlib.Path(sys.argv[2])
with old.open('ab', buffering=0) as stream:
    print('ready', flush=True)
    sys.stdin.readline()
    stream.write(b'open-descriptor\\n')
    with old.open('ab', buffering=0) as previous:
        previous.write(b'old-path\\n')
    with new.open('ab', buffering=0) as current:
        current.write(b'new-path\\n')
"""
        producer = subprocess.Popen(
            [
                sys.executable,
                "-c",
                writer_code,
                str(self.local),
                str(self.new / "hosts" / self.local_name),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: producer.poll() is None and producer.kill())
        self.assertEqual(producer.stdout.readline().strip(), "ready")
        inode = self.local.stat().st_ino
        self.execute(apply=True)
        stdout, stderr = producer.communicate("continue\n", timeout=5)
        self.assertEqual(producer.returncode, 0, stdout + stderr)
        self.assertEqual((self.new / "hosts" / self.local_name).stat().st_ino, inode)
        expected = b'{"session":"local"}\nopen-descriptor\nold-path\nnew-path\n'
        self.assertEqual(self.local.read_bytes(), expected)
        self.assertEqual((self.new / "hosts" / self.local_name).read_bytes(), expected)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS atomic swap")
    def test_all_profiles_trust_exact_keys_without_changing_unrelated_states(self):
        second = self.write_json(".codex-other/hooks.json", self.hooks("codex"))
        second_config = self.home / ".codex-other/config.toml"
        unrelated_key = f"{self.home}/some-other/hooks.json:stop:1:0"
        unrelated = f'\n[hooks.state."{unrelated_key}"]\nenabled = false\ntrusted_hash = "keep"\n'
        stale_key = f"{self.codex}:stop:1:0"
        stale = (
            f'\n[hooks.state."{stale_key}"]\nenabled = false\ntrusted_hash = "old"\n'
        )
        self.codex_config.write_text(self.codex_config.read_text() + unrelated + stale)
        second_config.write_text('model = "other"\n' + unrelated + stale)
        alias = self.home / ".codex-alias"
        alias.symlink_to(self.home / ".codex-other", target_is_directory=True)
        self.execute(apply=True)
        for path in (self.codex_config, second_config):
            text = path.read_text()
            self.assertIn(unrelated, text)
            document = tomllib.loads(text)
            states = document["hooks"]["state"]
            self.assertEqual(len(states), 3)
            for hooks_path in (self.codex, second):
                hook = json.loads(hooks_path.read_text())["hooks"]["Stop"][1]["hooks"][
                    0
                ]
                digest = MIGRATION.INSTALL.codex_trusted_hash("stop", None, hook)
                state = states[f"{hooks_path}:stop:1:0"]
                self.assertTrue(state["enabled"])
                self.assertEqual(state["trusted_hash"], digest)
        self.assertEqual(
            tomllib.loads(self.codex_config.read_text())["model"], "unchanged"
        )
        self.assertEqual(tomllib.loads(second_config.read_text())["model"], "other")

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS atomic swap")
    def test_rhapsody_bridge_and_cached_launchers_use_new_storage(self):
        rhapsody = self.home / ".rhapsody/conf.yaml"
        rhapsody.parent.mkdir()
        original = (
            'keep: value\nbridge: "~/.agents/agent-stat/bin/agent-stat-run-end.sh"\n'
        )
        rhapsody.write_text(original)
        self.execute(apply=True)
        self.assertEqual(
            (self.new / "archive/config/.rhapsody/conf.yaml").read_text(), original
        )
        self.assertIn(str(self.new / "bin/agent-stat-run-end.sh"), rhapsody.read_text())
        environment = dict(
            os.environ, HOME=str(self.home), AGENT_STAT_DIR=str(self.old)
        )
        result = subprocess.run(
            [
                "sh",
                str(self.old / "bin/agent-stat-run-end.sh"),
                "11111111-2222-4333-8444-555555555555",
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        today = __import__("time").strftime("%Y-%m-%d")
        records = (self.new / "hosts" / f"{self.host}-{today}.jsonl").read_text()
        self.assertIn('"session":"11111111-2222-4333-8444-555555555555"', records)
        for name in MIGRATION.SCRIPTS:
            self.assertIn(
                "export AGENT_STAT_DIR=", (self.old / "bin" / name).read_text()
            )

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS atomic swap")
    def test_repeated_apply_keeps_all_existing_history(self):
        self.execute(apply=True)
        before = self.tree()
        result = self.execute(apply=True)
        self.assertIn("already complete", result.stdout)
        self.assertEqual(self.tree(), before)
        (self.old / "hosts").unlink()
        self.assertIn("already complete", self.execute(apply=True).stdout)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS atomic swap")
    def test_config_change_after_plan_stops_before_any_mutation(self):
        plan = MIGRATION.Plan(self.home)
        changed = self.claude.read_bytes() + b"\n"
        self.claude.write_bytes(changed)
        with self.assertRaisesRegex(
            MIGRATION.MigrationError, "changed after preflight"
        ):
            plan.apply()
        self.assertEqual(self.claude.read_bytes(), changed)
        self.assertFalse(self.new.exists())

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS atomic swap")
    def test_config_change_during_copy_is_not_overwritten(self):
        plan = MIGRATION.Plan(self.home)
        original = self.claude.read_bytes()
        changed = original + b"\n"
        deploy = MIGRATION.INSTALL.deploy_script

        def concurrent_edit(script, target, apply):
            self.claude.write_bytes(changed)
            return deploy(script, target, apply)

        with mock.patch.object(
            MIGRATION.INSTALL, "deploy_script", side_effect=concurrent_edit
        ):
            with self.assertRaisesRegex(
                MIGRATION.MigrationError, "changed after preflight"
            ):
                plan.apply()
        self.assertEqual(self.claude.read_bytes(), changed)
        self.assertEqual(
            (self.new / "archive/config/.claude/settings.json").read_bytes(), original
        )
        self.assertFalse((self.new / MIGRATION.MARKER).exists())
        self.assertTrue((self.new / "hosts" / self.local_name).is_file())

    def test_invalid_json_stops_before_any_mutation(self):
        self.claude.write_text("bad JSON")
        before = self.tree()
        self.execute(apply=True, success=False)
        self.assertEqual(self.tree(), before)
        self.assertFalse(self.new.exists())

    def test_invalid_toml_stops_before_any_mutation(self):
        self.codex_config.write_text("invalid = [")
        before = self.tree()
        self.execute(apply=True, success=False)
        self.assertEqual(self.tree(), before)
        self.assertFalse(self.new.exists())

    def test_existing_destination_stops_before_any_mutation(self):
        self.new.mkdir(parents=True)
        (self.new / "existing-history").write_bytes(b"preserve")
        before = self.tree()
        self.execute(apply=True, success=False)
        self.assertEqual(self.tree(), before)

    def test_config_symlink_outside_home_stops_before_any_mutation(self):
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / "settings.json"
            target.write_text("{}")
            self.claude.unlink()
            self.claude.symlink_to(target)
            before = self.tree()
            self.execute(apply=True, success=False)
            self.assertEqual(self.tree(), before)
            self.assertFalse(self.new.exists())


if __name__ == "__main__":
    unittest.main()
