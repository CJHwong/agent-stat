#!/usr/bin/env python3
"""Check the remote install against a fake ssh that runs the other end here."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]

# The fake ssh drops this environment, the way a real login on another machine
# starts clean, and runs the remote command in a home of its own. A Mac login
# shell is zsh, where some names a plain sh allows are read-only.
FAKE_SSH = """#!/bin/sh
printf '%s\\n' "$@" > "$FAKE_HOME/ssh-args"
host=$2
command=$3
exec env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin /bin/zsh -c "$command"
"""


class RemoteInstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        tools = self.root / "tools"
        tools.mkdir()
        ssh = tools / "ssh"
        ssh.write_text(FAKE_SSH)
        ssh.chmod(0o755)
        self.environment = dict(
            os.environ, PATH=f"{tools}:{os.environ['PATH']}", FAKE_HOME=str(self.home)
        )

    def install(self, *arguments):
        return subprocess.run(
            ["python3", str(REPO / "install.py"), *arguments],
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def test_dry_run_writes_nothing_on_the_other_machine(self):
        result = self.install("--remote", "peer")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry run. nothing written", result.stdout)
        self.assertEqual(
            (self.home / "ssh-args").read_text().splitlines()[:2], ["-T", "peer"]
        )
        self.assertFalse((self.home / ".local").exists())

    def test_apply_deploys_into_the_other_home_and_leaves_no_copy(self):
        result = self.install("--remote", "peer", "--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        deployed = self.home / ".local/state/agent-stat/bin"
        for name in ("agent-stat-hook.sh", "agent-stat-run-end.sh", "stream-events.py"):
            self.assertEqual(
                (deployed / name).read_bytes(),
                next(REPO.glob(f"*/{name}")).read_bytes(),
            )
        self.assertTrue((self.home / ".claude/settings.json").exists())
        self.assertTrue((self.home / ".codex/config.toml").exists())
        self.assertNotIn(str(REPO), (self.home / ".codex/hooks.json").read_text())
        temporary = Path(
            result.stdout.split("hook script : ", 1)[1].split("/hooks/", 1)[0]
        )
        self.assertFalse(temporary.exists(), "the copy on the other machine is removed")

    def test_a_host_that_reads_as_an_option_is_refused(self):
        result = self.install("--remote", "-oProxyCommand=true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / "ssh-args").exists())

    def test_local_config_flags_do_not_mix_with_a_remote(self):
        result = self.install("--remote", "peer", "--codex-home", str(self.root))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / "ssh-args").exists())


if __name__ == "__main__":
    unittest.main()
