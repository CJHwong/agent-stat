import Foundation

/// Names are metadata. They must not make a quiet session look active.
final class CodexTitles {
    private static let dateFormats: [ISO8601DateFormatter] = [true, false].map { fractional in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    private struct Name {
        let title: String
        let updated: Date
    }

    private struct Index {
        let stamp: FileStamp
        let names: [String: Name]
    }

    private var indexes: [URL: Index] = [:]

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        CodexTitles().read(home: home)
    }

    func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        let children = (try? FileManager.default.contentsOfDirectory(at: home,
            includingPropertiesForKeys: nil)) ?? []
        var profiles = children.filter { $0.lastPathComponent.hasPrefix(".codex") }
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            profiles.append(URL(fileURLWithPath: custom))
        }
        var names: [String: Name] = [:]
        var visited: Set<URL> = []
        for profile in profiles.sorted(by: { $0.path < $1.path }) {
            let index = profile.appendingPathComponent("session_index.jsonl").resolvingSymlinksInPath()
            guard visited.insert(index).inserted else { continue }
            for (session, name) in readIndex(index) {
                guard name.updated >= (names[session]?.updated ?? .distantPast) else { continue }
                names[session] = name
            }
        }
        indexes = indexes.filter { visited.contains($0.key) }
        return names.mapValues(\.title)
    }

    private func readIndex(_ url: URL) -> [String: Name] {
        guard let stamp = FileStamp(url), stamp.isRegular else {
            indexes.removeValue(forKey: url)
            return [:]
        }
        if stamp.isPrecise, let previous = indexes[url], previous.stamp == stamp { return previous.names }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            indexes.removeValue(forKey: url)
            return [:]
        }
        var names: [String: Name] = [:]
        for line in text.split(separator: "\n") {
            guard let bytes = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let session = entry["id"] as? String,
                  let title = entry["thread_name"] as? String, !title.isEmpty else { continue }
            let clean = title.replacingOccurrences(of: "[\\n\\r\\t]+", with: " ", options: .regularExpression)
            names[session] = Name(title: String(clean.prefix(200)), updated: Self.timestamp(entry["updated_at"]))
        }
        indexes[url] = Index(stamp: stamp, names: names)
        return names
    }

    private static func timestamp(_ value: Any?) -> Date {
        guard let text = value as? String else { return .distantPast }
        return dateFormats.lazy.compactMap { $0.date(from: text) }.first ?? .distantPast
    }

    static func cached(in directory: URL) -> [String: String] {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("titles.json")),
              let names = try? JSONDecoder().decode([String: String].self, from: bytes) else { return [:] }
        return names
    }
}
