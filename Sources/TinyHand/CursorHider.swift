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
    static func reassert() {
        guard hidden else {
            return
        }
        let seed = cursorSeed?() ?? 0
        let interval = Date().timeIntervalSince(hiddenAt) < 1 ? 0.05 : 1.0
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
