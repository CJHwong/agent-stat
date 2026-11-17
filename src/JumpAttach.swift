import Foundation

/// A tmux session that no terminal shows. The jump already selected the pane inside
/// it, so either way of showing the session lands on that pane.
struct AttachTarget {
    /// The session identifier, such as `$3`. Names can repeat across servers, identifiers cannot.
    let session: String
    let name: String
    let pane: String
    /// How to run tmux on that server: the program, and the options before each command.
    let argv: [String]
    let prefix: [String]
    /// The route of a session on another machine, or nil for this machine.
    let route: Route?
    let host: String?
}

extension Jumper {
    /// Build the choice for a session without a client, reading its name for the panel.
    static func attachTarget(session: String, pane: String, argv: [String], prefix: [String],
                             route: Route? = nil, host: String? = nil) -> AttachTarget {
        let named = runTmux(argv, prefix + ["display-message", "-p", "-t", session, "#{session_name}"])
        let name = named.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return AttachTarget(session: session, name: named.status == 0 && !name.isEmpty ? name : session,
                            pane: pane, argv: argv, prefix: prefix, route: route, host: host)
    }

    /// Show the session in a terminal that already runs tmux on that server.
    static func showInCurrentTab(_ target: AttachTarget) -> JumpOutcome {
        // Outside tmux, a switch without -c moves the most recently used client.
        let switched = runTmux(target.argv, target.prefix + ["switch-client", "-t", target.session])
        guard switched.status == 0 else {
            return .failed(message: "no tmux client could switch to \(target.name)")
        }
        guard let route = target.route else {
            return focusTmuxClient(pane: target.pane, session: target.session, argv: target.argv, tabs: nil)
        }
        let tabs = tabs(for: route)
        if tabs.count > 1 { return .pick(folder: route.tab ?? target.host ?? "", tabs: tabs) }
        if let tab = tabs.first { return performGhostty(tab: tab) }
        return .done(message: "showing \(target.name) on \(target.host ?? "the other machine")")
    }

    /// Open a Ghostty tab that attaches to the session.
    static func showInNewTab(_ target: AttachTarget) -> JumpOutcome {
        let command = attachCommand(target).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
            set configuration to new surface configuration
            set command of configuration to "\(command)"
            if (count of windows) is 0 then
                new window with configuration configuration
            else
                new tab in (front window) with configuration configuration
            end if
            activate
        end tell
        """
        let result = CommandRunner.run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else {
            return .failed(message: "could not open a tab: \(result.output.prefix(60))")
        }
        return .done(message: nil)
    }

    /// The command line a new tab runs. A route goes through ssh, so the remote half is
    /// quoted once for the other machine's shell and once more for this one.
    static func attachCommand(_ target: AttachTarget) -> String {
        let attach = target.prefix + ["attach-session", "-t", target.session]
        guard target.route != nil else { return (target.argv + attach).map(shellQuoted).joined(separator: " ") }
        var argv = target.argv
        // The route asks for no terminal. Attaching needs one.
        if let index = argv.firstIndex(of: "-T") {
            argv[index] = "-t"
        } else if let index = argv.firstIndex(where: { ($0 as NSString).lastPathComponent == "ssh" }) {
            argv.insert("-t", at: index + 1)
        }
        let throughShell = argv.contains { ($0 as NSString).lastPathComponent == "ssh" }
        let remote = throughShell ? attach.map(shellQuoted) : attach
        return (argv + remote).map(shellQuoted).joined(separator: " ")
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
