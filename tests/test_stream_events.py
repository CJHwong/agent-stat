#!/usr/bin/env python3
"""Check the stream helper with separate producer and consumer processes."""

import base64
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / "scripts/stream-events.py"
HOST = "stream-test"
TODAY = f"{HOST}-2026-10-23.jsonl"
SPEC = importlib.util.spec_from_file_location("stream_events", HELPER)
STREAM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STREAM)


def record(session="sample", pid=None, **extra):
    event = {"session": session, "agent_pid": pid or os.getpid(), "ts": time.time()}
    event.update(extra)
    return json.dumps(event, ensure_ascii=False).encode() + b"\n"


def cursor(content):
    return {"offset": len(content), "tail": hashlib.sha256(content[-4096:]).hexdigest()}


class Consumer:
    def __init__(
        self,
        directory,
        offsets=None,
        home=None,
        file_limit=None,
        progress=None,
        restore_delay=0,
    ):
        arguments = [
            sys.executable,
            str(HELPER),
            "--directory",
            str(directory),
            "--host",
            HOST,
            "--interval",
            "0.02",
            "--heartbeat",
            "0.08",
        ]
        if restore_delay:
            wrapper = """
import importlib.util,sys,time
delay = float(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("helper", sys.argv[1])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
remember = helper.remember_sessions
def slow_history(content, sessions):
    time.sleep(delay)
    remember(content, sessions)
helper.remember_sessions = slow_history
sys.argv = sys.argv[1:]
raise SystemExit(helper.main())
"""
            arguments = [
                sys.executable,
                "-c",
                wrapper,
                str(restore_delay),
                *arguments[1:],
            ]
        if file_limit is not None:
            wrapper = "import os,resource,sys; resource.setrlimit(resource.RLIMIT_NOFILE,(int(sys.argv[1]),int(sys.argv[1]))); os.execv(sys.argv[2],sys.argv[2:])"
            arguments = [sys.executable, "-c", wrapper, str(file_limit), *arguments]
        environment = None
        if home:
            environment = {**os.environ, "HOME": str(home)}
            environment.pop("CODEX_HOME", None)
        self.process = subprocess.Popen(
            arguments,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        self.frames = queue.Queue()
        self.timeline = []
        self.thread = threading.Thread(target=self.read_frames, daemon=True)
        self.thread.start()
        request = {"protocol": 1, "offsets": offsets or {}}
        if progress is not None:
            request["progress"] = progress
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()

    def read_frames(self):
        for line in self.process.stdout:
            frame = json.loads(line)
            self.timeline.append((time.monotonic(), frame["type"]))
            self.frames.put(frame)

    def next(self, kind=None, timeout=4):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frame = self.frames.get(timeout=max(0.01, deadline - time.monotonic()))
            if kind is None or frame["type"] == kind:
                return frame
        raise AssertionError(f"no {kind} frame")

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
        self.process.wait(timeout=3)
        self.thread.join(timeout=3)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if not stream.closed:
                stream.close()


class StreamEventsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.hosts = self.directory / "hosts"
        self.hosts.mkdir()

    def start(self, offsets=None):
        consumer = Consumer(self.directory, offsets)
        self.addCleanup(consumer.close)
        return consumer

    def write(self, filename=TODAY, content=None):
        path = self.hosts / filename
        path.write_bytes(record() if content is None else content)
        return path

    def assert_error(self, consumer, fragment):
        error = consumer.next("error")
        self.assertIn(fragment, error["error"])
        self.assertEqual(consumer.process.wait(timeout=3), 1)
        self.assertIn(fragment, consumer.process.stderr.read())

    def test_unchanged_log_does_not_reopen_or_hash_its_tail(self):
        path = self.write()
        if path.stat().st_ctime_ns % 1_000_000_000 == 0:
            self.skipTest("coarse change timestamps require the full validation path")
        sessions = {}
        source = STREAM.LogCursor(path, None, sessions)
        with mock.patch.object(STREAM, "emit"):
            source.send_pending(sessions)
        with mock.patch.object(
            source, "open", side_effect=AssertionError("idle reopen")
        ):
            with mock.patch.object(
                STREAM, "tail_digest", side_effect=AssertionError("idle tail read")
            ):
                source.send_pending(sessions)

    def test_same_size_rewrite_with_restored_mtime_is_rejected(self):
        content = record(session="before")
        path = self.write(content=content)
        sessions = {}
        source = STREAM.LogCursor(path, None, sessions)
        with mock.patch.object(STREAM, "emit"):
            source.send_pending(sessions)
        original = path.stat()
        path.write_bytes(content.replace(b"before", b"after!"))
        os.utime(path, ns=(original.st_atime_ns, original.st_mtime_ns))
        self.assertEqual(path.stat().st_mtime_ns, original.st_mtime_ns)
        with self.assertRaisesRegex(STREAM.StreamError, "changed before the cursor"):
            source.send_pending(sessions)

    def test_coarse_change_timestamps_still_check_the_source_tail(self):
        content = record(session="before")
        path = self.write(content=content)
        original = path.stat()
        real_stat, real_fstat = os.stat, os.fstat

        def coarse(info):
            return SimpleNamespace(
                st_dev=info.st_dev,
                st_ino=info.st_ino,
                st_mode=info.st_mode,
                st_size=info.st_size,
                st_mtime_ns=info.st_mtime_ns,
                st_ctime_ns=original.st_ctime_ns // 1_000_000_000 * 1_000_000_000,
            )

        with (
            mock.patch.object(
                STREAM.os,
                "stat",
                side_effect=lambda *args, **kwargs: coarse(real_stat(*args, **kwargs)),
            ),
            mock.patch.object(
                STREAM.os,
                "fstat",
                side_effect=lambda descriptor: coarse(real_fstat(descriptor)),
            ),
            mock.patch.object(STREAM, "emit"),
        ):
            sessions = {}
            source = STREAM.LogCursor(path, None, sessions)
            source.send_pending(sessions)
            path.write_bytes(content.replace(b"before", b"after!"))
            os.utime(path, ns=(original.st_atime_ns, original.st_mtime_ns))
            with self.assertRaisesRegex(
                STREAM.StreamError, "changed before the cursor"
            ):
                source.send_pending(sessions)

    def test_append_during_send_remains_pending_for_the_next_scan(self):
        first = record(session="first")
        later = record(session="later")
        path = self.write(content=first)
        sessions = {}
        source = STREAM.LogCursor(path, None, sessions)
        frames = []

        def append_during_emit(frame):
            frames.append(frame)
            with path.open("ab") as stream:
                stream.write(later)

        with mock.patch.object(STREAM, "emit", side_effect=append_during_emit):
            source.send_pending(sessions)
        self.assertEqual(len(frames), 1)
        self.assertEqual(source.offset, len(first))
        with mock.patch.object(STREAM, "emit", side_effect=frames.append):
            source.send_pending(sessions)
        self.assertEqual(len(frames), 2)
        self.assertEqual(frames[1]["offset"], len(first))
        self.assertEqual(base64.b64decode(frames[1]["content"]), later)
        self.assertEqual(path.read_bytes(), first + later)

    def test_unchanged_partial_line_waits_without_reopening(self):
        first = record(session="first")
        second = record(session="second")
        path = self.write(content=first + second[:-1])
        if path.stat().st_ctime_ns % 1_000_000_000 == 0:
            self.skipTest("coarse change timestamps require the full validation path")
        sessions = {}
        source = STREAM.LogCursor(path, None, sessions)
        frames = []
        with mock.patch.object(STREAM, "emit", side_effect=frames.append):
            source.send_pending(sessions)
            with mock.patch.object(
                source, "open", side_effect=AssertionError("idle reopen")
            ):
                source.send_pending(sessions)
            with path.open("ab") as stream:
                stream.write(b"\n")
            source.send_pending(sessions)
        self.assertEqual(len(frames), 2)
        self.assertEqual(frames[1]["offset"], len(first))
        self.assertEqual(base64.b64decode(frames[1]["content"]), second)

    def test_requested_progress_keeps_slow_cached_restore_alive(self):
        home = tempfile.TemporaryDirectory(prefix="agent-stat-helper-home-")
        self.addCleanup(home.cleanup)
        history = b"".join(record(session="cached") for _ in range(40))
        appended = record(session="appended", message="繁體中文")
        path = self.write(content=history + appended)
        consumer = Consumer(
            self.directory,
            {TODAY: cursor(history)},
            home=Path(home.name),
            progress=True,
            restore_delay=0.01,
        )
        self.addCleanup(consumer.close)
        frames = []
        while True:
            frame = consumer.next()
            frames.append(frame)
            if frame["type"] == "status":
                break
        consumer.close()
        self.assertEqual(frames[0]["type"], "hello")
        progress = [frame for frame in frames if frame["type"] == "progress"]
        self.assertGreaterEqual(len(progress), 3)
        for frame in progress:
            self.assertEqual(set(frame), {"type", "time"})
            self.assertIs(type(frame["time"]), int)
        times = [when for when, _ in consumer.timeline[: len(frames)]]
        self.assertTrue(
            all(later - earlier < 0.3 for earlier, later in zip(times, times[1:]))
        )
        chunks = [frame for frame in frames if frame["type"] == "chunk"]
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0]["offset"], len(history))
        self.assertEqual(base64.b64decode(chunks[0]["content"]), appended)
        self.assertEqual(frames[-1]["alive"], {"cached": True, "appended": True})
        self.assertEqual(path.read_bytes(), history + appended)
        self.assertEqual(set(self.directory.iterdir()), {self.hosts})
        self.assertEqual(set(self.hosts.iterdir()), {path})

    def test_legacy_and_declined_progress_receive_no_extra_frames(self):
        history = b"".join(record() for _ in range(20))
        self.write(content=history)
        for requested in [None, False]:
            with self.subTest(progress=requested):
                consumer = Consumer(
                    self.directory,
                    {TODAY: cursor(history)},
                    home=self.directory,
                    progress=requested,
                    restore_delay=0.01,
                )
                self.addCleanup(consumer.close)
                self.assertEqual(consumer.next()["type"], "hello")
                self.assertEqual(consumer.next()["type"], "status")
                consumer.close()

    def test_progress_negotiation_requires_a_boolean(self):
        consumer = Consumer(self.directory, progress=1)
        self.addCleanup(consumer.close)
        self.assert_error(consumer, "progress must be a boolean")

    def test_history_exceeds_the_open_file_limit_and_still_appends(self):
        paths = []
        for number in range(85):
            day = datetime.date(2026, 1, 1) + datetime.timedelta(days=number)
            paths.append(
                self.write(
                    filename=f"{HOST}-{day}.jsonl", content=record(session=str(number))
                )
            )
        consumer = Consumer(self.directory, file_limit=64)
        self.addCleanup(consumer.close)
        received = set()
        for _ in paths:
            received.add(consumer.next("chunk")["file"])
        self.assertEqual(received, {path.name for path in paths})
        consumer.next("status")
        with paths[0].open("ab") as stream:
            stream.write(record(session="late append"))
        chunk = consumer.next("chunk")
        self.assertEqual(chunk["file"], paths[0].name)
        self.assertEqual(
            json.loads(base64.b64decode(chunk["content"]))["session"], "late append"
        )
        consumer.next("status")
        consumer.close()
        resumed = Consumer(
            self.directory,
            offsets={path.name: cursor(path.read_bytes()) for path in paths},
            file_limit=64,
        )
        self.addCleanup(resumed.close)
        self.assertTrue(resumed.next("status")["alive"]["late append"])

    def test_profile_names_use_the_latest_timestamp(self):
        self.write(content=record(agent="codex", session="quiet", event="Stop"))
        for profile, name, updated in [
            (".codex", "Newest", "2026-10-23T00:00:00.100Z"),
            (".codex-old", "Stale", "2026-10-23T00:00:00Z"),
        ]:
            directory = self.directory / profile
            directory.mkdir()
            (directory / "session_index.jsonl").write_text(
                json.dumps({"id": "quiet", "thread_name": name, "updated_at": updated})
                + "\n"
            )
        consumer = Consumer(self.directory, home=self.directory)
        self.addCleanup(consumer.close)
        self.assertEqual(consumer.next("status")["titles"], {"quiet": "Newest"})
        (self.directory / ".codex-old/session_index.jsonl").write_text(
            json.dumps(
                {
                    "id": "quiet",
                    "thread_name": "Renamed",
                    "updated_at": "2026-10-24T00:00:00Z",
                }
            )
            + "\n"
        )
        for _ in range(20):
            status = consumer.next("status")
            if status["titles"].get("quiet") == "Renamed":
                break
        self.assertEqual(status["titles"], {"quiet": "Renamed"})

    def test_status_backfills_and_refreshes_quiet_codex_names(self):
        self.write(content=record(agent="codex", session="quiet", event="Stop"))
        profile = self.directory / ".codex"
        profile.mkdir()
        index = profile / "session_index.jsonl"
        index.write_text('{"id":"quiet","thread_name":"First name"}\n')
        consumer = Consumer(self.directory, home=self.directory)
        self.addCleanup(consumer.close)
        self.assertEqual(consumer.next("status")["titles"], {"quiet": "First name"})
        index.write_text('broken\n[]\n{"id":"quiet","thread_name":"Renamed"}\n')
        for _ in range(20):
            status = consumer.next("status")
            if status.get("titles", {}).get("quiet") == "Renamed":
                break
        self.assertEqual(status["titles"], {"quiet": "Renamed"})
        self.assertEqual(len((self.hosts / TODAY).read_bytes().splitlines()), 1)

    def test_titles_cover_quiet_sessions_past_the_alive_window(self):
        old = time.time() - 13 * 3600
        self.write(content=record(agent="codex", session="old", event="Stop", ts=old))
        profile = self.directory / ".codex"
        profile.mkdir()
        (profile / "session_index.jsonl").write_text(
            json.dumps({"id": "old", "thread_name": "A quiet name"}) + "\n"
        )
        consumer = Consumer(self.directory, home=self.directory)
        self.addCleanup(consumer.close)
        self.assertEqual(consumer.next("status")["titles"], {"old": "A quiet name"})

    def test_title_falls_back_to_the_first_user_message(self):
        old = time.time() - 13 * 3600
        self.write(content=record(agent="codex", session="quiet", event="Stop", ts=old))
        profile = self.directory / ".codex"
        rollout = profile / "sessions/2026/10/23"
        rollout.mkdir(parents=True)
        (rollout / "rollout-2026-10-23T00-00-00-quiet.jsonl").write_text(
            json.dumps(
                {
                    "type": "response_item",
                    "payload": {
                        "type": "message",
                        "role": "user",
                        "content": [
                            {"type": "input_text", "text": "Imagine a tiny helper"}
                        ],
                    },
                }
            )
            + "\n"
        )
        consumer = Consumer(self.directory, home=self.directory)
        self.addCleanup(consumer.close)
        self.assertEqual(
            consumer.next("status")["titles"], {"quiet": "Imagine a tiny helper"}
        )

    def test_stream_uses_byte_offsets_and_complete_lines(self):
        first = record(message="繁體中文")
        second = record(session="second")
        path = self.write(content=first + second[:-1])
        consumer = self.start()
        self.assertEqual(consumer.next("hello")["host"], HOST)
        chunk = consumer.next("chunk")
        self.assertEqual(chunk["offset"], 0)
        self.assertEqual(base64.b64decode(chunk["content"]), first)
        consumer.next("status")
        with path.open("ab") as stream:
            stream.write(b"\n")
        appended = consumer.next("chunk")
        self.assertEqual(appended["offset"], len(first))
        self.assertEqual(base64.b64decode(appended["content"]), second)

    def test_reconnect_skips_history_and_preserves_session_liveness(self):
        first = record()
        self.write(content=first)
        consumer = self.start({TODAY: cursor(first)})
        consumer.next("hello")
        status = consumer.next()
        self.assertEqual(status["type"], "status")
        self.assertTrue(status["alive"]["sample"])

    def test_reconnect_streams_only_appended_bytes(self):
        first = record(message="中文")
        second = record("new")
        path = self.write(content=first)
        first_consumer = self.start()
        first_consumer.next("status")
        first_consumer.close()
        with path.open("ab") as stream:
            stream.write(second)
        consumer = self.start({TODAY: cursor(first)})
        chunk = consumer.next("chunk")
        self.assertEqual(chunk["offset"], len(first))
        self.assertEqual(base64.b64decode(chunk["content"]), second)
        self.assertEqual(set(consumer.next("status")["alive"]), {"sample", "new"})

    def test_matching_process_start_is_alive(self):
        started = subprocess.check_output(
            ["ps", "-p", str(os.getpid()), "-o", "lstart="], text=True
        ).strip()
        self.write(content=record(agent_start=started))
        self.assertTrue(self.start().next("status")["alive"]["sample"])

    def test_later_events_preserve_process_start(self):
        self.write(content=record(agent_start="wrong start") + record(event="Stop"))
        status = self.start().next("status")
        self.assertIs(type(status["time"]), int)
        self.assertFalse(status["alive"]["sample"])

    def test_run_end_preserves_process_identity(self):
        started = subprocess.check_output(
            ["ps", "-p", str(os.getpid()), "-o", "lstart="], text=True
        ).strip()
        ended = (
            json.dumps(
                {"session": "sample", "ts": time.time(), "event": "RunEnd"}
            ).encode()
            + b"\n"
        )
        self.write(content=record(agent_start=started) + record(event="Stop") + ended)
        self.assertTrue(self.start().next("status")["alive"]["sample"])

    def test_child_event_preserves_parent_process_identity(self):
        self.write(content=record() + record(agent_id="child", agent_pid=2147483647))
        self.assertTrue(self.start().next("status")["alive"]["sample"])

    def test_child_event_does_not_create_parent_identity(self):
        self.write(content=record(agent_id="child"))
        self.assertNotIn("sample", self.start().next("status")["alive"])

    def test_cursor_beyond_end_is_rejected(self):
        self.write(content=b"")
        self.assert_error(self.start({TODAY: cursor(b"missing\n")}), "shorter")

    def test_boolean_cursor_is_rejected(self):
        saved = cursor(b"")
        saved["offset"] = True
        self.assert_error(self.start({TODAY: saved}), "nonnegative integer")

    def test_rollover_ignores_foreign_and_conflict_files(self):
        self.write("other-2026-10-23.jsonl", b"invalid\n")
        self.write(f"{HOST}-2026-10-23.sync-conflict.jsonl", b"invalid\n")
        consumer = self.start()
        consumer.next("status")
        expected = record()
        self.write(f"{HOST}-2026-10-24.jsonl", expected)
        chunk = consumer.next("chunk")
        self.assertEqual(chunk["file"], f"{HOST}-2026-10-24.jsonl")
        self.assertEqual(base64.b64decode(chunk["content"]), expected)

    def test_files_are_sent_in_name_order(self):
        self.write(f"{HOST}-2026-10-24.jsonl")
        self.write()
        consumer = self.start()
        self.assertEqual(consumer.next("chunk")["file"], TODAY)
        self.assertEqual(consumer.next("chunk")["file"], f"{HOST}-2026-10-24.jsonl")

    def test_wrong_tail_is_rejected(self):
        first = record()
        self.write(content=first)
        saved = cursor(first)
        saved["tail"] = "0" * 64
        self.assert_error(self.start({TODAY: saved}), "saved cursor")

    def test_cursor_inside_line_is_rejected(self):
        first = record()
        self.write(content=first)
        self.assert_error(self.start({TODAY: cursor(first[:-1])}), "newline boundary")

    def test_missing_file_is_rejected(self):
        self.assert_error(self.start({TODAY: cursor(b"")}), "missing")

    def test_foreign_cursor_is_rejected(self):
        self.assert_error(self.start({"../secret": cursor(b"")}), "invalid filename")

    def test_malformed_record_is_rejected_before_transmission(self):
        self.write(content=b"not json\n")
        consumer = self.start()
        consumer.next("hello")
        self.assertEqual(consumer.next()["type"], "error")
        self.assertEqual(consumer.process.wait(timeout=3), 1)

    def test_source_truncation_is_rejected(self):
        path = self.write()
        consumer = self.start()
        consumer.next("status")
        path.write_bytes(b"")
        self.assert_error(consumer, "truncated")

    def test_source_replacement_is_rejected(self):
        path = self.write()
        consumer = self.start()
        consumer.next("status")
        replacement = self.hosts / "replacement"
        replacement.write_bytes(path.read_bytes())
        replacement.replace(path)
        self.assert_error(consumer, "replaced")

    def test_source_rewrite_is_rejected(self):
        path = self.write(content=record(session="old-session"))
        consumer = self.start()
        consumer.next("status")
        path.write_bytes(path.read_bytes().replace(b"old-session", b"new-session"))
        self.assert_error(consumer, "changed before")

    def test_symbolic_source_is_rejected(self):
        target = self.directory / "outside.jsonl"
        target.write_bytes(record())
        (self.hosts / TODAY).symlink_to(target)
        self.assert_error(self.start(), "symbolic link")

    def test_record_larger_than_chunk_is_rejected(self):
        self.write(content=record(message="a" * 65536))
        self.assert_error(self.start(), "64 KiB")

    def test_large_catchup_uses_bounded_chunks(self):
        expected = b"".join(
            record(str(index), message="繁體" * 20) for index in range(1200)
        )
        self.write(content=expected)
        consumer = self.start()
        received = bytearray()
        while True:
            frame = consumer.next()
            if frame["type"] == "status":
                break
            if frame["type"] != "chunk":
                continue
            self.assertEqual(frame["offset"], len(received))
            content = base64.b64decode(frame["content"])
            self.assertLessEqual(len(content), 65536)
            self.assertTrue(content.endswith(b"\n"))
            received.extend(content)
        self.assertEqual(received, expected)

    def test_separate_writer_process_is_followed_until_process_exit(self):
        producer_code = """
import json, os, pathlib, sys, time
path = pathlib.Path(sys.argv[1])
with path.open('ab') as stream:
    for number in range(6):
        record = {'ts': time.time(), 'session': 'producer', 'agent_pid': os.getpid(), 'number': number}
        stream.write((json.dumps(record) + '\\n').encode())
        stream.flush()
        time.sleep(0.05)
time.sleep(0.3)
"""
        consumer = self.start()
        consumer.next("status")
        producer = subprocess.Popen(
            [sys.executable, "-c", producer_code, str(self.hosts / TODAY)]
        )
        self.addCleanup(lambda: producer.poll() is None and producer.kill())
        numbers = []
        saw_alive = False
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            frame = consumer.next()
            if frame["type"] == "chunk":
                numbers.extend(
                    json.loads(line)["number"]
                    for line in base64.b64decode(frame["content"]).splitlines()
                )
            if frame["type"] == "status":
                saw_alive |= frame["alive"].get("producer", False)
            if len(numbers) == 6 and saw_alive:
                break
        self.assertEqual(numbers, list(range(6)))
        self.assertTrue(saw_alive)
        producer.wait(timeout=3)
        while consumer.next("status")["alive"].get("producer"):
            self.assertLess(time.monotonic(), deadline)

    def test_old_session_start_keeps_identity_for_recent_events(self):
        started = record(agent_start="wrong start", ts=time.time() - 13 * 3600)
        self.write(content=started + record(event="Stop"))
        self.assertFalse(self.start().next("status")["alive"]["sample"])

    def test_process_start_mismatch_and_old_session_are_not_alive(self):
        self.write(
            content=record(agent_start="wrong start")
            + record("expired", ts=time.time() - 13 * 3600)
        )
        status = self.start().next("status")
        self.assertFalse(status["alive"]["sample"])
        self.assertNotIn("expired", status["alive"])


if __name__ == "__main__":
    unittest.main()
