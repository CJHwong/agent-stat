import Foundation

/// What a session is doing, driven only by hook events.
enum SessionState: String {
    case starting       // SessionStart seen, no prompt yet
    case running        // a turn is in flight
    case waiting        // blocked on a permission prompt
    case idle           // turn finished, waiting on you
    case failed         // the turn died on an API error (Claude Code only)
    case interrupted    // the user interrupted (Codex only)
    case ended          // SessionEnd seen
}

let terminalStates: Set<SessionState> = [.ended, .failed, .interrupted]

/// A session is identified by the machine that owns it plus its session id.
/// A session never spans machines, so this key is what keeps event streams from
/// different machines from being merged.
struct SessionKey: Hashable {
    let host: String
    let id: String
}

struct Session {
    let key: SessionKey
    var isLocal: Bool = false
    var agent: String = "unknown"
    var cwd: String = ""
    /// The folder the session was launched in.
    ///
    /// This is the key for going back to the terminal tab, not `cwd`. The agent
    /// cwd drifts: it follows Claude when Claude changes directory, while the
    /// terminal tab keeps the shell cwd, which only changes when you change it.
    /// Matching on the drifting value misses the tab that is right in front of
    /// you.
    var launchCwd: String = ""
    var state: SessionState = .starting
    var model: String?
    /// The session's own name, when the agent gave it one. Preferred over the folder
    /// when the panel matches a terminal tab, because it belongs to this session alone.
    var title: String?
    var turn: String?
    var tool: String?
    var toolStartedAt: Int?
    /// Derived from the PreToolUse and PostToolUse timestamps. Never read from
    /// dur_ms, because Codex does not send that field at all.
    var lastToolSeconds: Int?
    var lastMessage: String?
    var lastTs: Int = 0
    /// When this session last asked for you: a finished turn, a permission
    /// prompt, a failure, or a notification.
    ///
    /// Work moves the clock constantly and asks for nothing, so `lastTs` is the
    /// wrong clock for a hidden row to come back on. This one is the right one.
    var askedAt: Int = 0
    var agentPid: Int?
    var agentStart: String?
    /// The terminal this session lives in. Set once, from the environment the
    /// agent inherited, and used to take you back to the right tab.
    var term: String?
    var tmuxPane: String?
    /// nil means unknown. Local probes and remote status frames report liveness.
    var alive: Bool?
    /// When the app first noticed this session's process was gone. Used to clear
    /// the row shortly after a session is closed.
    var goneSince: Int?
    /// Whether the session reported anything before an end record. A bare SessionEnd
    /// from a Codex app-server session is not a failed turn; it is not a row at all.
    var sawActivity = false

    init(key: SessionKey) {
        self.key = key
    }

    /// Fold one event into this session.
    ///
    /// This is a deterministic fold: the state depends only on the events seen, in
    /// order, never on how many times they were seen. That matters because a sync
    /// client can replace the events file, which makes the reader re-read it. A
    /// counter here would double count on a re-read.
    ///
    /// Two halves, because they answer different questions: what every event
    /// carries, and what the event means.
    mutating func apply(_ record: Record) {
        copy(record)
        fold(record)
        if record.event != "SessionEnd", record.event != "RunEnd" { sawActivity = true }
    }

    /// Take the fields an event carries, when it carries them.
    private mutating func copy(_ record: Record) {
        if record.timestamp > lastTs { lastTs = record.timestamp }
        if let agent = record.agent, !agent.isEmpty { self.agent = agent }
        if let cwd = record.cwd, !cwd.isEmpty {
            // The first folder seen stands in when SessionStart was missed, which
            // happens for a session that was already running when the hooks went in.
            if launchCwd.isEmpty { launchCwd = cwd }
            self.cwd = cwd
        }
        if let model = record.model { self.model = model }
        if let title = record.title, !title.isEmpty { self.title = title }
        if let turn = record.turn { self.turn = turn }
        if let pid = record.agentPid, pid > 0 {
            if agentPid != pid { agentStart = nil }
            agentPid = pid
        }
        if let start = record.agentStart, !start.isEmpty { agentStart = start }
        if let term = record.term, !term.isEmpty { self.term = term }
        if let pane = record.tmux, !pane.isEmpty { tmuxPane = pane }
        if let message = record.message, !message.isEmpty { lastMessage = message }
    }

    /// Move the state machine. One case per event that means something to a row.
    private mutating func fold(_ record: Record) {
        switch record.event {
        case "SessionStart":
            // Authoritative: this is where the session was launched.
            if let cwd = record.cwd, !cwd.isEmpty { launchCwd = cwd }
            state = .starting
        case "UserPromptSubmit":
            state = .running
            tool = nil
            toolStartedAt = nil
        case "PreToolUse":
            state = .running
            if let name = record.tool { tool = name }
            toolStartedAt = record.timestamp
        case "PostToolUse":
            if state == .waiting { state = .running }
            if let started = toolStartedAt {
                lastToolSeconds = max(0, record.timestamp - started)
            }
            tool = nil
            toolStartedAt = nil
        case "PermissionRequest":
            state = .waiting
            askedAt = record.timestamp
        case "Stop":
            state = .idle
            tool = nil
            toolStartedAt = nil
            askedAt = record.timestamp
        case "StopFailure":
            state = .failed
            askedAt = record.timestamp
        case "Notification":
            // Claude Code raises this when it wants a human, for a permission
            // prompt or an idle session. It asks for you and changes no state.
            askedAt = record.timestamp
        case "Interrupt":
            state = .interrupted
        case "SessionEnd":
            end(record, inferFailure: true)
        case "RunEnd":
            // An orchestrator finished running this session and says so, because
            // an interactive codex reports no end however it ends. This is the only
            // record that closes such a row on another machine.
            //
            // Deliberately not SessionEnd: codex never sent one, and a record
            // that borrowed that name would read as codex's own report. A run that
            // ends before Codex sent Stop did not finish, so it fails like one.
            end(record, inferFailure: true)
        default:
            // SubagentStart, SubagentStop, and anything a newer writer adds.
            // Recognized, deliberately not a state change and not an ask.
            break
        }
    }

    /// Close a session, and keep a failure visible.
    ///
    /// Claude sends StopFailure and then SessionEnd, and that pair is the only report
    /// of an API error, so the failure must survive the close. Codex sends no failure
    /// event, so an end while a turn is in flight, or before the first turn, is the
    /// failure: a completed turn always sends Stop first. Both SessionEnd and RunEnd
    /// infer it for Codex.
    private mutating func end(_ record: Record, inferFailure: Bool) {
        if inferFailure, agent == "codex", sawActivity,
           state == .starting || state == .running || state == .waiting {
            state = .failed
            askedAt = record.timestamp
            // The end record carries no error text. An older message would read as
            // the failure, so let the row say "API error" instead.
            lastMessage = nil
        } else if state != .failed {
            state = .ended
        }
        tool = nil
        toolStartedAt = nil
    }

    /// Seconds the current tool has been running, or nil when none is.
    func runningFor(now: Int) -> Int? {
        guard let started = toolStartedAt else { return nil }
        return max(0, now - started)
    }

    /// The other machine's name, or nil when this session is local.
    ///
    /// Nothing can cross machines. A tmux pane id is only unique within one tmux
    /// server, and a folder name exists on both machines, so acting on a remote
    /// session would land in the wrong place. Jumping is gated on this.
    var onAnotherMachine: String? {
        isLocal ? nil : key.host
    }

    /// The subagents currently running inside this session, by the id the agent
    /// gave each one.
    ///
    /// A subagent is not a session you can go back to, so it never gets a row. It
    /// does mean the parent is still working, which is the one thing a row needs
    /// to say while the parent itself is quiet.
    var liveSubagents: Set<String> = []

    /// Fold a subagent event into the parent session.
    ///
    /// The state is the parent's to report, so this moves only the clock and the
    /// count, and only for the two events that carry information a row can use. A
    /// subagent tool call is dropped, the way it always was. A subagent that never
    /// reports its stop leaves the count standing, which is what the records that
    /// arrived say.
    mutating func applySubagent(_ record: Record, agentId: String) {
        switch record.event {
        case "SubagentStart": liveSubagents.insert(agentId)
        case "SubagentStop": liveSubagents.remove(agentId)
        default: return
        }
        if record.timestamp > lastTs { lastTs = record.timestamp }
    }

    /// Is work in flight, whoever is doing it?
    ///
    /// A turn can finish while its subagents run on. That session is not waiting
    /// on you: nobody is asking you for anything while work continues, so it reads
    /// as working and stays out of the count. It becomes yours again when the last
    /// subagent stops.
    var isBusy: Bool {
        state == .running || (state == .idle && !liveSubagents.isEmpty)
    }

    /// The process vanished without an end record.
    ///
    /// Not the same as a clean exit, and not something that is waiting on you: a
    /// local session whose pid is gone has nothing left to do. The panel says so
    /// in the row text, leaves it out of the attention count, and must not paint
    /// it as a row that needs you.
    var vanishedWithoutEnd: Bool {
        alive == false && !terminalStates.contains(state)
    }

    func age(now: Int) -> Int {
        max(0, now - lastTs)
    }
}
