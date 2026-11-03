import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_stat_reader import EventReader, belongs_to_pane

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / "hosts").mkdir()
    filename = root / "hosts/test-2026-11-03.jsonl"
    reader = EventReader(root, "test")

    def event(name, **fields):
        record = {
            "session": "conversation",
            "event": name,
            "ts": 1,
            "agent": "claude",
            "tmux": "%1",
            "agent_pid": 12,
        }
        record.update(fields)
        with filename.open("a") as stream:
            stream.write(json.dumps(record) + "\n")
        return reader.update()["conversation"]

    assert event("SessionStart")["state"] == "idle"
    assert event("UserPromptSubmit")["state"] == "working"
    assert event("PermissionRequest")["state"] == "waiting"
    assert event("PostToolUse")["state"] == "working"
    event("SubagentStart", agent_id="child")
    record = event("Stop")
    assert record["state"] == "done" and record["children"] == {"child"}
    assert reader.update()["conversation"]["children"] == {"child"}
    assert not event("SubagentStop", agent_id="child")["children"]
    first_completion = reader.sessions["conversation"]["completion"]
    assert event("Stop")["completion"] != first_completion
    assert event("StopFailure")["state"] == "failed"
    assert event("SessionEnd")["state"] == "failed"
    assert event("Interrupt")["state"] == "interrupted"
    assert event("SessionEnd")["state"] == "closed"
    with filename.open("a") as stream:
        stream.write('{broken}\n{"session":"partial"')
    assert "partial" not in reader.update()
    with filename.open("a") as stream:
        stream.write(',"event":"Stop","ts":2}\n')
    assert reader.update()["partial"]["state"] == "done"
    foreign = root / "hosts/foreign-2026-11-03.jsonl"
    foreign.write_text('{"session":"foreign","event":"Stop"}\n')
    assert "foreign" not in reader.update()
    filename.write_text('{"session":"replacement","event":"SessionStart","ts":3}\n')
    assert set(reader.update()) == {"replacement"}
processes = {12: (11, "start"), 11: (1, "parent"), 1: (0, "root")}
assert belongs_to_pane({"pid": 12, "start": "start"}, 11, processes)
assert not belongs_to_pane({"pid": 12, "start": "old"}, 11, processes)
assert not belongs_to_pane({"pid": 12}, 99, processes)
print(
    "PASS: event states, subagents, incremental reads, partial lines, rotation, host isolation, and process identity"
)
