import Foundation
import SwiftUI

@MainActor
func testStartSources() {
    print("session start sources and dot colors")
    let cases: [(String?, String)] = [
        ("startup", "ready"), ("resume", "resumed"),
        ("clear", "cleared"), ("compact", "context compacted"),
        (nil, "ready"), ("future-source", "ready")
    ]
    for (source, detail) in cases {
        let store = SessionStore(localHost: HOST)
        let key = SessionKey(host: HOST, id: "start")
        let sourceField = source.map { #", "source":"\#($0)""# } ?? ""
        store.apply(decode(#"{"ts":1,"event":"PreToolUse","session":"start","tool":"Bash"}"#), host: HOST)
        store.apply(decode(#"{"ts":2,"event":"SessionStart","agent":"claude","session":"start"\#(sourceField)}"#), host: HOST)
        let session = store.sessions[key]!
        let model = PanelModel()
        model.update(from: [session], now: 3, eventsDirectory: URL(fileURLWithPath: "/unused"),
                     attention: store.attentionCount(now: 3), acknowledged: { _ in false })
        let row = model.groups[0].rows[0]
        checkEqual(row.detail, detail, "start source selects its text")
        checkEqual(row.accent, .blue, "a ready session has a blue dot without a click")
        check(!row.isWorking, "a ready session does not pulse")
        checkEqual(model.attentionCount, 0, "a ready session does not ask for attention")
        check(session.tool == nil && session.toolStartedAt == nil, "a new start clears the prior tool")
        store.apply(decode(#"{"ts":3,"event":"UserPromptSubmit","session":"start"}"#), host: HOST)
        model.update(from: [store.sessions[key]!], now: 3, eventsDirectory: URL(fileURLWithPath: "/unused"),
                     attention: 0, acknowledged: { _ in false })
        checkEqual(model.groups[0].rows[0].accent, .green, "a prompt returns the dot to green")
        checkEqual(model.groups[0].rows[0].detail, "thinking", "work replaces the start text")
        check(model.groups[0].rows[0].isWorking, "a running turn pulses")
    }
}
