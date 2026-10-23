import AppKit
import Foundation

/// A Ghostty tab, as far as we can see it. Ghostty exposes no pid and no tty, so
/// the folder is the only handle that can tie a session to a tab.
struct GhosttyTab: Identifiable, Equatable {
    let id: String
    let windowId: String
    let name: String
    let cwd: String
}

/// What clicking a row will do.
enum JumpPlan {
    /// A tmux pane id, which is exact within this machine's tmux server.
    case tmux(pane: String)
    /// Matching Ghostty tabs, plus the folder that matched. One tab acts
    /// directly, several open a picker, none just raises the app.
    case ghostty(folder: String, tabs: [GhosttyTab])
    /// No usable handle. Raise the terminal app and say so.
    case raiseApp(String)
    /// The session is on another machine and no route names that machine.
    case remote(host: String)
    /// The session is on another machine and a route reaches it. `pane` is nil
    /// for a session there that reports no tmux pane.
    case route(host: String, route: Route, pane: String?, folder: String)
}

/// What a click did, or what it needs from you.
enum JumpOutcome {
    /// The jump happened. A message is a short line for the panel, or nil when
    /// there is nothing to say.
    case done(message: String?)
    /// Several tabs could be the one, so nothing moved and the panel must ask.
    case pick(folder: String, tabs: [GhosttyTab])

    var message: String? {
        if case .done(let message) = self { return message }
        return nil
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
            return .route(host: host, route: route, pane: session.tmuxPane, folder: folder)
        }
        if let pane = session.tmuxPane, !pane.isEmpty {
            return .tmux(pane: pane)
        }
        let appName = session.term.flatMap(displayName(for:)) ?? "Ghostty"
        let (folder, tabs) = matchingTabs(for: session)
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

    /// Human name for a TERM_PROGRAM value.
    private static func displayName(for term: String) -> String? {
        switch term {
        case "ghostty": return "Ghostty"
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "WezTerm": return "WezTerm"
        case "vscode": return "Code"
        default: return nil
        }
    }

    // MARK: doing

    /// Carry out a plan. Everything that forks or waits happens here, which is
    /// why this runs off the main thread: an ssh to another machine can take
    /// seconds, and the panel must not wait on it.
    static func perform(_ plan: JumpPlan, tab: GhosttyTab? = nil) -> JumpOutcome {
        switch plan {
        case .tmux(let pane):
            return performTmux(pane: pane)
        case .ghostty(let folder, let tabs):
            if let chosen = tab {
                return performGhostty(tab: chosen)
            }
            guard tabs.count <= 1 else { return .pick(folder: folder, tabs: tabs) }
            guard let first = tabs.first else {
                return .done(message: "no tab found in that folder")
            }
            return performGhostty(tab: first)
        case .raiseApp(let name):
            activate(appNamed: name)
            return .done(message: "no tab found in that folder, raised \(name)")
        case .remote(let host):
            return .done(message: "that session is on \(host), not on this machine")
        case .route(let host, let route, let pane, let folder):
            return performRoute(host: host, route: route, pane: pane, folder: folder)
        }
    }

    /// Select the pane on the other machine, then come back here for the tab.
    ///
    /// The other machine's half is the network call, and this machine's half is
    /// the tab title match. A session there with no pane reported has nothing to
    /// select, so the click only brings a tab forward.
    private static func performRoute(host: String, route: Route, pane: String?,
                                     folder: String) -> JumpOutcome {
        let message = pane.flatMap {
            performRemote(host: host, route: route, pane: $0, folder: folder)
        }
        let tabs = tabs(for: route)
        switch tabs.count {
        case 1:
            let outcome = performGhostty(tab: tabs[0])
            return .done(message: outcome.message ?? message)
        case 2...:
            // A failed selection matters more than the tab question.
            if let message { return .done(message: message) }
            return .pick(folder: route.tab ?? host, tabs: tabs)
        default:
            if let name = route.tab, !name.isEmpty {
                return .done(message: message ?? "selected on \(host), no tab named \(name) here")
            }
            return .done(message: message ?? "selected the pane on \(host)")
        }
    }

    /// Select a pane on another machine, by running tmux there through the route.
    ///
    /// Returns a message when the click should say something, or nil when the
    /// pane was selected. A route that cannot be reached says so rather than
    /// pretending: a click that silently did nothing is worse than one that
    /// reports a failure.
    private static func performRemote(host: String, route: Route, pane: String,
                                      folder: String) -> String? {
        let listing = runTmux(route.argv, TmuxTargeting.listing)
        guard listing.status == 0 else {
            return "cannot reach tmux on \(host)"
        }
        guard let info = TmuxTargeting.paneInfo(pane, in: listing.output) else {
            return "pane \(pane) is gone on \(host)"
        }
        guard info.attached else {
            return "pane \(pane) has no tmux client on \(host)"
        }
        guard TmuxTargeting.folderMatches(folder, info.path) else {
            return "pane \(pane) is at a different folder on \(host)"
        }
        let commands = TmuxTargeting.selects(window: info.window, pane: pane)
        let selected = runTmux(route.argv, commands[0])
        _ = runTmux(route.argv, commands[1])
        guard selected.status == 0 else {
            return "could not select \(info.window) on \(host)"
        }
        return nil
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
    private static func runTmux(_ argv: [String], _ subcommand: [String]) -> Result {
        let start = executable(argv)
        return run(start.path, start.arguments + subcommand)
    }

    /// Where Homebrew puts tmux, tried when the PATH does not have it.
    ///
    /// A panel started at login inherits launchd's environment, which has no Homebrew
    /// on its PATH, so `env tmux` finds nothing there while the same click from a
    /// terminal works. These are the two prefixes Homebrew installs under.
    private static let tmuxFallbacks = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]

    /// List the panes, using the first tmux that answers.
    private static func listPanes() -> (result: Result, argv: [String]) {
        let shell = ["/usr/bin/env", "tmux"]
        let first = run(shell[0], Array(shell.dropFirst()) + TmuxTargeting.listing)
        if first.status == 0 { return (first, shell) }
        for candidate in tmuxFallbacks
        where FileManager.default.isExecutableFile(atPath: candidate) {
            let retry = run(candidate, TmuxTargeting.listing)
            if retry.status == 0 { return (retry, [candidate]) }
        }
        return (first, shell)
    }

    private static func performTmux(pane: String) -> JumpOutcome {
        // Resolve the pane to a window first, because select-window wants a window
        // target, and a pane id is not enough on its own.
        let (listed, argv) = listPanes()
        guard listed.status == 0 else {
            return .done(message: "tmux is not running")
        }
        guard let info = TmuxTargeting.paneInfo(pane, in: listed.output) else {
            return .done(message: "pane \(pane) is gone")
        }
        guard info.attached else {
            return .done(message: "pane \(pane) has no tmux client")
        }
        for command in TmuxTargeting.selects(window: info.window, pane: pane) {
            _ = run(argv[0], Array(argv.dropFirst()) + command)
        }
        activate(appNamed: "Ghostty")
        return .done(message: nil)
    }

    private static func performGhostty(tab: GhosttyTab) -> JumpOutcome {
        let script = """
        tell application "Ghostty"
            set targetWindow to (first window whose id is "\(tab.windowId)")
            set targetTab to (first tab of targetWindow whose id is "\(tab.id)")
            select tab targetTab
            activate window targetWindow
        end tell
        """
        let result = run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            return .done(message: "could not select the tab: \(result.output.prefix(60))")
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
                        set out to out & wid & fs & tid & fs & tname & fs & (working directory of term) & linefeed
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
                              name: parts[2], cwd: parts[3])
        }
    }

    /// Bring an app forward by name, without a fork.
    private static func activate(appNamed name: String) {
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: {
            $0.localizedName == name || $0.bundleIdentifier?.lowercased().contains(name.lowercased()) == true
        }) else { return }
        app.activate()
    }

    private struct Result {
        let status: Int32
        let output: String
    }

    /// Run a tool and wait, but never on the main thread. The first Ghostty call
    /// may raise a system automation prompt, and the panel must stay responsive
    /// while that is on screen.
    private static func run(_ path: String, _ arguments: [String],
                            timeout: TimeInterval = 10) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.write("jump: could not start \(path): \(error)")
            return Result(status: -1, output: "")
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                Log.write("jump: \(path) exceeded \(Int(timeout))s, terminating")
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return Result(status: process.terminationStatus,
                      output: String(data: data, encoding: .utf8) ?? "")
    }
}
