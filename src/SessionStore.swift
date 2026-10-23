import Foundation

/// One machine's worth of rows, for the panel's section header.
struct MachineGroup {
    let host: String
    let isLocal: Bool
    let sessions: [Session]
}

/// Holds every session the app knows about and folds events into them.
///
/// No SwiftUI, no file access, no timers. The whole thing is driven by
/// `apply(record:host:)` so tests can feed it a stream and assert on the result.
final class SessionStore {
    private struct ProcessIdentity: Hashable {
        let pid: Int
        let started: String?
    }

    /// A session with no event for this long drops out of the panel.
    static let visibleWindowSeconds = 12 * 3600
    /// A session that finished or was closed clears out this fast, so closing a
    /// terminal makes its row go away instead of lingering. A failure is the
    /// exception and stays for the normal window, because it asks for you.
    static let finishedGraceSeconds = 10
    /// A session whose process vanished without a SessionEnd. Codex does exactly
    /// this when its terminal closes, so this is the codex close path, not only a
    /// crash path. Long enough to notice, short enough not to clutter.
    static let crashedGraceSeconds = 60

    private(set) var sessions: [SessionKey: Session] = [:]
    /// The event timestamp each session was acknowledged at. Clicking a row
    /// acknowledges it: going to the session is dealing with it, so it should
    /// stop counting as needing you. A new event later moves the timestamp past
    /// this mark and the flag can come back.
    private(set) var acknowledged: [SessionKey: Int] = [:]
    /// The event timestamp each session was dismissed at. Dismissing hides a row
    /// without touching the record, so a stale session leaves the panel while the
    /// history stays whole. The row returns when the session asks for you again,
    /// which keeps a live session from staying hidden by mistake.
    ///
    /// Kept across restarts by the app, which writes both maps beside the route file.
    /// See `PanelMemory`. The store itself touches no files, so a test can drive it.
    private(set) var dismissed: [SessionKey: Int] = [:]
    private(set) var acknowledgedPositions: [SessionKey: EventPosition] = [:]
    private(set) var dismissedPositions: [SessionKey: EventPosition] = [:]
    private var positions: [SessionKey: EventPosition] = [:]
    private var askedPositions: [SessionKey: EventPosition] = [:]
    private let localHost: String

    init(localHost: String) {
        self.localHost = localHost
    }

    func apply(_ record: Record, host: String, position: EventPosition? = nil) {
        let id = record.session ?? ""
        guard !id.isEmpty else { return }
        let key = SessionKey(host: host, id: id)
        if let position, let previous = positions[key], position <= previous { return }
        // Subagent and teammate events carry an agent_id. They belong to the
        // parent session's row, not to a session you could go back to, so drop
        // them here rather than showing a row per subagent. A start and a stop are
        // still worth folding in: they are what keeps the parent row fresh, and
        // counting, while the parent itself is quiet.
        if let agentId = record.agentId, !agentId.isEmpty {
            guard var session = sessions[key] else { return }
            session.applySubagent(record, agentId: agentId)
            sessions[session.key] = session
            if let position, record.event == "SubagentStart" || record.event == "SubagentStop" {
                positions[key] = position
            }
            return
        }
        // The end bridge closes a row, it does not open one. A session nobody has
        // heard from has no row to close, and the panel would otherwise show an
        // empty one for the length of the grace period. A session that never
        // reported anything is not a session you can go back to.
        if record.event == "RunEnd", sessions[key] == nil { return }
        var session = sessions[key] ?? Session(key: key)
        session.isLocal = (host == localHost)
        let previousState = session.state
        session.apply(record)
        sessions[key] = session
        guard let position else { return }
        positions[key] = position
        let asks = ["Stop", "StopFailure", "PermissionRequest", "Notification"].contains(record.event)
        let failedOnEnd = record.event == "SessionEnd" && session.state == .failed && previousState != .failed
        if asks || failedOnEnd { askedPositions[key] = position }
    }

    func applyTitles(_ titles: [String: String], host: String) {
        for (identifier, title) in titles where !title.isEmpty {
            let key = SessionKey(host: host, id: identifier)
            guard var session = sessions[key], session.agent == "codex" else { continue }
            session.title = String(title.prefix(200))
            sessions[key] = session
        }
    }

    /// Refresh the alive flag for local sessions.
    ///
    /// `probe` answers whether a pid is still the same process. It is injected so
    /// the tests do not need real processes.
    func reapLocal(now: Int, probe: (Int, String?) -> Bool) {
        var aliveByProcess: [ProcessIdentity: Bool] = [:]
        // Retained history needs no process probe until another event makes its row recent.
        for (key, session) in sessions
        where session.isLocal && now - session.lastTs <= Self.visibleWindowSeconds {
            guard let pid = session.agentPid else { continue }
            var updated = session
            let identity = ProcessIdentity(pid: pid, started: session.agentStart)
            let alive = aliveByProcess[identity] ?? probe(pid, session.agentStart)
            aliveByProcess[identity] = alive
            updated.alive = alive
            if alive {
                updated.goneSince = nil
            } else {
                // Only a session that was live moments ago gets the grace period.
                // A record whose last event is already old is a leftover from an
                // earlier run, and listing it as "process gone" for a minute on
                // every app start is noise.
                let alreadyStale = now - session.lastTs > Self.crashedGraceSeconds
                if alreadyStale {
                    updated.goneSince = session.lastTs
                } else if updated.goneSince == nil {
                    updated.goneSince = now
                }
            }
            sessions[key] = updated
        }
    }

    func reapRemote(host: String, alive: [String: Bool], now: Int) {
        for (id, running) in alive {
            let key = SessionKey(host: host, id: id)
            guard var session = sessions[key], !session.isLocal else { continue }
            session.alive = running
            if running {
                session.goneSince = nil
            } else if session.goneSince == nil {
                let stale = now - session.lastTs > Self.crashedGraceSeconds
                session.goneSince = stale ? session.lastTs : now
            }
            sessions[key] = session
        }
    }

    /// Mark a session as dealt with, up to now and to its own last event.
    ///
    /// The cover includes the session's own timestamp because a session on
    /// another machine carries that machine's clock, which may run slightly
    /// ahead of this one. Without it, a remote row would refuse to clear.
    func acknowledge(_ key: SessionKey, now: Int) {
        let latest = sessions[key]?.lastTs ?? now
        acknowledged[key] = max(now, latest)
        acknowledgedPositions[key] = positions[key]
    }

    /// Take back both maps from before a relaunch.
    ///
    /// The stored covers go in as they were, not through `dismiss` or `acknowledge`,
    /// which would recompute them against a session that may have spoken since. A row
    /// whose session has spoken after the cover comes back, which is what makes this
    /// safe.
    func restore(dismissed: [SessionKey: Int], acknowledged: [SessionKey: Int],
                 dismissedPositions: [SessionKey: EventPosition] = [:],
                 acknowledgedPositions: [SessionKey: EventPosition] = [:]) {
        for (key, cover) in dismissed { self.dismissed[key] = max(self.dismissed[key] ?? 0, cover) }
        for (key, cover) in acknowledged {
            self.acknowledged[key] = max(self.acknowledged[key] ?? 0, cover)
        }
        self.dismissedPositions.merge(dismissedPositions, uniquingKeysWith: max)
        self.acknowledgedPositions.merge(acknowledgedPositions, uniquingKeysWith: max)
    }

    /// Hide a row until that session asks for you again.
    ///
    /// The cover includes the session's own timestamp because a session on
    /// another machine carries that machine's clock, which may run slightly
    /// ahead of this one. Without it, a remote row would refuse to clear.
    func dismiss(_ key: SessionKey, now: Int) {
        let latest = sessions[key]?.lastTs ?? now
        dismissed[key] = max(now, latest)
        dismissedPositions[key] = positions[key]
    }

    /// A dismissed row is hidden until that session asks for you again.
    ///
    /// Hiding covers what the session is doing now. Work moves the clock
    /// constantly and asks for nothing, so a tool call, a subagent start or a
    /// subagent stop leaves the row hidden. A finished turn, a permission
    /// prompt, a failure or a notification brings it back.
    private func isDismissed(_ session: Session) -> Bool {
        guard let cover = dismissed[session.key] else { return false }
        if let position = dismissedPositions[session.key] {
            guard let asked = askedPositions[session.key] else { return true }
            return asked <= position
        }
        return session.askedAt <= cover
    }

    /// Has this session's latest event already been dealt with?
    ///
    /// True after you clicked its row, until that session reports another event.
    /// The row keeps its state and only the dot changes: it still wants you, you
    /// just know about it.
    func isAcknowledged(_ session: Session) -> Bool {
        if let position = acknowledgedPositions[session.key], let latest = positions[session.key] {
            return latest <= position
        }
        return session.lastTs <= (acknowledged[session.key] ?? 0)
    }

    /// Does this session want your attention right now?
    ///
    /// A failed turn is one of the things you have to deal with, with a finished turn
    /// and a permission prompt. It stays here until you click it, so the row is still
    /// in the count after the process is gone.
    func needsAttention(_ session: Session) -> Bool {
        guard session.state == .waiting || session.state == .idle
            || session.state == .failed else { return false }
        // A turn that finished while its subagents run on is still working, so it
        // is not waiting on you yet.
        guard !session.isBusy else { return false }
        // A hidden row cannot be one you are being asked about.
        guard !isDismissed(session) else { return false }
        // A session whose process is gone is not waiting on you, whatever its
        // last event said.
        guard !session.vanishedWithoutEnd else { return false }
        return !isAcknowledged(session)
    }

    /// The badge count: rows that need you and that you can clear.
    ///
    /// It counts only what the panel shows. A session with no row cannot be
    /// clicked or dismissed, so counting it puts a number on the badge that
    /// nothing can take off. That is the shape a session on another machine
    /// takes once its last event leaves the visible window: nothing can probe
    /// its pid, and it never sent an end record.
    func attentionCount(now: Int) -> Int {
        sessions.values.filter { shouldShow($0, now: now) && needsAttention($0) }.count
    }

    /// A cover older than the visible window can hide no row that is still shown, so
    /// it is dropped. Without this the file gains a key for every click, forever.
    private func pruneAcknowledgements(now: Int) {
        let oldest = now - Self.visibleWindowSeconds
        for (key, cover) in acknowledged
        where sessions[key] == nil || cover < oldest {
            acknowledged.removeValue(forKey: key)
            acknowledgedPositions.removeValue(forKey: key)
        }
    }

    private func pruneDismissals(now: Int) {
        let oldest = now - Self.visibleWindowSeconds
        for (key, cover) in dismissed
        where sessions[key] == nil || cover < oldest {
            dismissed.removeValue(forKey: key)
            dismissedPositions.removeValue(forKey: key)
        }
    }

    /// Rows for the panel: what needs you first, then what is working, then what
    /// is finished. Within a group, most recent first.
    func visible(now: Int) -> [Session] {
        pruneAcknowledgements(now: now)
        pruneDismissals(now: now)
        return sessions.values
            .filter { shouldShow($0, now: now) }
            .sorted { lhs, rhs in
                let left = Self.rank(lhs)
                let right = Self.rank(rhs)
                if left != right { return left < right }
                return lhs.lastTs > rhs.lastTs
            }
    }

    private func shouldShow(_ session: Session, now: Int) -> Bool {
        if isDismissed(session) { return false }
        if now - session.lastTs > Self.visibleWindowSeconds { return false }
        if terminalStates.contains(session.state), session.state != .failed {
            // Finished or closed. Clear out quickly. For a session on another
            // machine the last event is the only clock available. A failure is the
            // exception: it asks for you, so it stays until you deal with it.
            return now - session.lastTs <= Self.finishedGraceSeconds
        }
        if session.state != .failed, let gone = session.goneSince,
           now - gone > Self.crashedGraceSeconds {
            return false
        }
        return true
    }

    /// Split rows by the machine that wrote them, local machine first.
    ///
    /// The rows arrive already sorted attention first, and that order is kept
    /// inside each group. Grouping must not bury a session that needs you under
    /// one that does not, so the divider goes between machines only. Local comes
    /// first because those are the sessions a click can reach.
    static func groupedByMachine(_ sessions: [Session]) -> [MachineGroup] {
        var hosts: [String] = []
        var rows: [String: [Session]] = [:]
        var locals: Set<String> = []
        for session in sessions {
            let host = session.key.host
            if rows[host] == nil { hosts.append(host) }
            rows[host, default: []].append(session)
            if session.isLocal { locals.insert(host) }
        }
        let ordered = hosts.filter { locals.contains($0) } + hosts.filter { !locals.contains($0) }
        return ordered.map {
            MachineGroup(host: $0, isLocal: locals.contains($0), sessions: rows[$0] ?? [])
        }
    }

    private static func rank(_ session: Session) -> Int {
        // Work in flight sorts with work in flight, whoever is doing it, because a
        // row that is not waiting on you must not sit above one that is.
        if session.isBusy { return 2 }
        switch session.state {
        case .waiting, .failed: return 0
        case .idle: return 1
        case .running, .starting: return 2
        case .interrupted: return 3
        case .ended: return 4
        }
    }
}
