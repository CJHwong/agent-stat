import Foundation

/// Claude reports a failed turn directly with StopFailure.
func testClaudeFailure() {
    print("a claude failure")
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":100,"event":"SessionStart","agent":"claude","session":"c","agent_pid":1}"#), host: HOST)
    store.apply(decode(#"{"ts":110,"event":"UserPromptSubmit","agent":"claude","session":"c"}"#), host: HOST)
    store.apply(decode(#"{"ts":120,"event":"StopFailure","agent":"claude","session":"c","message":"model_not_found"}"#), host: HOST)
    store.apply(decode(#"{"ts":121,"event":"SessionEnd","agent":"claude","session":"c","reason":"other"}"#), host: HOST)
    let session = store.sessions[SessionKey(host: HOST, id: "c")]!
    checkEqual(session.state, .failed, "a StopFailure survives SessionEnd")
    checkEqual(session.askedAt, 120, "the failure asks at its own timestamp")
    checkEqual(store.attentionCount(now: 121), 1, "a failed session needs you")
    checkEqual(store.isAcknowledged(session), false, "and it is not dealt with yet")
}

/// Codex sends no failure event, so an end mid-turn is the failure.
func testCodexFailure() {
    print("a codex failure")
    let failed = SessionStore(localHost: HOST)
    failed.apply(decode(#"{"ts":200,"event":"SessionStart","agent":"codex","session":"x","agent_pid":2}"#), host: HOST)
    failed.apply(decode(#"{"ts":210,"event":"UserPromptSubmit","agent":"codex","session":"x","turn":"t"}"#), host: HOST)
    failed.apply(decode(#"{"ts":215,"event":"Stop","agent":"codex","session":"x","message":"first turn"}"#), host: HOST)
    failed.apply(decode(#"{"ts":216,"event":"UserPromptSubmit","agent":"codex","session":"x","turn":"t2"}"#), host: HOST)
    failed.apply(decode(#"{"ts":220,"event":"SessionEnd","agent":"codex","session":"x","reason":"other"}"#), host: HOST)
    let session = failed.sessions[SessionKey(host: HOST, id: "x")]!
    checkEqual(session.state, .failed, "a codex end mid-turn is a failure")
    check(session.lastMessage == nil, "an older message is not shown as the error")
    checkEqual(failed.attentionCount(now: 221), 1, "and it needs you")

    // A completed turn sends Stop first, so its end is clean.
    let clean = SessionStore(localHost: HOST)
    clean.apply(decode(#"{"ts":300,"event":"SessionStart","agent":"codex","session":"k","agent_pid":3}"#), host: HOST)
    clean.apply(decode(#"{"ts":310,"event":"UserPromptSubmit","agent":"codex","session":"k","turn":"t"}"#), host: HOST)
    clean.apply(decode(#"{"ts":320,"event":"Stop","agent":"codex","session":"k","message":"ok"}"#), host: HOST)
    clean.apply(decode(#"{"ts":321,"event":"SessionEnd","agent":"codex","session":"k","reason":"other"}"#), host: HOST)
    checkEqual(clean.sessions[SessionKey(host: HOST, id: "k")]!.state, .ended,
               "a codex turn that stopped is a clean end")
    checkEqual(clean.attentionCount(now: 322), 0, "and it does not need you")

    // Only Codex infers this. Claude has its own failure record.
    let claude = SessionStore(localHost: HOST)
    claude.apply(decode(#"{"ts":400,"event":"SessionStart","agent":"claude","session":"q","agent_pid":4}"#), host: HOST)
    claude.apply(decode(#"{"ts":410,"event":"UserPromptSubmit","agent":"claude","session":"q"}"#), host: HOST)
    claude.apply(decode(#"{"ts":420,"event":"SessionEnd","agent":"claude","session":"q","reason":"other"}"#), host: HOST)
    checkEqual(claude.sessions[SessionKey(host: HOST, id: "q")]!.state, .ended,
               "a claude end mid-turn does not infer a failure")
}

/// A model at capacity fails before the first turn, and an orchestrator can end
/// a run that never sent Stop. Both are failures, not clean ends.
func testCodexEarlyEnd() {
    print("a codex end before a turn")
    let startup = SessionStore(localHost: HOST)
    startup.apply(decode(#"{"ts":250,"event":"SessionStart","agent":"codex","session":"s","agent_pid":5}"#), host: HOST)
    startup.apply(decode(#"{"ts":260,"event":"SessionEnd","agent":"codex","session":"s","reason":"other"}"#), host: HOST)
    checkEqual(startup.sessions[SessionKey(host: HOST, id: "s")]!.state, .failed,
               "a codex end before the first turn is a failure")
    checkEqual(startup.attentionCount(now: 261), 1, "and it needs you")

    // A Codex app-server session can send only an end. It is not a failed turn.
    let bare = SessionStore(localHost: HOST)
    bare.apply(decode(#"{"ts":240,"event":"SessionEnd","agent":"codex","session":"bare"}"#), host: HOST)
    checkEqual(bare.sessions[SessionKey(host: HOST, id: "bare")]!.state, .ended,
               "a codex end with no start is not a failure")
    checkEqual(bare.visible(now: 240 + SessionStore.finishedGraceSeconds + 1).count, 0,
               "and it leaves after the end grace")

    let run = SessionStore(localHost: HOST)
    run.apply(decode(#"{"ts":270,"event":"SessionStart","agent":"codex","session":"r","agent_pid":6}"#), host: HOST)
    run.apply(decode(#"{"ts":280,"event":"UserPromptSubmit","agent":"codex","session":"r"}"#), host: HOST)
    run.apply(decode(#"{"ts":290,"event":"RunEnd","session":"r"}"#), host: HOST)
    checkEqual(run.sessions[SessionKey(host: HOST, id: "r")]!.state, .failed,
               "a codex run ended mid-turn is a failure")
    checkEqual(run.attentionCount(now: 291), 1, "and it needs you")
}

/// A quiet session stays while its process is known alive, and leaves otherwise.
func testQuietLiveSession() {
    print("a quiet live session")
    let now = 1_000_000
    let last = now - SessionStore.visibleWindowSeconds - 3600
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":\#(last),"event":"Stop","session":"quiet","agent_pid":1}"#), host: HOST)
    store.reapLocal(now: last + 1) { _, _ in true }
    checkEqual(store.visible(now: now).map(\.key.id), ["quiet"],
               "a live quiet session stays past the window")

    let dead = SessionStore(localHost: HOST)
    dead.apply(decode(#"{"ts":\#(last),"event":"Stop","session":"quiet","agent_pid":2}"#), host: HOST)
    dead.reapLocal(now: last + 1) { _, _ in false }
    checkEqual(dead.visible(now: now).count, 0, "a dead quiet session still leaves")
}

/// A failure asks for you for half a day, then leaves.
func testOldFailure() {
    print("an old failure leaves")
    let now = 2_000_000
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":\#(now - SessionStore.failureWindowSeconds - 1),"event":"StopFailure","agent":"claude","session":"old"}"#), host: HOST)
    checkEqual(store.visible(now: now).count, 0, "a failure past its window leaves")
    store.apply(decode(#"{"ts":\#(now - 60),"event":"StopFailure","agent":"claude","session":"new"}"#), host: HOST)
    checkEqual(store.visible(now: now).map(\.key.id), ["new"], "a recent failure stays")
}

/// A failure stays until you deal with it, and it outranks work in flight.
func testFailureLifecycle() {
    print("a failure stays")
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":500,"event":"StopFailure","agent":"claude","session":"f"}"#), host: HOST)
    store.apply(decode(#"{"ts":590,"event":"UserPromptSubmit","agent":"claude","session":"w"}"#), host: HOST)
    checkEqual(store.visible(now: 591).first?.key.id, "f", "a failure sorts above work in flight")

    // A clean end is gone after ten seconds. A failure is still there.
    let later = 500 + SessionStore.finishedGraceSeconds + 1
    checkEqual(store.visible(now: later).contains { $0.key.id == "f" }, true,
               "a failure outlives the clean-end grace")
    checkEqual(store.attentionCount(now: later), 1, "and stays in the badge")

    // The process is gone, but the failure is not. A vanished process hides a
    // running row after a minute; a failure stays until you deal with it.
    let crashed = SessionStore(localHost: HOST)
    crashed.apply(decode(#"{"ts":700,"event":"StopFailure","agent":"claude","session":"g","agent_pid":9}"#), host: HOST)
    crashed.reapLocal(now: 700) { _, _ in false }
    let gone = 700 + SessionStore.crashedGraceSeconds + 1
    checkEqual(crashed.visible(now: gone).count, 1, "a failure outlives the vanished grace")
    checkEqual(crashed.attentionCount(now: gone), 1, "and stays in the badge")

    store.acknowledge(SessionKey(host: HOST, id: "f"), now: later)
    checkEqual(store.attentionCount(now: later), 0, "clicking a failure clears the flag")

    // The orchestrator bridge does not erase it either.
    let run = SessionStore(localHost: HOST)
    run.apply(decode(#"{"ts":600,"event":"StopFailure","agent":"claude","session":"r"}"#), host: HOST)
    run.apply(decode(#"{"ts":610,"event":"RunEnd","agent":"claude","session":"r"}"#), host: HOST)
    checkEqual(run.sessions[SessionKey(host: HOST, id: "r")]!.state, .failed,
               "RunEnd keeps a failure")
    checkEqual(run.attentionCount(now: 611), 1, "and it still needs you")
}

func testFinishedRunOutlivesItsProcess() {
    print("a finished run stays after its process exits")
    let host = "Other-Machine"
    let store = SessionStore(localHost: HOST)
    store.apply(decode(#"{"ts":800,"event":"Stop","agent":"codex","session":"done","agent_pid":7}"#), host: host)
    store.apply(decode(#"{"ts":800,"event":"RunEnd","session":"done"}"#), host: host)
    store.apply(decode(#"{"ts":800,"event":"PreToolUse","agent":"codex","session":"busy","agent_pid":8,"tool":"Bash"}"#),
                host: host)
    // A codex closed with its tab after a turn sends Stop and no end record. You
    // closed it, so it has nothing left to ask.
    store.apply(decode(#"{"ts":800,"event":"Stop","agent":"codex","session":"closed","agent_pid":9}"#), host: host)
    store.reapRemote(host: host, alive: ["done": false, "busy": false, "closed": false], now: 801)
    let later = 801 + SessionStore.crashedGraceSeconds + 1
    let finished = SessionKey(host: host, id: "done")
    check(!store.sessions[finished]!.vanishedWithoutEnd, "a run the bridge ended did not crash")
    checkEqual(store.visible(now: later).map(\.key.id), ["done"], "only the run the bridge ended stays")
    checkEqual(store.attentionCount(now: later), 1, "and it needs you")

    var routed = store.sessions[finished]!
    routed.tmuxPane = "%1"
    let routes = try! Routes.decode(Data(#"{"Other-Machine": {"tmux": ["ssh", "peer", "tmux"]}}"#.utf8))
    guard case .unavailable(let message) = Jumper.plan(for: routed, routes: routes) else {
        check(false, "a click on an ended run does not select a pane")
        return
    }
    check(message.contains("ended"), "and says the run ended")

    store.acknowledge(finished, now: later)
    check(store.visible(now: later).isEmpty, "a click clears the finished run")
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
    checkEqual(store.sessions[key]!.state, .idle, "a finished run keeps its answer")
    check(store.sessions[key]!.finishedRun, "and the bridge marks the run over")
    checkEqual(store.sessions[key]!.agent, "codex", "the agent name survives the smaller record")
    checkEqual(store.sessions[key]!.tmuxPane, "%1754", "and so does the terminal to go back to")
    store.reapRemote(host: other, alive: [id: false], now: now + 1)
    let later = now + SessionStore.crashedGraceSeconds + 2
    checkEqual(store.visible(now: later).count, 1, "it stays after its process exits")
    checkEqual(store.attentionCount(now: later), 1, "and it still needs you")
    store.acknowledge(key, now: later)
    checkEqual(store.visible(now: later).count, 0, "a click clears it")

    // An orchestrator resumes one codex session for its next run. That run is live until
    // the bridge ends it too, even after its own Stop.
    let next = later + 10
    store.apply(decode(#"{"ts":\#(next),"event":"SessionStart","agent":"codex","agent_pid":55063,"session":"\#(id)","cwd":"/w/runner","tmux":"%1760"}"#),
                host: other)
    store.apply(decode(#"{"ts":\#(next + 1),"event":"UserPromptSubmit","session":"\#(id)"}"#), host: other)
    store.apply(decode(#"{"ts":\#(next + 2),"event":"Stop","session":"\#(id)"}"#), host: other)
    store.reapRemote(host: other, alive: [id: true], now: next + 3)
    let routes = try! Routes.decode(Data(#"{"\#(other)": {"tmux": ["ssh", "peer", "tmux"]}}"#.utf8))
    check(!store.sessions[key]!.finishedRun, "a resumed run is not the run the bridge ended")
    guard case .route(_, _, let pane, _, _, _) = Jumper.plan(for: store.sessions[key]!, routes: routes) else {
        check(false, "a click on the resumed run goes to its new pane")
        return
    }
    checkEqual(pane ?? "-", "%1760", "the click uses the resumed run's pane")

    // A Claude run the bridge ended stays the same way. Without the bridge record,
    // a Claude whose process is gone after a Stop is a closed terminal.
    let claude = SessionStore(localHost: HOST)
    claude.apply(decode(#"{"ts":\#(now - 5),"event":"Stop","agent":"claude","session":"c"}"#), host: other)
    claude.apply(decode(#"{"ts":\#(now),"event":"RunEnd","session":"c"}"#), host: other)
    claude.reapRemote(host: other, alive: ["c": false], now: now + 1)
    checkEqual(claude.visible(now: later).count, 1, "a finished Claude run stays too")

    // A run that ends before its turn finished is not an answer.
    let cut = SessionStore(localHost: HOST)
    cut.apply(decode(#"{"ts":\#(now - 5),"event":"UserPromptSubmit","agent":"claude","session":"u"}"#), host: other)
    cut.apply(decode(#"{"ts":\#(now),"event":"RunEnd","session":"u"}"#), host: other)
    checkEqual(cut.sessions[SessionKey(host: other, id: "u")]!.state, .ended, "an unfinished run ends")
    checkEqual(cut.visible(now: now + SessionStore.finishedGraceSeconds + 1).count, 0,
               "and clears after the grace period")

    // A record for a session nobody has seen must not invent a row.
    let clean = SessionStore(localHost: HOST)
    clean.apply(decode(#"{"ts":\#(now),"event":"RunEnd","session":"01a1456c-0000-0000-0000-000000000000"}"#),
                host: other)
    checkEqual(clean.visible(now: now).count, 0, "an end record with no start shows nothing")
}
