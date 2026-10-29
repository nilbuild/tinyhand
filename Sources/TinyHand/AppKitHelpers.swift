import AppKit

extension NSView {
    // TinyHand never draws keyboard focus rings: call on a window's content view
    // once it's built.
    func removeFocusRings() {
        focusRingType = .none
        subviews.forEach { $0.removeFocusRings() }
    }
}

extension NSVisualEffectView {
    // Rounds the view with a mask image (not a layer corner radius), so the window
    // shadow follows the rounded shape instead of a square box behind it.
    func roundCorners(_ radius: CGFloat) {
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        maskImage = mask
    }
}
