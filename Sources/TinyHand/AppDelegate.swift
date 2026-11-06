import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayController()
    private let settings = SettingsWindow()
    private let updater = Updater()
    private let welcome = WelcomeWindow()
    private var permissionItem: NSMenuItem?
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    private var soundItem: NSMenuItem?
    private var snapItem: NSMenuItem?
    private var recordItem: NSMenuItem?
    private var toggleHotKey: UInt32?
    private var clearHotKey: UInt32?
    private var captureHotKey: UInt32?

    private enum ShortcutKind {
        case toggle, clear, capture
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editingMenu()
        HandAsset.preloadThumbnails(PointerStyle.allCases.compactMap(\.assetName))
        Log.write("launch \(Bundle.main.bundlePath) trusted=\(AXIsProcessTrusted())")
        CursorHider.enableBackgroundHiding()
        overlay.onActiveChanged = { [weak self] in
            self?.updateIcon()
        }
        overlay.onSoundChanged = { [weak self] in
            self?.refreshMenu()
        }
        overlay.onRecordingChanged = { [weak self] in
            self?.refreshMenu()
        }
        overlay.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        overlay.extraPassThrough = { [weak self] in
            guard let frame = self?.statusItem.button?.window?.frame else {
                return []
            }
            return [frame]
        }
        enableLaunchAtLoginOnFirstRun()
        updater.start()
        setupStatusItem()
        setupSettings()
        registerHotKeys()

        overlay.onNeedsPermission = { [weak self] in
            self?.welcome.show()
        }
        welcome.onTryIt = { [weak self] in
            self?.overlay.activate()
        }
        if !UserDefaults.standard.bool(forKey: WelcomeWindow.shownKey) || !AXIsProcessTrusted() {
            welcome.show()
        }
    }

    /// Opening TinyHand again (Finder, Spotlight, Launchpad) shows Settings, so it can be
    /// reached even when the menu bar icon is hidden behind the notch or a crowded menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.deactivate()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let permission = NSMenuItem(title: "Allow Accessibility…", action: #selector(showWelcome), keyEquivalent: "")
        permissionItem = permission
        menu.addItem(permission)
        let toggle = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        let clear = NSMenuItem(title: "", action: #selector(clearInk), keyEquivalent: "")
        let sound = NSMenuItem(title: "Tap Sound", action: #selector(toggleSound), keyEquivalent: "")
        toggleItem = toggle
        clearItem = clear
        soundItem = sound
        menu.addItem(toggle)
        menu.addItem(clear)
        menu.addItem(sound)
        menu.addItem(.separator())
        let snap = NSMenuItem(title: "", action: #selector(takeSnapshot), keyEquivalent: "")
        let record = NSMenuItem(title: "", action: #selector(toggleRecording), keyEquivalent: "")
        snapItem = snap
        recordItem = record
        menu.addItem(snap)
        menu.addItem(record)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        if Updater.isAvailable {
            menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TinyHand", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.delegate = self
    }

    private func setupSettings() {
        settings.applyToggleShortcut = { [weak self] s in
            self?.apply(s, kind: .toggle) ?? false
        }
        settings.applyClearShortcut = { [weak self] s in
            self?.apply(s, kind: .clear) ?? false
        }
        settings.applyCaptureShortcut = { [weak self] s in
            self?.apply(s, kind: .capture) ?? false
        }
        settings.updater = Updater.isAvailable ? updater : nil
        settings.onRecording = { [weak self] recording in
            if recording {
                self?.unregisterHotKeys()
            } else {
                self?.registerHotKeys()
            }
        }
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu else {
            overlay.toggle()
            return
        }
        refreshMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        overlay.suspendInput(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        overlay.suspendInput(false)
    }

    private func refreshMenu() {
        let on = overlay.isActive
        toggleItem?.title = "\(on ? "Turn Pointer Off" : "Turn Pointer On")    \(Preferences.toggleShortcut.display)"
        clearItem?.title = "Clear Drawing    \(Preferences.clearShortcut.display)"
        soundItem?.state = overlay.soundOn ? .on : .off
        snapItem?.title = "Take Snapshot    \(Preferences.captureShortcut.display)"
        recordItem?.title = overlay.isRecording ? "Stop Recording" : "Record Video    \(Preferences.captureShortcut.display) twice"
        permissionItem?.isHidden = AXIsProcessTrusted()
    }

    private func shortcut(_ kind: ShortcutKind) -> Shortcut {
        switch kind {
        case .toggle: return Preferences.toggleShortcut
        case .clear: return Preferences.clearShortcut
        case .capture: return Preferences.captureShortcut
        }
    }

    private func setShortcut(_ s: Shortcut, _ kind: ShortcutKind) {
        switch kind {
        case .toggle: Preferences.toggleShortcut = s
        case .clear: Preferences.clearShortcut = s
        case .capture: Preferences.captureShortcut = s
        }
    }

    private func hotKey(_ kind: ShortcutKind) -> UInt32? {
        switch kind {
        case .toggle: return toggleHotKey
        case .clear: return clearHotKey
        case .capture: return captureHotKey
        }
    }

    private func apply(_ s: Shortcut, kind: ShortcutKind) -> Bool {
        unregisterHotKeys()
        let old = shortcut(kind)
        setShortcut(s, kind)
        registerHotKeys()
        if hotKey(kind) != nil {
            return true
        }
        unregisterHotKeys()
        setShortcut(old, kind)
        registerHotKeys()
        return false
    }

    @discardableResult
    private func registerHotKeys() -> Bool {
        guard toggleHotKey == nil, clearHotKey == nil, captureHotKey == nil else {
            return true
        }
        let t = Preferences.toggleShortcut
        let c = Preferences.clearShortcut
        let k = Preferences.captureShortcut
        toggleHotKey = HotKeyCenter.shared.register(keyCode: t.keyCode, modifiers: t.modifiers) { [weak self] in
            self?.overlay.toggle()
        }
        clearHotKey = HotKeyCenter.shared.register(keyCode: c.keyCode, modifiers: c.modifiers) { [weak self] in
            self?.overlay.clearInk()
        }
        captureHotKey = HotKeyCenter.shared.register(keyCode: k.keyCode, modifiers: k.modifiers) { [weak self] in
            self?.overlay.captureGesture(hidePointer: false)
        }
        return toggleHotKey != nil && clearHotKey != nil && captureHotKey != nil
    }

    private func unregisterHotKeys() {
        for id in [toggleHotKey, clearHotKey, captureHotKey].compactMap({ $0 }) {
            HotKeyCenter.shared.unregister(id)
        }
        toggleHotKey = nil
        clearHotKey = nil
        captureHotKey = nil
    }

    @objc private func takeSnapshot() {
        // Give the menu a moment to close so it isn't in the picture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.overlay.takeSnapshot(hidePointer: false)
        }
    }

    @objc private func toggleRecording() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.overlay.toggleRecording()
        }
    }

    @objc private func toggle() {
        overlay.toggle()
    }

    @objc private func clearInk() {
        overlay.clearInk()
    }

    @objc private func toggleSound() {
        overlay.soundOn.toggle()
    }

    @objc private func openSettings() {
        overlay.exit()
        settings.show()
    }

    @objc private func showWelcome() {
        overlay.exit()
        welcome.show()
    }

    @objc private func checkForUpdates() {
        overlay.exit()
        updater.checkForUpdates()
    }

    @objc private func quit() {
        // Let a recording finish writing its file before quitting.
        overlay.stopRecording {
            self.overlay.deactivate()
            NSApp.terminate(nil)
        }
    }

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "loginItemSetUp"
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        Preferences.launchAtLogin = true
        Log.write("first run: open at login = \(Preferences.launchAtLogin)")
    }

    private func updateIcon() {
        let on = overlay.isActive
        let image = Bundle.main.image(forResource: on ? "menubar_on" : "menubar_off")
            ?? NSImage(systemSymbolName: on ? "hand.point.up.left.fill" : "hand.point.up.left",
                       accessibilityDescription: "TinyHand")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = overlay.isActive
            ? "TinyHand is on — click to turn off, right-click for the menu"
            : "TinyHand — click to turn on, right-click for the menu"
    }

    private func editingMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit TinyHand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
