import AppKit

/// The rounded body and beak mask for the panel.
///
/// The beak is part of the material's own mask, so it blurs with the rest of the
/// panel rather than being a sticker on top of it. The mask is built for a size
/// passed in, never for the effect view's current bounds: a window frame change
/// updates those bounds on the next layout pass, and a mask built from the old
/// bounds sits at the bottom of the new window.
@MainActor
final class PanelMask {
    static let beakHeight: CGFloat = 7
    private var mask: CAShapeLayer?

    func apply(to effect: NSVisualEffectView, size: NSSize, beakCentre: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        guard bounds.width > 0, bounds.height > Self.beakHeight else { return }

        let body = CGRect(x: 0, y: 0, width: bounds.width,
                          height: bounds.height - Self.beakHeight)
        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: 10, cornerHeight: 10)

        let halfWidth: CGFloat = 8
        let inset: CGFloat = 10 + halfWidth
        let centre = min(max(beakCentre, inset), max(inset, bounds.width - inset))
        path.move(to: CGPoint(x: centre - halfWidth, y: body.maxY))
        path.addLine(to: CGPoint(x: centre, y: bounds.maxY))
        path.addLine(to: CGPoint(x: centre + halfWidth, y: body.maxY))
        path.closeSubpath()

        let mask = self.mask ?? CAShapeLayer()
        mask.path = path
        self.mask = mask
        effect.layer?.mask = mask
    }
}
