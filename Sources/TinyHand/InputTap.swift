import AppKit

// A session-level CGEventTap that SWALLOWS mouse clicks while the hand is active,
// so tapping is purely cosmetic — it never focuses, activates, or presses anything
// underneath. It reports down/up (sound + tap animation) and left drags (ink).
// Mouse *moves* are left alone, so the hand still follows the pointer.
//
// Requires Accessibility permission (an active tap that can drop events).
final class InputTap {
    var onMouseDown: (() -> Void)?
    var onMouseUp: (() -> Void)?
    var onLeftDragged: (() -> Void)?
    // Presses that start in these rects (CG global coords, top-left origin) reach
    // the app underneath for real: our toolbar and menu bar icon. Follow-up drags
    // and the release go the same way as the press that started them.
    var passThroughRects: [CGRect] = []
    // A press that went through for real (e.g. opening a menu), with its location.
    var onPassThroughPress: ((CGPoint) -> Void)?
    private var passingThrough = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var active = false

    // true once the tap is installed; false if Accessibility was denied.
    private(set) var isInstalled = false

    @discardableResult
    func install() -> Bool {
        guard tap == nil else {
            return true
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let me = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.tap = tap
        self.source = source
        isInstalled = true
        return true
    }

    func setActive(_ value: Bool) {
        active = value
        guard let tap = tap else {
            return
        }
        CGEvent.tapEnable(tap: tap, enable: value)
    }

    // Drives the real handler with a synthetic event, without touching the system.
    func simulate(_ type: CGEventType) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left) else {
            return
        }
        let was = active
        active = true
        _ = handle(type: type, event: event)
        active = was
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: active)
            }
            return Unmanaged.passUnretained(event)
        }

        guard active else {
            return Unmanaged.passUnretained(event)
        }

        // Decide and return at once: macOS holds back ALL mouse input until this
        // callback returns, and disables the tap if it's slow. The work (sound, ink)
        // runs right after, on the next turn of the main run loop.
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            passingThrough = passThroughRects.contains { $0.contains(event.location) }
            if passingThrough {
                let location = event.location
                DispatchQueue.main.async { [weak self] in self?.onPassThroughPress?(location) }
            }
        default:
            break
        }
        if passingThrough {
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                passingThrough = false
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            DispatchQueue.main.async { [weak self] in self?.onMouseDown?() }
            return nil // swallow — no real click happens
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            DispatchQueue.main.async { [weak self] in self?.onMouseUp?() }
            return nil
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Don't swallow drags: the cursor's position is updated from these very
            // events, so dropping them freezes the cursor while the button is held.
            // Pass them on as plain moves instead, so the cursor keeps moving but
            // nothing underneath sees a drag (no text selection, no window drag).
            if type == .leftMouseDragged {
                DispatchQueue.main.async { [weak self] in self?.onLeftDragged?() }
            }
            event.type = .mouseMoved
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
