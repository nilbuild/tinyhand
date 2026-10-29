import AppKit
import Carbon.HIToolbox
import SwiftUI

// The Settings window: a sidebar of sections (General, Pointers, Appearance, Drawing,
// Sound, About) drawn by SettingsView. Changes apply immediately.
final class SettingsWindow: NSObject, NSWindowDelegate {
    // Asked to apply a recorded shortcut; returns false if it couldn't be registered.
    var applyToggleShortcut: ((Shortcut) -> Bool)? {
        didSet { model.applyToggleShortcut = applyToggleShortcut }
    }
    var applyClearShortcut: ((Shortcut) -> Bool)? {
        didSet { model.applyClearShortcut = applyClearShortcut }
    }
    // Global shortcuts are paused while recording, so the combo being typed isn't run.
    var onRecording: ((Bool) -> Void)? {
        didSet { model.onRecording = onRecording }
    }
    // Set when the app can update itself; adds the update options.
    var updater: Updater? {
        didSet { model.updater = updater }
    }

    private var window: NSWindow?
    private let model = SettingsModel()

    func show(_ section: SettingsSection? = nil) {
        if window == nil {
            build()
        }
        if let section = section {
            model.section = section
        }
        model.shortcutError = nil
        model.pinMessage = nil
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
    }

    // Picture of one section, for tests: shows the window briefly and captures it, since
    // SwiftUI scroll views don't draw offscreen.
    func snapshot(_ section: SettingsSection = .general, dark: Bool = false) -> CGImage? {
        if window == nil {
            build()
        }
        guard let w = window else {
            return nil
        }
        model.section = section
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.center()
        w.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        w.orderOut(nil)
        return image
    }

    private func build() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "TinyHand Settings"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.focusRingType = .none
        w.contentView = host
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        onRecording?(false)
    }
}

// A button that shows a shortcut and records a new one when clicked.
final class ShortcutRecorder: NSButton {
    var onChange: ((Shortcut) -> Bool)?
    var onRecording: ((Bool) -> Void)?

    private var shortcut: Shortcut
    private var monitor: Any?

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setLabel(shortcut.display)
    }

    // Shows a shortcut set elsewhere (e.g. by a reset), unless one is being recorded.
    func show(_ s: Shortcut) {
        guard monitor == nil, s != shortcut else {
            return
        }
        shortcut = s
        setLabel(s.display)
    }

    private func setLabel(_ text: String) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    @objc private func startRecording() {
        guard monitor == nil else {
            return
        }
        setLabel("Type shortcut…")
        onRecording?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
        monitor = nil
        setLabel(shortcut.display)
        onRecording?(false)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        // Needs ⌃, ⌥ or ⌘, so a shortcut can't swallow a plain key everywhere.
        guard !flags.intersection([.control, .option, .command]).isEmpty else {
            NSSound.beep()
            return
        }
        let s = Shortcut(keyCode: UInt32(event.keyCode), modifiers: ShortcutRecorder.carbon(flags),
                         display: ShortcutRecorder.symbols(flags) + ShortcutRecorder.keyName(event))
        if onChange?(s) == true {
            shortcut = s
        }
        stopRecording()
    }

    private static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = special[Int(event.keyCode)] {
            return name
        }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
