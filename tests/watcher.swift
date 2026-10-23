import Darwin
import Foundation

// The watcher answers "did the events change", so its tests use real files and a
// real run loop.
func pumpRunLoop(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

func appendLine(_ text: String, to path: URL) {
    let handle = try! FileHandle(forWritingTo: path)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: text.appending("\n").data(using: .utf8)!)
    try! handle.close()
}

func testWatcherReplacement() {
    print("watcher: replaced file")
    withTempDir { dir in
        let path = dir.appendingPathComponent("\(HOST)-2026-10-16.jsonl")
        try! "x\n".write(to: path, atomically: true, encoding: .utf8)
        var fired = 0
        let watcher = EventWatcher(directory: dir) { fired += 1 }
        withExtendedLifetime(watcher) {
            pumpRunLoop()
            fired = 0
            appendLine("x", to: path)
            pumpRunLoop()
            check(fired > 0, "an append reaches the watcher")

            // The same name, a new inode: an atomic save, and what a sync client does.
            fired = 0
            try! "x\n".write(to: path, atomically: true, encoding: .utf8)
            pumpRunLoop()
            appendLine("x", to: path)
            pumpRunLoop()
            check(fired > 0, "an append after a replacement reaches the watcher")
        }
    }
}

func testWatcherScope() {
    print("watcher: what it watches")
    withTempDir { dir in
        let path = dir.appendingPathComponent("\(HOST)-2026-10-16.jsonl")
        try! "x\n".write(to: path, atomically: true, encoding: .utf8)
        var fired = 0
        let watcher = EventWatcher(directory: dir) { fired += 1 }
        withExtendedLifetime(watcher) {
            pumpRunLoop()

            // A conflict copy is not watched: the reader ignores it.
            let conflict = dir.appendingPathComponent(
                "\(HOST)-2026-10-16.sync-conflict-20261016-000000-ABCDEF.jsonl")
            try! "x\n".write(to: conflict, atomically: true, encoding: .utf8)
            pumpRunLoop()
            fired = 0
            appendLine("y", to: conflict)
            pumpRunLoop()
            checkEqual(fired, 0, "a sync conflict file is not watched")

            // More files than the watcher keeps: newest first, the rest poll.
            for index in 0..<12 {
                let old = dir.appendingPathComponent(
                    "\(HOST)-2026-10-\(String(format: "%02d", index + 1)).jsonl")
                try! "x\n".write(to: old, atomically: true, encoding: .utf8)
                try! FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceNow: -3600 * Double(20 - index))],
                    ofItemAtPath: old.path)
            }
            pumpRunLoop()
            fired = 0
            appendLine("z", to: dir.appendingPathComponent("\(HOST)-2026-10-01.jsonl"))
            pumpRunLoop()
            checkEqual(fired, 0, "a file outside the newest eight is not watched")
            fired = 0
            appendLine("x", to: path)
            pumpRunLoop()
            check(fired > 0, "the newest file is still watched")
        }
    }
    testWatcherMissingDirectory()
    testWatcherDirectoryReplacement()
    testWatcherDirectoryRecreation()
    testWatcherRelease()
}

func testWatcherMissingDirectory() {
    print("watcher: directory appears after startup")
    withTempDir { root in
        let directory = root.appendingPathComponent("events")
        var fired = 0
        let watcher = EventWatcher(directory: directory) { fired += 1 }
        withExtendedLifetime(watcher) {
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            watcher.refresh()
            pumpRunLoop(0.1)
            fired = 0
            try! "record\n".write(to: directory.appendingPathComponent("host-2026-10-23.jsonl"),
                                  atomically: false, encoding: .utf8)
            pumpRunLoop(0.2)
            check(fired > 0, "a refresh restores discovery after the directory appears")
        }
    }
}

func testWatcherDirectoryReplacement() {
    print("watcher: repeated directory replacement")
    withTempDir { root in
        let directory = root.appendingPathComponent("events")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var fired = 0
        let watcher = EventWatcher(directory: directory) { fired += 1 }
        withExtendedLifetime(watcher) {
            for index in 0..<3 {
                let old = root.appendingPathComponent("old-\(index)")
                try! FileManager.default.moveItem(at: directory, to: old)
                try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                pumpRunLoop(0.1)
                fired = 0
                let file = directory.appendingPathComponent("host-2026-10-23.jsonl")
                try! "record\n".write(to: file, atomically: false, encoding: .utf8)
                pumpRunLoop(0.2)
                check(fired > 0, "replacement \(index) still discovers new event files")
                fired = 0
                appendLine("record", to: file)
                pumpRunLoop(0.1)
                check(fired > 0, "replacement \(index) still watches appended records")
                fired = 0
                try! "old\n".write(to: old.appendingPathComponent("host-2026-10-24.jsonl"),
                                  atomically: false, encoding: .utf8)
                pumpRunLoop(0.1)
                checkEqual(fired, 0, "replacement \(index) releases the old directory")
            }
        }
    }
}

func testWatcherDirectoryRecreation() {
    print("watcher: deleted directory recovers on refresh")
    withTempDir { root in
        let directory = root.appendingPathComponent("events")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var fired = 0
        let watcher = EventWatcher(directory: directory) { fired += 1 }
        withExtendedLifetime(watcher) {
            try! FileManager.default.removeItem(at: directory)
            pumpRunLoop(0.1)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            watcher.refresh()
            pumpRunLoop(0.1)
            fired = 0
            try! "record\n".write(to: directory.appendingPathComponent("host-2026-10-23.jsonl"),
                                  atomically: false, encoding: .utf8)
            pumpRunLoop(0.2)
            check(fired > 0, "the existing fallback restores discovery after deletion")
        }
    }
}

func testWatcherRelease() {
    print("watcher: releasing sources closes descriptors")
    withTempDir { directory in
        for index in 0..<12 {
            try! "record\n".write(to: directory.appendingPathComponent("host-2026-10-\(index + 1).jsonl"),
                                  atomically: false, encoding: .utf8)
        }
        pumpRunLoop(0.1)
        let before = openWatcherDescriptorCount()
        for _ in 0..<4 {
            var watcher: EventWatcher? = EventWatcher(directory: directory) {}
            checkEqual(openWatcherDescriptorCount() - before, 9, "one directory and at most eight files stay open")
            watcher?.refresh()
            watcher = nil
            pumpRunLoop(0.1)
            checkEqual(openWatcherDescriptorCount(), before, "release closes every descriptor")
        }
    }
}

private func openWatcherDescriptorCount() -> Int {
    (0..<getdtablesize()).filter { fcntl($0, F_GETFD) >= 0 }.count
}
