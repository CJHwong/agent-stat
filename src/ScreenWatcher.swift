import AppKit

/// Whether anything can see the menu bar right now.
///
/// The icon costs one menu bar update per step, and a locked or sleeping screen
/// cannot show it. Agents often work while you are away, so the steps stop there
/// and resume on wake. Two sources are watched: the display and system sleep, from
/// `NSWorkspace`, and the lock screen, from its own distributed notifications.
@MainActor
final class ScreenWatcher {
    private(set) var awake = true
    /// Called on the main thread after the value changes.
    var onChange: ((Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.screensDidSleepNotification, awake: false)
        watch(workspace, NSWorkspace.willSleepNotification, awake: false)
        watch(workspace, NSWorkspace.screensDidWakeNotification, awake: true)
        watch(workspace, NSWorkspace.didWakeNotification, awake: true)
        let distributed = DistributedNotificationCenter.default()
        watch(distributed, Notification.Name("com.apple.screenIsLocked"), awake: false)
        watch(distributed, Notification.Name("com.apple.screenIsUnlocked"), awake: true)
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, awake next: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.awake != next else { return }
                self.awake = next
                Log.write("screen: \(next ? "awake" : "asleep")")
                self.onChange?(next)
            }
        }
        tokens.append(token)
    }
}
