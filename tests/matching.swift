import Foundation

/// Which Ghostty tab a click goes to. The folder, the session name, and the tty
/// are three handles of increasing exactness, and each one is a fallback for the
/// one above it.

func testMatchingTabs() {
    print("matching a row to its tab")
    let tabs = [
        GhosttyTab(id: "t1", windowId: "w1", name: "first", cwd: "/Users/you/work/api", tty: ""),
        GhosttyTab(id: "t2", windowId: "w1", name: "second", cwd: "/Users/you/work/api", tty: ""),
        GhosttyTab(id: "t3", windowId: "w1", name: "notes", cwd: "/Users/you/work/notes", tty: "")
    ]
    var session = Session(key: SessionKey(host: HOST, id: "s"))
    session.isLocal = true
    session.launchCwd = "/Users/you/work/api"
    checkEqual(Jumper.matchingTabs(for: session, in: tabs).tabs.count, 2,
               "two tabs in that folder are both candidates, which is why a click asks")

    session.launchCwd = "/Users/you/work/api/sub"
    checkEqual(Jumper.matchingTabs(for: session, in: tabs).tabs.count, 2,
               "a session in a subfolder falls back to the folder its tab sits in")

    // A session that knows its own name matches on it, which is what separates two
    // sessions sharing one folder, the case the folder alone cannot settle.
    var named = session
    named.title = "Builder Workshop"
    let namedTabs = [
        GhosttyTab(id: "t1", windowId: "w1", name: "\u{2733} Builder Workshop",
                   cwd: "/Users/you/work/api", tty: ""),
        GhosttyTab(id: "t2", windowId: "w1", name: "image-gen",
                   cwd: "/Users/you/work/api", tty: "")
    ]
    checkEqual(Jumper.matchingTabs(for: named, in: namedTabs).tabs.map(\.id), ["t1"],
               "the session name picks its own tab out of a folder two tabs share")

    named.title = "no tab carries this"
    checkEqual(Jumper.matchingTabs(for: named, in: namedTabs).tabs.count, 2,
               "and a name no tab carries falls back to matching the folder")

    // A word shared with a tab in another folder is not evidence. The session's own
    // folder wins, or a click would land in a window that has nothing to do with it.
    var titled = Session(key: SessionKey(host: HOST, id: "titled"))
    titled.isLocal = true
    titled.launchCwd = "/Users/you/work/backend"
    titled.title = "api"
    let mixedTabs = [
        GhosttyTab(id: "x1", windowId: "w1", name: "api notes", cwd: "/Users/you/work/docs",
                   tty: ""),
        GhosttyTab(id: "x2", windowId: "w1", name: "backend", cwd: "/Users/you/work/backend",
                   tty: "")
    ]
    checkEqual(Jumper.matchingTabs(for: titled, in: mixedTabs).tabs.map(\.id), ["x2"],
               "a name found only in another folder does not move the click there")

    // With no tab in its folder, the name is the only handle left: the tab may have
    // changed directory after the session started.
    titled.launchCwd = "/Users/you/work/moved"
    checkEqual(Jumper.matchingTabs(for: titled, in: mixedTabs).tabs.map(\.id), ["x1"],
               "with no tab in its folder, a name elsewhere is used")

    session.launchCwd = "/Users/you/work/nowhere"
    checkEqual(Jumper.matchingTabs(for: session, in: tabs).tabs.count, 0,
               "a folder no tab sits in matches nothing")
    checkEqual(Jumper.matchingTabs(for: session, in: []).tabs.count, 0,
               "and with no tabs read at all, nothing matches")
}

/// The tty is the exact handle, and it is new, so every case here also pins what
/// happens when it is missing.
func testMatchingTabsByTTY() {
    print("matching a row to its tab by tty")
    // A tty names exactly one surface, so it settles what the folder cannot: two
    // sessions launched in the same folder, which is the case a click has to ask
    // about. Measured on a live machine, two of four rows needed the picker and
    // the tty separated them.
    let ptyTabs = [
        GhosttyTab(id: "p1", windowId: "w1", name: "first", cwd: "/Users/you/work/api",
                   tty: "/dev/ttys001"),
        GhosttyTab(id: "p2", windowId: "w1", name: "second", cwd: "/Users/you/work/api",
                   tty: "/dev/ttys002")
    ]
    var session = Session(key: SessionKey(host: HOST, id: "tty"))
    session.isLocal = true
    session.launchCwd = "/Users/you/work/api"
    session.tty = "/dev/ttys002"
    checkEqual(Jumper.matchingTabs(for: session, in: ptyTabs).tabs.map(\.id), ["p2"],
               "the tty picks its own tab out of a folder two tabs share")

    // The whole point of the fallback: a record written before the tty was
    // recorded, or by a Ghostty that does not report one, must plan exactly as
    // it did before. Same folder, same answer, picker included.
    session.tty = ""
    checkEqual(Jumper.matchingTabs(for: session, in: ptyTabs).tabs.count, 2,
               "a session with no tty falls back to the folder, as before")

    session.tty = "/dev/ttys999"
    checkEqual(Jumper.matchingTabs(for: session, in: ptyTabs).tabs.count, 2,
               "a tty no tab reports falls back to the folder, never to nothing")

    // An empty tty must never match an empty tty. Without this guard, every
    // session from an older record would claim the first tab of an older Ghostty.
    let bareTabs = [
        GhosttyTab(id: "b1", windowId: "w1", name: "unrelated", cwd: "/Users/you/work/other",
                   tty: "")
    ]
    var bare = Session(key: SessionKey(host: HOST, id: "bare"))
    bare.isLocal = true
    bare.launchCwd = "/Users/you/work/api"
    bare.tty = ""
    checkEqual(Jumper.matchingTabs(for: bare, in: bareTabs).tabs.count, 0,
               "an empty tty never matches an empty tty, or a wrong tab would win")
}

/// Inside tmux the agent owns the pane pty, not the Ghostty surface pty, so the
/// tty compare could not match anyway. The pane is exact and is decided first.
func testTTYDoesNotOverrideTmux() {
    print("a tty does not override a tmux pane")
    var local = Session(key: SessionKey(host: HOST, id: "tty-pane"))
    local.isLocal = true
    local.tmuxPane = "%9"
    local.tty = "/dev/ttys009"
    guard case .tmux(let pane, _) = Jumper.plan(for: local, routes: .none) else {
        check(false, "a local session with a tty still plans its pane")
        return
    }
    checkEqual(pane, "%9", "the pane wins over the tty")
}

func testMatchingTmuxClientTabs() {
    print("a local tmux client identifies its Ghostty tab")
    let tabs = [
        GhosttyTab(id: "local", windowId: "window", name: "tmux", cwd: "/w", tty: "/dev/ttys101"),
        GhosttyTab(id: "remote", windowId: "window", name: "ssh peer", cwd: "/w", tty: "/dev/ttys102"),
        GhosttyTab(id: "unknown", windowId: "window", name: "shell", cwd: "/w", tty: "")
    ]
    checkEqual(TmuxTargeting.matchingClientTabs(in: "/dev/ttys101\n\n", tabs: tabs).map(\.id), ["local"],
               "the client terminal selects the local tab instead of the remote tab")
    check(TmuxTargeting.matchingClientTabs(in: "\n", tabs: tabs).isEmpty,
          "a control client without a terminal does not match an unknown surface")
    checkEqual(TmuxTargeting.matchingClientTabs(in: "/dev/ttys101\n/dev/ttys102\n", tabs: tabs).count, 2,
               "several terminal tabs remain candidates")
    check(TmuxTargeting.matchingClientTabs(in: "/dev/ttys103\n", tabs: tabs).isEmpty,
          "a client in another terminal app matches no Ghostty tab")
}

private func withRemoteJump(title: String = "Memory report", pane: String? = nil,
                            titles: String = "%12,Memory report | operator\n",
                            listing: String = "%12,@3,1,/w\n",
                            failure: String = "",
                            _ body: (JumpOutcome, String) -> Void) {
    withTempDir { directory in
        let script = directory.appendingPathComponent("tmux.sh")
        try """
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        case "$*" in
            *pane_title*) cat titles ;;
            list-panes*) cat listing ;;
            run-shell*) exit 1 ;;
            *) while [ "$#" -gt 0 ]; do
                   case "$1" in
                       select-window|select-pane)
                           command="$1"
                           printf '%s %s %s\\n' "$1" "$2" "$3" >> selected
                           shift 3
                           if [ "$command" = "$(cat failure)" ]; then exit 1; fi ;;
                       display-message) printf '%s\\n' "$3"; shift 3 ;;
                       ';') shift ;;
                       *) exit 1 ;;
                   esac
               done ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try titles.write(to: directory.appendingPathComponent("titles"), atomically: true, encoding: .utf8)
        try listing.write(to: directory.appendingPathComponent("listing"), atomically: true, encoding: .utf8)
        try failure.write(to: directory.appendingPathComponent("failure"), atomically: true, encoding: .utf8)
        let encoded = try JSONSerialization.data(withJSONObject: ["peer": ["tmux": ["/bin/sh", script.path]]])
        let routes = try Routes.decode(encoded)
        var session = Session(key: SessionKey(host: "peer", id: "ram"))
        session.title = title
        session.tmuxPane = pane
        session.launchCwd = "/w"
        let outcome = Jumper.perform(Jumper.plan(for: session, routes: routes))
        let selected = (try? String(contentsOf: directory.appendingPathComponent("selected"), encoding: .utf8)) ?? ""
        body(outcome, selected)
    }
}

func testRemotePaneTitleFallback() {
    print("a remote session without a pane uses its title")
    withRemoteJump { outcome, selected in
        check(outcome.message?.contains("selected the pane") == true, "a unique title selects the pane")
        checkEqual(selected, "select-window -t @3\nselect-pane -t %12\n", "the click selects the window and split")
    }
    withRemoteJump(titles: "%12,Memory report\n%12,Memory report\n") { _, selected in
        check(selected.contains("select-pane -t %12"), "a linked window does not make one pane ambiguous")
    }
    withRemoteJump(titles: "%12,⠏ Memory report | operator\n") { _, selected in
        check(selected.contains("select-pane -t %12"), "a live Codex spinner does not hide the session title")
    }
    withRemoteJump(pane: "%12", titles: "%13,Memory report | operator\n") { _, selected in
        check(selected.contains("select-pane -t %12"), "the recorded identifier keeps priority")
    }
}

func testRemotePaneTitleRefusals() {
    print("a title fallback refuses uncertain targets")
    withRemoteJump(titles: "%12,Memory report | operator\n%13,Memory report\n",
                   listing: "%12,@3,1,/w\n%13,@4,1,/w\n") { outcome, selected in
        check(outcome.message?.contains("multiple panes") == true, "duplicate titles report ambiguity")
        checkEqual(selected, "", "duplicate titles select nothing")
    }
    withRemoteJump(titles: "%12,Memory report notes\n") { outcome, selected in
        check(outcome.message?.contains("no pane") == true, "a partial title reports no match")
        checkEqual(selected, "", "a partial title selects nothing")
    }
    withRemoteJump(listing: "%12,@3,0,/w\n") { outcome, selected in
        check(outcome.message?.contains("no tmux client") == true, "a detached match reports no client")
        checkEqual(selected, "", "a detached match selects nothing")
    }
    withRemoteJump(listing: "%12,@3,1,/other\n") { outcome, selected in
        check(outcome.message?.contains("different folder") == true, "a match in another folder stays refused")
        checkEqual(selected, "", "another folder selects nothing")
    }
    withRemoteJump(title: "") { outcome, selected in
        check(outcome.message?.contains("no tmux pane") == true, "missing metadata reports an unavailable target")
        checkEqual(selected, "", "missing metadata does not claim a selection")
    }
    withRemoteJump(titles: "%12,Memory report\n%13,Memory report\n",
                   listing: "%12,@3,1,/w\n%13,@4,1,/other\n") { _, selected in
        check(selected.contains("select-pane -t %12"), "folder evidence narrows duplicate title matches")
    }
}

func testRemotePaneSelectionErrors() {
    print("a failed remote selection reports the error")
    withRemoteJump(failure: "select-window") { outcome, selected in
        check(outcome.message?.contains("could not select @3") == true, "a window failure reports the error")
        checkEqual(selected, "select-window -t @3\n", "a window failure stops before pane selection")
    }
    withRemoteJump(failure: "select-pane") { outcome, _ in
        check(outcome.message?.contains("could not select pane %12") == true, "a split failure reports the error")
    }
}

func testRemotePaneTitleParsing() {
    print("pane titles preserve punctuation and require a complete name")
    let listing = "%1,Memory report, today | operator\n%2,memory report\n%3,Memory report notes\n%4,notes Memory report\nmalformed\n"
    checkEqual(TmuxTargeting.matchingPanes(title: "Memory report, today", in: listing), ["%1"],
               "a comma in the title survives")
    checkEqual(TmuxTargeting.matchingPanes(title: "Memory report", in: listing), ["%2"],
               "case does not change a match, but extra words do")
    check(TmuxTargeting.matchingPanes(title: "   ", in: listing).isEmpty, "a blank title matches nothing")
    for prefix in ["⠏ ", "⠋ ", "✳ ", "✳️ "] {
        checkEqual(TmuxTargeting.matchingPanes(title: "Memory report", in: "%12,\(prefix)Memory report | operator"), ["%12"],
                   "a status symbol preserves the session title")
    }
}
