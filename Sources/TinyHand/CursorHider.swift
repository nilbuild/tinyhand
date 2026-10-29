import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Hides the real system cursor — even while another app (your browser) is frontmost.
//
// CGDisplayHideCursor alone only works while OUR app is frontmost. The private
// CGS "SetsCursorInBackground" connection property lifts that restriction, which
// is the whole trick that makes this usable for recording demos without stealing
// focus. Resolved via dlsym so there is no link-time dependency on private symbols.
enum CursorHider {
    private static var hidden = false

    static func enableBackgroundHiding() {
        typealias MainConn = @convention(c) () -> Int32
        typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

        guard let handle = dlopen(nil, RTLD_NOW) else {
            return
        }
        guard let mainConnSym = dlsym(handle, "CGSMainConnectionID"),
              let setPropSym = dlsym(handle, "CGSSetConnectionProperty") else {
            return
        }

        let mainConn = unsafeBitCast(mainConnSym, to: MainConn.self)
        let setProp = unsafeBitCast(setPropSym, to: SetProp.self)
        let cid = mainConn()
        _ = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    // Hide/show use a balanced counter, so guard against double calls.
    static func hide() {
        guard !hidden else {
            return
        }
        hidden = true
        hideCount = 1
        hiddenAt = Date()
        CGDisplayHideCursor(CGMainDisplayID())
    }

    static func show() {
        guard hidden else {
            return
        }
        hidden = false
        for _ in 0..<hideCount {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        hideCount = 0
    }

    private static var hideCount = 0
    private static var lastSeed: Int32 = 0
    private static var lastReassert = Date.distantPast
    private static var hiddenAt = Date.distantPast

    private static let cursorSeed: (() -> Int32)? = {
        typealias Seed = @convention(c) () -> Int32
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGSCurrentCursorSeed") else {
            return nil
        }
        return unsafeBitCast(sym, to: Seed.self)
    }()

    // The cursor can come back on its own: some apps (terminals with their I-beam,
    // for one) set it themselves, and a single hide often doesn't take straight away
    // (measured: still visible 0.4 s later). macOS can't tell us whether it's
    // visible, so hide again whenever any app changes the cursor (the cursor seed
    // moves), every 50 ms for the first second after hiding, and once a second after. Extra hides are balanced
    // in show(), and extra shows can't push the count below zero.
    // `fighting` is for places that keep forcing the cursor back, like the Dock
    // while its hover labels and magnification are active: re-hide every ~30 ms.
    static func reassert(fighting: Bool = false) {
        guard hidden else {
            return
        }
        let seed = cursorSeed?() ?? 0
        let interval = fighting ? 0.03 : Date().timeIntervalSince(hiddenAt) < 1 ? 0.05 : 1.0
        guard seed != lastSeed || Date().timeIntervalSince(lastReassert) > interval else {
            return
        }
        lastSeed = seed
        lastReassert = Date()
        enableBackgroundHiding()
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }
}

// Where the Dock's icons are, from the Dock's accessibility tree (works with an
// auto-hiding Dock too). CG global coords; refreshed at most once a second.
enum DockArea {
    private static var frame: CGRect = .null
    private static var lastRead = Date.distantPast

    static func contains(_ cgPoint: CGPoint) -> Bool {
        if Date().timeIntervalSince(lastRead) > 1 {
            lastRead = Date()
            frame = read()
        }
        return frame.insetBy(dx: -8, dy: -8).contains(cgPoint)
    }

    private static func read() -> CGRect {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return .null
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = (children as? [AXUIElement])?.first else {
            return .null
        }
        var pos: CFTypeRef?
        var size: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &pos)
        AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &size)
        var origin = CGPoint.zero
        var extent = CGSize.zero
        if let pos = pos, CFGetTypeID(pos) == AXValueGetTypeID() {
            AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
        }
        if let size = size, CFGetTypeID(size) == AXValueGetTypeID() {
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        }
        return extent == .zero ? .null : CGRect(origin: origin, size: extent)
    }
}
