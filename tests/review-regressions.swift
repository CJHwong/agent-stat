import Darwin
import Foundation

func testReviewRegressions() {
    testPermissionCompletion()
    testMultipleTmuxClients()
    testLocalProcessIdentity()
    testPreciseCovers()
    testPreciseCoverPersistence()
    testReaderPositions()
    testLivenessWithRetainedHistory()
    testLivenessWindowBoundary()
    testLaunchFolderAnchor()
}

/// The launch folder anchors to the agent process, not to the latest start.
///
/// A real session re-fired SessionStart many times over its life, and each one
/// carried the cwd the agent had at that moment. One landed far inside a worktree,
/// so the click refused with "pane %1757 is at a different folder" while the pane
/// sat at the repository root.
func testLaunchFolderAnchor() {
    print("launch folder anchors to the process")
    let store = SessionStore(localHost: HOST)
    let repo = "/Users/you/work/repo"
    let deep = repo + "/.claude/worktrees/two/app/freight/func/shipment/air_booking/entry/handlers/tests"
    let stream = [
        #"{"ts":1,"event":"SessionStart","agent":"claude","agent_pid":383,"agent_start":"t0","session":"s1","cwd":"\#(repo)"}"#,
        #"{"ts":2,"event":"UserPromptSubmit","agent":"claude","agent_pid":383,"session":"s1","cwd":"\#(repo)/.claude/worktrees/one","turn":"p1"}"#,
        #"{"ts":3,"event":"SessionStart","agent":"claude","agent_pid":383,"agent_start":"t0","session":"s1","cwd":"\#(deep)"}"#
    ]
    for line in stream { store.apply(decode(line), host: HOST) }

    let session = store.sessions[SessionKey(host: HOST, id: "s1")]!
    checkEqual(session.launchCwd, repo, "a later start does not move the launch folder")
    checkEqual(session.cwd, deep, "the agent folder still follows the last record")
    check(TmuxTargeting.folderMatches(session.launchCwd, repo),
          "the click accepts a pane at the launch folder")

    // A resume is a new process. Its own first folder is the new anchor.
    store.apply(decode(#"{"ts":4,"event":"SessionStart","agent":"claude","agent_pid":404,"agent_start":"t1","session":"s1","cwd":"/Users/you/work/other"}"#),
                host: HOST)
    checkEqual(store.sessions[SessionKey(host: HOST, id: "s1")]!.launchCwd,
               "/Users/you/work/other", "a new process anchors its own first folder")
}

func testPermissionCompletion() {
    print("approved tools resume their turn")
    let store = SessionStore(localHost: HOST)
    for event in ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse"] {
        store.apply(decode(#"{"ts":100,"event":"\#(event)","session":"permission"}"#), host: HOST)
    }
    let session = store.sessions[SessionKey(host: HOST, id: "permission")]!
    checkEqual(session.state, .running, "a successful tool resumes an approved turn")
    checkEqual(store.attentionCount(now: 100), 0, "a completed permission request needs no attention")
}

func testMultipleTmuxClients() {
    print("tmux supports multiple attached clients")
    for count in [1, 2, 12] {
        checkEqual(TmuxTargeting.paneInfo("%0", in: "%0,@0,\(count),/tmp")?.attached, true,
                   "\(count) attached clients make the pane reachable")
    }
    for count in ["0", "-1", "unknown"] {
        checkEqual(TmuxTargeting.paneInfo("%0", in: "%0,@0,\(count),/tmp")?.attached, false,
                   "\(count) is not a positive attached count")
    }
}

func testLocalProcessIdentity() {
    print("local process identity includes its start")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "lstart=", "-p", String(getpid())]
    let output = Pipe()
    process.standardOutput = output
    try! process.run()
    let started = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
    process.waitUntilExit()
    checkEqual(process.terminationStatus, 0, "ps reports this process start")
    check(processIsAlive(getpid(), started: started), "the actual start matches the hook format")
    check(!processIsAlive(getpid(), started: "Thu Jan 1 00:00:00 1970"), "a recycled process does not match")
    check(processIsAlive(getpid()), "legacy records without a start retain the process check")
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":100,"event":"Stop","session":"reused","agent_pid":\#(getpid()),"agent_start":"old"}"#),
                host: HOST)
    store.reapLocal(now: 200) { pid, started in processIsAlive(Int32(pid), started: started) }
    checkEqual(store.sessions[SessionKey(host: HOST, id: "reused")]?.alive, false,
               "the store checks the captured process identity")
    checkEqual(store.visible(now: 200).count, 0, "an old session cannot borrow a live process")
    store.apply(decode(#"{"ts":201,"event":"PreToolUse","session":"reused","agent_pid":\#(getppid())}"#), host: HOST)
    check(store.sessions[SessionKey(host: HOST, id: "reused")]?.agentStart == nil,
          "a new process does not inherit the prior process start")
}

func testPreciseCovers() {
    print("same-second events pass precise covers")
    let key = SessionKey(host: HOST, id: "precise")
    let store = SessionStore(localHost: HOST)
    let first = decode(#"{"ts":100,"event":"Stop","session":"precise"}"#)
    store.apply(first, host: HOST, position: EventPosition(file: "host-2026-10-23.jsonl", offset: 100))
    store.acknowledge(key, now: 100)
    store.dismiss(key, now: 100)
    store.apply(first, host: HOST, position: EventPosition(file: "host-2026-10-23.jsonl", offset: 100))
    checkEqual(store.visible(now: 100).count, 0, "replay cannot reopen a dismissed row")
    store.apply(decode(#"{"ts":100,"event":"SubagentStart","session":"precise","agent_id":"child"}"#),
                host: HOST, position: EventPosition(file: "host-2026-10-23.jsonl", offset: 200))
    store.apply(decode(#"{"ts":100,"event":"SubagentStop","session":"precise","agent_id":"child"}"#),
                host: HOST, position: EventPosition(file: "host-2026-10-23.jsonl", offset: 300))
    checkEqual(store.visible(now: 100).count, 0, "subagent work does not reopen a dismissed row")
    store.apply(first, host: HOST, position: EventPosition(file: "host-2026-10-23.jsonl", offset: 400))
    checkEqual(store.visible(now: 100).count, 1, "a later ask in the same second reopens the row")
    checkEqual(store.attentionCount(now: 100), 1, "a later ask in the same second restores attention")
    store.acknowledge(key, now: 100)
    checkEqual(store.attentionCount(now: 100), 0, "a second click covers the later ask")
    store.apply(first, host: HOST, position: EventPosition(file: "host-2026-10-23.jsonl", offset: 100))
    checkEqual(store.attentionCount(now: 100), 0, "an older replay cannot undo the second click")
}

func testPreciseCoverPersistence() {
    print("precise covers survive a restart")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("host-2026-10-23.jsonl")
    let record = #"{"ts":100,"event":"Stop","session":"persisted"}"# + "\n"
    try! Data(record.utf8).write(to: file)
    let store = SessionStore(localHost: "host")
    for item in EventReader().poll(directory: directory) {
        store.apply(item.record, host: item.host, position: item.position)
    }
    let key = SessionKey(host: "host", id: "persisted")
    store.acknowledge(key, now: 100)
    store.dismiss(key, now: 100)
    let memoryFile = directory.appendingPathComponent("memory.json")
    PanelMemory.save(dismissed: store.dismissed, acknowledged: store.acknowledged,
                     dismissedPositions: store.dismissedPositions,
                     acknowledgedPositions: store.acknowledgedPositions, to: memoryFile)
    let memory = PanelMemory.load(from: memoryFile)
    let restored = SessionStore(localHost: "host")
    restored.restore(dismissed: memory.dismissed, acknowledged: memory.acknowledged,
                     dismissedPositions: memory.dismissedPositions,
                     acknowledgedPositions: memory.acknowledgedPositions)
    let reader = EventReader()
    for item in reader.poll(directory: directory) {
        restored.apply(item.record, host: item.host, position: item.position)
    }
    checkEqual(restored.visible(now: 100).count, 0, "startup replay retains the dismissal")
    let handle = try! FileHandle(forWritingTo: file)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data(record.utf8))
    try! handle.close()
    for item in reader.poll(directory: directory) {
        restored.apply(item.record, host: item.host, position: item.position)
    }
    checkEqual(restored.visible(now: 100).count, 1, "an identical later record survives restart")
    checkEqual(restored.attentionCount(now: 100), 1, "its new position restores attention")
    try! Data(#"{"dismissed":{"host/persisted":100},"acknowledged":{"host/persisted":100}}"#.utf8)
        .write(to: memoryFile)
    let legacy = PanelMemory.load(from: memoryFile)
    checkEqual(legacy.dismissed[key], 100, "legacy second-based covers still load")
    check(legacy.dismissedPositions.isEmpty, "legacy covers have no invented event position")
}

func testReaderPositions() {
    print("record positions count bytes and follow day files")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("host-2026-10-23.jsonl")
    let first = #"{"ts":100,"event":"Stop","session":"unicode","message":"中文"}"# + "\n"
    let second = #"{"ts":100,"event":"Stop","session":"unicode","message":"again"}"#
    try! Data((first + second).utf8).write(to: file)
    let reader = EventReader()
    let records = reader.poll(directory: directory)
    checkEqual(records.count, 1, "the reader leaves a partial record behind")
    checkEqual(records.first?.position.offset, UInt64(first.utf8.count), "positions count UTF8 bytes")
    let handle = try! FileHandle(forWritingTo: file)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data("\n".utf8))
    try! handle.close()
    let appended = reader.poll(directory: directory)
    checkEqual(appended.first?.position.offset, UInt64(first.utf8.count + second.utf8.count + 1),
               "a completed partial record keeps its actual byte boundary")
    let replay = EventReader().poll(directory: directory)
    checkEqual(replay.map(\.position), (records + appended).map(\.position),
               "a fresh reader produces the same positions")
    let nextFile = directory.appendingPathComponent("host-2026-10-24.jsonl")
    try! Data(first.utf8).write(to: nextFile)
    let rotated = reader.poll(directory: directory)
    checkEqual(rotated.count, 1, "the next day contributes only its new record")
    check(rotated[0].position > appended[0].position, "a new day sorts after the previous byte boundary")
    let store = SessionStore(localHost: "host")
    for item in records + appended { store.apply(item.record, host: item.host, position: item.position) }
    store.dismiss(SessionKey(host: "host", id: "unicode"), now: 100)
    store.acknowledge(SessionKey(host: "host", id: "unicode"), now: 100)
    store.apply(rotated[0].record, host: "host", position: rotated[0].position)
    checkEqual(store.attentionCount(now: 100), 1, "day rotation passes a prior cover even with equal timestamps")
}

func testLivenessWithRetainedHistory() {
    print("liveness skips retained expired history")
    let now = 1_000_000
    let store = SessionStore(localHost: HOST)
    let expired = now - SessionStore.visibleWindowSeconds - 1
    for index in 0..<10_000 {
        store.apply(decode(#"{"ts":\#(expired),"event":"Stop","session":"expired-\#(index)","agent_pid":\#(1000 + index)}"#),
                    host: HOST)
    }
    for index in 0..<20 {
        let pid = index < 15 ? 1 : 2
        let start = index < 10 ? "start-a" : "start-b"
        store.apply(decode(#"{"ts":\#(now),"event":"Stop","session":"recent-\#(index)","agent_pid":\#(pid),"agent_start":"\#(start)"}"#),
                    host: HOST)
    }
    var probed: [String] = []
    store.reapLocal(now: now) { pid, started in
        probed.append("\(pid)/\(started ?? "")")
        return pid == 1 && started == "start-a"
    }
    checkEqual(probed.count, 3, "only distinct recent process identities need a probe")
    check(Set(probed) == ["1/start-a", "1/start-b", "2/start-b"], "process starts separate reused identifiers")
    checkEqual(store.sessions.count, 10_020, "liveness keeps the complete session history")
    checkEqual(store.visible(now: now).count, 20, "recent rows keep their crash grace")
    checkEqual(store.attentionCount(now: now), 10, "only live recent rows request attention")
    let key = SessionKey(host: HOST, id: "expired-0")
    store.apply(decode(#"{"ts":\#(now + 1),"event":"Stop","session":"expired-0","agent_pid":3}"#), host: HOST)
    probed.removeAll()
    store.reapLocal(now: now + 1) { pid, started in
        probed.append("\(pid)/\(started ?? "")")
        return true
    }
    checkEqual(probed.count, 4, "a new event restores the expired session to the liveness pass")
    checkEqual(store.sessions[key]?.alive, true, "the revived session receives a current process result")
    check(store.visible(now: now + 1).contains { $0.key == key }, "the revived session becomes visible")
    checkEqual(store.attentionCount(now: now + 1), 21, "each pass refreshes shared process results")
}

func testLivenessWindowBoundary() {
    print("liveness includes the exact visibility boundary")
    let now = 1_000_000
    let store = SessionStore(localHost: HOST)
    let boundary = now - SessionStore.visibleWindowSeconds
    for (identifier, timestamp, pid) in [("boundary", boundary, 31), ("expired", boundary - 1, 32),
                                          ("future", now + 100, 33)] {
        store.apply(decode(#"{"ts":\#(timestamp),"event":"Stop","session":"\#(identifier)","agent_pid":\#(pid)}"#), host: HOST)
    }
    var probed: [Int] = []
    store.reapLocal(now: now) { pid, _ in
        probed.append(pid)
        return true
    }
    checkEqual(probed.sorted(), [31, 33], "boundary and future timestamps remain eligible")
    checkEqual(store.visible(now: now).map(\.key.id), ["future", "boundary"], "the visibility boundary stays inclusive")
}
