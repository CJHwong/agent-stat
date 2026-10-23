import ServiceManagement

/// Whether the panel starts at login, and how to change that.
///
/// The modern login item API, so there is no plist of ours and nothing for the user to
/// edit. macOS keeps the entry, and it can ask the user to approve it in System Settings
/// before it takes effect.
///
/// It registers the bundle that is running, so the app has to stay where it was
/// registered from. Moving or rebuilding it somewhere else leaves the login item
/// pointing at the copy that is no longer there.
enum LoginItem {
    static var isOn: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS is holding it for approval, which the user gives in System
    /// Settings, then General, then Login Items.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// What macOS reports, for the menu and for the development flag.
    static var state: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "starts at login"
        case .notRegistered: return "does not start at login"
        case .requiresApproval: return "waiting for approval in System Settings"
        case .notFound: return "the bundle cannot be found where it was registered"
        @unknown default: return "unknown"
        }
    }

    /// Take the user to the place where macOS waits for approval.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func set(_ startAtLogin: Bool) {
        do {
            if startAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("login item: could not turn it \(startAtLogin ? "on" : "off"): \(error)")
        }
        Log.write("login item: \(state)")
    }
}
