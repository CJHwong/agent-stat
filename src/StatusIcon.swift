import AppKit

/// The menu bar icon: the panel in miniature.
///
/// Three rows, each a status dot and a bar, so the icon and the thing it opens look
/// alike. One dot carries the highlight and is solid, the rest are lighter. A template
/// image, so the menu bar tints it for the light and dark appearances and beside the
/// count it stays legible. Drawn rather than borrowed from the symbol set, because no
/// symbol says "a list of sessions".
enum StatusIcon {
    /// The rows it draws, top row first.
    static let baselines: [CGFloat] = [11.6, 7.4, 3.2]

    /// Which row carries the highlight, advanced on an interval while work is going on.
    ///
    /// A watcher tick is not a clock. A busy machine ticks several times a second, and
    /// stepping on each tick made the icon flicker and cost a status item update per
    /// record. Seconds are the unit, so the step rate is the same whether the panel
    /// is open or closed.
    struct Stepper {
        /// How long the highlight stays on one row. Three seconds still reads as
        /// motion, and every step costs the menu bar one image update.
        static let secondsPerStep = 3
        /// The row drawn now, from 0.
        private(set) var step = 0
        private var lastSecond = 0

        /// The row to draw: the next one after the interval passes, and the first
        /// row once the work stops.
        mutating func advance(working: Bool, second: Int) -> Int {
            guard working else {
                step = 0
                return step
            }
            if second - lastSecond >= Self.secondsPerStep {
                lastSecond = second
                step = (step + 1) % StatusIcon.baselines.count
            }
            return step
        }
    }

    static func image(highlight: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            for (index, baseline) in baselines.enumerated() {
                let alpha: CGFloat = index == highlight ? 1 : 0.45
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: 0.6, y: baseline - 1.6, width: 3.4, height: 3.4)).fill()
                NSBezierPath(roundedRect: NSRect(x: 6.4, y: baseline - 1.1, width: 11, height: 2.2),
                             xRadius: 1.1, yRadius: 1.1).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "agent-stat"
        return image
    }
}
