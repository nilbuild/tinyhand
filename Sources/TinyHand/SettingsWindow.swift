import AppKit
import Carbon.HIToolbox

// The Settings window: shortcuts, pointer size, how long drawings stay, tap sound,
// launch at login. Changes apply immediately.
final class SettingsWindow: NSObject, NSWindowDelegate {
    // Asked to apply a recorded shortcut; returns false if it couldn't be registered.
    var applyToggleShortcut: ((Shortcut) -> Bool)?
    var applyClearShortcut: ((Shortcut) -> Bool)?
    // Global shortcuts are paused while recording, so the combo being typed isn't run.
    var onRecording: ((Bool) -> Void)?
    // Set when the app can update itself; adds the automatic-check option.
    var updater: Updater?

    private var window: NSWindow?
    private let message = NSTextField(labelWithString: "")
    private var fadePopup: NSPopUpButton?
    private var loginCheckbox: NSButton?
    private var handSoundCheckbox: NSButton?
    private var laserSoundCheckbox: NSButton?
    private var sizeSlider: NSSlider?
    private var shadowCheckbox: NSButton?
    private var updatesCheckbox: NSButton?

    private static let fadeChoices: [(String, Double)] = [
        ("Fade after 3 seconds", 3),
        ("Fade after 6 seconds", 6),
        ("Fade after 10 seconds", 10),
        ("Keep until cleared", 0),
    ]

    func show() {
        if window == nil {
            build()
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil) // nothing focused (and outlined) on open
    }

    // Offscreen picture of the window's content, for tests.
    func snapshot() -> NSBitmapImageRep? {
        if window == nil {
            build()
        }
        refresh()
        guard let view = window?.contentView else {
            return nil
        }
        // Offscreen rendering skips the window background, so draw on light grey.
        window?.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        window?.setContentSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func build() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 470, height: 340),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "TinyHand Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let toggle = ShortcutRecorder(shortcut: Preferences.toggleShortcut)
        toggle.onRecording = { [weak self] on in self?.onRecording?(on) }
        toggle.onChange = { [weak self] s in self?.apply(s, toggle, self?.applyToggleShortcut) ?? false }

        let clear = ShortcutRecorder(shortcut: Preferences.clearShortcut)
        clear.onRecording = { [weak self] on in self?.onRecording?(on) }
        clear.onChange = { [weak self] s in self?.apply(s, clear, self?.applyClearShortcut) ?? false }

        let slider = NSSlider(value: Double(Preferences.pointerSize),
                              minValue: Double(Preferences.pointerSizeRange.lowerBound),
                              maxValue: Double(Preferences.pointerSizeRange.upperBound),
                              target: self, action: #selector(sizeChanged(_:)))
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        sizeSlider = slider

        let shadow = NSButton(checkboxWithTitle: "Shadow under the pointer", target: self, action: #selector(shadowChanged(_:)))
        shadowCheckbox = shadow

        let fade = NSPopUpButton(frame: .zero, pullsDown: false)
        fade.addItems(withTitles: SettingsWindow.fadeChoices.map { $0.0 })
        fade.target = self
        fade.action = #selector(fadeChanged(_:))
        fadePopup = fade

        let handSound = NSButton(checkboxWithTitle: "Hands", target: self, action: #selector(soundChanged(_:)))
        let laserSound = NSButton(checkboxWithTitle: "Laser dot", target: self, action: #selector(soundChanged(_:)))
        handSoundCheckbox = handSound
        laserSoundCheckbox = laserSound
        let sounds = NSStackView(views: [handSound, laserSound])
        sounds.spacing = 16

        let login = NSButton(checkboxWithTitle: "Open TinyHand when you log in", target: self, action: #selector(loginChanged(_:)))
        loginCheckbox = login
        let updates = NSButton(checkboxWithTitle: "Check for updates automatically", target: self, action: #selector(updatesChanged(_:)))
        updatesCheckbox = updates

        let grid = NSGridView(views: [
            [label("Turn pointer on/off:"), toggle],
            [label("Clear drawing:"), clear],
            [label("Pointer size:"), slider],
            [NSGridCell.emptyContentView, shadow],
            [label("Drawings:"), fade],
            [label("Tap sound:"), sounds],
            [NSGridCell.emptyContentView, login],
            [NSGridCell.emptyContentView, updates],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        message.textColor = .systemRed
        message.font = NSFont.systemFont(ofSize: 12)

        let hint = NSTextField(wrappingLabelWithString:
            "Click the menu bar icon to turn the pointer on or off; right-click it for the menu. " +
            "While it's on: click to tap, hold and drag to draw, Esc to clear and exit.")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.preferredMaxLayoutWidth = 410
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 410).isActive = true

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let about = NSTextField(labelWithString: "TinyHand \(version)")
        about.textColor = .tertiaryLabelColor
        about.font = NSFont.systemFont(ofSize: 11)

        let stack = NSStackView(views: [grid, message, hint, about])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content
        window = w
    }

    private func refresh() {
        message.stringValue = ""
        message.isHidden = true
        sizeSlider?.doubleValue = Double(Preferences.pointerSize)
        shadowCheckbox?.state = Preferences.showShadow ? .on : .off
        let index = SettingsWindow.fadeChoices.firstIndex { $0.1 == Preferences.fadeSeconds } ?? 0
        fadePopup?.selectItem(at: index)
        handSoundCheckbox?.state = Preferences.handSound ? .on : .off
        laserSoundCheckbox?.state = Preferences.laserSound ? .on : .off
        loginCheckbox?.state = Preferences.launchAtLogin ? .on : .off
        updatesCheckbox?.isHidden = updater == nil
        updatesCheckbox?.state = updater?.automaticallyChecks == true ? .on : .off
    }

    private func apply(_ s: Shortcut, _ recorder: ShortcutRecorder, _ handler: ((Shortcut) -> Bool)?) -> Bool {
        guard handler?(s) == true else {
            message.stringValue = "\(s.display) is already used by another app. Pick a different shortcut."
            message.isHidden = false
            return false
        }
        message.stringValue = ""
        message.isHidden = true
        return true
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        Preferences.pointerSize = CGFloat(sender.doubleValue)
    }

    @objc private func shadowChanged(_ sender: NSButton) {
        Preferences.showShadow = sender.state == .on
    }

    @objc private func fadeChanged(_ sender: NSPopUpButton) {
        Preferences.fadeSeconds = SettingsWindow.fadeChoices[max(0, sender.indexOfSelectedItem)].1
    }

    @objc private func soundChanged(_ sender: NSButton) {
        if sender === handSoundCheckbox {
            Preferences.handSound = sender.state == .on
        }
        if sender === laserSoundCheckbox {
            Preferences.laserSound = sender.state == .on
        }
    }

    @objc private func updatesChanged(_ sender: NSButton) {
        updater?.automaticallyChecks = sender.state == .on
    }

    @objc private func loginChanged(_ sender: NSButton) {
        Preferences.launchAtLogin = sender.state == .on
        sender.state = Preferences.launchAtLogin ? .on : .off
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
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        title = shortcut.display
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    @objc private func startRecording() {
        guard monitor == nil else {
            return
        }
        title = "Type shortcut…"
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
        title = shortcut.display
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
