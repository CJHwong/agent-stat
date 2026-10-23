import Darwin
import Foundation

func testCodexTitles() {
    testCodexTitleCacheInvalidation()
    print("codex names: metadata preserves session status")
    withTempDir { directory in
        let index = directory.appendingPathComponent(".codex/session_index.jsonl")
        do {
            try FileManager.default.createDirectory(at: index.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try "{\"id\":\"quiet\",\"thread_name\":\"Old\"}\ninvalid\n[]\n{\"id\":\"quiet\",\"thread_name\":\"Renamed\\nname\"}\n"
                .write(to: index, atomically: true, encoding: .utf8)
            let oldProfile = directory.appendingPathComponent(".codex-old")
            try FileManager.default.createDirectory(at: oldProfile, withIntermediateDirectories: true)
            try "{\"id\":\"dated\",\"thread_name\":\"Current\",\"updated_at\":\"2026-10-23T00:00:00.100Z\"}\n"
                .write(to: index, atomically: true, encoding: .utf8)
            try "{\"id\":\"dated\",\"thread_name\":\"Stale\",\"updated_at\":\"2026-10-23T00:00:00Z\"}\n"
                .write(to: oldProfile.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
            checkEqual(CodexTitles.read(home: directory)["dated"], "Current", "newest profile name wins across fractional timestamps")
            try "{\"id\":\"quiet\",\"thread_name\":\"Old\"}\ninvalid\n[]\n{\"id\":\"quiet\",\"thread_name\":\"Renamed\\nname\"}\n"
                .write(to: index, atomically: true, encoding: .utf8)
            let names = CodexTitles.read(home: directory)
            checkEqual(names["quiet"], "Renamed name", "last valid name wins")
            let store = SessionStore(localHost: "local")
            store.apply(decode("{\"ts\":100,\"event\":\"Stop\",\"session\":\"quiet\",\"agent\":\"codex\"}"), host: "peer")
            store.apply(decode("{\"ts\":100,\"event\":\"Stop\",\"session\":\"quiet\",\"agent\":\"codex\"}"), host: "local")
            store.apply(decode("{\"ts\":100,\"event\":\"Stop\",\"session\":\"claude\",\"agent\":\"claude\",\"title\":\"Claude name\"}"), host: "peer")
            store.applyTitles(["claude": "Wrong name"], host: "peer")
            checkEqual(store.sessions[SessionKey(host: "peer", id: "claude")]?.title,
                       "Claude name", "index cannot rename Claude")
            let attention = store.attentionCount(now: 101)
            store.applyTitles(names, host: "peer")
            checkEqual(store.attentionCount(now: 101), attention, "name preserves attention count")
            let remote = store.sessions[SessionKey(host: "peer", id: "quiet")]!
            checkEqual(remote.title, "Renamed name", "quiet remote gets name")
            checkEqual(remote.lastTs, 100, "name preserves event time")
            checkEqual(remote.state, .idle, "name preserves state")
            checkEqual(store.sessions[SessionKey(host: "local", id: "quiet")]?.title, nil,
                       "name stays on its host")
            store.applyTitles(["unknown": "No row"], host: "peer")
            checkEqual(store.sessions.count, 3, "name cannot create a session")
        } catch {
            check(false, "name fixture: \(error)")
        }
    }
}

func testCodexTitleCacheInvalidation() {
    print("codex names: cached files still detect changes")
    withTempDir { home in
        do {
            let profile = home.appendingPathComponent(".codex")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let index = profile.appendingPathComponent("session_index.jsonl")
            let original = "{\"id\":\"cached\",\"thread_name\":\"First\"}\n"
            try original.write(to: index, atomically: true, encoding: .utf8)
            let reader = CodexTitles()
            checkEqual(reader.read(home: home)["cached"], "First", "the first read loads names")
            checkEqual(reader.read(home: home)["cached"], "First", "an unchanged read keeps names")
            let before = FileStamp(index)!
            let handle = try FileHandle(forWritingTo: index)
            try handle.write(contentsOf: Data(original.replacingOccurrences(of: "First", with: "Other").utf8))
            try handle.close()
            var timestamps = [timespec(tv_sec: before.modifiedSeconds, tv_nsec: before.modifiedNanoseconds),
                              timespec(tv_sec: before.modifiedSeconds, tv_nsec: before.modifiedNanoseconds)]
            checkEqual(utimensat(AT_FDCWD, index.path, &timestamps, 0), 0, "restore the exact modification time")
            checkEqual(FileStamp(index)?.modifiedNanoseconds, before.modifiedNanoseconds, "mtime restoration preserves nanoseconds")
            checkEqual(reader.read(home: home)["cached"], "Other", "same-size rewrites invalidate names even with restored mtime")
            try FileManager.default.removeItem(at: index)
            checkEqual(reader.read(home: home)["cached"], nil, "a missing index cannot retain cached names")
            try original.write(to: index, atomically: true, encoding: .utf8)
            checkEqual(reader.read(home: home)["cached"], "First", "a recreated index reloads names")
            try Data([0xFF, 0x0A]).write(to: index, options: .atomic)
            checkEqual(reader.read(home: home)["cached"], nil, "an invalid index cannot retain cached names")
            try original.write(to: index, atomically: true, encoding: .utf8)
            checkEqual(reader.read(home: home)["cached"], "First", "a repaired index reloads names")
        } catch {
            check(false, "name cache fixture: \(error)")
        }
    }
}
