import Foundation

extension Jumper {
    /// Why a click must not touch the other machine yet: its stream is not connected.
    ///
    /// A pane id outlives its process, and a tmux restart hands it to another pane.
    /// The live status is what marks a run dead, and an offline stream keeps the last
    /// value it sent. The row then says alive while the pane may hold another run.
    /// A route with no event stream reports no state, and keeps working as before.
    static func unconfirmedRefusal(for session: Session, connection: String?) -> String? {
        guard let host = session.onAnotherMachine, let connection, connection != "connected" else { return nil }
        return "no live status from \(host), so its pane may hold another run"
    }

    /// Select the pane on the other machine, then come back here for the tab.
    ///
    /// The other machine's half is the network call, and this machine's half is
    /// the tab title match. A unique pane title can recover a missing identifier.
    static func performRoute(host: String, route: Route, pane: String?,
                             folder: String, title: String?,
                             snapshot: [GhosttyTab]? = nil) -> JumpOutcome {
        if let socket = route.recordedSocket, !socket.hasPrefix("/") {
            return .failed(message: "the tmux socket path is invalid")
        }
        let step: RemoteStep
        if let pane, !pane.isEmpty {
            step = performRemote(host: host, route: route, pane: pane, folder: folder)
        } else if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            step = performNamedRemote(host: host, route: route, title: title, folder: folder)
        } else {
            step = .failed("that session reports no tmux pane on \(host)")
        }
        switch step {
        case .selected: break
        // A failed selection left that machine on some other pane, so raising its
        // tab would show the wrong place.
        case .failed(let text): return .failed(message: text)
        case .detached(let target): return .attach(target)
        }
        let tabs = tabs(for: route, in: snapshot)
        switch tabs.count {
        case 1:
            return performGhostty(tab: tabs[0])
        case 2...:
            return .pick(folder: route.tab ?? host, tabs: tabs)
        default:
            if let name = route.tab, !name.isEmpty {
                return .failed(message: "selected on \(host), no tab named \(name) here")
            }
            return .done(message: "selected the pane on \(host)")
        }
    }

    private enum RemoteStep {
        case selected
        case failed(String)
        case detached(AttachTarget)
    }

    private static func performNamedRemote(host: String, route: Route, title: String,
                                           folder: String) -> RemoteStep {
        let panes = runTmux(route.argv, route.command(TmuxTargeting.listing))
        guard panes.status == 0 else { return .failed("cannot reach tmux on \(host)") }
        let candidates = TmuxTargeting.matchingPanes(title: title, in: panes.output)
        var resolvedFolder: String?
        let compatible = candidates.filter { pane in
            guard let info = TmuxTargeting.paneInfo(pane, in: panes.output) else { return false }
            return info.attached && remoteFolderMatches(folder, info.path, route: route, resolved: &resolvedFolder)
        }
        let matches = compatible.isEmpty ? candidates : compatible
        guard matches.count <= 1 else { return .failed("multiple panes match \(title) on \(host)") }
        guard let pane = matches.first else { return .failed("no pane matches \(title) on \(host)") }
        return performRemote(host: host, route: route, pane: pane, folder: folder,
                             listing: panes.output, resolvedFolder: resolvedFolder)
    }

    /// Select a pane on another machine, by running tmux there through the route.
    ///
    /// A route that cannot be reached says so rather than pretending: a click that
    /// silently did nothing is worse than one that reports a failure. A session that
    /// no client shows has its pane selected, then the panel asks where to show it.
    private static func performRemote(host: String, route: Route, pane: String,
                                      folder: String, listing snapshot: String? = nil,
                                      resolvedFolder: String? = nil) -> RemoteStep {
        let listing = snapshot.map { Result(status: 0, output: $0) }
            ?? runTmux(route.argv, route.command(TmuxTargeting.listing))
        guard listing.status == 0 else {
            return .failed("cannot reach tmux on \(host)")
        }
        guard let info = TmuxTargeting.paneInfo(pane, in: listing.output) else {
            return .failed("pane \(pane) is gone on \(host)")
        }
        var resolved = resolvedFolder
        guard remoteFolderMatches(folder, info.path, route: route, resolved: &resolved) else {
            return .failed("pane \(pane) is at a different folder on \(host)")
        }
        let command = TmuxTargeting.selection(window: info.window, pane: pane, session: info.session)
        let selected = runTmux(route.argv, route.command(command))
        guard selected.status == 0 else {
            let failed = selected.output.contains(TmuxTargeting.windowSelected) ? "pane \(pane)" : info.window
            return .failed("could not select \(failed) on \(host)")
        }
        guard info.attached else {
            guard let session = info.session else { return .failed("pane \(pane) has no tmux client on \(host)") }
            return .detached(attachTarget(session: session, pane: pane, argv: route.argv,
                                          prefix: route.command([]), route: route, host: host))
        }
        return .selected
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
