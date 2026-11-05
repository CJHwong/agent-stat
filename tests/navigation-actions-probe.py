#!/usr/bin/env python3
"""Check real panel navigation with isolated records and synthetic tmux commands."""

from pathlib import Path
import json
import os
import subprocess
import tempfile

repository = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="jump-actions-") as directory:
    root = Path(directory)
    wrapper = root / "tmux.sh"
    wrapper.write_text("""#!/bin/sh
cd "$(dirname "$0")" || exit 1
label=$1
shift
case "$1" in
list-panes) if [ "$label" = slow ]; then sleep 0.5; fi
printf '%%1,@1,1,/work\\n' ;;
select-window) printf 'agent-stat-window-selected\\n'
case " $* " in *' select-pane '*) printf '%s\\n' "$label" >> trace ;; *) exit 1 ;; esac ;;
esac
""")
    routes = {
        host: {"tmux": ["/bin/sh", str(wrapper), host]} for host in ["slow", "fast"]
    }
    (root / "routes.json").write_text(json.dumps(routes))
    source = (
        (repository / "src/main.swift")
        .read_text()
        .rsplit("\nMainActor.assumeIsolated {", 1)[0]
    )
    source += """
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let now = Int(Date().timeIntervalSince1970)
    for host in ["slow", "fast", "missing"] {
        let encoded = try! JSONSerialization.data(withJSONObject: ["ts": now, "event": "Stop", "session": host,
                                                                  "cwd": "/work", "tmux": "%1"])
        delegate.store.apply(try! JSONDecoder().decode(Record.self, from: encoded), host: host)
    }
    let missing = delegate.store.sessions[SessionKey(host: "missing", id: "missing")]!
    delegate.jump(to: missing)
    let failedDeadline = Date(timeIntervalSinceNow: 2)
    while delegate.model.status == nil && Date() < failedDeadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
    precondition(!delegate.store.isAcknowledged(missing), "a failed jump must retain attention")
    print("PASS a failed jump retains the session attention marker")
    delegate.jump(to: delegate.store.sessions[SessionKey(host: "slow", id: "slow")]!)
    delegate.jump(to: delegate.store.sessions[SessionKey(host: "fast", id: "fast")]!)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
    precondition(delegate.model.status == "selected the pane on fast", "a slow old click must not overwrite the latest click")
    print("PASS the latest click controls the final navigation result")
}
"""
    (root / "main.swift").write_text(source)
    subprocess.run(
        [
            "swiftc",
            "-o",
            str(root / "audit"),
            str(root / "main.swift"),
            *[
                str(path)
                for path in sorted((repository / "src").glob("*.swift"))
                if path.name != "main.swift"
            ],
            "-framework",
            "AppKit",
            "-framework",
            "SwiftUI",
        ],
        check=True,
    )
    result = subprocess.run(
        [str(root / "audit")],
        env=os.environ
        | {
            "AGENT_STAT_DIR": str(root / "events"),
            "AGENT_STAT_MEMORY": str(root / "memory.json"),
            "AGENT_STAT_ROUTES": str(root / "routes.json"),
        },
        text=True,
        capture_output=True,
        check=True,
        timeout=10,
    )
    print(result.stdout)
    print(result.stderr)
    selections = (root / "trace").read_text().strip().splitlines()
    assert selections[-1] == "fast", selections
    print("PASS the latest click selects its pane last")
