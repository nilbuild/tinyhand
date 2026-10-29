import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Menu bar icon: click to turn the pointer on or off, right-click (or ⌃-click)
// for the menu. Owns the global shortcuts and the Settings window.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayController()
    private let settings = SettingsWindow()
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    private var soundItem: NSMenuItem?
    private var toggleHotKey: UInt32?
    private var clearHotKey: UInt32?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch \(Bundle.main.bundlePath) trusted=\(AXIsProcessTrusted())")
        CursorHider.enableBackgroundHiding()
        overlay.onActiveChanged = { [weak self] in
            self?.updateIcon()
        }
        overlay.onSoundChanged = { [weak self] in
            self?.refreshMenu()
        }
        // The icon must stay clickable while the pointer swallows clicks elsewhere.
        overlay.extraPassThrough = { [weak self] in
            guard let frame = self?.statusItem.button?.window?.frame else {
                return []
            }
            return [frame]
        }
        enableLaunchAtLoginOnFirstRun()
        ensureAccessibility()
        setupStatusItem()
        setupSettings()
        registerHotKeys()
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
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TinyHand", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.delegate = self
    }

    private func setupSettings() {
        settings.applyToggleShortcut = { [weak self] s in
            self?.apply(s, isToggle: true) ?? false
        }
        settings.applyClearShortcut = { [weak self] s in
            self?.apply(s, isToggle: false) ?? false
        }
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
    }

    // Tries the new shortcut; on failure keeps the old one working.
    private func apply(_ s: Shortcut, isToggle: Bool) -> Bool {
        unregisterHotKeys()
        let old = isToggle ? Preferences.toggleShortcut : Preferences.clearShortcut
        if isToggle {
            Preferences.toggleShortcut = s
        } else {
            Preferences.clearShortcut = s
        }
        let ok = registerHotKeys()
        if ok {
            return true
        }
        unregisterHotKeys()
        if isToggle {
            Preferences.toggleShortcut = old
        } else {
            Preferences.clearShortcut = old
        }
        registerHotKeys()
        return false
    }

    @discardableResult
    private func registerHotKeys() -> Bool {
        guard toggleHotKey == nil, clearHotKey == nil else {
            return true
        }
        let t = Preferences.toggleShortcut
        let c = Preferences.clearShortcut
        toggleHotKey = HotKeyCenter.shared.register(keyCode: t.keyCode, modifiers: t.modifiers) { [weak self] in
            self?.overlay.toggle()
        }
        clearHotKey = HotKeyCenter.shared.register(keyCode: c.keyCode, modifiers: c.modifiers) { [weak self] in
            self?.overlay.clearInk()
        }
        return toggleHotKey != nil && clearHotKey != nil
    }

    private func unregisterHotKeys() {
        if let id = toggleHotKey {
            HotKeyCenter.shared.unregister(id)
        }
        if let id = clearHotKey {
            HotKeyCenter.shared.unregister(id)
        }
        toggleHotKey = nil
        clearHotKey = nil
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

    // Settings needs a normal cursor and clicks, so leave pointer mode first.
    @objc private func openSettings() {
        overlay.exit()
        settings.show()
    }

    @objc private func quit() {
        overlay.deactivate()
        NSApp.terminate(nil)
    }

    // Opening at login is on by default. Only decided once, and only for a copy
    // installed in Applications, so a dev build elsewhere doesn't claim the login item.
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

    // Swallowing clicks needs an active event tap, which needs Accessibility.
    // Prompts once; the toolbar offers to open Settings if it's still missing.
    private func ensureAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // The hand-cursor icon: outline when off, filled when on. Template images, so
    // macOS tints them for light and dark menu bars.
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
}
