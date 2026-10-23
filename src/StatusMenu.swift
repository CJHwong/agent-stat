import AppKit

/// The menu a right click on the icon opens.
///
/// Built here rather than in the delegate, which keeps the delegate to being a delegate.
/// The shape is the one the widget app uses: the checkable item first, a separator, then
/// Quit, and the menu is attached to the status item for the moment it is shown so it is
/// drawn with the menu bar metrics rather than the context menu ones.
enum StatusMenu {
    static func build(target: AnyObject, loginAction: Selector) -> NSMenu {
        let menu = NSMenu()
        // A checkmark carries the state and the title stays put, which is the menu bar
        // convention and which reserves the mark column for every item in the menu.
        // A checkmark carries the state. When macOS is holding the item for approval
        // there is no checkmark yet, so the title says where to give it.
        let title = LoginItem.needsApproval
            ? "Start at login (approve in System Settings)"
            : "Start at login"
        let login = NSMenuItem(title: title, action: loginAction, keyEquivalent: "")
        login.target = target
        login.state = LoginItem.isOn ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit agent-stat",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }
}
