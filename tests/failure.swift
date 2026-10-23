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
