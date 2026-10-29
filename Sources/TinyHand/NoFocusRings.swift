import AppKit

extension NSView {
    // TinyHand never draws keyboard focus rings: call on a window's content view
    // once it's built.
    func removeFocusRings() {
        focusRingType = .none
        subviews.forEach { $0.removeFocusRings() }
    }
}
