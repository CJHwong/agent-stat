import Darwin
import Foundation

enum Paths {
    /// Overridable so the app can be pointed at a test tree.
    static var eventsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENT_STAT_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/agent-stat")
    }

    static var hostsDirectory: URL {
        eventsDirectory.appendingPathComponent("hosts")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/agent-stat.log")
    }

    /// This machine's name, the same value the hook writes into every record.
    ///
    /// Read with gethostname(2), which returns the same kernel nodename that
    /// `uname -n` prints in the hook. ProcessInfo.hostName is NOT that value: it
    /// comes back lowercased, so comparing it against the written host marked
    /// every local session remote. That silently broke three things, because
    /// locality gates them all: clicking a row refused to jump, the liveness
    /// probe never ran, and the local machine stopped sorting first.
    ///
    /// The two sides must stay byte identical. A case-insensitive compare here
    /// would hide the next mismatch instead of showing it.
    ///
    /// Deliberately not read from a file in the events directory: a copied
    /// directory can carry another machine name, and both machines end up
    /// claiming to be the same one.
    static func localHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else {
            // Fails closed, and the startup line in the log shows it as an empty
            // localHost rather than hiding it.
            return ""
        }
        // A fail-closed decode: an empty name means no session counts as local, and
        // the startup line in the log shows an empty localHost rather than hiding it.
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        let raw = String(bytes: bytes, encoding: .utf8) ?? ""
        return raw.hasSuffix(".local") ? String(raw.dropLast(".local".count)) : raw
    }
}

enum Log {
    private static let formatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return dateFormatter
    }()

    /// One line per event. Enough detail to diagnose a failure after the fact.
    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = Paths.logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}
