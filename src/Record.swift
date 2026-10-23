import Foundation

/// One line from an events file.
///
/// Everything past `timestamp` and `event` is optional on purpose. The events file is
/// streamed between machines, so an older build on the other machine may write a
/// smaller record. Unknown fields are ignored. A line that will not decode is
/// skipped by the reader rather than killing the file.
struct Record: Decodable {
    /// The event time, `ts` on the wire.
    let timestamp: Int
    let event: String
    let agent: String?
    let agentPid: Int?
    let agentStart: String?
    let session: String?
    let cwd: String?
    let turn: String?
    let model: String?
    /// The agent's own name for the session, when it has one. Optional like everything
    /// past `ts` and `event`: an older build writes records without it.
    let title: String?
    let tool: String?
    let durationMs: Int?
    let message: String?
    /// Terminal identity, captured from the environment the agent inherited.
    let term: String?
    let tmux: String?
    /// Present only for an event raised inside a subagent or an in-process
    /// teammate. Those records belong to the parent session, not to a session of
    /// their own.
    let agentId: String?

    enum CodingKeys: String, CodingKey {
        case event, agent, session, cwd, turn, model, title, tool, message, term, tmux
        case timestamp = "ts"
        case agentPid = "agent_pid"
        case agentStart = "agent_start"
        case durationMs = "dur_ms"
        case agentId = "agent_id"
    }
}
