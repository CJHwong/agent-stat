#!/usr/bin/env python3
"""Check session names through the hook subprocess and its event files."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HOOK = Path(__file__).resolve().parents[1] / "hooks/agent-stat-hook.sh"
SESSION = "01a1456c-85a3-7312-b94d-5a38b040104f"


class HookTitleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="agent-stat-hook-titles-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.home = self.directory / "home"
        self.profile = self.directory / "profile with spaces"
        self.events = self.directory / "events"
        self.home.mkdir()
        self.profile.mkdir()
        self.environment = os.environ.copy()
        self.environment.update(
            HOME=str(self.home),
            CODEX_HOME=str(self.profile),
            AGENT_STAT_DIR=str(self.events),
            AGENT_HOOK_AGENT_PID=str(os.getpid()),
        )

    def index(self, rows, profile=None):
        directory = self.profile if profile is None else profile
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "session_index.jsonl"
        path.write_text(
            "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows)
        )
        return path

    def records(self):
        filenames = list((self.events / "hosts").glob("*.jsonl"))
        if not filenames:
            return []
        self.assertEqual(len(filenames), 1)
        host = os.uname().nodename.removesuffix(".local")
        self.assertTrue(filenames[0].name.startswith(host + "-"))
        return [json.loads(line) for line in filenames[0].read_text().splitlines()]

    def hook(self, agent="codex", kind="Stop", **fields):
        payload = {"hook_event_name": kind, "session_id": SESSION, "cwd": "/probe"}
        payload.update(fields)
        result = subprocess.run(
            [str(HOOK), agent],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            env=self.environment,
            timeout=2,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "{}\n")
        return self.records()

    def assert_record(self, records, title):
        self.assertTrue(records, "hook drops the event")
        self.assertEqual(records[-1]["title"], title)
        self.assertEqual(records[-1]["session"], SESSION)
        self.assertEqual(records[-1]["cwd"], "/probe")

    def test_custom_profile_with_spaces_supplies_name(self):
        self.index([{"id": SESSION, "thread_name": "Custom profile name"}])
        self.assert_record(self.hook(), "Custom profile name")

    def test_profile_alias_reads_its_symlinked_regular_index(self):
        shared = self.index(
            [{"id": SESSION, "thread_name": "Shared profile name"}],
            self.directory / "shared index",
        )
        (self.profile / "session_index.jsonl").symlink_to(shared)
        self.assert_record(self.hook(), "Shared profile name")

    def test_default_home_supplies_name_when_profile_is_unset(self):
        self.environment.pop("CODEX_HOME")
        self.index(
            [{"id": SESSION, "thread_name": "Default profile name"}],
            self.home / ".codex",
        )
        self.assert_record(self.hook(), "Default profile name")

    def test_empty_profile_uses_default_home(self):
        self.environment["CODEX_HOME"] = ""
        self.index(
            [{"id": SESSION, "thread_name": "Default name"}], self.home / ".codex"
        )
        self.assert_record(self.hook(), "Default name")

    def test_custom_profile_never_reads_default_or_sibling_profile(self):
        self.index(
            [{"id": SESSION, "thread_name": "Wrong default"}], self.home / ".codex"
        )
        self.index(
            [{"id": SESSION, "thread_name": "Wrong sibling"}],
            self.directory / "other profile",
        )
        self.index([{"id": SESSION + "-other", "thread_name": "Wrong session"}])
        self.assert_record(self.hook(), None)

    def test_session_id_match_is_exact(self):
        self.index(
            [
                {"id": SESSION, "thread_name": "Exact session"},
                {"id": SESSION[:-1], "thread_name": "Prefix session"},
                {"id": "prefix-" + SESSION, "thread_name": "Suffix session"},
                {"id": SESSION + "-child", "thread_name": "Child session"},
            ]
        )
        self.assert_record(self.hook(), "Exact session")

    def test_latest_usable_matching_row_wins(self):
        self.index(
            [
                {"id": SESSION, "thread_name": "Original"},
                {"id": "foreign", "thread_name": "Foreign"},
                {"id": SESSION, "thread_name": "Renamed"},
            ]
        )
        self.assert_record(self.hook(), "Renamed")

    def test_late_name_and_rename_appear_on_later_events(self):
        self.assert_record(self.hook(kind="SessionStart"), None)
        path = self.index([{"id": SESSION, "thread_name": "Late name"}])
        self.assert_record(self.hook(kind="PreToolUse", tool_name="Bash"), "Late name")
        with path.open("a") as stream:
            stream.write(json.dumps({"id": SESSION, "thread_name": "Renamed"}) + "\n")
        records = self.hook(kind="PostToolUse", tool_name="Bash")
        self.assert_record(records, "Renamed")
        self.assertEqual(
            [row["event"] for row in records],
            ["SessionStart", "PreToolUse", "PostToolUse"],
        )

    def test_malformed_and_nonobject_rows_do_not_hide_valid_rows(self):
        path = self.index([{"id": SESSION, "thread_name": "Before junk"}])
        with path.open("a") as stream:
            stream.write('not JSON\n{broken\nnull\n[]\n42\n"string"\n\n')
            stream.write(
                json.dumps({"id": SESSION, "thread_name": "After junk"}) + "\n"
            )
        self.assert_record(self.hook(), "After junk")

    def test_empty_null_and_nonstring_names_keep_prior_usable_name(self):
        rows = [{"id": SESSION, "thread_name": "Keep this name"}]
        rows.extend(
            {"id": SESSION, "thread_name": name}
            for name in ["", None, 42, False, {}, []]
        )
        rows.extend(
            [
                {"id": SESSION},
                {"thread_name": "Missing identity"},
                {"id": None, "thread_name": "Null identity"},
            ]
        )
        self.index(rows)
        self.assert_record(self.hook(), "Keep this name")

    def test_invalid_names_without_prior_name_preserve_event(self):
        self.index(
            [
                {"id": SESSION, "thread_name": name}
                for name in [None, "", 7, True, {}, []]
            ]
        )
        self.assert_record(self.hook(), None)

    def test_unicode_index_name_normalizes_record_whitespace(self):
        self.index([{"id": SESSION, "thread_name": "修正\n標題\t內容\r\n完成"}])
        self.assert_record(self.hook(), "修正 標題 內容 完成")

    def test_index_name_caps_characters_without_breaking_unicode(self):
        self.index([{"id": SESSION, "thread_name": "臺灣" * 150}])
        records = self.hook()
        self.assert_record(records, "臺灣" * 100)
        self.assertEqual(len(records[-1]["title"]), 200)

    def test_explicit_nonempty_title_wins(self):
        self.index([{"id": SESSION, "thread_name": "Indexed name"}])
        self.assert_record(self.hook(session_title="Explicit name"), "Explicit name")

    def test_explicit_empty_title_uses_index_name(self):
        self.index([{"id": SESSION, "thread_name": "Indexed name"}])
        self.assert_record(self.hook(session_title=""), "Indexed name")

    def test_missing_index_preserves_event(self):
        self.assert_record(self.hook(), None)

    def test_unreadable_index_preserves_event(self):
        path = self.index([{"id": SESSION, "thread_name": "Unreadable"}])
        path.chmod(0)
        self.addCleanup(path.chmod, 0o600)
        if os.access(path, os.R_OK):
            self.skipTest("current account can read files without permission bits")
        self.assert_record(self.hook(), None)

    def test_index_directory_preserves_event(self):
        (self.profile / "session_index.jsonl").mkdir()
        self.assert_record(self.hook(), None)

    def test_index_fifo_preserves_event_without_waiting_for_writer(self):
        os.mkfifo(self.profile / "session_index.jsonl")
        self.assert_record(self.hook(), None)

    def test_claude_keeps_explicit_title_and_ignores_codex_name(self):
        self.index([{"id": SESSION, "thread_name": "Codex name"}])
        self.assert_record(
            self.hook(agent="claude", session_title="Claude name"), "Claude name"
        )
        self.assert_record(self.hook(agent="claude"), None)

    def test_claude_start_preserves_source(self):
        for source in ["startup", "resume", "clear", "compact"]:
            with self.subTest(source=source):
                records = self.hook(agent="claude", kind="SessionStart", source=source)
                self.assertEqual(records[-1].get("source"), source)

    def test_claude_never_waits_on_codex_fifo(self):
        os.mkfifo(self.profile / "session_index.jsonl")
        self.assert_record(
            self.hook(agent="claude", session_title="Claude name"), "Claude name"
        )

    def test_subagent_tool_stays_suppressed_with_index_name(self):
        self.index([{"id": SESSION, "thread_name": "Parent name"}])
        self.assertEqual(
            self.hook(kind="PreToolUse", agent_id="child", tool_name="Bash"), []
        )
        records = self.hook(kind="SubagentStart", agent_id="child")
        self.assert_record(records, "Parent name")
        self.assertEqual(records[-1]["agent_id"], "child")

    def test_index_read_failure_retries_event_without_index(self):
        real_jq = shutil.which("jq")
        self.assertIsNotNone(real_jq)
        self.index([{"id": SESSION, "thread_name": "Indexed name"}])
        binaries = self.directory / "bin"
        binaries.mkdir()
        marker = self.directory / "jq-failed"
        stub = binaries / "jq"
        stub.write_text(
            "#!/bin/sh\n"
            'case " $* " in\n'
            "  *session_index.jsonl*)\n"
            f'    if [ ! -e "{marker}" ]; then\n'
            f'      : > "{marker}"\n'
            "      exit 1\n"
            "    fi\n"
            "    ;;\n"
            "esac\n"
            f'exec "{real_jq}" "$@"\n'
        )
        stub.chmod(0o755)
        self.environment["PATH"] = str(binaries) + os.pathsep + self.environment["PATH"]
        records = self.hook()
        self.assertTrue(
            marker.exists(), "fixture never triggers the indexed jq failure"
        )
        self.assert_record(records, None)


if __name__ == "__main__":
    unittest.main()
