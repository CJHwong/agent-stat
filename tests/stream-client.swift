import Darwin
import Foundation

@main
struct StreamProbeClient {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5, let seconds = Double(arguments[3]), seconds > 0 else {
            fputs("usage: stream-client HOST CACHE SECONDS COMMAND [ARGUMENTS]\n", stderr)
            exit(2)
        }
        let host = arguments[1]
        let directory = URL(fileURLWithPath: arguments[2])
        let reader = EventReader()
        let store = SessionStore(localHost: "probe-consumer")
        let report: (String, [String: Bool]?) -> Void = { state, alive in
            let records = reader.poll(directory: directory)
            for item in records { store.apply(item.record, host: item.host, position: item.position) }
            store.applyTitles(CodexTitles.cached(in: directory), host: host)
            if let alive { store.reapRemote(host: host, alive: alive, now: Int(Date().timeIntervalSince1970)) }
            var sessions: [String: [String: Any]] = [:]
            for session in store.sessions.values {
                sessions[session.key.id] = ["state": session.state.rawValue,
                                            "title": session.title as Any? ?? NSNull(),
                                            "timestamp": session.lastTs,
                                            "alive": session.alive.map { $0 as Any } ?? NSNull(),
                                            "subagents": session.liveSubagents.count]
            }
            let snapshot: [String: Any] = [
                "state": state, "alive": alive ?? [:], "sessions": sessions,
                "records": records.map { ["session": $0.record.session ?? "", "event": $0.record.event] }
            ]
            do {
                var encoded = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
                encoded.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: encoded)
            } catch {
                fputs("cannot write probe snapshot: \(error)\n", stderr)
                exit(1)
            }
        }
        report("cached", nil)
        let stream = RemoteStream(host: host, argv: Array(arguments.dropFirst(4)),
                                  directory: directory) { _, state, alive in report(state, alive) }
        stream.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            stream.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
        }
        dispatchMain()
    }
}
