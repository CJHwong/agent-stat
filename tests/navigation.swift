import Foundation

func testNavigationMetadata() {
    print("navigation: a new process discards old terminal metadata")
    var session = Session(key: SessionKey(host: HOST, id: "resumed"))
    let original = #"{"ts":1,"event":"SessionStart","agent_pid":101,"agent_start":"old","tmux":"%1","tmux_socket":"/tmp/synthetic","term":"tmux","cwd":"/work/old"}"#
    session.apply(decode(original))
    checkEqual(session.tmuxSocket, "/tmp/synthetic", "hook records carry their tmux server identity")
    session.apply(decode(#"{"ts":2,"event":"SessionStart","agent_pid":202,"agent_start":"new","cwd":"/work/new"}"#))
    check(session.tmuxPane == nil, "a new process cannot retain an old pane")
    check(session.tmuxSocket == nil, "a new process cannot retain an old server socket")
    check(session.term == nil, "a new process cannot retain an old terminal app")
    session.tmuxPane = "%2"
    session.apply(decode(#"{"ts":3,"event":"SessionStart","agent_pid":202,"agent_start":"reused","cwd":"/work/reused"}"#))
    check(session.tmuxPane == nil, "a reused process identifier cannot retain an old pane")
    checkEqual(session.launchCwd, "/work/reused", "a changed process start resets its folder")
}

func testNavigationPaneParsing() {
    print("navigation: empty folders and linked windows")
    let line = { (pane: String, window: String, attached: String, session: String, tty: String, path: String, title: String) in
        [pane, window, attached, session, tty, path, title].joined(separator: "\u{1f}")
    }
    check(TmuxTargeting.paneInfo("%1", in: line("%1", "@1", "1", "$2", "", "", "")) != nil,
          "an unknown folder does not hide the pane")
    let linked = line("%1", "@1", "0", "$1", "", "/work", "") + "\n"
        + line("%1", "@1", "1", "$1", "", "/work", "")
    checkEqual(TmuxTargeting.paneInfo("%1", in: linked)?.attached, true,
               "an attached linked copy takes priority over a detached copy")
    let details = line("%1", "@1", "1", "$2", "/dev/ttys101", "/work,with,commas", "Report")
    checkEqual(TmuxTargeting.paneInfo("%1", in: details)?.path, "/work,with,commas",
               "a folder keeps its commas")
    checkEqual(TmuxTargeting.paneInfo("%1", in: line("%1", "@1", "1", "$2", "", "", ""))?.path, "",
               "empty terminal and folder fields remain valid")
}

func testNavigationDuplicateClients() {
    print("navigation: one tab can contain several tmux clients")
    let tabs = [
        GhosttyTab(id: "same", windowId: "window", name: "tmux", cwd: "/work", tty: "/dev/ttys101"),
        GhosttyTab(id: "same", windowId: "window", name: "tmux", cwd: "/work", tty: "/dev/ttys102")
    ]
    checkEqual(TmuxTargeting.matchingClientTabs(in: "/dev/ttys101\n/dev/ttys102\n", tabs: tabs).count, 1,
               "two clients showing the same pane need one tab choice")
}

func testNavigationRemotePaths() {
    print("navigation: remote checks do not use local symbolic links")
    withTempDir { directory in
        let target = directory.appendingPathComponent("target")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        check(TmuxTargeting.folderMatches(alias.path, target.path), "a local alias names its local target")
        check(!TmuxTargeting.folderMatches(alias.path, target.path, resolveSymlinks: false),
              "a remote alias cannot inherit a local filesystem mapping")
    }
}

func testNavigationDeadlines() {
    print("navigation: command deadlines include descendants and open pipes")
    for command in ["trap '' TERM; sleep 30", "(trap '' TERM; sleep 30) & exit 0"] {
        let started = ProcessInfo.processInfo.systemUptime
        let result = CommandRunner.run("/bin/sh", ["-c", command], timeout: 0.15)
        check(result.timedOut, "a stalled command reports its deadline")
        check(ProcessInfo.processInfo.systemUptime - started < 1, "the output pipe cannot defeat the deadline")
    }
    let failed = CommandRunner.run("/bin/sh", ["-c", "printf 'synthetic error' >&2; exit 7"])
    checkEqual(failed.status, 7, "the runner preserves a command failure")
    check(failed.output.contains("synthetic error"), "the runner preserves useful error text")
    let closed = CommandRunner.run("/bin/sh", ["-c", "exec 1>&- 2>&-; sleep 30"], timeout: 0.15)
    check(closed.timedOut, "closed output does not disable the process deadline")
    let burst = CommandRunner.run("/usr/bin/head", ["-c", "524288", "/dev/zero"], timeout: 0.3)
    checkEqual(burst.status, 0, "a large ready output does not wait between chunks")
    checkEqual(burst.output.utf8.count, 524288, "the runner drains every output chunk")
    let excess = CommandRunner.run("/usr/bin/head", ["-c", "1048577", "/dev/zero"])
    checkEqual(excess.status, -1, "the output limit remains enforced")
    let noisy = CommandRunner.run("/bin/sh", ["-c", "while :; do printf 'synthetic output'; done"], timeout: 0.15)
    check(noisy.timedOut, "continuous output cannot defeat the deadline")
}

func testNavigationCommandCounts() {
    print("navigation: title jumps reuse pane details and folder resolution")
    withTempDir { directory in
        let script = directory.appendingPathComponent("tmux.sh")
        try """
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        if [ "$1" = -u ]; then shift; fi
        printf '%s\\n' "$1" >> calls
        case "$*" in
            list-panes*) printf '%%12\\037@3\\0371\\037$1\\037/dev/ttys101\\037/canonical\\037Synthetic target\\n'
                printf '%%13\\037@4\\0371\\037$1\\037/dev/ttys102\\037/other\\037Synthetic target\\n' ;;
            run-shell*) printf '/canonical\\n' ;;
            select-window*) printf 'agent-stat-window-selected\\n' ;;
            *) exit 1 ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        let encoded = try JSONSerialization.data(withJSONObject: ["peer": ["tmux": ["/bin/sh", script.path]]])
        let route = try Routes.decode(encoded).route(for: "peer")!
        let result = Jumper.performRoute(host: "peer", route: route, pane: nil, folder: "/alias", title: "Synthetic target")
        check(result.succeeded, "one compatible title candidate selects successfully")
        let calls = try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)
        let operations = calls.split(separator: "\n")
        checkEqual(operations.filter { $0 == "list-panes" }.count, 1,
                   "the title match and the pane details share one listing")
        checkEqual(operations.filter { $0 == "run-shell" }.count, 1, "all candidates share one remote folder resolution")
        checkEqual(operations.filter { $0 == "select-window" }.count, 1, "one command selects both window and pane")
        checkEqual(operations.filter { $0 == "select-pane" }.count, 0, "pane selection adds no separate process")
    }
}

func testNavigationIdentity() {
    print("navigation: stale process and terminal identifiers cannot select another session")
    var session = Session(key: SessionKey(host: HOST, id: "stale"))
    session.isLocal = true
    session.agentPid = Int(Int32.max)
    session.tty = "/dev/ttys101"
    guard case .unavailable = Jumper.plan(for: session) else {
        check(false, "a dead process cannot claim a recycled terminal")
        return
    }
    session.agentPid = nil
    session.launchCwd = "/work"
    let recycled = GhosttyTab(id: "recycled", windowId: "window", name: "shell", cwd: "/other", tty: "/dev/ttys101")
    check(Jumper.matchingTabs(for: session, in: [recycled]).tabs.isEmpty,
          "legacy terminal identifiers need compatible folder evidence")
    session.tmuxPane = "%1"
    session.tmuxSocket = "/tmp/synthetic-first"
    var other = Session(key: SessionKey(host: HOST, id: "other"))
    other.isLocal = true
    other.launchCwd = session.launchCwd
    other.tmuxPane = session.tmuxPane
    other.tmuxSocket = "/tmp/synthetic-second"
    check(TmuxTargeting.sharedPaneRefusal(for: session, among: [session, other]) == nil,
          "separate servers can reuse one pane identifier")
    other.tmuxSocket = session.tmuxSocket
    check(TmuxTargeting.sharedPaneRefusal(for: session, among: [session, other]) != nil,
          "local rows use the same ambiguity rule as remote rows")
    other.alive = false
    check(TmuxTargeting.sharedPaneRefusal(for: session, among: [session, other]) == nil,
          "a verified dead row cannot block the current session")
}

func testNavigationCompletionOrder() {
    print("navigation: the latest click controls the final result")
    let queue = JumpQueue()
    let started = DispatchSemaphore(value: 0)
    var completions: [String] = []
    queue.submit({
        started.signal()
        Thread.sleep(forTimeInterval: 0.1)
        return JumpExecution(summary: "old", outcome: .done(message: nil))
    }, completion: { completions.append($0.summary) })
    checkEqual(started.wait(timeout: .now() + 1), .success, "the older click starts first")
    queue.submit({ JumpExecution(summary: "new", outcome: .done(message: nil)) },
                 completion: { completions.append($0.summary) })
    pumpRunLoop(0.3)
    checkEqual(completions, ["new"], "an older completion cannot overwrite the newer result")
}

func testNavigationAttentionReceipt() {
    print("navigation: a jump acknowledges only the clicked event")
    let store = SessionStore(localHost: HOST)
    let key = SessionKey(host: HOST, id: "attention")
    let first = decode(#"{"ts":100,"event":"Stop","session":"attention"}"#)
    store.apply(first, host: HOST, position: EventPosition(file: "host.jsonl", offset: 100))
    let receipt = store.attentionReceipt(for: store.sessions[key]!, now: 100)
    check(!store.isAcknowledged(store.sessions[key]!), "a pending jump does not clear attention")
    store.apply(first, host: HOST, position: EventPosition(file: "host.jsonl", offset: 200))
    store.acknowledge(receipt)
    check(!store.isAcknowledged(store.sessions[key]!), "a new event remains unread when an old jump finishes")
}

func testNavigationClickSurvivesNonAskingEvents() {
    print("navigation: a click holds until the session asks again")
    let store = SessionStore(localHost: HOST)
    let key = SessionKey(host: HOST, id: "asks")
    var offset: UInt64 = 0
    func feed(_ json: String) {
        offset += 100
        store.apply(decode(json), host: HOST, position: EventPosition(file: "host.jsonl", offset: offset))
    }
    feed(#"{"ts":100,"event":"PreToolUse","session":"asks","turn":"one","tool":"Bash"}"#)
    feed(#"{"ts":101,"event":"Stop","session":"asks","turn":"one"}"#)
    store.acknowledge(store.attentionReceipt(for: store.sessions[key]!, now: 102))
    feed(#"{"ts":160,"event":"Notification","session":"asks","turn":"one"}"#)
    check(store.isAcknowledged(store.sessions[key]!), "the idle reminder for the clicked stop keeps the click")
    feed(#"{"ts":170,"event":"SubagentStop","session":"asks","agent_id":"helper"}"#)
    check(store.isAcknowledged(store.sessions[key]!), "a finished subagent keeps the click")
    feed(#"{"ts":180,"event":"UserPromptSubmit","session":"asks","turn":"two"}"#)
    feed(#"{"ts":181,"event":"PreToolUse","session":"asks","turn":"two","tool":"Bash"}"#)
    feed(#"{"ts":182,"event":"Notification","session":"asks","turn":"two"}"#)
    check(!store.isAcknowledged(store.sessions[key]!), "a notification after new work asks again")
    store.acknowledge(store.attentionReceipt(for: store.sessions[key]!, now: 183))
    feed(#"{"ts":190,"event":"PreToolUse","session":"asks","turn":"two","tool":"Bash"}"#)
    feed(#"{"ts":191,"event":"Notification","session":"asks","turn":"two"}"#)
    check(!store.isAcknowledged(store.sessions[key]!), "a notification after tool work in the same turn asks again")
    feed(#"{"ts":192,"event":"Stop","session":"asks","turn":"two"}"#)
    check(!store.isAcknowledged(store.sessions[key]!), "a new stop asks again")
}

func testNavigationShellQuoting() {
    print("navigation: session identifiers survive an SSH shell")
    withTempDir { directory in
        let ssh = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\nexec /bin/sh -c \"printf '%s\\n' $*\"\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let selected = Jumper.runTmux([ssh.path], ["select-window", "-t", "$2:@1"])
        checkEqual(selected.output, "select-window\n-t\n$2:@1\n", "the shell cannot expand a tmux session identifier")
        let batch = Jumper.runTmux([ssh.path], TmuxTargeting.selection(window: "@1", pane: "%2", session: "$2"))
        check(batch.output.contains("$2:@1\n;\n"), "SSH preserves the session and tmux command separator")
        check(batch.output.hasSuffix("select-pane\n-t\n%2\n"), "SSH sends the pane selection to tmux")
        let marker = directory.appendingPathComponent("must-not-exist")
        let literal = "$(touch \(marker.path))"
        let quoted = Jumper.runTmux([ssh.path], [literal])
        checkEqual(quoted.output, literal + "\n", "the shell preserves literal command text")
        check(!FileManager.default.fileExists(atPath: marker.path), "quoted text cannot execute a shell command")
    }
}

func testNavigationSharedDeadline() {
    print("navigation: several commands share one operation deadline")
    let started = ProcessInfo.processInfo.systemUptime
    CommandRunner.withDeadline(timeout: 0.2) {
        let first = CommandRunner.run("/bin/sh", ["-c", "sleep 0.1"])
        checkEqual(first.status, 0, "the first command completes inside the deadline")
        let second = CommandRunner.run("/bin/sh", ["-c", "sleep 30"])
        check(second.timedOut, "the second command uses only the remaining time")
    }
    check(ProcessInfo.processInfo.systemUptime - started < 1, "several commands cannot restart the deadline")
}

/// A route tab name can also appear in an unrelated tab title. The tab that runs
/// ssh to the route host is the one a click wants, so the picker is not needed.
func testRouteTabPrefersTheSSHTerminal() {
    print("a route click prefers the tab that runs ssh to its host")
    let argv = ["ssh", "-T", "-o", "BatchMode=yes", "-p", "22", "office", "/opt/homebrew/bin/tmux"]
    checkEqual(Jumper.sshDestination(argv) ?? "-", "office", "options and their values are skipped")
    checkEqual(Jumper.sshDestination(["/usr/bin/ssh", "-oBatchMode=yes", "me@office"]) ?? "-", "me@office",
               "a joined option takes no value")
    check(Jumper.sshDestination(["/opt/homebrew/bin/tmux"]) == nil, "a route without ssh has no destination")
    let processes = """
    ttys001  -/bin/zsh
    ttys001  ssh office
    ttys001  python3 /Users/you/.local/bin/ssh-route office 22
    ttys002  -/bin/zsh
    ttys002  claude --resume office
    ttys003  ssh -p 22 laptop
    ??       /usr/bin/ssh-agent -l
    """
    checkEqual(Jumper.ttysRunningSSH(to: "office", in: processes), ["/dev/ttys001"],
               "only a terminal that runs ssh to the host counts")
    let ssh = GhosttyTab(id: "a", windowId: "w", name: "ssh office", cwd: "/", tty: "/dev/ttys001")
    let other = GhosttyTab(id: "b", windowId: "w", name: "Office notes", cwd: "/", tty: "/dev/ttys002")
    checkEqual(Jumper.preferSSH([ssh, other], destination: "office", processes: processes).map(\.id), ["a"],
               "the ssh tab wins over a tab that only shares the name")
    checkEqual(Jumper.preferSSH([ssh, other], destination: "laptop", processes: processes).map(\.id), ["a", "b"],
               "no ssh tab to the host keeps every named tab")
}

func testAttachCommandSurvivesBothShells() {
    print("navigation: a new tab command survives this shell and the remote one")
    withTempDir { directory in
        let ssh = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\nexec /bin/sh -c \"printf '%s\\n' $*\"\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        var route = try Routes.decode(Data(#"{"peer": {"tmux": ["\#(ssh.path)", "-T", "-o", "BatchMode=yes", "office", "tmux"]}}"#.utf8))
            .route(for: "peer")!
        route.recordedSocket = "/tmp/it's here/default"
        let remote = AttachTarget(session: "$3", name: "work", pane: "%1", argv: route.argv,
                                  prefix: route.command([]), route: route, host: "peer")
        let shown = CommandRunner.run("/bin/sh", ["-c", Jumper.attachCommand(remote)])
        checkEqual(shown.output, "-t\n-o\nBatchMode=yes\noffice\ntmux\n-u\n-S\n/tmp/it's here/default\nattach-session\n-t\n$3\n",
                   "the remote shell receives the session identifier and a terminal request")
        let local = AttachTarget(session: "$3", name: "work", pane: "%1", argv: ["/usr/bin/printf", "%s\\n", "-u"],
                                 prefix: [], route: nil, host: nil)
        let printed = CommandRunner.run("/bin/sh", ["-c", Jumper.attachCommand(local)])
        checkEqual(printed.output, "-u\nattach-session\n-t\n$3\n", "a local session attaches without ssh")
    }
}

func testNavigationNeedsLiveRemoteStatus() {
    print("navigation: a remote pane is trusted only while its machine reports status")
    var session = Session(key: SessionKey(host: "peer", id: "run"))
    session.tmuxPane = "%3"
    session.alive = true
    check(Jumper.unconfirmedRefusal(for: session, connection: "connected") == nil,
          "a live status lets the click select the pane")
    check(Jumper.unconfirmedRefusal(for: session, connection: nil) == nil,
          "a route without an event stream keeps working as before")
    for state in ["offline", "catching up"] {
        let refusal = Jumper.unconfirmedRefusal(for: session, connection: state)
        check(refusal?.contains("peer") == true, "an \(state) stream refuses, because the pane may be another run")
    }
    session.isLocal = true
    check(Jumper.unconfirmedRefusal(for: session, connection: "offline") == nil, "a local session is not gated")
}
