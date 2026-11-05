"""Check tmux server identity with synthetic hook environments."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HOOK = Path(__file__).resolve().parents[1] / "hooks/agent-stat-hook.sh"


class HookNavigationTests(unittest.TestCase):
    def record(self, socket):
        with tempfile.TemporaryDirectory(
            prefix="agent-stat-hook-navigation-"
        ) as folder:
            root = Path(folder)
            environment = os.environ | {
                "AGENT_STAT_DIR": str(root),
                "AGENT_HOOK_AGENT_PID": "1",
                "TMUX": socket,
                "TMUX_PANE": "%7",
            }
            payload = {
                "hook_event_name": "SessionStart",
                "session_id": "synthetic",
                "cwd": "/work",
            }
            result = subprocess.run(
                [str(HOOK), "claude"],
                input=json.dumps(payload),
                text=True,
                capture_output=True,
                env=environment,
                timeout=3,
                check=True,
            )
            self.assertEqual(result.stdout.strip(), "{}")
            files = list((root / "hosts").glob("*.jsonl"))
            self.assertEqual(len(files), 1)
            return json.loads(files[0].read_text())

    def test_server_socket_preserves_commas(self):
        record = self.record("/tmp/synthetic,socket,123,0")
        self.assertEqual(record["tmux_socket"], "/tmp/synthetic,socket")
        self.assertEqual(record["tmux"], "%7")

    def test_missing_server_is_optional(self):
        self.assertIsNone(self.record("")["tmux_socket"])


if __name__ == "__main__":
    unittest.main()
