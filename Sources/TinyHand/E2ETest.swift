import AppKit

// End-to-end check with REAL system mouse events: activates the pointer, posts a
// press, a drag and a release through the actual event tap, and reports whether
// ink was drawn. A catcher window sits under the test point, so if the tap ever
// failed to swallow a click it would land on our own window, never on another app.
// Invoked via:  TinyHand --e2e-test
enum E2ETest {
    private final class CatcherView: NSView {
        var clicks = 0
        var scrolls = 0
        override func mouseDown(with event: NSEvent) {
            clicks += 1
        }
        override func scrollWheel(with event: NSEvent) {
            scrolls += 1
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.95, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }

    static func run() {
        setlinebuf(stdout)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        guard let screen = NSScreen.screens.first else {
            print("no screen")
            return
        }
        let size = CGSize(width: 520, height: 360)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let catcher = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let catcherView = CatcherView(frame: CGRect(origin: .zero, size: size))
        catcher.contentView = catcherView
        catcher.level = .statusBar
        catcher.orderFrontRegardless()

        let saved = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)
        // CG global coordinates have their origin at the top-left of the main screen.
        let start = CGPoint(x: screen.frame.midX - 150, y: screen.frame.height - screen.frame.midY)

        func pump(_ seconds: Double) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                if let e = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) {
                    app.sendEvent(e)
                }
            }
        }
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        func state(_ label: String, _ overlay: OverlayController) {
            let m = NSEvent.mouseLocation
            let down = CGEventSource.buttonState(.hidSystemState, button: .left)
            print(String(format: "%-14@ mouse=(%.0f,%.0f) hidDown=%@ %@", label as NSString, m.x, m.y,
                         down ? "yes" : "no", overlay.debugState))
        }

        let savedStyle = PointerStyle.saved
        PointerStyle.saved = .lavender
        let overlay = OverlayController()
        let installed = overlay.activate()
        print("tap installed:", installed)
        pump(0.3)

        post(.mouseMoved, start)
        pump(0.2)
        state("before press", overlay)

        post(.leftMouseDown, start)
        pump(0.1)
        state("pressed", overlay)

        for k in 1...40 {
            let p = CGPoint(x: start.x + CGFloat(k) * 6, y: start.y + 30 * sin(CGFloat(k) / 6))
            post(.leftMouseDragged, p)
            pump(0.016)
        }
        state("dragged", overlay)

        post(.leftMouseUp, CGPoint(x: start.x + 240, y: start.y))
        pump(0.2)
        state("released", overlay)

        // Scrolling right after drawing must reach the app underneath.
        for _ in 0..<5 {
            CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: -2, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            pump(0.03)
        }
        pump(0.1)
        print("scroll ticks right after drawing that reached the app (of 5):", catcherView.scrolls)

        // A plain click: should tap, leave no ink, and never reach the catcher.
        let before = overlay.inkStrokes
        post(.leftMouseDown, start)
        pump(0.05)
        post(.leftMouseUp, start)
        pump(0.2)
        state("plain click", overlay)
        print("plain click added strokes:", overlay.inkStrokes - before)

        // Click the toolbar's Dot button through the real tap: it must reach the button.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        if let c = overlay.toolbarButtonCenter(.laser) {
            let p = CGPoint(x: c.x, y: primaryH - c.y)
            post(.mouseMoved, p)
            pump(0.2)
            // Queue both: the button tracks the mouse inside its own event loop until
            // the release arrives, as it would under a real finger.
            post(.leftMouseDown, p)
            post(.leftMouseUp, p)
            pump(0.4)
        }
        print("style after clicking the toolbar's laser button:", overlay.style.rawValue)
        print("clicks that leaked to the catcher window:", catcherView.clicks)

        // Esc exits pointer mode.
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: down)?.post(tap: .cghidEventTap)
            pump(0.1)
        }
        pump(0.2)
        print("active after Esc:", overlay.isActive)

        overlay.deactivate()
        PointerStyle.saved = savedStyle
        catcher.orderOut(nil)
        CGWarpMouseCursorPosition(saved)
        pump(0.1)
    }
}
