import CoreGraphics

/// Where the panel sits relative to the menu bar item that opened it.
///
/// Pure, so it can be tested without a screen. The flip case is the reason: the
/// panel grows to the right of the item by default, and only hangs to the left
/// when it would otherwise run off the screen. An item with room to its right
/// never flips, which is the common case, so the branch would otherwise never be
/// exercised by hand.
enum Placement {
    static let margin: CGFloat = 8

    static func panelX(item: CGRect, panelWidth: CGFloat, visible: CGRect) -> CGFloat {
        // Default: the left edge lines up with the item's left edge, so the panel
        // grows to the right of the icon.
        var originX = item.minX
        if originX + panelWidth > visible.maxX - margin {
            // Not enough room on the right, so hang to the left of the item.
            originX = item.maxX - panelWidth
        }
        let lowest = visible.minX + margin
        let highest = max(lowest, visible.maxX - panelWidth - margin)
        return min(max(originX, lowest), highest)
    }
}
