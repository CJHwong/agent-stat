import AppKit
import Foundation
import SwiftUI

/// The development flags, documented in CLAUDE.md. Each one prints something and exits,
/// so the app never starts.
enum DevFlags {
    /// Run whichever flag the arguments name. True means one ran, and the app exits.
    @MainActor
    static func run(_ arguments: [String]) -> Bool {
if let index = arguments.firstIndex(of: "--render") {
    let path = index + 1 < arguments.count ? arguments[index + 1] : "/tmp/agent-stat.png"
    render(to: path)
    exit(0)
}
if let index = arguments.firstIndex(of: "--login-item") {
    let action = index + 1 < arguments.count ? arguments[index + 1] : "state"
    if action == "on" { LoginItem.set(true) }
    if action == "off" { LoginItem.set(false) }
    print(LoginItem.state)
    exit(0)
}
if let index = arguments.firstIndex(of: "--plan-jump") {
    let folder = index + 1 < arguments.count ? arguments[index + 1] : ""
    // An optional second argument is the pty the session runs on, which is what
    // a real record now carries. Leave it out to see the folder-only plan every
    // record written before the tty was captured produces.
    let tty = index + 2 < arguments.count ? arguments[index + 2] : ""
    var session = Session(key: SessionKey(host: "local", id: "probe"))
    session.cwd = (folder as NSString).expandingTildeInPath
    session.term = "ghostty"
    session.tty = tty.hasPrefix("/") ? tty : ""
    session.isLocal = true
    switch Jumper.plan(for: session) {
    case .tmux(let pane):
        print("plan: tmux pane \(pane)")
    case .ghostty(_, let tabs) where tabs.isEmpty:
        print("plan: no tab found for \(session.launchCwd) or its parents")
    case .ghostty(let folder, let tabs):
        print("plan: \(tabs.count) matching tab(s) for \(folder)")
        for tab in tabs { print("  \(tab.name)  [\(tab.cwd)]") }
    case .raiseApp(let name):
        print("plan: raise \(name)")
    case .remote(let host):
        print("plan: refuse, that session is on \(host)")
    case .route(let host, let route, let pane, _):
        print("plan: on \(host) via \(route.argv.joined(separator: " ")), pane \(pane ?? "-")")
    }
    exit(0)
}

        return false
    }

    @MainActor
    static func render(to path: String) {
    let now = Int(Date().timeIntervalSince1970)
    let store = SessionStore(localHost: Paths.localHostName())
    let reader = EventReader()
    for item in reader.poll(directory: Paths.hostsDirectory) {
        store.apply(item.record, host: item.host, position: item.position)
    }
    let remotes = Routes.load().streams.keys.filter { $0 != Paths.localHostName() }
    for host in remotes where !host.contains("/") && host != "." && host != ".." {
        let directory = Paths.eventsDirectory.appendingPathComponent("remote")
            .appendingPathComponent(host).appendingPathComponent("hosts")
        for item in EventReader().poll(directory: directory) {
            store.apply(item.record, host: host, position: item.position)
        }
        store.applyTitles(CodexTitles.cached(in: directory), host: host)
    }
    store.applyTitles(CodexTitles.read(), host: Paths.localHostName())
    store.reapLocal(now: now) { pid, started in
        processIsAlive(Int32(pid), started: started)
    }
    let model = PanelModel()
    model.update(from: store.visible(now: now), now: now,
                 eventsDirectory: Paths.eventsDirectory,
                 attention: store.attentionCount(now: now),
                 acknowledged: { _ in false },
                 tabs: Jumper.ghosttyTabs(),
                 connections: Dictionary(uniqueKeysWithValues: remotes.map { ($0, "offline") }))

    // The panel draws its own material in the window, which does not exist here,
    // so the render gets an opaque background to sit on.
    let view = PanelView(model: model, scrolls: false)
        .background(Color(nsColor: .windowBackgroundColor))
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("render failed")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("rendered \(path) \(Int(image.size.width))x\(Int(image.size.height))pt "
          + "from \(store.visible(now: now).count) sessions")
    }
}
