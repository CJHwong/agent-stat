import Foundation

/// What tmux is asked for, and how its answer is read.
///
/// Split from `Jumper`, which decides where a click goes: these are the tmux shapes
/// themselves, plus the rules over them that a test can drive without a server.
enum TmuxTargeting {
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
    /// watching moves nothing you can see.
    static let listing = [
        "list-panes", "-a",
        "-F#{pane_id},#{window_id},#{session_attached},#{pane_current_path}"
    ]

    /// The two subcommands that move a client to a pane.
    ///
    /// Both halves are needed: selecting a window does not move the pane inside
    /// it, which was measured and not assumed.
    static func selects(window: String, pane: String) -> [[String]] {
        [["select-window", "-t", window], ["select-pane", "-t", pane]]
    }

    struct PaneInfo {
        let window: String
        let attached: Bool
        let path: String
    }

    /// The window that holds this pane, whether a client shows its session, and the
    /// folder the pane sits in. The path is last, so a comma inside it survives.
    static func paneInfo(_ pane: String, in listing: String) -> PaneInfo? {
        guard let line = listing
            .split(separator: "\n")
            .first(where: { $0.hasPrefix(pane + ",") }) else { return nil }
        let fields = line.split(separator: ",", maxSplits: 3)
        guard fields.count >= 4 else { return nil }
        return PaneInfo(window: String(fields[1]), attached: (Int(fields[2]) ?? 0) > 0,
                        path: String(fields[3]))
    }

    /// Why a click cannot pick this session's pane: several visible sessions on the
    /// same machine in the same folder name it. A pane is one place, so the click
    /// cannot know which row it belongs to. A session in another folder is not a
    /// sharer: it inherited the pane from the process that started it, which is the
    /// replay case.
    static func sharedPaneRefusal(for session: Session, among visible: [Session]) -> String? {
        guard let host = session.onAnotherMachine,
              let pane = session.tmuxPane, !pane.isEmpty else { return nil }
        let folder = session.launchCwd.isEmpty ? session.cwd : session.launchCwd
        let sharing = visible.filter { other in
            guard other.onAnotherMachine == host, other.tmuxPane == pane else { return false }
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
    static func folderMatches(_ sessionFolder: String, _ panePath: String) -> Bool {
        guard !sessionFolder.isEmpty, !panePath.isEmpty else { return true }
        var candidate = sessionFolder
        for _ in 0..<8 {
            if samePath(candidate, panePath) { return true }
            if candidate.isEmpty || candidate == "/" { break }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return false
    }
}
