import AppKit
import Darwin
import SwiftUI

/// Menu bar app: polls the events directory once a second and shows a panel.
///
/// The panel is a positioned NSPanel rather than an NSPopover. A popover shown
/// from a status item without a click was placed loose on the screen instead of
/// attached under the menu bar, and it did not appear at all. Positioning the
/// window myself removes that variable.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    let model = PanelModel()
    private var panel: NSPanel?
    private var hosting: NSHostingController<PanelView>?
    private var effectView: NSVisualEffectView?
    private let panelMask = PanelMask()
    private var clickMonitor: Any?
    /// The clock, which runs slowly while the panel is closed. See `refreshTickInterval`.
    private lazy var clock = TickClock { [weak self] in self?.tick(clock: true) }
    /// Whether any session is working, as of the last tick. This decides the cadence.
    private var anyBusy = false
    /// Whether the screen can show the menu bar. The icon stops while it cannot.
    private let screen = ScreenWatcher()
    /// Ghostty's tabs, as last read, and whether a read is in flight. Read only while
    /// the panel is open, on a background queue, so a row can name its tab without the
    /// panel ever waiting on an AppleScript.
    private var tabs: [GhosttyTab] = []
    private var tabReadInFlight = false

    /// The events directory and its files, watched so a landing record updates the panel
    /// at once rather than at the next second.
    private lazy var watcher = EventWatcher(directory: Paths.hostsDirectory) { [weak self] in
        self?.scheduleTick()
    }
    /// One tick per run-loop turn. A single write can fire more than one source event.
    private var tickScheduled = false
    /// The clock work runs on the one second timer, not on every record: liveness, the
    /// tab list and the watch-list refresh cannot change faster than that.
    private var lastProbeSecond = 0
    private var lastTitleSecond = 0
    private var lastTabSecond = 0
    private var lastWatchRefreshSecond = 0
    /// The tab titles carry a spinner that changes every second, and the whole tab list
    /// costs an AppleScript. A row's hint can lag this long; a click reads the live list.
    private static let tabRefreshSeconds = 30
    /// A fallback for the directory source, which already refreshes on a create or rename.
    private static let watchRefreshSeconds = 60

    /// Where the icon's highlight is, and which row is drawn right now.
    private var icon = StatusIcon.Stepper()
    private var iconStepShown = -1
    /// The panel's own fitting size, kept between ticks. See `position`.
    private var fittedSize: CGSize?
    /// The window size and beak the mask was last built for. Auto Layout can resize
    /// the window to the SwiftUI content before `position` runs, so the frame can
    /// already match the target and the mask would otherwise stay at the old size.
    private var shapedSize: CGSize?
    private var shapedBeak: CGFloat?
    /// Where the panel was opened from. It keeps that item and screen while the panel
    /// stays open, so a badge change does not move the panel.
    private let anchor = PanelAnchor()
    /// True while the panel is being opened, so the rows are rebuilt before the first
    /// draw rather than one tick later.
    private var openingPanel = false

    lazy var store = SessionStore(localHost: Paths.localHostName())
    private let reader = EventReader()
    private let names = CodexTitles()
    private lazy var remote = RemoteHosts(store: store) { [weak self] in self?.scheduleTick() }

    func applicationWillTerminate(_ notification: Notification) {
        remote.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.image(highlight: 0)
        statusItem.button?.imagePosition = .imageLeading
        // Bold digits read at a glance, and monospaced digits keep the item width
        // steady as the count changes.
        statusItem.button?.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .bold)
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        // A left click opens the panel, a right click offers the menu a menu bar app is
        // expected to have. Without this the app can only be stopped with `killall`,
        // since it has no window and no dock icon.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildPanel()

        model.onJump = { [weak self] session in self?.jump(to: session) }
        model.onPick = { [weak self] tab in self?.jumpTo(tab: tab) }
        model.onDismiss = { [weak self] session in self?.dismiss(session) }

        let memory = PanelMemory.load()
        store.restore(dismissed: memory.dismissed, acknowledged: memory.acknowledged,
                      dismissedPositions: memory.dismissedPositions,
                      acknowledgedPositions: memory.acknowledgedPositions)
        Log.write("started. events=\(Paths.eventsDirectory.path) "
                  + "localHost=\(Paths.localHostName()) routes=\(Routes.load().count) "
                  + "hidden=\(store.dismissed.count) clicked=\(store.acknowledged.count)")
        remote.start()
        tick(clock: true)

        // A lock, a sleeping display or a wake changes what needs ticking, and a
        // wake has to redraw the icon at once rather than at the next slow tick.
        screen.onChange = { [weak self] _ in self?.tick(clock: true) }
        refreshTickInterval()

        if ProcessInfo.processInfo.environment["AGENT_STAT_SHOW_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showPanel()
            }
        }
    }

    /// Move the highlight in the icon while work is going on.
    ///
    /// The solid dot steps down a row each second, and the image is only redrawn when
    /// that step changes, so a quiet panel costs nothing. This runs whether the panel
    /// is open or closed: the moving row is how you tell work is in flight without
    /// opening it.
    private func advanceIcon(working: Bool, now: Int) {
        let step = icon.advance(working: working, second: now)
        if step != iconStepShown {
            statusItem.button?.image = StatusIcon.image(highlight: step)
            iconStepShown = step
        }
    }

    // MARK: panel

    private func buildPanel() {
        let hosting = NSHostingController(rootView: PanelView(model: model))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The effect view must BE the content view. Setting contentViewController
        // instead replaces the content view outright, which silently threw this
        // away and left the SwiftUI view sitting on a transparent window.
        //
        // No border: a hairline outline over rounded corners reads as a cheap
        // box. The material and the window shadow already define the edge.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        let content = hosting.view
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            // The beak occupies the top strip, so the content starts below it.
            content.topAnchor.constraint(equalTo: effect.topAnchor, constant: PanelMask.beakHeight),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
        ])

        panel.contentView = effect
        self.hosting = hosting
        self.effectView = effect
        self.panel = panel
    }

    /// Size to the content, then sit under the status item, right of it by default and
    /// flipping to the left only when the panel would run off the screen that way.
    private func position(_ panel: NSPanel, refit: Bool) {
        // The status item jumps to whichever display has the active menu bar, and it
        // moves sideways when the badge changes its width. The anchor keeps the item
        // and the screen it opened against, so the open panel stays put.
        guard let window = statusItem.button?.window else { return }
        guard let item = anchor.current(window: window) else { return }
        let screen = anchor.openedScreen
            ?? PanelAnchor.screen(for: item, window: window) ?? NSScreen.main
        // The fitting size lays the whole panel out, so the answer is kept until the
        // rows publish.
        let measured = refit || fittedSize == nil
        if measured {
            // A published change is applied to the SwiftUI tree on the next layout
            // pass. Measuring first returns the previous height, and the cached
            // answer then holds the panel at that size after Auto Layout grows it.
            hosting?.view.layoutSubtreeIfNeeded()
            fittedSize = hosting?.view.fittingSize
        }
        let contentSize = fittedSize ?? CGSize(width: 380, height: 120)
        let width = max(contentSize.width, 380)
        // A list too long for the cap scrolls. A scroll view reports no content height,
        // so the window is sized from the same estimate that chose the scroll view.
        let scrolling = model.estimatedContentHeight > PanelModel.maxListHeight
        let contentHeight = scrolling
            ? 48 + PanelModel.maxListHeight + (model.status == nil ? 0 : 30)
            : contentSize.height
        let maxHeight = max(240, (screen?.visibleFrame.height ?? 900) - 40)
        let height = min(max(contentHeight, 60), maxHeight) + PanelMask.beakHeight
        // Setting a size or an origin the window already has still lays it out, and this
        // runs several times a second while the panel is open. So, only on a change.
        let size = NSSize(width: width, height: height)
        let visible = screen?.visibleFrame ?? .zero
        let originX = Placement.panelX(item: item, panelWidth: width, visible: visible)
        // The beak touches the menu bar, so the body sits just below it.
        let top = item.minY - 1
        let origin = NSPoint(x: originX, y: top - height)
        // One frame change, not a resize and then a move. A taller panel, which is
        // what the footer adds, grew upward from its origin for one frame before
        // the origin moved down, and that reads as the panel jumping.
        let frame = NSRect(origin: origin, size: size)
        let changed = panel.frame != frame
        if changed { panel.setFrame(frame, display: true) }

        let itemCentre = item.minX + item.width / 2
        let beakCentre = itemCentre - panel.frame.minX
        if let effect = effectView,
           panel.frame.size != shapedSize || beakCentre != shapedBeak {
            panelMask.apply(to: effect, size: panel.frame.size, beakCentre: beakCentre)
            shapedSize = panel.frame.size
            shapedBeak = beakCentre
        }
    }

    private func showPanel() {
        guard let panel else { return }
        // Freeze the item and the screen the panel belongs to while it is open.
        anchor.open(window: statusItem.button?.window)
        // Opening counts as open. The rows are rebuilt only while the panel is up, so
        // without this the first draw is whatever the panel last showed, and on a fresh
        // launch nothing: the window fitted an empty model and opened forty pixels tall.
        openingPanel = true
        // The first draw reads the tabs, whatever the refresh clock says.
        lastTabSecond = 0
        tick(clock: true)
        openingPanel = false
        position(panel, refit: true)
        panel.orderFrontRegardless()
        Log.write("panel opened. item=\(statusItem.button?.window?.frame ?? .zero) "
                  + "panel=\(panel.frame)")
        installClickMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        // The ages no longer need a second, so stop paying for one at once.
        refreshTickInterval()
    }

    private func installClickMonitor() {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hidePanel() }
            }
    }

    /// A left click opens the panel, a right click opens the menu.
    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        guard let panel else { return }
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    @objc func toggleLoginItem() {
        // Registering again while macOS holds the item does nothing useful. Send the
        // user to the switch it is waiting on instead.
        if LoginItem.needsApproval {
            LoginItem.openSystemSettings()
            return
        }
        LoginItem.set(!LoginItem.isOn)
    }

    /// Show the menu the status item owns, attached for the moment it is shown and then
    /// detached so a left click still opens the panel. See `StatusMenu`.
    private func showStatusMenu() {
        Log.write("status menu: right click")
        statusItem.menu = StatusMenu.build(target: self, loginAction: #selector(toggleLoginItem))
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: data

    /// Coalesce watcher callbacks into one tick per run-loop turn.
    private func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.tickScheduled = false
            self?.tick(clock: false)
        }
    }

    /// Read whatever is new and redraw.
    ///
    /// `clock` marks the timer pass: liveness, the tab list and the watch-list fallback.
    /// A tick caused by a record repeats none of them, so a burst of writes costs the
    /// poll and the draw, nothing more.
    func tick(clock: Bool = false) {
        let now = Int(Date().timeIntervalSince1970)
        for item in reader.poll(directory: Paths.hostsDirectory) {
            store.apply(item.record, host: item.host, position: item.position)
        }
        remote.read()
        if now - lastTitleSecond >= 5 {
            lastTitleSecond = now
            store.applyTitles(names.read(), host: Paths.localHostName())
        }
        if clock {
            if now != lastProbeSecond {
                lastProbeSecond = now
                store.reapLocal(now: now) { pid, started in
                    processIsAlive(Int32(pid), started: started)
                }
            }
            let open = panel?.isVisible == true || openingPanel
            if open, !tabReadInFlight, now - lastTabSecond >= Self.tabRefreshSeconds {
                lastTabSecond = now
                tabReadInFlight = true
                DispatchQueue.global(qos: .utility).async {
                    let read = Jumper.ghosttyTabs()
                    Task { @MainActor in
                        self.tabs = read
                        self.tabReadInFlight = false
                    }
                }
            }
            if now - lastWatchRefreshSecond >= Self.watchRefreshSeconds {
                lastWatchRefreshSecond = now
                watcher.refresh()
            }
        }
        let sessions = store.visible(now: now)
        // The badge is computed from the store every tick, whatever the panel is doing:
        // it used to read the model, which is only rebuilt while the panel is open, so it
        // froze at the last value you saw and only a click moved it.
        let attention = store.attentionCount(now: now)
        // Only while the panel is open: laying the rows out cost a sixth of a core
        // even with nothing on screen. The badge and icon come from the store instead.
        var published = PanelModel.PublishResult(content: false, layout: false)
        if panel?.isVisible == true || openingPanel {
            published = model.update(from: sessions, now: now,
                         eventsDirectory: Paths.eventsDirectory,
                         attention: attention,
                         acknowledged: { store.isAcknowledged($0) },
                         tabs: tabs, connections: remote.labels(now: now))
        }
        // The icon steps whenever an agent works, open or closed: the moving row is
        // the signal that something is in flight. It stops while the screen cannot
        // show it, and moves one row per step interval, not once per tick.
        anyBusy = sessions.contains { $0.isBusy }
        advanceIcon(working: screen.awake && anyBusy, now: now)

        let wanted = attention > 0 ? " \(attention)" : ""
        if statusItem.button?.title != wanted { statusItem.button?.title = wanted }
        if panel?.isVisible == true, let panel { position(panel, refit: published.layout) }
        refreshTickInterval()
    }
}

extension AppDelegate {
    /// The app's only wakeup while the panel is closed. A record still wakes a tick at once.
    private func refreshTickInterval() {
        clock.schedule(every: TickClock.cadence(
            panelOpen: panel?.isVisible == true || openingPanel,
            screenAwake: screen.awake,
            busy: anyBusy))
    }
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments

    if DevFlags.run(arguments) { return }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
