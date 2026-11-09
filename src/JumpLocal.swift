import Foundation

extension Jumper {
    static func localContext(for session: Session) -> TmuxContext {
        var context = TmuxContext(socket: session.tmuxSocket,
                                  folder: session.launchCwd.isEmpty ? session.cwd : session.launchCwd,
                                  title: session.title, tty: session.tty,
                                  pid: session.agentPid, started: session.agentStart)
        guard let pid = context.pid, pid > 0 else { return context }
        guard pid <= Int(Int32.max), processIsAlive(Int32(pid), started: context.started) else {
            context.refusal = "that session process has ended or changed"
            return context
        }
        let terminal = runTmux(["/bin/ps"], ["-o", "tty=", "-p", String(pid)])
        guard terminal.status == 0 else {
            context.refusal = "cannot verify that session terminal"
            return context
        }
        let name = terminal.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = name.isEmpty || name == "??" ? "" : "/dev/" + name
        if !context.tty.isEmpty && context.tty != actual {
            context.refusal = "that session terminal has changed"
        }
        if context.tty.isEmpty { context.tty = actual }
        return context
    }

    static func localRefusal(_ context: TmuxContext) -> String? {
        if let refusal = context.refusal { return refusal }
        if let pid = context.pid, pid > 0,
           pid > Int(Int32.max) || !processIsAlive(Int32(pid), started: context.started) {
            return "that session process has ended or changed"
        }
        guard let socket = context.socket else { return nil }
        return socket.hasPrefix("/") ? nil : "the tmux socket path is invalid"
    }

    private static func listPanes(socket: String?) -> (result: Result, argv: [String]) {
        let socketArguments = socket.map { ["-S", $0] } ?? []
        let candidates = ["tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        var last = Result(status: -1, output: "")
        for candidate in candidates {
            let argv = [candidate] + socketArguments
            last = runTmux(argv, TmuxTargeting.listing)
            if last.status == 0 { return (last, argv) }
        }
        return (last, ["tmux"] + socketArguments)
    }

    static func localClientsContain(_ tabs: [GhosttyTab], socket: String?) -> Bool {
        let socketArguments = socket.map { ["-S", $0] } ?? []
        for candidate in ["tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"] {
            let clients = runTmux([candidate] + socketArguments, ["list-clients", "-F#{client_tty}"])
            if clients.status == 0 {
                return !TmuxTargeting.matchingClientTabs(in: clients.output, tabs: tabs).isEmpty
            }
        }
        return false
    }

    static func performTmux(pane: String?, context: TmuxContext) -> JumpOutcome {
        if let refusal = localRefusal(context) { return .failed(message: refusal) }
        let (listed, argv) = listPanes(socket: context.socket)
        guard listed.status == 0 else { return .failed(message: "tmux is not running at the recorded socket") }
        let target = pane ?? namedLocalPane(context, listing: listed.output)
        guard let target else { return .failed(message: "no unique tmux pane matches that session") }
        guard let info = TmuxTargeting.paneInfo(target, in: listed.output) else {
            return .failed(message: "pane \(target) is gone")
        }
        guard info.attached else { return .failed(message: "pane \(target) has no tmux client") }
        if let refusal = localOwnership(target, context: context, info: info) {
            return .failed(message: refusal)
        }
        let selected = runTmux(argv, TmuxTargeting.selection(window: info.window, pane: target, session: info.session))
        guard selected.status == 0 else {
            let window = info.session.map { $0 + ":" + info.window } ?? info.window
            let failed = selected.output.contains(TmuxTargeting.windowSelected) ? target : window
            return .failed(message: "could not select \(failed)")
        }
        return focusTmuxClient(pane: target, session: info.session, argv: argv, tabs: context.tabs)
    }

    private static func namedLocalPane(_ context: TmuxContext, listing: String) -> String? {
        guard let title = context.title, !title.isEmpty else { return nil }
        let matches = TmuxTargeting.matchingPanes(title: title, in: listing).filter { pane in
            guard let info = TmuxTargeting.paneInfo(pane, in: listing) else { return false }
            return info.attached && TmuxTargeting.folderMatches(context.folder, info.path)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func localOwnership(_ pane: String, context: TmuxContext,
                                       info: TmuxTargeting.PaneInfo) -> String? {
        if !context.tty.isEmpty {
            guard info.tty == context.tty else {
                return "pane \(pane) belongs to another terminal"
            }
            return nil
        }
        guard !context.folder.isEmpty else { return "cannot verify ownership of pane \(pane)" }
        return TmuxTargeting.folderMatches(context.folder, info.path)
            ? nil : "pane \(pane) is at a different folder"
    }

    private static func focusTmuxClient(pane: String, session: String?, argv: [String],
                                        tabs snapshot: [GhosttyTab]?) -> JumpOutcome {
        let clients = runTmux(argv, TmuxTargeting.clients(pane: pane, session: session))
        guard clients.status == 0 else {
            return .failed(message: "selected pane \(pane), could not read tmux clients")
        }
        let matched = TmuxTargeting.matchingClientTabs(in: clients.output,
                                                       tabs: snapshot ?? ghosttyTabs())
        let outcome = selectTab(matched, pane: pane)
        // The panel's tab list can be old. If a tab or surface closed since it was
        // read, read the live list once and try again before reporting the failure.
        guard case .failed = outcome, let snapshot, !snapshot.isEmpty else { return outcome }
        let live = TmuxTargeting.matchingClientTabs(in: clients.output, tabs: ghosttyTabs())
        return live.isEmpty ? outcome : selectTab(live, pane: pane)
    }

    private static func selectTab(_ tabs: [GhosttyTab], pane: String) -> JumpOutcome {
        if tabs.count > 1 { return .pick(folder: "tmux pane \(pane)", tabs: tabs) }
        if let tab = tabs.first { return performGhostty(tab: tab) }
        activate(appNamed: "Ghostty")
        return .failed(message: "selected pane \(pane), no matching Ghostty tab")
    }
}
