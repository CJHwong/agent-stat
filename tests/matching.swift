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
    guard case .tmux(let pane) = Jumper.plan(for: local, routes: .none) else {
        check(false, "a local session with a tty still plans its pane")
        return
    }
    checkEqual(pane, "%9", "the pane wins over the tty")
}
