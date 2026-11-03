import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("tmux_install", ROOT / "install.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)


class InstallTests(unittest.TestCase):
    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            INSTALL.install(home, Path("/usr/bin/python3"))
            self.assertEqual(list(home.iterdir()), [])

    def test_apply_preserves_config_and_adds_no_hooks(self):
        with tempfile.TemporaryDirectory(prefix="tmux home ") as directory:
            home = Path(directory)
            (home / ".tmux.conf").write_text("set -g mouse on\n")
            hooks = home / ".claude/settings.json"
            hooks.parent.mkdir()
            hooks.write_text('{"hooks":{}}\n')
            INSTALL.install(home, Path("/usr/bin/python3"), apply=True)
            INSTALL.install(home, Path("/usr/bin/python3"), apply=True)
            config = (home / ".tmux.conf").read_text()
            self.assertTrue(config.startswith("set -g mouse on\n"))
            self.assertEqual(config.count("source-file"), 1)
            self.assertEqual(hooks.read_text(), '{"hooks":{}}\n')
            deployed = home / ".agents/tmux"
            self.assertTrue(all((deployed / name).exists() for name in INSTALL.SCRIPTS))
            rendered = (home / ".config/tmux/window-sidebar.conf").read_text()
            self.assertNotIn("@SIDEBAR_COMMAND@", rendered)
            self.assertIn(str(deployed), rendered)


if __name__ == "__main__":
    unittest.main()
