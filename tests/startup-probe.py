#!/usr/bin/env python3
"""Check actual app startup against isolated remote cache and saved row memory."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

REPOSITORY = Path(__file__).resolve().parents[1]
HARNESS = r"""
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let now = Int(Date().timeIntervalSince1970)
    precondition(delegate.store.dismissed.count == 1, "startup discarded the remote dismissal")
    precondition(delegate.store.acknowledged.count == 1, "startup discarded the remote acknowledgement")
    precondition(delegate.store.visible(now: now).isEmpty, "a dismissed remote row returned after startup")
    precondition(delegate.store.attentionCount(now: now) == 0, "an acknowledged remote row restored attention")
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    print("PASS actual AppDelegate startup preserves remote dismissals and acknowledgements")
}
"""


def main():
    with tempfile.TemporaryDirectory(prefix="agent-stat-startup-") as folder:
        root = Path(folder)
        host, session = "review-peer", "saved"
        events = root / "events"
        cache = events / "remote" / host / "hosts"
        cache.mkdir(parents=True)
        now = int(time.time())
        filename = f"{host}-2026-10-23.jsonl"
        record = json.dumps({"ts": now, "event": "Stop", "session": session}) + "\n"
        (cache / filename).write_text(record)
        position = {"file": filename, "offset": len(record.encode())}
        key = f"{host}/{session}"
        memory = root / "memory.json"
        memory.write_text(
            json.dumps(
                {
                    "dismissed": {key: now},
                    "acknowledged": {key: now},
                    "dismissedPositions": {key: position},
                    "acknowledgedPositions": {key: position},
                }
            )
        )
        routes = root / "routes.json"
        routes.write_text(json.dumps({host: {"events": ["/usr/bin/true"]}}))
        source = (REPOSITORY / "src/main.swift").read_text()
        main_file = root / "main.swift"
        main_file.write_text(
            source.rsplit("\nMainActor.assumeIsolated {", 1)[0] + HARNESS
        )
        binary = root / "startup-probe"
        subprocess.run(
            [
                "swiftc",
                "-o",
                str(binary),
                str(main_file),
                *[
                    str(path)
                    for path in sorted((REPOSITORY / "src").glob("*.swift"))
                    if path.name != "main.swift"
                ],
                "-framework",
                "AppKit",
                "-framework",
                "SwiftUI",
            ],
            check=True,
            timeout=90,
        )
        subprocess.run(
            [str(binary)],
            env={
                **os.environ,
                "AGENT_STAT_DIR": str(events),
                "AGENT_STAT_MEMORY": str(memory),
                "AGENT_STAT_ROUTES": str(routes),
                "AGENT_STAT_SHOW_PANEL": "0",
            },
            check=True,
            timeout=15,
        )
    print("Temporary startup files removed")


if __name__ == "__main__":
    main()
