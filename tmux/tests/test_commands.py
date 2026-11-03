from pathlib import Path
import struct
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import process_commands as commands


class CommandTests(unittest.TestCase):
    def test_kernel_parser_excludes_environment(self):
        payload = (
            struct.pack("i", 3)
            + b"/bin/tool\0\0tool\0two words\0; touch nope\0SECRET=private\0"
        )
        self.assertEqual(
            commands.parse_procargs(payload), ["tool", "two words", "; touch nope"]
        )

    def test_exact_arguments_keep_spaces_and_shell_characters(self):
        arguments = [
            sys.executable,
            "-c",
            "import time;time.sleep(30)",
            "two words",
            "; touch nope",
            "",
        ]
        process = subprocess.Popen(arguments)
        try:
            self.assertEqual(commands.process_arguments(process.pid), arguments)
        finally:
            process.terminate()
            process.wait()

    def test_secrets_shells_and_agents_do_not_offer_plain_rerun(self):
        for arguments in [
            ["tool", "--token", "private"],
            ["tool", "--password=private"],
            ["tool", "https://user:pass@example.test"],
            ["zsh"],
            ["claude"],
            ["codex"],
        ]:
            self.assertEqual(commands.replay_arguments({"command_argv": arguments}), [])
        self.assertNotIn(
            "private", commands.redact_command("tool --token 'private text'")
        )


if __name__ == "__main__":
    unittest.main()
