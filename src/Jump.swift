import AppKit
import Foundation

/// A Ghostty tab, as far as we can see it.
///
/// Since 1.4.0 the scripting dictionary reports the pty and the foreground pid of
/// every surface. The tty is the exact handle: it names one surface, where a
/// folder can name several tabs. It is empty when the running Ghostty does not
/// report it, which is every build before 1.4.0.
struct GhosttyTab: Identifiable, Equatable {
    let id: String
    let windowId: String
    let name: String
    let cwd: String
    /// The surface pty, as `/dev/ttysNNN`. Empty when unknown.
    let tty: String
    var surfaceID: String?

    var selectionID: String { windowId + ":" + id + ":" + (surfaceID ?? tty) }

    func pickerName(in tabs: [GhosttyTab]) -> String {
        let surfaces = tabs.filter { $0.windowId == windowId && $0.id == id }
        guard surfaces.count > 1, let index = surfaces.firstIndex(of: self) else { return name }
        return "\(name) (split \(index + 1))"
    }
}

/// What clicking a row will do.
struct TmuxContext {
    var socket: String?
    var folder = ""
    var title: String?
    var tty = ""
    var pid: Int?
    var started: String?
    var refusal: String?
    var tabs: [GhosttyTab]?
}

enum JumpPlan {
    /// A tmux pane id, which is exact within this machine's tmux server.
    case tmux(pane: String?, context: TmuxContext = TmuxContext())
    case unavailable(String)
    /// Matching Ghostty tabs, plus the folder that matched. One tab acts
    /// directly, several open a picker, none just raises the app.
    case ghostty(folder: String, tabs: [GhosttyTab])
    /// No usable handle. Raise the terminal app and say so.
    case raiseApp(String)
    /// The session is on another machine and no route names that machine.
    case remote(host: String)
    /// The session is on another machine and a route reaches it. `pane` is nil
    /// for a session there that reports no tmux pane.
    case route(host: String, route: Route, pane: String?, folder: String,
               title: String? = nil, socket: String? = nil)
}

/// What a click did, or what it needs from you.
enum JumpOutcome {
    /// The jump happened. A message is a short line for the panel, or nil when
    /// there is nothing to say.
    case done(message: String?)
    case failed(message: String)
    /// Several tabs could be the one, so nothing moved and the panel must ask.
    case pick(folder: String, tabs: [GhosttyTab])

    var message: String? {
        switch self {
        case .done(let message): return message
        case .failed(let message): return message
        case .pick: return nil
        }
    }

    var succeeded: Bool {
        if case .done = self { return true }
        return false
    }
}

/// Human name for a TERM_PROGRAM value.
private func displayName(for term: String) -> String? {
    switch term {
    case "ghostty": return "Ghostty"
    case "Apple_Terminal": return "Terminal"
    case "iTerm.app": return "iTerm"
    case "WezTerm": return "WezTerm"
    case "vscode": return "Code"
    default: return nil
    }
}

enum Jumper {
    private static let fieldSeparator = "\u{1f}"

    // MARK: planning

    static func plan(for session: Session, routes: Routes = .none) -> JumpPlan {
        // Refuse to cross machines before looking at anything local, unless a
        // route names that machine. A tmux pane id is only unique inside one tmux
        // server, and a folder exists on both machines, so acting locally on a
        // remote session lands in the wrong tab.
        if let host = session.onAnotherMachine {
            guard let route = routes.route(for: host) else { return .remote(host: host) }
            let folder = session.launchCwd.isEmpty ? session.cwd : session.launchCwd
            return .route(host: host, route: route, pane: session.tmuxPane, folder: folder,
                          title: session.title, socket: session.tmuxSocket)
        }
        var context = localContext(for: session)
        if let refusal = localRefusal(context) { return .unavailable(refusal) }
        if let pane = session.tmuxPane, !pane.isEmpty {
            return .tmux(pane: pane, context: context)
        }
        let appName = session.term.flatMap(displayName(for:)) ?? "Ghostty"
        guard appName == "Ghostty" else { return .raiseApp(appName) }
        var identified = session
        identified.tty = context.tty
        let snapshot = ghosttyTabs()
        let (folder, tabs) = matchingTabs(for: identified, in: snapshot)
        context.tabs = snapshot
        if let title = session.title, !title.isEmpty,
           tabs.isEmpty || localClientsContain(tabs, socket: context.socket) {
            return .tmux(pane: nil, context: context)
        }
        return tabs.isEmpty ? .raiseApp(appName) : .ghostty(folder: folder, tabs: tabs)
    }

    /// Tabs for the folder the session was launched in.
    ///
    /// Falls back to ancestors, because an agent launched in a subdirectory of
    /// the folder its tab sits in is normal: `cd` inside a tool call moves the
    /// agent and leaves the tab behind. Closest ancestor with a match wins.
    static func matchingTabs(for session: Session) -> (folder: String, tabs: [GhosttyTab]) {
        matchingTabs(for: session, in: ghosttyTabs())
    }

    /// Tabs for the folder the session was launched in, from a list already read.
    ///
    /// Split from the read so the panel can match every row against one enumeration
    /// instead of forking once per row, and so a test can drive the match directly.
    static func matchingTabs(for session: Session,
                             in all: [GhosttyTab]) -> (folder: String, tabs: [GhosttyTab]) {
        guard !all.isEmpty else { return ("", []) }
        // A tty names exactly one surface, so it settles what the folder cannot:
        // two sessions launched in one folder. Every step below is a fallback for
        // a record written before the tty was captured, or for a Ghostty that
        // does not report one, so an empty tty must never match an empty tty.
        let exact = session.tty.isEmpty ? [] : all.filter { $0.tty == session.tty }
        if exact.count == 1 {
            let folder = session.launchCwd.isEmpty ? session.cwd : session.launchCwd
            let compatible = !folder.isEmpty && TmuxTargeting.folderMatches(folder, exact[0].cwd)
            guard session.agentPid != nil || compatible else {
                return ("", [])
            }
            return (exact[0].cwd, exact)
        }
        let byFolder = folderCandidates(for: session, in: all)
        // A session that knows its own name matches on that first, because a tab title
        // is usually that name: Claude Code sets the tab title from the conversation.
        // Two sessions in one folder therefore separate, which matching by folder cannot
        // do. A tab title carries a status glyph the session name does not, so the title
        // is looked for inside the tab's name rather than compared to it.
        //
        // The search stays inside the session's folder: a tab elsewhere that shares the
        // word is not evidence. Only a folder with no tab at all falls back to the name,
        // which happens when the tab changed directory after the session started.
        if let title = session.title, !title.isEmpty {
            let named = byFolder.tabs.filter {
                $0.name.range(of: title, options: .caseInsensitive) != nil
            }
            if named.count == 1 { return (byFolder.folder, named) }
            if byFolder.tabs.isEmpty {
                let namedAnywhere = all.filter {
                    $0.name.range(of: title, options: .caseInsensitive) != nil
                }
                if namedAnywhere.count == 1 { return (session.launchCwd, namedAnywhere) }
            }
        }
        return byFolder
    }

    /// The tabs in the session's folder, walking up to four parents.
    private static func folderCandidates(for session: Session,
                                         in all: [GhosttyTab]) -> (folder: String, tabs: [GhosttyTab]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidate = session.launchCwd.isEmpty ? session.cwd : session.launchCwd
        for _ in 0..<4 {
            let matches = all.filter { TmuxTargeting.samePath($0.cwd, candidate) }
            if !matches.isEmpty { return (candidate, matches) }
            if candidate.isEmpty || candidate == "/" || candidate == home { break }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return ("", [])
    }

    // MARK: doing

    /// Carry out a plan. Everything that forks or waits happens here, which is
    /// why this runs off the main thread: an ssh to another machine can take
    /// seconds, and the panel must not wait on it.
    static func perform(_ plan: JumpPlan, tab: GhosttyTab? = nil) -> JumpOutcome {
        CommandRunner.withDeadline { performWithinDeadline(plan, tab: tab) }
    }

    private static func performWithinDeadline(_ plan: JumpPlan, tab: GhosttyTab?) -> JumpOutcome {
        switch plan {
        case .tmux(let pane, let context):
            return performTmux(pane: pane, context: context)
        case .unavailable(let message):
            return .failed(message: message)
        case .ghostty(let folder, let tabs):
            if let chosen = tab {
                return performGhostty(tab: chosen)
            }
            guard tabs.count <= 1 else { return .pick(folder: folder, tabs: tabs) }
            guard let first = tabs.first else {
                return .failed(message: "no tab found in that folder")
            }
            return performGhostty(tab: first)
        case .raiseApp(let name):
            activate(appNamed: name)
            return .failed(message: "no tab found in that folder, raised \(name)")
        case .remote(let host):
            return .failed(message: "that session is on \(host), not on this machine")
        case .route(let host, let route, let pane, let folder, let title, let socket):
            var resolved = route
            resolved.recordedSocket = socket
            return performRoute(host: host, route: resolved, pane: pane, folder: folder, title: title)
        }
    }

    /// Tabs on this machine whose title names the route's machine.
    ///
    /// Several is normal, and none is normal too: a tab title is the program
    /// running in it, not a name you chose. The panel asks when there are
    /// several, and reports where the pane was selected when there are none.
    static func tabs(for route: Route) -> [GhosttyTab] {
        guard let name = route.tab, !name.isEmpty else { return [] }
        return ghosttyTabs().filter { $0.name.localizedCaseInsensitiveContains(name) }
    }

    /// Split a route's argv into the program to start and its arguments.
    ///
    /// A route may name a bare command the way a shell would, but Process wants a
    /// real file: a bare name is read as a path relative to the working directory,
    /// which turned "ssh" into "/ssh" and made every route fail before it started.
    /// A bare name goes through env, which is what the local tmux path does too.
    static func executable(_ argv: [String]) -> (path: String, arguments: [String]) {
        guard let binary = argv.first else { return ("/usr/bin/env", []) }
        return binary.contains("/") ? (binary, Array(argv.dropFirst()))
                                   : ("/usr/bin/env", argv)
    }

    /// Run one tmux subcommand through a route's argv.
    static func runTmux(_ argv: [String], _ subcommand: [String]) -> Result {
        let start = executable(argv)
        let throughShell = argv.contains { ($0 as NSString).lastPathComponent == "ssh" }
        let arguments = throughShell ? subcommand.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                                    : subcommand
        return run(start.path, start.arguments + arguments)
    }

    static func performGhostty(tab: GhosttyTab) -> JumpOutcome {
        let terminal = tab.tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let surface = tab.surfaceID?.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let selector = surface.map { "id is \"\($0)\"" } ?? "tty is \"\(terminal)\""
        let focus = terminal.isEmpty && surface == nil ? ""
            : "focus (first terminal of targetTab whose \(selector))"
        let script = """
        tell application "Ghostty"
            set targetWindow to (first window whose id is "\(tab.windowId)")
            set targetTab to (first tab of targetWindow whose id is "\(tab.id)")
            select tab targetTab
            \(focus)
            activate window targetWindow
        end tell
        """
        let result = run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            return .failed(message: "could not select the tab: \(result.output.prefix(60))")
        }
        activate(appNamed: "Ghostty")
        return .done(message: nil)
    }

    /// Read every Ghostty tab. Empty when Ghostty is not running or refuses.
    static func ghosttyTabs() -> [GhosttyTab] {
        let script = """
        tell application "Ghostty"
            set fs to (ASCII character 31)
            set out to ""
            repeat with w in windows
                set wid to (id of w)
                repeat with t in tabs of w
                    set tname to (name of t)
                    set tid to (id of t)
                    repeat with term in terminals of t
                        set tt to ""
                        set sid to ""
                        try
                            set tt to (tty of term) as text
                            set sid to (id of term) as text
                        end try
                        set out to out & wid & fs & tid & fs & tname & fs
                        set out to out & (working directory of term) & fs & tt & fs & sid & linefeed
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        let result = run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: fieldSeparator)
            guard parts.count >= 4 else { return nil }
            return GhosttyTab(id: parts[1], windowId: parts[0],
                              name: parts[2], cwd: parts[3],
                              tty: parts.count >= 5 ? parts[4] : "",
                              surfaceID: parts.count >= 6 && !parts[5].isEmpty ? parts[5] : nil)
        }
    }

    /// Bring an app forward by name, without a fork.
    static func activate(appNamed name: String) {
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: {
            $0.localizedName == name || $0.bundleIdentifier?.lowercased().contains(name.lowercased()) == true
        }) else { return }
        app.activate()
    }

    typealias Result = CommandRunner.Result

    private static func run(_ path: String, _ arguments: [String],
                            timeout: TimeInterval = 10) -> Result {
        CommandRunner.run(path, arguments, timeout: timeout)
    }
}
