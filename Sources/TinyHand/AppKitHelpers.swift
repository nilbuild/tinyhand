import AppKit

extension NSView {
    func removeFocusRings() {
        focusRingType = .none
        subviews.forEach { $0.removeFocusRings() }
    }
}

extension NSVisualEffectView {
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
