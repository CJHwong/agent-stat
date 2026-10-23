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
        model.status = nil
        // Clicking a row means you are dealing with it, so it stops counting as
        // needing you. A later event raises the flag again.
        store.acknowledge(session.key, now: now)
        remember()
        tick()
        // A pane several rows name cannot be picked for one of them. Say so here,
        // without an ssh round trip.
        if let refusal = TmuxTargeting.sharedPaneRefusal(for: session,
                                                         among: store.visible(now: now)) {
            Log.write("jump \(session.key.host)/\(session.key.id) refused: \(refusal)")
            model.status = refusal
            tick()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = Jumper.plan(for: session, routes: Routes.load())
            let outcome = Jumper.perform(plan)
            Task { @MainActor in
                // One line per click, so a failed jump can be read afterwards.
                Log.write("jump \(session.key.host)/\(session.key.id) "
                          + "plan=\(plan.summary) result=\(outcome.summary)")
                self.show(outcome)
            }
        }
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
        model.picker = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Jumper.perform(.ghostty(folder: "", tabs: [tab]), tab: tab)
            Task { @MainActor in
                Log.write("jump tab=\(tab.name) result=\(outcome.summary)")
                self.model.status = outcome.message
                self.tick()
            }
        }
    }
}

/// One line of evidence per click, for the log.
extension JumpPlan {
    var summary: String {
        switch self {
        case .tmux(let pane):
            return "tmux pane=\(pane)"
        case .ghostty(let folder, let tabs):
            return "ghostty folder=\(folder) tabs=\(tabs.count)"
        case .raiseApp(let name):
            return "raise app=\(name)"
        case .remote(let host):
            return "no route host=\(host)"
        case .route(let host, let route, let pane, let folder):
            return "route host=\(host) pane=\(pane ?? "-") folder=\(folder) "
                + "tab=\(route.tab ?? "-")"
        }
    }
}

extension JumpOutcome {
    var summary: String {
        switch self {
        case .done(let message):
            return message ?? "ok"
        case .pick(let folder, let tabs):
            return "pick \(tabs.count) tabs in \(folder)"
        }
    }
}
