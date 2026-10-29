import AppKit
import Carbon.HIToolbox
import ServiceManagement

// A global keyboard shortcut, stored with the label shown to the user.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier flags (controlKey, optionKey, …)
    var display: String

    static let toggleDefault = Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥H")
    static let clearDefault = Shortcut(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥X")
}

// Settings that persist between launches. Posts `changed` whenever one is set.
enum Preferences {
    static let changed = Notification.Name("TinyHandPreferencesChanged")
    private static let defaults = UserDefaults.standard

    static var toggleShortcut: Shortcut {
        get { loadShortcut("shortcut.toggle") ?? .toggleDefault }
        set { saveShortcut(newValue, "shortcut.toggle") }
    }

    static var clearShortcut: Shortcut {
        get { loadShortcut("shortcut.clear") ?? .clearDefault }
        set { saveShortcut(newValue, "shortcut.clear") }
    }

    static let pointerSizeRange: ClosedRange<CGFloat> = 0.08...0.20

    // On-screen hand height as a fraction of screen height.
    static var pointerSize: CGFloat {
        get { (defaults.object(forKey: "pointerSize") as? Double).map { CGFloat($0) } ?? 0.13 }
        set { set(Double(newValue), "pointerSize") }
    }

    static var showShadow: Bool {
        get { defaults.object(forKey: "showShadow") as? Bool ?? true }
        set { set(newValue, "showShadow") }
    }

    // Seconds a stroke stays before fading; 0 keeps strokes until cleared.
    static var fadeSeconds: Double {
        get { defaults.object(forKey: "fadeSeconds") as? Double ?? 3 }
        set { set(newValue, "fadeSeconds") }
    }

    static var handSound: Bool {
        get { defaults.object(forKey: "sound.hands") as? Bool ?? true }
        set { set(newValue, "sound.hands") }
    }

    // The laser is for quiet pointing, so it starts silent.
    static var laserSound: Bool {
        get { defaults.object(forKey: "sound.laser") as? Bool ?? false }
        set { set(newValue, "sound.laser") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.write("launch at login change failed: \(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func loadShortcut(_ key: String) -> Shortcut? {
        guard let d = defaults.dictionary(forKey: key),
              let code = d["keyCode"] as? Int, let mods = d["modifiers"] as? Int, let label = d["display"] as? String else {
            return nil
        }
        return Shortcut(keyCode: UInt32(code), modifiers: UInt32(mods), display: label)
    }

    private static func saveShortcut(_ s: Shortcut, _ key: String) {
        set(["keyCode": Int(s.keyCode), "modifiers": Int(s.modifiers), "display": s.display], key)
    }
}
