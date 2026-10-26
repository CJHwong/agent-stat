import Foundation

// Tests for the model, presentation, and reader. The real-agent probe is tests/live-probe.py.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL  \(label)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL  \(label): got \(actual), expected \(expected)")
    }
}

func decode(_ json: String) -> Record {
    try! JSONDecoder().decode(Record.self, from: json.data(using: .utf8)!)
}

let HOST = "workstation"

// ---------------------------------------------------------------- state machine

func testStateMachine() {
    print("state machine")
    let store = SessionStore(localHost: HOST)
    let stream = [
        #"{"ts":100,"event":"SessionStart","agent":"claude","agent_pid":42,"agent_start":"t0","session":"s1","cwd":"/w/api"}"#,
        #"{"ts":101,"event":"UserPromptSubmit","agent":"claude","agent_pid":42,"session":"s1","cwd":"/w/api","turn":"p1"}"#,
        #"{"ts":102,"event":"PreToolUse","agent":"claude","agent_pid":42,"session":"s1","tool":"Bash"}"#,
        #"{"ts":132,"event":"PostToolUse","agent":"claude","agent_pid":42,"session":"s1","tool":"Bash"}"#,
        #"{"ts":140,"event":"Stop","agent":"claude","agent_pid":42,"session":"s1","message":"done, tests pass"}"#
    ]
    for line in stream { store.apply(decode(line), host: HOST) }

    let session = store.sessions[SessionKey(host: HOST, id: "s1")]!
    checkEqual(session.state, .idle, "Stop leaves the session idle, waiting on you")
    checkEqual(session.agentPid, 42, "pid captured")
    checkEqual(session.turn, "p1", "turn captured")
    checkEqual(session.lastMessage, "done, tests pass", "message captured")
    check(session.tool == nil, "tool cleared after PostToolUse")

    // Duration must come from the timestamps, because Codex sends no dur_ms.
    checkEqual(session.lastToolSeconds, 30, "tool duration derived from timestamps")
    checkEqual(session.age(now: 200), 60, "age from the last event")

    print("  permission and terminal states")
    let other = SessionStore(localHost: HOST)
    other.apply(decode(#"{"ts":1,"event":"PermissionRequest","session":"s2","tool":"Bash"}"#), host: HOST)
    checkEqual(other.sessions[SessionKey(host: HOST, id: "s2")]!.state, .waiting, "PermissionRequest waits")
    other.apply(decode(#"{"ts":2,"event":"StopFailure","session":"s2"}"#), host: HOST)
    checkEqual(other.sessions[SessionKey(host: HOST, id: "s2")]!.state, .failed, "StopFailure fails")
    other.apply(decode(#"{"ts":3,"event":"Interrupt","session":"s2"}"#), host: HOST)
    checkEqual(other.sessions[SessionKey(host: HOST, id: "s2")]!.state, .interrupted, "Interrupt")
    other.apply(decode(#"{"ts":4,"event":"SessionEnd","session":"s2","reason":"exit"}"#), host: HOST)
    checkEqual(other.sessions[SessionKey(host: HOST, id: "s2")]!.state, .ended, "SessionEnd ends")
}

func testIdempotence() {
    print("idempotence (a sync re-read must not change anything)")
    let lines = [
        #"{"ts":100,"event":"SessionStart","agent":"codex","agent_pid":7,"session":"s1","cwd":"/w"}"#,
        #"{"ts":101,"event":"UserPromptSubmit","session":"s1","turn":"t1"}"#,
        #"{"ts":102,"event":"PreToolUse","session":"s1","tool":"Bash"}"#,
        #"{"ts":160,"event":"PostToolUse","session":"s1","tool":"Bash"}"#,
        #"{"ts":161,"event":"Stop","session":"s1","message":"ok"}"#
    ]
    let once = SessionStore(localHost: HOST)
    for line in lines { once.apply(decode(line), host: HOST) }
    let twice = SessionStore(localHost: HOST)
    for _ in 0..<2 {
        for line in lines { twice.apply(decode(line), host: HOST) }
    }
    let onceSession = once.sessions[SessionKey(host: HOST, id: "s1")]!
    let twiceSession = twice.sessions[SessionKey(host: HOST, id: "s1")]!
    checkEqual(twiceSession.state, onceSession.state, "state unchanged by a full replay")
    checkEqual(twiceSession.lastToolSeconds, onceSession.lastToolSeconds, "derived duration not doubled")
    checkEqual(twiceSession.lastMessage, onceSession.lastMessage, "message unchanged")
    checkEqual(twiceSession.lastTs, onceSession.lastTs, "timestamp unchanged")
}

func testUnknownAndMalformed() {
    print("tolerance")
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":1,"event":"SessionStart","session":"s1"}"#), host: HOST)
    store.apply(decode(#"{"ts":2,"event":"SomethingFromTheFuture","session":"s1"}"#), host: HOST)
    checkEqual(store.sessions[SessionKey(host: HOST, id: "s1")]!.lastTs, 2,
               "an unknown event still advances the timestamp")

    // A subagent tool call is dropped before it reaches the session. A start and a
    // stop are folded in, which is why they move the clock and this one does not.
    store.apply(decode(#"{"ts":3,"event":"PreToolUse","session":"s1","agent_id":"a","tool":"Bash"}"#),
                host: HOST)
    checkEqual(store.sessions[SessionKey(host: HOST, id: "s1")]!.state, .starting,
               "a subagent tool call does not disturb the state")
    checkEqual(store.sessions[SessionKey(host: HOST, id: "s1")]!.lastTs, 2,
               "a subagent tool call is ignored entirely")

    // A record with no session id is dropped rather than inventing a session.
    store.apply(decode(#"{"ts":4,"event":"Stop"}"#), host: HOST)
    checkEqual(store.sessions.count, 1, "record without a session id ignored")
}

func testOrderingAndWindow() {
    print("ordering and visibility window")
    let store = SessionStore(localHost: HOST)
    let now = 100_000
    let ancientTs = now - SessionStore.visibleWindowSeconds - 3600
    store.apply(decode(#"{"ts":99990,"event":"Stop","session":"idle","message":"m"}"#), host: HOST)
    store.apply(decode(#"{"ts":99991,"event":"PermissionRequest","session":"wait","tool":"Bash"}"#), host: HOST)
    store.apply(decode(#"{"ts":99992,"event":"PreToolUse","session":"run","tool":"Bash"}"#), host: HOST)
    store.apply(decode(#"{"ts":99993,"event":"SessionEnd","session":"over"}"#), host: HOST)
    store.apply(decode(#"{"ts":\#(ancientTs),"event":"Stop","session":"ancient"}"#), host: HOST)

    let rows = store.visible(now: now).map(\.key.id)
    checkEqual(rows, ["wait", "idle", "run", "over"], "attention first, then running, then finished")
    check(!rows.contains("ancient"), "session older than the window is hidden")

    // Two machines, same session id, must stay two sessions.
    store.apply(decode(#"{"ts":99994,"event":"Stop","session":"shared"}"#), host: HOST)
    store.apply(decode(#"{"ts":99995,"event":"Stop","session":"shared"}"#), host: "Other-Machine")
    checkEqual(store.sessions.count, 7, "same session id on two hosts is two sessions")
    checkEqual(store.sessions[SessionKey(host: HOST, id: "shared")]!.isLocal, true, "local flagged")
    checkEqual(store.sessions[SessionKey(host: "Other-Machine", id: "shared")]!.isLocal, false,
               "remote not flagged local")
}

func testLiveness() {
    print("liveness")
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":1,"event":"PreToolUse","session":"s1","agent_pid":4242,"tool":"Bash"}"#), host: HOST)
    store.apply(decode(#"{"ts":2,"event":"PreToolUse","session":"remote","agent_pid":99,"tool":"Bash"}"#),
                host: "Other-Machine")
    store.reapLocal(now: 10) { pid, _ in pid == 4242 }
    checkEqual(store.sessions[SessionKey(host: HOST, id: "s1")]!.alive, true, "local pid alive")
    check(store.sessions[SessionKey(host: "Other-Machine", id: "remote")]!.alive == nil,
          "remote session is never claimed alive or dead")
    store.reapLocal(now: 11) { _, _ in false }
    checkEqual(store.sessions[SessionKey(host: HOST, id: "s1")]!.alive, false, "local pid gone")
    check(store.sessions[SessionKey(host: HOST, id: "s1")]!.vanishedWithoutEnd,
          "a gone process with no end record counts as vanished")
    check(!store.sessions[SessionKey(host: "Other-Machine", id: "remote")]!.vanishedWithoutEnd,
          "a remote session is never claimed gone")

    // A process that is gone after a real end record is a clean exit, not a
    // crash, so the panel keeps saying "ended" and does not call it vanished.
    store.apply(decode(#"{"ts":12,"event":"SessionEnd","session":"s1"}"#), host: HOST)
    store.reapLocal(now: 13) { _, _ in false }
    check(!store.sessions[SessionKey(host: HOST, id: "s1")]!.vanishedWithoutEnd,
          "a gone process that reported its end is not a crash")
}

// ------------------------------------------------------------------- the reader

func withTempDir(_ body: (URL) throws -> Void) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("as-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try! body(dir)
}

func testReaderFileName() {
    print("reader: file name to host")
    checkEqual(EventReader.host(fromFileName: "workstation-2026-10-16.jsonl"),
               "workstation", "dashes in the host name are preserved")
    checkEqual(EventReader.host(fromFileName: "studio.local-2026-01-02.jsonl"),
               "studio.local", "short host")
    checkEqual(EventReader.host(fromFileName: "weird.jsonl"), "weird", "no date suffix")
}

func testReaderPartialLineAndReplacement() {
    print("reader: partial lines, appends, replacement")

    withTempDir { dir in
        let name = "\(HOST)-2026-10-16.jsonl"
        let path = dir.appendingPathComponent(name)
        let reader = EventReader()

        // A half written record must be held back, not guessed at.
        try! #"{"ts":1,"event":"Stop","session":"s1""#.write(to: path, atomically: true, encoding: .utf8)
        checkEqual(reader.poll(directory: dir).count, 0, "partial line held back")

        // Completing the line releases it.
        var handle = try! FileHandle(forWritingTo: path)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: #","message":"hi"}"#.appending("\n").data(using: .utf8)!)
        try! handle.close()

        var applied = reader.poll(directory: dir)
        checkEqual(applied.count, 1, "completed line applied once")
        checkEqual(applied.first?.record.message, "hi", "record decoded after completion")

        // Appending more applies only the new line.
        handle = try! FileHandle(forWritingTo: path)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: #"{"ts":2,"event":"SessionEnd","session":"s1"}"#.appending("\n").data(using: .utf8)!)
        try! handle.close()
        applied = reader.poll(directory: dir)
        checkEqual(applied.count, 1, "only the appended line is applied")
        checkEqual(applied.first?.record.event, "SessionEnd", "appended record")

        // A replacement with identical content must replay nothing.
        let copy = dir.appendingPathComponent("swap.tmp")
        try! FileManager.default.copyItem(at: path, to: copy)
        _ = try? FileManager.default.removeItem(at: path)
        try! FileManager.default.moveItem(at: copy, to: path)
        checkEqual(reader.poll(directory: dir).count, 0, "replaced file replays nothing")

        // A replacement that is shorter is treated as a new file.
        try! #"{"ts":9,"event":"Stop","session":"fresh"}"#.appending("\n")
            .write(to: path, atomically: true, encoding: .utf8)
        let after = reader.poll(directory: dir)
        checkEqual(after.count, 1, "shrunk file re-read from the start")
        checkEqual(after.first?.record.session, "fresh", "fresh content applied")
    }
}

func testReaderSkipsJunk() {
    print("reader: junk")
    withTempDir { dir in
        let name = "\(HOST)-2026-10-16.jsonl"
        let path = dir.appendingPathComponent(name)
        try! """
        {"ts":1,"event":"Stop","session":"s1"}
        not json at all
        {"ts":2,"event":"Stop","session":"s2"}

        """.write(to: path, atomically: true, encoding: .utf8)

        // Same file, second name that must be ignored entirely.
        try! #"{"ts":3,"event":"Stop","session":"nope"}"#.appending("\n")
            .write(to: dir.appendingPathComponent("\(HOST)-2026-10-16.sync-conflict-20260101-000000-AAAA.jsonl"),
                   atomically: true, encoding: .utf8)

        let reader = EventReader()
        let applied = reader.poll(directory: dir)
        checkEqual(applied.count, 2, "bad line skipped, sync-conflict file ignored")
        checkEqual(reader.undecodableLines, 1, "junk counted")
        check(applied.allSatisfy { $0.host == HOST }, "host attached to every record")
    }
}

func testCleanup() {
    print("cleanup: closing a session must clear its row")
    let store = SessionStore(localHost: HOST)
    let now = 500_000

    // Finished cleanly: gone shortly after.
    store.apply(decode(#"{"ts":\#(now),"event":"Stop","session":"done","agent_pid":1}"#), host: HOST)
    store.apply(decode(#"{"ts":\#(now),"event":"SessionEnd","session":"done","agent_pid":1}"#), host: HOST)

    // Closed mid turn: no SessionEnd, the process just vanishes.
    store.apply(decode(#"{"ts":\#(now),"event":"PreToolUse","session":"killed","agent_pid":2,"tool":"Bash"}"#),
                host: HOST)

    // Still alive and waiting on you: must not be cleared.
    store.apply(decode(#"{"ts":\#(now),"event":"Stop","session":"alive","agent_pid":3,"message":"m"}"#), host: HOST)

    func ids(_ now: Int) -> [String] {
        store.reapLocal(now: now) { pid, _ in pid != 2 }
        return store.visible(now: now).map(\.key.id).sorted()
    }

    check(ids(now + 5).contains("done"), "just finished still visible")
    check(!ids(now + 20).contains("done"), "finished session cleared after the grace")
    check(ids(now + 20).contains("killed"), "crashed session kept past the short grace")
    check(!ids(now + 400).contains("killed"), "crashed session cleared after the long grace")
    check(ids(now + 400).contains("alive"), "a live session waiting on you is never cleared")

    // A leftover record from an earlier run must not appear at all, rather than
    // showing as "process gone" for the grace period on every app start.
    let old = SessionStore(localHost: HOST)
    let staleTs = now - 3600
    old.apply(decode(#"{"ts":\#(staleTs),"event":"Stop","session":"leftover","agent_pid":77}"#), host: HOST)
    old.reapLocal(now: now) { _, _ in false }
    check(!old.visible(now: now).contains { $0.key.id == "leftover" },
          "an old record with a dead pid is hidden at once")
}

func testSubagentsIgnored() {
    print("subagent events")
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":1,"event":"SessionStart","session":"s1","agent_pid":9,"cwd":"/w"}"#), host: HOST)
    store.apply(decode(#"{"ts":2,"event":"PreToolUse","session":"s1","tool":"Bash"}"#), host: HOST)

    // A subagent event carries agent_id and must not disturb the parent row.
    store.apply(decode(#"{"ts":3,"event":"Stop","session":"s1","agent_id":"sub-1","message":"sub done"}"#),
                host: HOST)
    let parent = store.sessions[SessionKey(host: HOST, id: "s1")]!
    checkEqual(parent.state, .running, "a subagent Stop does not finish the parent turn")
    check(parent.lastMessage == nil, "a subagent message does not become the parent message")

    // And it never becomes a row of its own.
    store.apply(decode(#"{"ts":4,"event":"SessionStart","session":"sub-1","agent_id":"sub-1"}"#), host: HOST)
    checkEqual(store.sessions.count, 1, "a subagent never becomes its own session")

    // The start and the stop are the two that are kept, and what they buy is a
    // parent row that stays fresh and says how many subagents are running.
    store.apply(decode(#"{"ts":5,"event":"SubagentStart","session":"s1","agent_id":"sub-a"}"#), host: HOST)
    store.apply(decode(#"{"ts":6,"event":"SubagentStart","session":"s1","agent_id":"sub-b"}"#), host: HOST)
    let two = store.sessions[SessionKey(host: HOST, id: "s1")]!
    checkEqual(two.liveSubagents.count, 2, "two subagents are running")
    checkEqual(two.lastTs, 6, "and their start moves the parent clock, so the row is not stale")
    checkEqual(store.sessions.count, 1, "with no extra rows for either of them")

    store.apply(decode(#"{"ts":7,"event":"SubagentStop","session":"s1","agent_id":"sub-a"}"#), host: HOST)
    let one = store.sessions[SessionKey(host: HOST, id: "s1")]!
    checkEqual(one.liveSubagents.count, 1, "one subagent is left")
    checkEqual(one.lastTs, 7, "and its stop moves the clock too")

    // A start for a session nobody has reported is not a way to invent a row.
    store.apply(decode(#"{"ts":8,"event":"SubagentStart","session":"ghost","agent_id":"sub-c"}"#), host: HOST)
    checkEqual(store.sessions.count, 1, "a subagent start with no parent shows nothing")

    // Work in flight, whoever is doing it: a turn that finished while its
    // subagents run on is not waiting on you yet.
    let busy = SessionStore(localHost: HOST)
    busy.apply(decode(#"{"ts":100,"event":"SessionStart","session":"b","agent_pid":7,"cwd":"/w"}"#), host: HOST)
    busy.apply(decode(#"{"ts":110,"event":"UserPromptSubmit","session":"b"}"#), host: HOST)
    busy.apply(decode(#"{"ts":120,"event":"SubagentStart","session":"b","agent_id":"sub-x"}"#), host: HOST)
    busy.apply(decode(#"{"ts":130,"event":"Stop","session":"b","message":"turn done"}"#), host: HOST)
    busy.reapLocal(now: 131) { _, _ in true }
    let finishedTurn = busy.sessions[SessionKey(host: HOST, id: "b")]!
    checkEqual(finishedTurn.state, .idle, "the turn itself is over")
    checkEqual(finishedTurn.isBusy, true, "but the session is still working")
    checkEqual(busy.needsAttention(finishedTurn), false, "so it is not waiting on you")
    checkEqual(busy.attentionCount(now: 131), 0, "and it stays out of the count")

    // It becomes yours again when the last subagent stops.
    busy.apply(decode(#"{"ts":140,"event":"SubagentStop","session":"b","agent_id":"sub-x"}"#), host: HOST)
    let alone = busy.sessions[SessionKey(host: HOST, id: "b")]!
    checkEqual(alone.isBusy, false, "the last subagent stopped")
    checkEqual(busy.attentionCount(now: 141), 1, "so the row needs you now")

    // And a row that is not waiting on you must not sort above one that is.
    let order = SessionStore(localHost: HOST)
    order.apply(decode(#"{"ts":200,"event":"Stop","session":"waiting","agent_pid":1,"message":"m"}"#), host: HOST)
    order.apply(decode(#"{"ts":100,"event":"UserPromptSubmit","session":"working","agent_pid":2}"#), host: HOST)
    order.apply(decode(#"{"ts":110,"event":"SubagentStart","session":"working","agent_id":"s"}"#), host: HOST)
    order.apply(decode(#"{"ts":120,"event":"Stop","session":"working"}"#), host: HOST)
    order.reapLocal(now: 210) { _, _ in true }
    checkEqual(order.visible(now: 210).map(\.key.id), ["waiting", "working"],
               "the row waiting on you comes first, work in flight after it")
}

func testMachineGating() {
    print("machine gating")
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":1,"event":"Stop","session":"here","agent_pid":1}"#), host: HOST)
    store.apply(decode(#"{"ts":2,"event":"Stop","session":"there","agent_pid":2}"#), host: "laptop")

    let here = store.sessions[SessionKey(host: HOST, id: "here")]!
    let there = store.sessions[SessionKey(host: "laptop", id: "there")]!
    checkEqual(here.onAnotherMachine, nil, "a local session names no other machine")
    checkEqual(there.onAnotherMachine, "laptop", "a remote session names its machine")
    check(here.isLocal && !there.isLocal, "locality is set from the machine that wrote the record")
}

testStateMachine()
testIdempotence()
testUnknownAndMalformed()
testOrderingAndWindow()
testLiveness()
testReaderFileName()
testReaderPartialLineAndReplacement()
testWatcherReplacement()
testWatcherScope()
testReaderSkipsJunk()
testCleanup()
testIconStepper()
testTickCadence()
testClaudeFailure()
testCodexFailure()
testCodexEarlyEnd(); testQuietLiveSession(); testOldFailure()
testFailureLifecycle()
func testPlacement() {
    print("panel placement")
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let width: CGFloat = 380

    // An item with room to its right: the panel grows right, left edges aligned.
    let roomy = CGRect(x: 400, y: 949, width: 32, height: 33)
    checkEqual(Placement.panelX(item: roomy, panelWidth: width, visible: screen), 400,
               "grows to the right when there is room")

    // An item near the right edge: no room, so it hangs to the left.
    let corner = CGRect(x: 1420, y: 949, width: 32, height: 33)
    checkEqual(Placement.panelX(item: corner, panelWidth: width, visible: screen), 1452 - width,
               "flips to the left when the right side is too small")

    // Clamped so it can never leave the screen.
    let far = CGRect(x: 1505, y: 949, width: 32, height: 33)
    let originX = Placement.panelX(item: far, panelWidth: width, visible: screen)
    check(originX >= screen.minX + Placement.margin && originX + width <= screen.maxX,
          "never leaves the screen")
}

func testAcknowledge() {
    print("acknowledging a session")
    let now = 900_000
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":\#(now - 5),"event":"Stop","session":"s1","agent_pid":1,"message":"m"}"#), host: HOST)
    store.reapLocal(now: now) { _, _ in true }
    checkEqual(store.attentionCount(now: now), 1, "an idle live session needs you")

    store.acknowledge(SessionKey(host: HOST, id: "s1"), now: now)
    checkEqual(store.attentionCount(now: now), 0, "clicking it clears the flag")
    checkEqual(store.isAcknowledged(store.sessions[SessionKey(host: HOST, id: "s1")]!), true,
               "and the row says so, which is what turns its dot blue")
    checkEqual(store.sessions[SessionKey(host: HOST, id: "s1")]!.state, .idle,
               "the state itself does not change")

    store.apply(decode(#"{"ts":\#(now + 30),"event":"Stop","session":"s1","message":"again"}"#), host: HOST)
    checkEqual(store.attentionCount(now: now), 1, "a later event raises the flag again")
    checkEqual(store.isAcknowledged(store.sessions[SessionKey(host: HOST, id: "s1")]!), false,
               "so the dot goes back to red")

    let dead = SessionStore(localHost: HOST)
    dead.apply(decode(#"{"ts":1,"event":"Stop","session":"d","agent_pid":2}"#), host: HOST)
    dead.reapLocal(now: 100) { _, _ in false }
    checkEqual(dead.attentionCount(now: 100), 0, "a session whose process is gone never needs you")

    // A remote row carries the other machine's clock, so acknowledging must
    // cover the session's own timestamp or the row could never clear.
    let remote = SessionStore(localHost: HOST)
    remote.apply(decode(#"{"ts":\#(now + 500),"event":"Stop","session":"r","agent_pid":3}"#), host: "laptop")
    checkEqual(remote.attentionCount(now: now), 1, "a remote idle session needs you")
    remote.acknowledge(SessionKey(host: "laptop", id: "r"), now: now)
    checkEqual(remote.attentionCount(now: now), 0, "a remote session clears even when its clock runs ahead")

    // A counted session with no row is a number nothing can clear: no row to
    // click, no row to dismiss. A remote session that never reported an end and
    // whose last event has left the window is exactly that shape.
    let stale = SessionStore(localHost: HOST)
    stale.apply(decode(#"{"ts":100,"event":"Stop","session":"old","agent_pid":4,"message":"m"}"#),
                host: "laptop")
    let late = 100 + SessionStore.visibleWindowSeconds + 1
    checkEqual(stale.visible(now: late).count, 0, "a stale remote row has left the panel")
    checkEqual(stale.attentionCount(now: late), 0, "and it stops counting toward the badge")
    checkEqual(stale.attentionCount(now: 100 + SessionStore.visibleWindowSeconds), 1,
               "up to the last moment it has a row, it counts")
}

/// The app and the hook each name this machine, in different languages. Every
/// locality rule is a string compare between those two answers, so a mismatch
/// silently turns the local machine into a remote one. Run the hook's own
/// command and compare.
func testLocalHostAgreesWithTheHook() {
    print("local host name agrees with the hook")
    let uname = Process()
    uname.executableURL = URL(fileURLWithPath: "/usr/bin/uname")
    uname.arguments = ["-n"]
    let output = Pipe()
    uname.standardOutput = output
    try! uname.run()
    let decoded = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
    let raw = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    uname.waitUntilExit()
    let shellHost = raw.hasSuffix(".local") ? String(raw.dropLast(".local".count)) : raw

    check(!shellHost.isEmpty, "the shell reported a host name")
    checkEqual(Paths.localHostName(), shellHost,
               "the app must name this machine exactly as the hook writes it")
}

func testDismiss() {
    print("dismissing a row")
    let now = 800_000
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":\#(now - 5),"event":"Stop","session":"s1","agent_pid":1,"message":"m"}"#), host: HOST)
    store.apply(decode(#"{"ts":\#(now - 5),"event":"Stop","session":"s2","agent_pid":2,"message":"m"}"#), host: HOST)
    store.reapLocal(now: now) { _, _ in true }
    checkEqual(store.visible(now: now).count, 2, "both rows are there to dismiss")
    checkEqual(store.attentionCount(now: now), 2, "and both need you")

    store.dismiss(SessionKey(host: HOST, id: "s1"), now: now)
    checkEqual(store.visible(now: now).map(\.key.id), ["s2"], "only the dismissed row is hidden")
    checkEqual(store.attentionCount(now: now), 1, "a hidden row stops counting toward the badge")
    checkEqual(store.sessions[SessionKey(host: HOST, id: "s1")]!.state, .idle,
               "the session itself is untouched")

    // Work asks for nothing, so the row stays hidden while the session works.
    store.apply(decode(#"{"ts":\#(now + 60),"event":"PreToolUse","session":"s1","agent_pid":1,"tool":"Bash"}"#),
                host: HOST)
    checkEqual(store.visible(now: now + 61).map(\.key.id), ["s2"], "a working session stays hidden")
    checkEqual(store.sessions[SessionKey(host: HOST, id: "s1")]!.state, .running,
               "even though its state did move on")

    // Subagent churn is the same: it moves the clock and asks for nothing.
    store.apply(decode(#"{"ts":\#(now + 65),"event":"SubagentStart","session":"s1","agent_id":"a"}"#), host: HOST)
    store.apply(decode(#"{"ts":\#(now + 66),"event":"SubagentStop","session":"s1","agent_id":"a"}"#), host: HOST)
    checkEqual(store.visible(now: now + 67).map(\.key.id), ["s2"], "subagent churn stays hidden")

    // It comes back when the session asks for you.
    store.apply(decode(#"{"ts":\#(now + 120),"event":"Stop","session":"s1","agent_pid":1,"message":"m"}"#),
                host: HOST)
    checkEqual(store.visible(now: now + 121).map(\.key.id), ["s1", "s2"], "a finished turn brings it back")
    checkEqual(store.attentionCount(now: now + 121), 2, "and it counts toward the badge again")

    // Every way a session asks for you brings the row back.
    for event in ["Stop", "StopFailure", "PermissionRequest", "Notification"] {
        let asker = SessionStore(localHost: HOST)
        asker.apply(decode(#"{"ts":\#(now - 5),"event":"Stop","session":"s1","agent_pid":1}"#), host: HOST)
        asker.dismiss(SessionKey(host: HOST, id: "s1"), now: now)
        checkEqual(asker.visible(now: now).count, 0, "hidden to start with")
        asker.apply(decode(#"{"ts":\#(now + 60),"event":"\#(event)","session":"s1","agent_pid":1}"#), host: HOST)
        checkEqual(asker.visible(now: now + 61).count, 1, "\(event) brings the row back")
    }

    // The case this is for: a stale remote row that never speaks again.
    let remote = SessionStore(localHost: HOST)
    let remoteKey = SessionKey(host: "laptop", id: "r")
    remote.apply(decode(#"{"ts":\#(now - 7200),"event":"SessionStart","session":"r","agent_pid":9}"#),
                 host: "laptop")
    checkEqual(remote.visible(now: now).count, 1, "a two hour old remote row is visible")
    remote.dismiss(remoteKey, now: now)
    checkEqual(remote.visible(now: now + 60).count, 0, "dismissing it hides it at once")
    checkEqual(remote.visible(now: now + 3600).count, 0, "and it stays hidden")

    // In memory by choice, so a restart brings a stale row back. That is the
    // trade, pinned here so nobody reads it later as a bug.
    let restarted = SessionStore(localHost: HOST)
    restarted.apply(decode(#"{"ts":\#(now - 5),"event":"Stop","session":"s1","agent_pid":1}"#), host: HOST)
    checkEqual(restarted.visible(now: now).count, 1, "a restart brings a dismissed row back, by design")
}

func testRoutes() {
    print("routes to another machine")
    let json = """
    {
      "laptop": {
        "tmux": ["ssh", "-o", "BatchMode=yes", "laptop", "/opt/homebrew/bin/tmux"],
        "tab": "laptop"
      },
      "Bare": { "tab": "here" }
    }
    """
    guard let routes = try? Routes.decode(Data(json.utf8)) else {
        check(false, "the route file decodes")
        return
    }
    checkEqual(routes.count, 2, "two routes load")

    // The two machines differ by one character. A prefix or substring match would
    // send a click to the wrong one, so this compare is exact.
    check(routes.route(for: "laptop") != nil, "a host with a route matches")
    check(routes.route(for: "workstation") == nil,
          "another machine is not that host, however close the name looks")
    check(routes.route(for: "laptop-2026-10-17") == nil, "a file name is not a host")
    check(routes.route(for: "LAPTOP") == nil, "host names are compared as written")

    let route = routes.route(for: "laptop")!
    checkEqual(route.argv, ["ssh", "-o", "BatchMode=yes", "laptop", "/opt/homebrew/bin/tmux"],
               "the route runs tmux there through ssh")
    checkEqual(route.tab ?? "-", "laptop", "and names the tab to bring forward")

    // A route with no tmux argv means this machine, which is how the panel is
    // tested without ssh and without touching a real tmux server.
    let bare = routes.route(for: "Bare")!
    checkEqual(bare.argv, ["tmux"], "no tmux argv means tmux on this machine")

}

/// What a click can tell about a remote pane: shared, attached, or gone.
func testPaneAvailability() {
    print("pane availability")
    // Several rows naming one pane cannot be told apart by a click. The replay
    // harness is the real case: every run inherits the pane it was started from.
    var first = Session(key: SessionKey(host: "laptop", id: "a"))
    first.tmuxPane = "%5"
    first.cwd = "/w/api"
    var second = Session(key: SessionKey(host: "laptop", id: "b"))
    second.tmuxPane = "%5"
    second.cwd = "/w/api"
    var third = Session(key: SessionKey(host: "laptop", id: "c"))
    third.tmuxPane = "%6"
    third.cwd = "/w/other"
    checkEqual(TmuxTargeting.sharedPaneRefusal(for: first, among: [first, second, third]) ?? "-",
               "pane %5 is shared by 2 sessions on laptop", "a shared pane is refused")
    check(TmuxTargeting.sharedPaneRefusal(for: first, among: [first, third]) == nil,
          "a pane one row names is not refused")

    // Another folder in the same pane inherited it; it is not a sharer. The replay
    // harness is the real case: its runs start from one tmux pane.
    var inherited = Session(key: SessionKey(host: "laptop", id: "d"))
    inherited.tmuxPane = "%5"
    inherited.cwd = "/w/replay"
    check(TmuxTargeting.sharedPaneRefusal(for: first, among: [first, inherited]) == nil,
          "a session in another folder does not share the pane")
    var sharedLocal = first
    sharedLocal.isLocal = true
    check(TmuxTargeting.sharedPaneRefusal(for: sharedLocal, among: [sharedLocal]) == nil,
          "a local row is never refused this way")

    // The listing carries the window and whether a client shows the session, so a
    // detached pane is reported instead of silently selected.
    let output = "%5,@3,1,/w/api\n%6,@4,0,/w/api,with,commas"
    checkEqual(TmuxTargeting.paneInfo("%5", in: output)?.window, "@3", "a pane names its window")
    checkEqual(TmuxTargeting.paneInfo("%5", in: output)?.attached, true, "and shows it is attached")
    checkEqual(TmuxTargeting.paneInfo("%6", in: output)?.attached, false, "a detached pane is not attached")
    checkEqual(TmuxTargeting.paneInfo("%5", in: output)?.path, "/w/api", "a pane names its folder")
    checkEqual(TmuxTargeting.paneInfo("%6", in: output)?.path, "/w/api,with,commas",
               "a comma in the folder survives")
    check(TmuxTargeting.paneInfo("%9", in: output) == nil, "a missing pane has no entry")

    // A launch folder deep under `.claude` still sits inside the pane's folder.
    check(TmuxTargeting.folderMatches(
        "/Users/you/work/repo/.claude/local.notes/build/de153/live",
        "/Users/you/work/repo"),
        "a deep launch folder matches its pane folder")
    check(!TmuxTargeting.folderMatches(
        "/Users/you/work/other/project", "/Users/you/work/repo"),
        "another repository does not match")
}

/// What a row from another machine plans, with a route and without one.
func testRoutePlanning() {
    print("planning a route")
    let json = #"{"laptop": {"tmux": ["ssh", "laptop", "tmux"], "tab": "laptop"}}"#
    let routes = try! Routes.decode(Data(json.utf8))
    var routedSession = Session(key: SessionKey(host: "laptop", id: "r"))
    routedSession.tmuxPane = "%3"

    // A remote session with a route plans to select there; without one it is
    // refused, which is still the default.
    let routed = Jumper.plan(for: routedSession, routes: routes)
    guard case .route(let host, _, let pane, _) = routed else {
        check(false, "a routed remote session plans a route")
        return
    }
    checkEqual(host, "laptop", "the plan carries the host")
    checkEqual(pane ?? "-", "%3", "and the pane from the record")

    let unrouted = Jumper.plan(for: routedSession, routes: .none)
    guard case .remote(let refusedHost) = unrouted else {
        check(false, "a remote session with no route is refused")
        return
    }
    checkEqual(refusedHost, "laptop", "and the refusal names the machine")

    // A local session never looks at routes, so a route cannot change a local
    // click.
    var local = Session(key: SessionKey(host: HOST, id: "l"))
    local.isLocal = true
    local.tmuxPane = "%9"
    guard case .tmux(let localPane) = Jumper.plan(for: local, routes: routes) else {
        check(false, "a local session still plans a local jump")
        return
    }
    checkEqual(localPane, "%9", "with its own pane")

    // A broken edit yields no routes and a log line, never a broken panel.
    checkEqual(Routes.load(from: URL(fileURLWithPath: "/nonexistent/routes.json")).count, 0,
               "a missing route file is no routes")
    let broken = URL(fileURLWithPath: NSTemporaryDirectory() + "as-broken-routes.json")
    try? Data("{ not json".utf8).write(to: broken)
    checkEqual(Routes.load(from: broken).count, 0, "a malformed route file is no routes")
    try? FileManager.default.removeItem(at: broken)

}

/// Every argument the panel hands to tmux must survive a shell, because a route
/// sends it through ssh and ssh hands the other end to a shell. This is not theory:
/// a space in the format made the shell split it, and a leading # made it a comment,
/// so the other end reported "-F expects an argument".
func testRouteShellSafety() {
    print("what a route sends survives a shell")
    let shellBreakers = " \t\n;|&$`\"'<>()*?[]!"
    var sent = TmuxTargeting.listing
    sent += TmuxTargeting.selects(window: "@3", pane: "%12").flatMap { $0 }
    for argument in sent {
        check(!argument.isEmpty, "no empty argument: \(sent)")
        check(argument.first != "#", "an argument must not start with #: \(argument)")
        check(!argument.contains(where: { shellBreakers.contains($0) }),
              "an argument must not contain a shell character: \(argument)")
    }
    check(sent.contains("%12") && sent.contains("@3"),
          "the pane and the window travel as plain ids")

    // A route names a command the way a shell would, but Process starts a file.
    // A bare name read as a relative path became "/ssh", and no route ran at all.
    let viaPath = Jumper.executable(["ssh", "-o", "BatchMode=yes", "laptop"])
    checkEqual(viaPath.path, "/usr/bin/env", "a bare command is resolved through env")
    checkEqual(viaPath.arguments, ["ssh", "-o", "BatchMode=yes", "laptop"],
               "and keeps every argument, itself included")
    check(FileManager.default.isExecutableFile(atPath: viaPath.path), "which is a real file")

    let absolute = Jumper.executable(["/opt/homebrew/bin/tmux", "list-panes"])
    checkEqual(absolute.path, "/opt/homebrew/bin/tmux", "an absolute command starts directly")
    checkEqual(absolute.arguments, ["list-panes"], "without repeating the program name")
    check(FileManager.default.isExecutableFile(atPath: absolute.path), "and is a real file too")
}

/// A hidden row survives a restart, and still yields to a later ask.
func testDismissSurvivesRestart() {
    print("a dismissal survives a restart")
    let now = 800_000
    let stored: [SessionKey: Int] = [SessionKey(host: HOST, id: "s1"): now + 30]
    let relaunched = SessionStore(localHost: HOST)
    relaunched.apply(decode(#"{"ts":\#(now - 5),"event":"Stop","session":"s1","agent_pid":1,"message":"m"}"#),
                     host: HOST)
    relaunched.restore(dismissed: stored, acknowledged: [:])
    checkEqual(relaunched.visible(now: now).count, 0, "a restored dismissal hides the row")
    relaunched.apply(decode(#"{"ts":\#(now + 60),"event":"Stop","session":"s1","message":"asked again"}"#),
                     host: HOST)
    checkEqual(relaunched.visible(now: now + 61).map(\.key.id), ["s1"],
               "and a later ask brings it back")

    // A click survives a relaunch the same way, which is the other half of dealing with
    // a row: blue means seen, and a restart should not make it red again.
    let clicked: [SessionKey: Int] = [SessionKey(host: HOST, id: "s1"): now + 30]
    let reopened = SessionStore(localHost: HOST)
    reopened.apply(decode(#"{"ts":\#(now - 5),"event":"Stop","session":"s1","agent_pid":1,"message":"m"}"#),
                   host: HOST)
    reopened.restore(dismissed: [:], acknowledged: clicked)
    checkEqual(reopened.needsAttention(reopened.sessions[SessionKey(host: HOST, id: "s1")]!), false,
               "a restored click leaves the row seen")
    checkEqual(reopened.attentionCount(now: now), 0, "and out of the badge")

    // The file itself round trips, both maps together.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory() + "as-memory.json")
    PanelMemory.save(dismissed: stored, acknowledged: clicked, to: tmp)
    let back = PanelMemory.load(from: tmp)
    checkEqual(back.dismissed, stored, "the hidden rows survive a round trip on disk")
    checkEqual(back.acknowledged, clicked, "and so do the clicked ones")
    checkEqual(PanelMemory.load(from: URL(fileURLWithPath: "/nonexistent/x.json")).dismissed.count, 0,
               "a missing file is nothing dealt with")

    // A cover older than the visible window can hide no row that is still shown, so it
    // is dropped. Otherwise the file gains a key for every click, forever.
    let ancient = SessionKey(host: HOST, id: "ancient")
    let pruned = SessionStore(localHost: HOST)
    let expired = now - SessionStore.visibleWindowSeconds - 1
    pruned.restore(dismissed: [ancient: expired], acknowledged: [ancient: expired])
    _ = pruned.visible(now: now)
    check(pruned.dismissed[ancient] == nil, "a dismissal older than the window is dropped")
    check(pruned.acknowledged[ancient] == nil, "and so is a click")
    try? FileManager.default.removeItem(at: tmp)

}

func testMatchingTabs() {
    print("matching a row to its tab")
    let tabs = [
        GhosttyTab(id: "t1", windowId: "w1", name: "first", cwd: "/Users/you/work/api"),
        GhosttyTab(id: "t2", windowId: "w1", name: "second", cwd: "/Users/you/work/api"),
        GhosttyTab(id: "t3", windowId: "w1", name: "notes", cwd: "/Users/you/work/notes")
    ]
    var session = Session(key: SessionKey(host: HOST, id: "s"))
    session.isLocal = true
    session.launchCwd = "/Users/you/work/api"
    checkEqual(Jumper.matchingTabs(for: session, in: tabs).tabs.count, 2,
               "two tabs in that folder are both candidates, which is why a click asks")

    session.launchCwd = "/Users/you/work/api/sub"
    checkEqual(Jumper.matchingTabs(for: session, in: tabs).tabs.count, 2,
               "a session in a subfolder falls back to the folder its tab sits in")

    // A session that knows its own name matches on it, which is what separates two
    // sessions sharing one folder, the case the folder alone cannot settle.
    var named = session
    named.title = "Builder Workshop"
    let namedTabs = [
        GhosttyTab(id: "t1", windowId: "w1", name: "\u{2733} Builder Workshop", cwd: "/Users/you/work/api"),
        GhosttyTab(id: "t2", windowId: "w1", name: "image-gen", cwd: "/Users/you/work/api")
    ]
    checkEqual(Jumper.matchingTabs(for: named, in: namedTabs).tabs.map(\.id), ["t1"],
               "the session name picks its own tab out of a folder two tabs share")

    named.title = "no tab carries this"
    checkEqual(Jumper.matchingTabs(for: named, in: namedTabs).tabs.count, 2,
               "and a name no tab carries falls back to matching the folder")

    // A word shared with a tab in another folder is not evidence. The session's own
    // folder wins, or a click would land in a window that has nothing to do with it.
    var titled = Session(key: SessionKey(host: HOST, id: "titled"))
    titled.isLocal = true
    titled.launchCwd = "/Users/you/work/backend"
    titled.title = "api"
    let mixedTabs = [
        GhosttyTab(id: "x1", windowId: "w1", name: "api notes", cwd: "/Users/you/work/docs"),
        GhosttyTab(id: "x2", windowId: "w1", name: "backend", cwd: "/Users/you/work/backend")
    ]
    checkEqual(Jumper.matchingTabs(for: titled, in: mixedTabs).tabs.map(\.id), ["x2"],
               "a name found only in another folder does not move the click there")

    // With no tab in its folder, the name is the only handle left: the tab may have
    // changed directory after the session started.
    titled.launchCwd = "/Users/you/work/moved"
    checkEqual(Jumper.matchingTabs(for: titled, in: mixedTabs).tabs.map(\.id), ["x1"],
               "with no tab in its folder, a name elsewhere is used")

    session.launchCwd = "/Users/you/work/nowhere"
    checkEqual(Jumper.matchingTabs(for: session, in: tabs).tabs.count, 0,
               "a folder no tab sits in matches nothing")
    checkEqual(Jumper.matchingTabs(for: session, in: []).tabs.count, 0,
               "and with no tabs read at all, nothing matches")
}

func testGroupingByMachine() {
    print("grouping rows by machine")
    let now = 700_000
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":\#(now - 10),"event":"Stop","session":"remote-idle","agent_pid":1}"#),
                host: "laptop")
    store.apply(decode(#"{"ts":\#(now - 5),"event":"PreToolUse","session":"here-run","agent_pid":2,"tool":"Bash"}"#),
                host: HOST)
    store.apply(decode(#"{"ts":\#(now - 4),"event":"Stop","session":"here-idle","agent_pid":3,"message":"m"}"#),
                host: HOST)

    let ordered = store.visible(now: now)
    checkEqual(ordered.map(\.key.id), ["here-idle", "remote-idle", "here-run"],
               "the flat list still sorts attention first across machines")

    let groups = SessionStore.groupedByMachine(ordered)
    checkEqual(groups.count, 2, "one group per machine")
    checkEqual(groups.map(\.host), [HOST, "laptop"], "the local machine leads")
    checkEqual(groups.map(\.isLocal), [true, false], "locality carried into the group")
    checkEqual(groups[0].sessions.map(\.key.id), ["here-idle", "here-run"],
               "order inside a group keeps what needs you first")
    checkEqual(groups[1].sessions.map(\.key.id), ["remote-idle"], "remote row is in its own group")
    checkEqual(groups.flatMap(\.sessions).count, ordered.count, "no row lost or duplicated")

    // One machine is the common case and must stay one group.
    let solo = SessionStore(localHost: HOST)
    solo.apply(decode(#"{"ts":1,"event":"Stop","session":"only","agent_pid":1}"#), host: HOST)
    let single = SessionStore.groupedByMachine(solo.visible(now: 10))
    checkEqual(single.count, 1, "one machine is one group")
    checkEqual(single[0].sessions.count, 1, "and it holds every row")
}

func testRunEnd() {
    print("the run end bridge")
    let now = 900_000
    let other = "laptop"
    let id = "01a1456c-85a3-7312-b94d-5a38b040104f"
    let key = SessionKey(host: other, id: id)
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":\#(now - 5),"event":"Stop","agent":"codex","agent_pid":55062,"session":"\#(id)","cwd":"/w/runner/workspaces/github","tmux":"%1754"}"#),
                host: other)
    checkEqual(store.visible(now: now).count, 1, "a finished remote codex row is shown")
    checkEqual(store.sessions[key]!.state, .idle, "and it is waiting on you")

    // The record the bridge writes carries only ts, event and session. Everything
    // else the panel shows comes from that session's own hook records.
    store.apply(decode(#"{"ts":\#(now),"event":"RunEnd","session":"\#(id)"}"#), host: other)
    checkEqual(store.sessions[key]!.state, .ended, "the bridge record ends it")
    checkEqual(store.sessions[key]!.agent, "codex", "the agent name survives the smaller record")
    checkEqual(store.sessions[key]!.tmuxPane, "%1754", "and so does the terminal to go back to")
    checkEqual(store.needsAttention(store.sessions[key]!), false, "an ended row no longer needs you")

    checkEqual(store.visible(now: now + SessionStore.finishedGraceSeconds).count, 1,
               "it is still listed inside the grace period")
    checkEqual(store.visible(now: now + SessionStore.finishedGraceSeconds + 1).count, 0,
               "and gone after it, with no liveness check available on another machine")

    // A record for a session nobody has seen must not invent a row.
    let clean = SessionStore(localHost: HOST)
    clean.apply(decode(#"{"ts":\#(now),"event":"RunEnd","session":"01a1456c-0000-0000-0000-000000000000"}"#),
                host: other)
    checkEqual(clean.visible(now: now).count, 0, "an end record with no start shows nothing")
}

testSubagentsIgnored()
testMachineGating()
testPlacement()
testAcknowledge()
testLocalHostAgreesWithTheHook()
testGroupingByMachine()
testMatchingTabs()
testDismiss()
testDismissSurvivesRestart()
testRoutes()
testRoutePlanning()
testPaneAvailability()
testRouteShellSafety()
testRunEnd()
testRemoteTransport()
testCodexTitles()
testReviewRegressions()
MainActor.assumeIsolated { testStartSources() }

print("")
if failures == 0 {
    print("PASS  \(checks) checks")
    exit(0)
} else {
    print("FAIL  \(failures) of \(checks) checks failed")
    exit(1)
}
