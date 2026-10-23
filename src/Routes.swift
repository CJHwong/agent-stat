import Foundation

/// Where a click sends a session that lives on another machine.
///
/// A tmux pane id is only unique inside one tmux server, and a folder name exists
/// on both machines, so acting locally on a remote row lands in the wrong place.
/// The panel refuses that by default, and a route is the explicit exception: it
/// says how to run tmux on that machine.
struct Route: Decodable {
    /// The argv that reaches tmux on that machine. The panel appends the tmux
    /// subcommand, so the last element is tmux itself, with any flags it needs:
    ///
    ///   ["ssh", "-o", "BatchMode=yes", "laptop", "/opt/homebrew/bin/tmux"]
    ///
    /// An empty list means tmux on this machine. That is for a test, or for a
    /// tmux that the panel finds on its own PATH.
    private let tmux: [String]?
    /// A Ghostty tab title substring to bring forward on this machine, matched
    /// without case. Optional: without it the click selects on the other machine
    /// and says where.
    let tab: String?
    /// The event helper command uses the same SSH host as the jump route.
    let events: [String]?

    var argv: [String] {
        guard let tmux, !tmux.isEmpty else { return ["tmux"] }
        return tmux
    }
}

/// Every route, keyed by the host name the events file carries.
struct Routes {
    private let byHost: [String: Route]

    static let none = Routes(byHost: [:])

    private init(byHost: [String: Route]) {
        self.byHost = byHost
    }

    static func load() -> Routes {
        load(from: routesURL)
    }

    /// Read the route file. A missing file is no routes, and a broken one is no
    /// routes plus a log line: a bad edit must never take the panel down.
    static func load(from url: URL?) -> Routes {
        guard let url, let data = try? Data(contentsOf: url) else { return .none }
        do {
            return try decode(data)
        } catch {
            Log.write("routes: cannot read \(url.path): \(error)")
            return .none
        }
    }

    static func decode(_ data: Data) throws -> Routes {
        Routes(byHost: try JSONDecoder().decode([String: Route].self, from: data))
    }

    /// Overridable so a test tree can carry its own routes.
    static var routesURL: URL? {
        if let override = ProcessInfo.processInfo.environment["AGENT_STAT_ROUTES"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-stat/routes.json")
    }

    /// The route for a host, by exact name.
    ///
    /// Never by prefix or substring. The two machines in the events files differ
    /// by one character, and a guess would send a click to the wrong one.
    func route(for host: String) -> Route? {
        byHost[host]
    }

    /// For the startup line, so the log says whether any route loaded at all.
    var count: Int { byHost.count }

    var streams: [String: [String]] {
        byHost.compactMapValues { route in
            guard let events = route.events, !events.isEmpty else { return nil }
            return events
        }
    }
}
