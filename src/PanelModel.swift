import SwiftUI

/// What the panel draws, as data: one row, the rows of one machine, the tab picker a
/// click can raise, and the model that turns sessions into those. No window, no timer
/// and no file access, so the shape of a panel can be driven from a test or a probe.
///
/// One row's worth of presentation. Built from a Session so the view layer never
/// has to know about liveness rules or the visible window.
struct SessionRow: Identifiable {
    let session: Session
    let id: String
    let agent: String
    let cwd: String
    let state: SessionState
    let detail: String
    let age: String
    /// You already clicked this row, so the session still wants you and you know.
    let acknowledged: Bool
    /// The terminal tab a click would take you to, by name, or how many tabs could
    /// be it. Nil when nothing here matches: another machine's rows, and a session in
    /// tmux, which jumps by pane rather than by tab.
    let tab: String?

    /// What the dot says, one meaning per colour.
    ///
    /// Red waits on you: a finished turn, or an open permission prompt. Clicking
    /// the row deals with it, so the dot turns blue and the row stops counting
    /// toward the badge; the session's next event makes it red again. Green is
    /// work in flight, and that includes a turn that finished while its subagents
    /// run on: nobody is waiting on you while work continues. Orange is a failure,
    /// which also waits on you and counts in the badge; clicking it deals with it.
    /// Purple is an interrupt, and grey is a closed session or a process that
    /// vanished, which waits on nobody.
    var accent: Color {
        if session.vanishedWithoutEnd { return .secondary }
        if session.isBusy { return .green }
        switch state {
        case .waiting, .idle: return acknowledged ? .blue : .red
        case .running, .starting: return .green
        case .failed: return .orange
        case .interrupted: return .purple
        case .ended: return .secondary
        }
    }

    /// Work in flight, which is what the dot pulses for.
    ///
    /// A session that has not taken a prompt yet stays solid: it is up, it is not
    /// working, and a green dot that pulses for it would read as busy forever.
    var isWorking: Bool {
        session.isBusy
    }
}

/// The rows of one machine, under a header that names it.
///
/// The machine is named here and not on the row, because events arrive from
/// several machines: a row without a machine is a row you have to guess about, and a row
/// that repeats the header is noise.
struct RowGroup: Identifiable {
    let host: String
    let isLocal: Bool
    let rows: [SessionRow]
    var connection: String?

    var id: String { host }
}

/// Shown when more than one tab in the same folder could be the session.
struct TabPicker {
    let label: String
    let tabs: [GhosttyTab]
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var groups: [RowGroup] = []
    @Published var subtitle: String = ""
    @Published var emptyHint: String?
    @Published var attentionCount: Int = 0
    @Published var picker: TabPicker?
    @Published var status: String?
    /// What the last publish would have drawn, so an identical one can be skipped.
    private var lastSignature: String?
    /// What the last publish would have sized, so a content change alone can skip the
    /// fitting-size measurement.
    private var lastLayoutSignature: String?

    /// What one update changed.
    ///
    /// `content` redraws the rows. `layout` also changes the panel's height, so only a
    /// layout change asks for a fresh fitting size. The age and the tab name change
    /// every second while the panel is open, and re-measuring the whole panel for that
    /// was the largest cost of an open panel.
    struct PublishResult {
        let content: Bool
        let layout: Bool
    }

    /// The tallest the list may grow before it scrolls. The window uses the same
    /// number, because a scroll view has no content height of its own to measure.
    static let maxListHeight: CGFloat = 520

    /// Roughly what the list would measure at its drawn heights. It only decides
    /// whether the list scrolls, so it does not need to be exact.
    var estimatedContentHeight: CGFloat {
        if let picker { return 80 + CGFloat(picker.tabs.count) * 30 }
        if emptyHint != nil { return 60 }
        let rows = groups.reduce(0) { $0 + $1.rows.count }
        return CGFloat(rows) * 50 + CGFloat(groups.count) * 29
    }

    /// Set by the app delegate. Clicking a row asks it to take you to the session.
    var onJump: ((Session) -> Void)?
    var onPick: ((GhosttyTab) -> Void)?
    /// Set by the app delegate. The x on a row asks it to hide that row.
    var onDismiss: ((Session) -> Void)?

    /// `acknowledged` answers whether that session's latest event has been dealt
    /// with by a click on its row. Only the dot uses it: red while it waits on
    /// you, blue after you have seen it.
    @discardableResult
    func update(from sessions: [Session], now: Int, eventsDirectory: URL, attention: Int,
                acknowledged: (Session) -> Bool, tabs: [GhosttyTab] = [],
                connections: [String: String] = [:]) -> PublishResult {
        let rows = SessionStore.groupedByMachine(sessions).map { group in
            RowGroup(
                host: group.host,
                isLocal: group.isLocal,
                rows: group.sessions.map { session in
                    SessionRow(
                        session: session,
                        id: session.key.host + "/" + session.key.id,
                        agent: session.agent,
                        cwd: Self.folderName(session.cwd),
                        state: session.state,
                        detail: Self.detail(for: session, now: now),
                        age: Self.shortDuration(session.age(now: now)),
                        acknowledged: acknowledged(session),
                        tab: Self.tabName(for: session, in: tabs)
                    )
                },
                connection: connections[group.host]
            )
        }
        let built = Self.includeEmptyHosts(rows, connections: connections)
        // Assigning the rows lays the panel window out, and a tick now happens whenever a
        // record lands, which can be several times a second. The ages change once a
        // second, so this compares what would be drawn and stops when it is the same:
        // a record that changes a row still redraws at once.
        let count = built.reduce(0) { $0 + $1.rows.count }
        let installed = FileManager.default.fileExists(atPath: eventsDirectory.path)
        // Deliberately not "no sessions in the visible window": a row you dismissed
        // also leaves nothing to show, and that claim would be false.
        let hint = built.isEmpty && !installed
            ? "No events directory yet.\nRun install.py --apply from the agent-stat repo."
            : (built.isEmpty ? "No sessions to show." : nil)

        // Two signatures. The content one says what would be drawn; the layout one says
        // what would be sized. Only the second may ask for a fitting size, so a changing
        // age, detail or tab name redraws without laying the whole panel out again.
        let signature = built.map { group in
            group.host + (group.connection ?? "") + group.rows.map {
                "\($0.id)|\($0.state.rawValue)|\($0.detail)|\($0.age)|\($0.tab ?? "")|\($0.acknowledged)"
            }.joined()
        }.joined()
            + "|picker:\(picker.map { "\($0.label)|\($0.tabs.map(\.id).joined(separator: ","))" } ?? "")"
            + "|status:\(status ?? "")"
            + "|hint:\(hint == nil ? "" : "1")"
        let layoutSignature = built.map { "\($0.host)|\($0.rows.count)" }.joined()
            + "|picker:\(picker.map { "\($0.label)|\($0.tabs.count)" } ?? "")"
            + "|status:\(status ?? "")"
            + "|hint:\(hint == nil ? "" : "1")"

        let content = signature != lastSignature
        let layoutChanged = layoutSignature != lastLayoutSignature
        if content {
            lastSignature = signature
            groups = built
        }
        if layoutChanged { lastLayoutSignature = layoutSignature }
        if attentionCount != attention { attentionCount = attention }
        // The header publishes to the same view, so it gets the same treatment: assigning
        // an equal string still redraws it.
        let subtitle = count == 0 ? "" : "\(count) session\(count == 1 ? "" : "s")"
        if self.subtitle != subtitle { self.subtitle = subtitle }
        if emptyHint != hint { emptyHint = hint }
        return PublishResult(content: content, layout: layoutChanged)
    }

    private static func includeEmptyHosts(_ groups: [RowGroup], connections: [String: String]) -> [RowGroup] {
        var result = groups
        let visible = Set(groups.map(\.host))
        for host in connections.keys.sorted() where !visible.contains(host) {
            result.append(RowGroup(host: host, isLocal: false, rows: [], connection: connections[host]))
        }
        return result
    }

    /// What a click would do, as a row can say it.
    ///
    /// One tab names itself. Several are counted, because a click asks which rather
    /// than guessing. A session in tmux jumps to its pane, so its tab is not the
    /// handle and there is nothing to say.
    private static func tabName(for session: Session, in tabs: [GhosttyTab]) -> String? {
        // The session's own name is worth showing whoever reported it. Only the tab
        // hint below is local: a remote row has no tab here to name.
        if let title = session.title, !title.isEmpty { return title }
        guard session.isLocal, session.tmuxPane?.isEmpty ?? true else { return nil }
        let matches = Jumper.matchingTabs(for: session, in: tabs).tabs
        if matches.count == 1 { return matches[0].name }
        if matches.count > 1 { return "\(matches.count) tabs" }
        return nil
    }

    private static func folderName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func detail(for session: Session, now: Int) -> String {
        // A process that vanished without a SessionEnd is a crash. It must not
        // read the same as a clean exit.
        if session.vanishedWithoutEnd {
            return "process gone"
        }
        let count = session.liveSubagents.count
        let note = count == 1 ? "1 subagent" : "\(count) subagents"
        // A turn that finished while its subagents run on: the count is the news,
        // and it goes first so that a long message cannot truncate it away.
        if count > 0, session.state == .idle {
            return "\(note), turn finished"
        }
        // No tool and nobody under it, so the count is all there is to say.
        if count > 0, session.state == .running, session.tool == nil {
            return note
        }
        let line = baseDetail(for: session, now: now)
        return count > 0 ? "\(line) (\(note))" : line
    }

    /// What the session is doing, with no mention of any subagent.
    private static func baseDetail(for session: Session, now: Int) -> String {
        switch session.state {
        case .running:
            if let tool = session.tool, let seconds = session.runningFor(now: now) {
                return "\(tool), \(shortDuration(seconds))"
            }
            return "thinking"
        case .waiting:
            return session.tool.map { "permission: \($0)" } ?? "waiting on you"
        case .idle:
            return shortMessage(session.lastMessage) ?? "turn finished"
        case .starting:
            return "starting"
        case .failed:
            return shortMessage(session.lastMessage) ?? "API error"
        case .interrupted:
            return "interrupted"
        case .ended:
            return shortMessage(session.lastMessage) ?? "ended"
        }
    }

    /// The longest message a row will measure, in characters.
    private static let messageLimit = 200

    /// The row shows one line of text. A long message is cut here, not in the view.
    /// Measuring a message of any size on every redraw costs the layout, and the
    /// rest of it can never be seen.
    private static func shortMessage(_ message: String?) -> String? {
        guard let message, message.count > messageLimit else { return message }
        return String(message.prefix(messageLimit))
    }

    /// Compact durations: 12s, 4m, 2h, 3d. Rounded, so 1h57m does not read as 1h.
    static func shortDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = Double(seconds) / 60
        if minutes < 59.5 { return "\(Int(minutes.rounded()))m" }
        let hours = Double(seconds) / 3600
        if hours < 23.5 { return "\(Int(hours.rounded()))h" }
        return "\(Int((Double(seconds) / 86_400).rounded()))d"
    }
}
