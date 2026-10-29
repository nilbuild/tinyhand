import AppKit

// A session-level CGEventTap that SWALLOWS mouse clicks while the hand is active,
// so tapping is purely cosmetic — it never focuses, activates, or presses anything
// underneath. It reports down/up (sound + tap animation) and left drags (ink).
// Mouse *moves* are left alone, so the hand still follows the pointer.
//
// A press made while the interact key (e.g. ⌥) is held goes through for real, with
// that key taken off, so it lands as a plain click, drag or right-click.
//
// macOS holds back ALL mouse input until a tap's callback returns, so the tap runs
// on its own thread: a busy or stalled main thread can never freeze clicks system
// wide. The callback only decides; the work (sound, ink) runs on the main thread.
//
// Requires Accessibility permission (an active tap that can drop events).
final class InputTap {
    var onMouseDown: (() -> Void)?
    var onMouseUp: (() -> Void)?
    var onLeftDragged: (() -> Void)?
    // A press that went through for real (e.g. opening a menu), with its location.
    var onPassThroughPress: ((CGPoint) -> Void)?

    // Shared with the tap thread.
    private let lock = NSLock()
    private var _active = false
    private var _passThroughRects: [CGRect] = []
    private var _interactKey: CGEventFlags = []
    private var _interactPress = false

    // Presses that start in these rects (CG global coords, top-left origin) reach
    // the app underneath for real: our toolbar and menu bar icon. Follow-up drags
    // and the release go the same way as the press that started them.
    var passThroughRects: [CGRect] {
        get { lock.withLock { _passThroughRects } }
        set { lock.withLock { _passThroughRects = newValue } }
    }

    private var active: Bool {
        lock.withLock { _active }
    }

    // Modifier that makes presses real while held; empty turns it off.
    var interactKey: CGEventFlags {
        get { lock.withLock { _interactKey } }
        set { lock.withLock { _interactKey = newValue } }
    }

    // True from a real (interact) press until its release, even if the key is let go.
    var interactPressing: Bool {
        lock.withLock { _interactPress }
    }

    private var passingThrough = false // tap thread only
    // Longest wait (ms) between an event being created and reaching this tap, for tests.
    private(set) var maxWaitMs: Double = 0
    private var tap: CFMachPort?
    private var thread: Thread?

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
        CGEvent.tapEnable(tap: tap, enable: false)

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "TinyHand event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        self.tap = tap
        self.thread = thread
        isInstalled = true
        return true
    }

    func setActive(_ value: Bool) {
        lock.withLock {
            _active = value
            _interactPress = false
        }
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
        lock.withLock { _active = true }
        _ = handle(type: type, event: event)
        lock.withLock { _active = was }
    }

    func resetWait() {
        maxWaitMs = 0
    }

    // Runs on the tap thread. Decide and return at once.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.timestamp > 0 {
            let wait = Double(DispatchTime.now().uptimeNanoseconds &- event.timestamp) / 1_000_000
            if wait < 600_000 {
                maxWaitMs = max(maxWaitMs, wait)
            }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout {
                Log.write("event tap was disabled by a timeout; re-enabled")
            }
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: active)
            }
            return Unmanaged.passUnretained(event)
        }

        guard active else {
            return Unmanaged.passUnretained(event)
        }

        let key = interactKey
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !key.isEmpty && (event.flags.contains(key) || CGEventSource.flagsState(.hidSystemState).contains(key)) {
                lock.withLock { _interactPress = true }
            }
        default:
            break
        }
        if lock.withLock({ _interactPress }) {
            event.flags.remove(key)
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                lock.withLock { _interactPress = false }
            }
            return Unmanaged.passUnretained(event)
        }

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
