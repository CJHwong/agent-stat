import Foundation

extension Jumper {
    /// Select the pane on the other machine, then come back here for the tab.
    ///
    /// The other machine's half is the network call, and this machine's half is
    /// the tab title match. A unique pane title can recover a missing identifier.
    static func performRoute(host: String, route: Route, pane: String?,
                             folder: String, title: String?) -> JumpOutcome {
        let message: String?
        if let pane, !pane.isEmpty {
            message = performRemote(host: host, route: route, pane: pane, folder: folder)
        } else if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = performNamedRemote(host: host, route: route, title: title, folder: folder)
        } else {
            message = nil
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

    private static func performNamedRemote(host: String, route: Route, title: String,
                                           folder: String) -> String? {
        let listing = runTmux(route.argv, TmuxTargeting.titleListing)
        guard listing.status == 0 else { return "cannot reach tmux on \(host)" }
        let matches = TmuxTargeting.matchingPanes(title: title, in: listing.output)
        guard matches.count <= 1 else { return "multiple panes match \(title) on \(host)" }
        guard let pane = matches.first else { return "no pane matches \(title) on \(host)" }
        return performRemote(host: host, route: route, pane: pane, folder: folder)
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
        guard selected.status == 0 else {
            return "could not select \(info.window) on \(host)"
        }
        let selectedPane = runTmux(route.argv, commands[1])
        guard selectedPane.status == 0 else {
            return "could not select pane \(pane) on \(host)"
        }
        return nil
    }
}
