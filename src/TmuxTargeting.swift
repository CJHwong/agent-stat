import Foundation

/// What tmux is asked for, and how its answer is read.
///
/// Split from `Jumper`, which decides where a click goes: these are the tmux shapes
/// themselves, plus the rules over them that a test can drive without a server.
enum TmuxTargeting {
    /// The field separator. A comma can appear in a title or a path, and the shell
    /// safety test refuses spaces and tabs, so the listing uses the ASCII unit
    /// separator. It has no meaning inside the single quotes a route adds.
    private static let separator: Character = "\u{1f}"

    /// The listing, in a shape that survives a shell.
    ///
    /// A route sends this through ssh, and ssh hands the other end to a shell.
    /// Two things break there, both measured: a space lets the shell split the
    /// format into two arguments, and a # at the start of a word starts a comment.
    /// Either one turns a working route into "-F expects an argument". Attaching
    /// the value to its flag leaves no space, and the # is then mid-word.
    ///
    /// It carries the window id, not a session and a window index, because a
    /// session name may contain a space and a window id never does. The attached
    /// count says whether a client shows the pane: selecting a pane nobody is
    /// watching moves nothing you can see. The title is last, so one listing
    /// serves both a title match and the pane details: a title jump then needs
    /// one remote call instead of two.
    static let listing = [
        "list-panes", "-a",
        "-F#{pane_id}\u{1f}#{window_id}\u{1f}#{session_attached}\u{1f}#{session_id}"
            + "\u{1f}#{pane_tty}\u{1f}#{pane_current_path}\u{1f}#{pane_title}"
    ]

    static func matchingPanes(title: String, in listing: String) -> [String] {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return [] }
        let decoration = CharacterSet.symbols.union(.whitespacesAndNewlines).union(.nonBaseCharacters)
        let matches = listing.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: separator, maxSplits: 6,
                                    omittingEmptySubsequences: false)
            guard fields.count == 7 else { return nil }
            let paneTitle = fields[6].lowercased()
            guard let match = paneTitle.range(of: name) else { return nil }
            // Codex adds a changing spinner before the session title.
            let prefix = String(paneTitle[..<match.lowerBound])
            guard prefix.trimmingCharacters(in: decoration).isEmpty else { return nil }
            let suffix = paneTitle[match.upperBound...]
            guard suffix.isEmpty || suffix.hasPrefix(" | ") else { return nil }
            return String(fields[0])
        }
        // Linked windows can list the same pane through several sessions.
        return Array(Set(matches)).sorted()
    }

    /// The two subcommands that move a client to a pane.
    ///
    /// Both halves are needed: selecting a window does not move the pane inside
    /// it, which was measured and not assumed.
    static func selects(window: String, pane: String, session: String? = nil) -> [[String]] {
        let target = session.map { $0 + ":" + window } ?? window
        return [["select-window", "-t", target], ["select-pane", "-t", pane]]
    }

    static let windowSelected = "agent-stat-window-selected"

    static func selection(window: String, pane: String, session: String? = nil) -> [String] {
        let commands = selects(window: window, pane: pane, session: session)
        // tmux stops the command queue on error. The marker identifies which selection failed.
        return commands[0] + [";", "display-message", "-p", windowSelected, ";"] + commands[1]
    }

    static func clients(pane: String, session: String? = nil) -> [String] {
        ["list-clients", "-t", session ?? pane, "-F#{client_tty}"]
    }

    static func matchingClientTabs(in listing: String, tabs: [GhosttyTab]) -> [GhosttyTab] {
        // Control clients have no terminal. Their empty values cannot identify a tab.
        let terminals = Set(listing.split(separator: "\n").map(String.init))
        var seen = Set<String>()
        return tabs.filter {
            !$0.tty.isEmpty && terminals.contains($0.tty)
                && seen.insert($0.windowId + ":" + $0.id).inserted
        }
    }

    struct PaneInfo {
        let window: String
        let attached: Bool
        let path: String
        var session: String?
        var tty: String?
    }

    /// The window that holds this pane, whether a client shows its session, and the
    /// folder the pane sits in. One listing carries all of it, so a title match and
    /// a pane lookup share one answer.
    static func paneInfo(_ pane: String, in listing: String) -> PaneInfo? {
        let matches = listing.split(separator: "\n").compactMap { line -> PaneInfo? in
            let fields = line.split(separator: separator, maxSplits: 6,
                                    omittingEmptySubsequences: false)
            guard fields.count == 7, fields[0] == Substring(pane) else { return nil }
            return PaneInfo(window: String(fields[1]), attached: (Int(fields[2]) ?? 0) > 0,
                            path: String(fields[5]), session: String(fields[3]),
                            tty: String(fields[4]))
        }
        return matches.first(where: \.attached) ?? matches.first
    }

    /// Why a click cannot pick this session's pane: several visible sessions on the
    /// same machine in the same folder name it. A pane is one place, so the click
    /// cannot know which row it belongs to. A session in another folder is not a
    /// sharer: it inherited the pane from the process that started it, which is the
    /// replay case.
    static func sharedPaneRefusal(for session: Session, among visible: [Session]) -> String? {
        guard let pane = session.tmuxPane, !pane.isEmpty else { return nil }
        let host = session.key.host
        let folder = session.launchCwd.isEmpty ? session.cwd : session.launchCwd
        let sharing = visible.filter { other in
            guard other.key.host == host, other.tmuxPane == pane else { return false }
            guard other.alive != false, other.state != .ended else { return false }
            if let socket = session.tmuxSocket, let otherSocket = other.tmuxSocket, socket != otherSocket {
                return false
            }
            let otherFolder = other.launchCwd.isEmpty ? other.cwd : other.launchCwd
            return samePath(folder, otherFolder)
        }.count
        guard sharing > 1 else { return nil }
        return "pane \(pane) is shared by \(sharing) sessions on \(host)"
    }

    /// Compare resolved paths. Claude reports /private/var/... where Ghostty may
    /// report /var/..., and both name the same place.
    static func samePath(_ left: String, _ right: String) -> Bool {
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let leftResolved = URL(fileURLWithPath: left).resolvingSymlinksInPath().path
        let rightResolved = URL(fileURLWithPath: right).resolvingSymlinksInPath().path
        return leftResolved == rightResolved
    }

    /// Does a session's launch folder sit at the pane's folder or inside it?
    ///
    /// The worktrees and notes under `.claude` put a session five or six levels below
    /// the folder its terminal tab sits in, so the walk allows eight parents. The home
    /// directory still ends it. Unknown paths never block: a missing value is not
    /// evidence of a mismatch.
    static func folderMatches(_ sessionFolder: String, _ panePath: String,
                              resolveSymlinks: Bool = true) -> Bool {
        guard !sessionFolder.isEmpty, !panePath.isEmpty else { return true }
        var candidate = sessionFolder
        for _ in 0..<8 {
            if resolveSymlinks ? samePath(candidate, panePath) : candidate == panePath { return true }
            if candidate.isEmpty || candidate == "/" { break }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return false
    }
}
