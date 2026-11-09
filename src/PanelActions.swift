import AppKit

/// What a click does: hide a row, or go to the session, in one place.
extension AppDelegate {
    // MARK: going to a session

    /// Write down what you have dealt with, so a restart does not undo it. Called when a
    /// row is hidden and when one is clicked, which are the two things you do to a row.
    private func remember() {
        PanelMemory.save(dismissed: store.dismissed, acknowledged: store.acknowledged,
                         dismissedPositions: store.dismissedPositions,
                         acknowledgedPositions: store.acknowledgedPositions)
    }

    /// Hiding a row changes what the panel shows and nothing else. The record
    /// stays in the events file, so a dismissed stale session is still on record
    /// if you go looking. The row returns when that session asks for you again.
    func dismiss(_ session: Session) {
        model.status = nil
        store.dismiss(session.key, now: Int(Date().timeIntervalSince1970))
        remember()
        tick()
    }

    /// Planning and doing both read Ghostty through AppleScript, which can raise
    /// a system permission prompt the first time, so they never run on the main
    /// thread. A route forks an ssh on top of that, which is why perform moved
    /// off the main thread with them.
    func jump(to session: Session) {
        let now = Int(Date().timeIntervalSince1970)
        let started = ProcessInfo.processInfo.systemUptime
        let receipt = store.attentionReceipt(for: session, now: now)
        let refusal = TmuxTargeting.sharedPaneRefusal(for: session, among: store.visible(now: now))
        let tabSnapshot = tabs
        model.status = "Jump to \(jumpLabel(for: session))"
        model.picker = nil
        navigation.receipt = nil
        // The status line adds a row to the panel. Refit now, or SwiftUI draws it into
        // the old height and squeezes the header until the click finishes.
        tick()
        navigation.queue.submit({
            if let refusal { return JumpExecution(summary: "refused", outcome: .failed(message: refusal)) }
            // Planning and doing share one deadline, so a slow lookup cannot add
            // its own timeout on top of the click's bound.
            return CommandRunner.withDeadline {
                let plan = Jumper.plan(for: session, routes: Routes.load(), tabs: tabSnapshot)
                return JumpExecution(summary: plan.summary,
                                     outcome: Jumper.perform(plan, tabs: tabSnapshot))
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            Log.write("jump \(session.key.host)/\(session.key.id) "
                      + "plan=\(result.summary) result=\(result.outcome.summary) elapsed=\(elapsed)ms")
            if result.outcome.succeeded {
                self.store.acknowledge(receipt)
                self.remember()
            }
            if case .pick = result.outcome { self.navigation.receipt = receipt }
            self.show(result.outcome)
        })
    }

    /// The shortest name for a row: its title, or the folder it runs in.
    private func jumpLabel(for session: Session) -> String {
        if let title = session.title, !title.isEmpty { return title }
        let folder = session.launchCwd.isEmpty ? session.cwd : session.launchCwd
        let name = (folder as NSString).lastPathComponent
        return name.isEmpty ? "session" : name
    }

    /// Put a finished jump on screen: a status line, or the tabs to choose from.
    private func show(_ outcome: JumpOutcome) {
        if case .pick(let folder, let tabs) = outcome {
            let name = (folder as NSString).lastPathComponent
            model.picker = TabPicker(
                label: "\(tabs.count) tabs in \(name.isEmpty ? folder : name)",
                tabs: tabs)
        } else {
            model.picker = nil
            model.status = outcome.message
        }
        tick()
    }

    func jumpTo(tab: GhosttyTab) {
        let receipt = navigation.receipt
        let started = ProcessInfo.processInfo.systemUptime
        model.picker = nil
        navigation.receipt = nil
        navigation.queue.submit({
            JumpExecution(summary: "selected tab", outcome: Jumper.performGhostty(tab: tab))
        }, completion: { [weak self] result in
            guard let self else { return }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            Log.write("jump tab=\(tab.name) result=\(result.outcome.summary) elapsed=\(elapsed)ms")
            if result.outcome.succeeded, let receipt {
                self.store.acknowledge(receipt)
                self.remember()
            }
            self.model.status = result.outcome.message
            self.tick()
        })
    }

}

/// One line of evidence per click, for the log.
extension JumpPlan {
    var summary: String {
        switch self {
        case .tmux(let pane, _):
            return "tmux pane=\(pane ?? "title lookup")"
        case .unavailable(let message):
            return "unavailable \(message)"
        case .ghostty(let folder, let tabs):
            return "ghostty folder=\(folder) tabs=\(tabs.count)"
        case .raiseApp(let name):
            return "raise app=\(name)"
        case .remote(let host):
            return "no route host=\(host)"
        case .route(let host, let route, let pane, let folder, let title, _):
            return "route host=\(host) pane=\(pane ?? "-") folder=\(folder) "
                + "tab=\(route.tab ?? "-") title=\(title ?? "-")"
        }
    }
}

extension JumpOutcome {
    var summary: String {
        switch self {
        case .done(let message):
            return message ?? "ok"
        case .failed(let message):
            return message
        case .pick(let folder, let tabs):
            return "pick \(tabs.count) tabs in \(folder)"
        }
    }
}
