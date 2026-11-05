import Foundation

extension Jumper {
    /// Select the pane on the other machine, then come back here for the tab.
    ///
    /// The other machine's half is the network call, and this machine's half is
    /// the tab title match. A unique pane title can recover a missing identifier.
    static func performRoute(host: String, route: Route, pane: String?,
                             folder: String, title: String?) -> JumpOutcome {
        if let socket = route.recordedSocket, !socket.hasPrefix("/") {
            return .failed(message: "the tmux socket path is invalid")
        }
        let message: String?
        if let pane, !pane.isEmpty {
            message = performRemote(host: host, route: route, pane: pane, folder: folder)
        } else if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = performNamedRemote(host: host, route: route, title: title, folder: folder)
        } else {
            message = "that session reports no tmux pane on \(host)"
        }
        let tabs = tabs(for: route)
        switch tabs.count {
        case 1:
            let outcome = performGhostty(tab: tabs[0])
            if let message { return .failed(message: message) }
            return outcome
        case 2...:
            // A failed selection matters more than the tab question.
            if let message { return .failed(message: message) }
            return .pick(folder: route.tab ?? host, tabs: tabs)
        default:
            if let message { return .failed(message: message) }
            if let name = route.tab, !name.isEmpty {
                return .failed(message: "selected on \(host), no tab named \(name) here")
            }
            return .done(message: message ?? "selected the pane on \(host)")
        }
    }

    private static func performNamedRemote(host: String, route: Route, title: String,
                                           folder: String) -> String? {
        let listing = runTmux(route.argv, route.command(TmuxTargeting.titleListing))
        guard listing.status == 0 else { return "cannot reach tmux on \(host)" }
        let candidates = TmuxTargeting.matchingPanes(title: title, in: listing.output)
        let panes = runTmux(route.argv, route.command(TmuxTargeting.listing))
        guard panes.status == 0 else { return "cannot reach tmux on \(host)" }
        var resolvedFolder: String?
        let compatible = candidates.filter { pane in
            guard let info = TmuxTargeting.paneInfo(pane, in: panes.output) else { return false }
            return info.attached && remoteFolderMatches(folder, info.path, route: route, resolved: &resolvedFolder)
        }
        let matches = compatible.isEmpty ? candidates : compatible
        guard matches.count <= 1 else { return "multiple panes match \(title) on \(host)" }
        guard let pane = matches.first else { return "no pane matches \(title) on \(host)" }
        return performRemote(host: host, route: route, pane: pane, folder: folder,
                             listing: panes.output, resolvedFolder: resolvedFolder)
    }

    /// Select a pane on another machine, by running tmux there through the route.
    ///
    /// Returns a message when the click should say something, or nil when the
    /// pane was selected. A route that cannot be reached says so rather than
    /// pretending: a click that silently did nothing is worse than one that
    /// reports a failure.
    private static func performRemote(host: String, route: Route, pane: String,
                                      folder: String, listing snapshot: String? = nil,
                                      resolvedFolder: String? = nil) -> String? {
        let listing = snapshot.map { Result(status: 0, output: $0) }
            ?? runTmux(route.argv, route.command(TmuxTargeting.listing))
        guard listing.status == 0 else {
            return "cannot reach tmux on \(host)"
        }
        guard let info = TmuxTargeting.paneInfo(pane, in: listing.output) else {
            return "pane \(pane) is gone on \(host)"
        }
        guard info.attached else {
            return "pane \(pane) has no tmux client on \(host)"
        }
        var resolved = resolvedFolder
        guard remoteFolderMatches(folder, info.path, route: route, resolved: &resolved) else {
            return "pane \(pane) is at a different folder on \(host)"
        }
        let command = TmuxTargeting.selection(window: info.window, pane: pane, session: info.session)
        let selected = runTmux(route.argv, route.command(command))
        guard selected.status == 0 else {
            let failed = selected.output.contains(TmuxTargeting.windowSelected) ? "pane \(pane)" : info.window
            return "could not select \(failed) on \(host)"
        }
        return nil
    }

    private static func remoteFolderMatches(_ folder: String, _ panePath: String, route: Route,
                                            resolved: inout String?) -> Bool {
        if TmuxTargeting.folderMatches(folder, panePath, resolveSymlinks: false) { return true }
        if let resolved {
            return !resolved.isEmpty && TmuxTargeting.folderMatches(resolved, panePath, resolveSymlinks: false)
        }
        let quoted = "'" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // tmux sends this result to its calling client, without writing into the target pane.
        let result = runTmux(route.argv, route.command(["run-shell", "cd -- \(quoted) && pwd -P"]))
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        resolved = result.status == 0 && path.hasPrefix("/") ? path : ""
        guard resolved != "" else { return false }
        return TmuxTargeting.folderMatches(path, panePath, resolveSymlinks: false)
    }
}
