import AppKit

/// Where the panel belongs while it is open.
///
/// The anchor is the status item captured when the panel opened, and it does not
/// change while the panel stays open. The item moves sideways when the badge
/// appears or clears: the menu bar right-aligns its items, so a narrower item
/// starts further right. Following that move slid the panel 16 points sideways a
/// moment after a click, which reads as a jump. An open panel stays where it was
/// opened, the way a menu does, and is aligned to the item again at the next open.
///
/// The screen is captured with it, so a click that brings another display forward
/// does not drag the panel there.
@MainActor
final class PanelAnchor {
    private var frame: CGRect?
    private var screen: NSScreen?

    /// Capture the item the panel is opening from.
    func open(window: NSWindow?) {
        guard let window else { return }
        frame = window.frame
        screen = PanelAnchor.screen(for: window.frame, window: window)
    }

    /// Where the panel should sit now, or nil when there is no item yet.
    func current(window: NSWindow?) -> CGRect? {
        frame ?? window?.frame
    }

    /// The screen the panel belongs to.
    var openedScreen: NSScreen? { screen }

    /// The screen that holds the menu bar item.
    ///
    /// The item window's own report is used first. It can be nil, so the fallback is
    /// the screen whose top edge the item sits on. `NSScreen.main` is not that screen:
    /// it follows the key window and can be the other display.
    static func screen(for frame: CGRect, window: NSWindow?) -> NSScreen? {
        if let reported = window?.screen { return reported }
        let candidates = NSScreen.screens.filter {
            $0.frame.minX <= frame.midX && frame.midX <= $0.frame.maxX
        }
        return candidates.min {
            abs($0.frame.maxY - frame.maxY) < abs($1.frame.maxY - frame.maxY)
        }
    }
}
