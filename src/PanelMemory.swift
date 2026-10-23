import Foundation

/// What you have already dealt with: the rows you hid, and the rows you clicked.
///
/// Both are machine-local, and both have the same shape: a session key and the time you
/// dealt with it. A row comes back when its session asks for you after that time, so
/// neither a hide nor a click can outlive the session it was about.
///
/// Written beside the route file, not in the synced events directory, where it would
/// travel to a machine that has no panel.
enum PanelMemory {
    struct Snapshot {
        var dismissed: [SessionKey: Int] = [:]
        var acknowledged: [SessionKey: Int] = [:]
        var dismissedPositions: [SessionKey: EventPosition] = [:]
        var acknowledgedPositions: [SessionKey: EventPosition] = [:]
    }

    /// The file's shape. Keys are "host/session", values are the time dealt with.
    private struct Stored: Codable {
        var dismissed: [String: Int] = [:]
        var acknowledged: [String: Int] = [:]
        var dismissedPositions: [String: EventPosition]?
        var acknowledgedPositions: [String: EventPosition]?
    }

    /// Overridable so a test or a probe can use its own file.
    static var url: URL {
        if let override = ProcessInfo.processInfo.environment["AGENT_STAT_MEMORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-stat/memory.json")
    }

    /// Read what was dealt with. A missing file is nothing, and a broken one is nothing
    /// plus a log line: a bad edit must never take the panel down.
    static func load(from url: URL? = nil) -> Snapshot {
        let target = url ?? Self.url
        guard let data = try? Data(contentsOf: target) else { return Snapshot() }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            return Snapshot(dismissed: keys(from: stored.dismissed), acknowledged: keys(from: stored.acknowledged),
                            dismissedPositions: keys(from: stored.dismissedPositions ?? [:]),
                            acknowledgedPositions: keys(from: stored.acknowledgedPositions ?? [:]))
        } catch {
            Log.write("memory: cannot read \(target.path): \(error)")
            return Snapshot()
        }
    }

    /// Write what was dealt with. The file is small, and it is written only when you
    /// hide a row or click one.
    static func save(dismissed: [SessionKey: Int], acknowledged: [SessionKey: Int],
                     dismissedPositions: [SessionKey: EventPosition] = [:],
                     acknowledgedPositions: [SessionKey: EventPosition] = [:],
                     to url: URL? = nil) {
        let target = url ?? Self.url
        let stored = Stored(dismissed: names(of: dismissed), acknowledged: names(of: acknowledged),
                            dismissedPositions: names(of: dismissedPositions),
                            acknowledgedPositions: names(of: acknowledgedPositions))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Atomic: a crash or a full disk mid-write must not truncate the file, because
        // the load path would then discard every dismissal and acknowledgement.
        try? data.write(to: target, options: .atomic)
    }

    private static func names<Value>(of dealt: [SessionKey: Value]) -> [String: Value] {
        var out: [String: Value] = [:]
        for (key, when) in dealt { out["\(key.host)/\(key.id)"] = when }
        return out
    }

    private static func keys<Value>(from names: [String: Value]) -> [SessionKey: Value] {
        var out: [SessionKey: Value] = [:]
        for (name, when) in names {
            guard let split = name.firstIndex(of: "/") else { continue }
            let host = String(name[name.startIndex..<split])
            let id = String(name[name.index(after: split)...])
            guard !host.isEmpty, !id.isEmpty else { continue }
            out[SessionKey(host: host, id: id)] = when
        }
        return out
    }
}
