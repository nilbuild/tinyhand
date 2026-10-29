import AppKit
import Carbon.HIToolbox

// A full-screen, transparent, click-through overlay on whichever screen holds the
// cursor. The arm lives at the bottom and aims at the pointer. While active, clicks
// are SWALLOWED by InputTap — tapping is cosmetic only (sound + poke), it never
// focuses, activates, or presses anything underneath. Holding and dragging draws ink.
final class OverlayController {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let window: OverlayWindow
    private let armView: ArmView
    private let inputTap = InputTap()
    private let tapSound = TapSound()
    private var timer: Timer?
    private var currentFrame: CGRect?
    private var downPoint: CGPoint?
    private var buttonSeenDown = false
    private var dragEvents = 0

    private let toolbar = Toolbar()
    private var revealUntil = Date.distantPast
    // True while the real cursor is shown instead of the pointer: over the toolbar,
    // the menu bar, or any open menu, so those can be used normally.
    private var normalCursor = false
    private var ownMenuOpen = false
    private var menuRects: [CGRect] = []   // open menus on screen, CG global coords
    private var lastMenuScan = Date.distantPast
    // A menu bar click opens a menu, but its window takes a moment to show up in
    // the window list; keep the real cursor meanwhile.
    private var menuOpeningUntil = Date.distantPast
    private var escHotKey: UInt32?
    private var lastPermissionCheck = Date.distantPast

    private(set) var isActive = false
    var onActiveChanged: (() -> Void)?

    init() {
        let frame = (NSScreen.main ?? NSScreen.screens.first).map { $0.frame }
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Above the toolbar, so the hand is drawn over it while pointing at its buttons.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        armView = ArmView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = armView

        inputTap.onMouseDown = { [weak self] in
            guard let self = self else {
                return
            }
            self.armView.press()
            self.armView.held = true
            self.tapSound.play()
            self.downPoint = self.localMouse()
            self.dragEvents = 0
            Log.write("press at \(self.downPoint.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?")")
        }
        inputTap.onLeftDragged = { [weak self] in
            self?.dragEvents += 1
            self?.drag()
        }
        inputTap.onMouseUp = { [weak self] in
            self?.release()
        }
        inputTap.onPassThroughPress = { [weak self] location in
            guard let screen = self?.currentScreen() else {
                return
            }
            let bar = OverlayController.cgRect(OverlayController.menuBarRect(screen))
            if bar.contains(location) {
                self?.menuOpeningUntil = Date().addingTimeInterval(1)
            }
        }

        toolbar.onPick = { [weak self] style in
            self?.pick(style)
        }
        toolbar.onToggleSound = { [weak self] in
            self?.soundOn.toggle()
        }
        toolbar.onExit = { [weak self] in
            self?.exit()
        }
        toolbar.onFixPermission = {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        toolbar.select(armView.style)
        tapSound.enabled = soundOn
        toolbar.setSoundOn(soundOn)
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.syncSound()
        }
    }

    var soundOn: Bool {
        get { armView.style == .laser ? Preferences.laserSound : Preferences.handSound }
        set {
            if armView.style == .laser {
                Preferences.laserSound = newValue
            } else {
                Preferences.handSound = newValue
            }
        }
    }
    var onSoundChanged: (() -> Void)?

    func pick(_ style: PointerStyle) {
        armView.setStyle(style)
        PointerStyle.saved = armView.style
        toolbar.select(armView.style)
        syncSound()
    }

    // Sound is remembered separately for the hands (default on) and the laser
    // (default off).
    private func syncSound() {
        tapSound.enabled = soundOn
        toolbar.setSoundOn(soundOn)
        onSoundChanged?()
    }

    // Screen areas (AppKit global coords) whose clicks must reach the real thing,
    // e.g. the menu bar icon. Asked for every frame.
    var extraPassThrough: (() -> [CGRect])?

    // Lets clicks through while a menu is open, so its items can be chosen.
    func suspendInput(_ suspended: Bool) {
        guard isActive, inputTap.isInstalled else {
            return
        }
        ownMenuOpen = suspended
        inputTap.setActive(!suspended)
        if let screen = currentScreen() {
            updateZones(mouse: NSEvent.mouseLocation, screen: screen)
        }
    }

    // Esc and the toolbar's ✕: wipe the drawing and leave pointer mode. The app
    // stays in the menu bar, so ⌃⌥H brings it straight back.
    func exit() {
        clearInk()
        deactivate()
    }

    private func release() {
        if let start = downPoint {
            let moved = localMouse().map { Int(hypot($0.x - start.x, $0.y - start.y)) } ?? -1
            Log.write("release, drag events=\(dragEvents) moved=\(moved)pt stroke drawn=\(armView.ink.isDrawing)")
        }
        buttonSeenDown = false
        armView.held = false
        downPoint = nil
        armView.ink.end()
    }


    var style: PointerStyle { armView.style }

    func toolbarButtonCenter(_ style: PointerStyle) -> CGPoint? {
        toolbar.center(of: style)
    }

    var inkStrokes: Int { armView.ink.layer.sublayers?.count ?? 0 }

    var debugState: String {
        "held=\(armView.held) downPoint=\(downPoint != nil) drawing=\(armView.ink.isDrawing) strokes=\(inkStrokes)"
    }

    func clearInk() {
        armView.ink.clear()
    }

    // A press only becomes a stroke once it moves a few points, so a plain click
    // stays a tap and leaves no dot.
    private func drag() {
        guard let start = downPoint, let p = localMouse() else {
            return
        }
        let ink = armView.ink
        if !ink.isDrawing {
            if hypot(p.x - start.x, p.y - start.y) < 4 {
                return
            }
            ink.begin(at: start, width: armView.inkWidth)
        }
        ink.extend(to: p)
    }

    private func localMouse() -> CGPoint? {
        guard let frame = currentFrame else {
            return nil
        }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.origin.x, y: mouse.y - frame.origin.y)
    }

    func toggle() {
        if isActive {
            deactivate()
            return
        }
        activate()
    }

    // Returns false if clicks can't be swallowed (Accessibility not granted yet);
    // the arm still shows and aims, it just won't intercept taps.
    @discardableResult
    func activate() -> Bool {
        guard !isActive else {
            return inputTap.isInstalled
        }
        isActive = true
        currentFrame = nil

        CursorHider.hide()
        tick()
        window.orderFrontRegardless()

        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let installed = inputTap.install()
        inputTap.setActive(installed)
        Log.write("activate trusted=\(AXIsProcessTrusted()) tapInstalled=\(installed)")

        if let screen = currentScreen() {
            toolbar.place(on: screen)
        }
        toolbar.setNeedsPermission(!installed)
        toolbar.show()
        revealUntil = Date().addingTimeInterval(3)
        setEscEnabled(true)
        onActiveChanged?()
        return installed
    }

    func deactivate() {
        guard isActive else {
            return
        }
        isActive = false

        timer?.invalidate()
        timer = nil
        inputTap.setActive(false)
        armView.held = false
        downPoint = nil
        armView.ink.clear()
        window.orderOut(nil)
        toolbar.hide()
        normalCursor = false
        armView.pointerHidden = false
        inputTap.passThroughRects = []
        setEscEnabled(false)
        ownMenuOpen = false
        CursorHider.show()
        onActiveChanged?()
    }

    // The toolbar shows for a few seconds after switching on, then only while the
    // cursor is near it (so it stays out of recordings), and always while there's a
    // permission problem to fix.
    //
    // Over the toolbar, the menu bar, or any open menu (ours or another app's), the
    // pointer steps aside: the real cursor comes back and clicks reach what's there.
    private func updateZones(mouse: CGPoint, screen: NSScreen) {
        let f = toolbar.frame
        let near = f.insetBy(dx: -80, dy: 0).union(f.offsetBy(dx: 0, dy: 90)).insetBy(dx: 0, dy: -10).contains(mouse)
        let needsPermission = !inputTap.isInstalled
        let drawing = downPoint != nil
        toolbar.setRevealed(!drawing && (near || Date() < revealUntil || needsPermission))

        if Date().timeIntervalSince(lastMenuScan) > 0.05 {
            lastMenuScan = Date()
            menuRects = OverlayController.openMenus()
        }
        let menuBar = OverlayController.menuBarRect(screen)
        let cgMouse = OverlayController.cgPoint(mouse)
        let overMenu = menuBar.contains(mouse) || menuRects.contains { $0.contains(cgMouse) }
            || Date() < menuOpeningUntil
        // The toolbar keeps the hand (its clicks still pass through to the buttons);
        // only menus and the menu bar bring the real cursor back.
        let normal = !drawing && (overMenu || ownMenuOpen)
        // Esc belongs to an open menu (to close it), not to us.
        setEscEnabled(menuRects.isEmpty && !ownMenuOpen)

        if normal != normalCursor {
            let at = "at \(Int(mouse.x)),\(Int(mouse.y))"
            Log.write(normal ? "real cursor (\(menuBar.contains(mouse) ? "menu bar" : "menu")) \(at)" : "pointer back \(at)")
            normalCursor = normal
            armView.pointerHidden = normal
            if normal {
                CursorHider.show()
            } else {
                CursorHider.hide()
            }
        }

        var rects = (extraPassThrough?() ?? []).map(OverlayController.cgRect)
        rects.append(OverlayController.cgRect(menuBar))
        rects.append(contentsOf: menuRects)
        if toolbar.revealed {
            rects.append(OverlayController.cgRect(f))
        }
        inputTap.passThroughRects = rects
    }

    private func setEscEnabled(_ enabled: Bool) {
        if enabled && isActive && escHotKey == nil {
            escHotKey = HotKeyCenter.shared.register(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
                self?.exit()
            }
        }
        if !enabled, let id = escHotKey {
            HotKeyCenter.shared.unregister(id)
            escHotKey = nil
        }
    }

    // The menu bar strip at the top of a screen (AppKit global coords).
    private static func menuBarRect(_ screen: NSScreen) -> CGRect {
        let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    // Every open menu on screen (menu bar menus, context menus), from the window
    // list. Only bounds and layer are read, which needs no extra permission.
    private static func openMenus() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == menuLevel,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return nil
            }
            return rect
        }
    }

    private static func cgPoint(_ p: CGPoint) -> CGPoint {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryH - p.y)
    }

    // Accessibility can be granted while we're running; pick it up within a second.
    private func checkPermission() {
        guard !inputTap.isInstalled, Date().timeIntervalSince(lastPermissionCheck) > 1 else {
            return
        }
        lastPermissionCheck = Date()
        guard AXIsProcessTrusted(), inputTap.install() else {
            return
        }
        Log.write("permission granted while running; tap installed")
        inputTap.setActive(true)
        toolbar.setNeedsPermission(false)
    }

    // AppKit global coords (bottom-left origin) to CG global coords (top-left origin).
    private static func cgRect(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    // Offscreen check of the click and drag paths: real handlers and frame ticks,
    // but no event tap, no cursor hiding, and the window never shown.
    func runClickTest() {
        func time(_ label: String, _ body: () -> Void) {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            print(String(format: "%@: %.1f ms", label, (CFAbsoluteTimeGetCurrent() - t) * 1000))
        }
        func spin(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        tick()
        time("tick") { tick() }
        time("mouseDown (tap callback)") { inputTap.simulate(.leftMouseDown) }
        time("mouseDown (deferred work)") { spin(0.01) }
        time("10 ticks while held") { for _ in 0..<10 { tick() } }
        time("mouseUp (tap callback)") { inputTap.simulate(.leftMouseUp) }
        spin(0.01)
        spin(0.3)
        time("second click (tap callbacks)") {
            inputTap.simulate(.leftMouseDown)
            inputTap.simulate(.leftMouseUp)
        }
        spin(0.05)
        time("drag x50 (tap callbacks)") {
            inputTap.simulate(.leftMouseDown)
            for _ in 0..<50 { inputTap.simulate(.leftMouseDragged) }
            inputTap.simulate(.leftMouseUp)
        }
        spin(0.05)
        time("ticks after up") { for _ in 0..<20 { tick() } }
        print("held after up:", armView.held, "drawing:", armView.ink.isDrawing)
    }

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        guard let screen = currentScreen() else {
            return
        }

        if currentFrame != screen.frame {
            currentFrame = screen.frame
            armView.ink.clear() // ink belongs to the display it was drawn on
            window.setFrame(screen.frame, display: false)
            armView.frame = NSRect(origin: .zero, size: screen.frame.size)
            toolbar.place(on: screen)
        }

        updateZones(mouse: mouse, screen: screen)
        if !normalCursor {
            CursorHider.reassert()
        }
        checkPermission()

        let local = CGPoint(x: mouse.x - screen.frame.origin.x, y: mouse.y - screen.frame.origin.y)
        armView.aim(cursor: local)
        guard downPoint != nil else {
            return
        }
        // Safety net: if the button-up event never reached us, the real button
        // state still ends the press, so the pointer can't get stuck drawing. Only
        // trusted once it has reported this press as down.
        let down = CGEventSource.buttonState(.hidSystemState, button: .left)
        if down {
            buttonSeenDown = true
        }
        if buttonSeenDown && !down {
            release()
            return
        }
        drag()
    }
}
