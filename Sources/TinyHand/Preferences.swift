import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let toggleDefault = Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥H")
    static let clearDefault = Shortcut(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥X")
}

enum InteractKey: String, CaseIterable {
    case option, command, control, off

    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .off: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .off: return ""
        }
    }

    var cgFlags: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .control: return .maskControl
        case .off: return []
        }
    }
}

enum InkChoice: String, CaseIterable {
    case match, red, orange, yellow, green, blue, purple, white, black

    var title: String {
        switch self {
        case .match: return "Match the pointer"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .white: return "White"
        case .black: return "Black"
        }
    }

    /// The colour with the Ink tone setting applied.
    var color: CGColor? {
        baseColor.map(Preferences.inkTone.apply)
    }

    private var baseColor: CGColor? {
        switch self {
        case .match: return nil
        case .red: return Ink.red
        case .orange: return Ink.hex(0xFF8A00)
        case .yellow: return Ink.hex(0xFFCC00)
        case .green: return Ink.hex(0x30C25A)
        case .blue: return Ink.hex(0x0A84FF)
        case .purple: return Ink.hex(0x8754F2)
        case .white: return Ink.hex(0xFFFFFF)
        case .black: return Ink.hex(0x1D1D21)
        }
    }

    func resolved(for style: PointerStyle) -> CGColor {
        color ?? Preferences.inkTone.apply(style.inkColor)
    }
}

/// Shifts every ink colour together: softer, greyer or darker.
enum InkTone: String, CaseIterable {
    case vivid, pastel, muted, deep

    var title: String {
        switch self {
        case .vivid: return "Vivid"
        case .pastel: return "Pastel"
        case .muted: return "Muted"
        case .deep: return "Deep"
        }
    }

    func apply(_ color: CGColor) -> CGColor {
        guard self != .vivid, let ns = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else {
            return color
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.08 {
            return color   // leave white and black alone
        }
        switch self {
        case .vivid: break
        case .pastel: s *= 0.45; b = min(1, b * 0.25 + 0.78)
        case .muted: s *= 0.55; b *= 0.82
        case .deep: s = min(1, s * 1.05); b *= 0.62
        }
        return NSColor(hue: h, saturation: s, brightness: b, alpha: a).cgColor
    }
}

/// Left-click ripple look.
enum RippleStyle: String, CaseIterable {
    case glass, glow, line

    var title: String {
        switch self {
        case .glass: return "Glass"
        case .glow: return "Glow"
        case .line: return "Line"
        }
    }
}

enum RippleColor: String, CaseIterable {
    case blue, teal, purple, gold, white, ink

    var title: String {
        switch self {
        case .blue: return "Blue"
        case .teal: return "Teal"
        case .purple: return "Purple"
        case .gold: return "Gold"
        case .white: return "White"
        case .ink: return "Ink"
        }
    }

    /// nil means "use the current ink colour".
    var color: CGColor? {
        switch self {
        case .blue: return CGColor(srgbRed: 0.45, green: 0.68, blue: 1.00, alpha: 1)
        case .teal: return CGColor(srgbRed: 0.22, green: 0.80, blue: 0.78, alpha: 1)
        case .purple: return CGColor(srgbRed: 0.62, green: 0.46, blue: 1.00, alpha: 1)
        case .gold: return CGColor(srgbRed: 1.00, green: 0.78, blue: 0.32, alpha: 1)
        case .white: return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .ink: return nil
        }
    }
}

enum RippleSize: String, CaseIterable {
    case small, medium, large

    var title: String { rawValue.capitalized }

    var diameter: CGFloat {
        switch self {
        case .small: return 100
        case .medium: return 140
        case .large: return 200
        }
    }
}

enum RippleSpeed: String, CaseIterable {
    case quick, normal, slow

    var title: String { rawValue.capitalized }

    var duration: TimeInterval {
        switch self {
        case .quick: return 0.4
        case .normal: return 0.55
        case .slow: return 0.85
        }
    }
}

enum PenSize: String, CaseIterable {
    case thin, medium, thick

    var title: String {
        switch self {
        case .thin: return "Thin"
        case .medium: return "Medium"
        case .thick: return "Thick"
        }
    }

    var scale: CGFloat {
        switch self {
        case .thin: return 0.55
        case .medium: return 1
        case .thick: return 1.9
        }
    }
}

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

    static var pointerSize: CGFloat {
        get { (defaults.object(forKey: "pointerSize") as? Double).map { CGFloat($0) } ?? 0.13 }
        set { set(Double(newValue), "pointerSize") }
    }

    static var showShadow: Bool {
        get { defaults.object(forKey: "showShadow") as? Bool ?? true }
        set { set(newValue, "showShadow") }
    }

    static var fadeSeconds: Double {
        get { defaults.object(forKey: "fadeSeconds") as? Double ?? 3 }
        set { set(newValue, "fadeSeconds") }
    }

    static var inkTone: InkTone {
        get { defaults.string(forKey: "inkTone").flatMap(InkTone.init(rawValue:)) ?? .vivid }
        set { set(newValue.rawValue, "inkTone") }
    }

    static var penSize: PenSize {
        get { defaults.string(forKey: "penSize").flatMap(PenSize.init(rawValue:)) ?? .medium }
        set { set(newValue.rawValue, "penSize") }
    }

    /// Off (default): every click is a tap that reaches nothing, as before.
    /// On: the left button clicks for real (with a ripple), the right button taps and draws.
    static var realClicks: Bool {
        get { defaults.object(forKey: "realClicks") as? Bool ?? false }
        set { set(newValue, "realClicks") }
    }

    static var rippleOn: Bool {
        get { defaults.object(forKey: "ripple.on") as? Bool ?? true }
        set { set(newValue, "ripple.on") }
    }

    static var rippleStyle: RippleStyle {
        get { defaults.string(forKey: "ripple.style").flatMap(RippleStyle.init(rawValue:)) ?? .glass }
        set { set(newValue.rawValue, "ripple.style") }
    }

    static var rippleColor: RippleColor {
        get { defaults.string(forKey: "ripple.color").flatMap(RippleColor.init(rawValue:)) ?? .blue }
        set { set(newValue.rawValue, "ripple.color") }
    }

    static var rippleSize: RippleSize {
        get { defaults.string(forKey: "ripple.size").flatMap(RippleSize.init(rawValue:)) ?? .medium }
        set { set(newValue.rawValue, "ripple.size") }
    }

    static var rippleSpeed: RippleSpeed {
        get { defaults.string(forKey: "ripple.speed").flatMap(RippleSpeed.init(rawValue:)) ?? .normal }
        set { set(newValue.rawValue, "ripple.speed") }
    }

    static var handSound: Bool {
        get { defaults.object(forKey: "sound.hands") as? Bool ?? true }
        set { set(newValue, "sound.hands") }
    }

    static var tapSound: TapSoundChoice {
        get { defaults.string(forKey: "tapSound").flatMap(TapSoundChoice.init(rawValue:)) ?? .thock }
        set { set(newValue.rawValue, "tapSound") }
    }

    static var laserSound: Bool {
        get { defaults.object(forKey: "sound.laser") as? Bool ?? false }
        set { set(newValue, "sound.laser") }
    }

    static var interactKeepsHand: Bool {
        get { defaults.bool(forKey: "interactKeepsHand") }
        set { set(newValue, "interactKeepsHand") }
    }

    static var doubleShiftClickThrough: Bool {
        get { defaults.object(forKey: "doubleShiftClickThrough") as? Bool ?? true }
        set { set(newValue, "doubleShiftClickThrough") }
    }

    static var interactKey: InteractKey {
        get { defaults.string(forKey: "interactKey").flatMap(InteractKey.init(rawValue:)) ?? .option }
        set { set(newValue.rawValue, "interactKey") }
    }

    static var inkChoice: InkChoice {
        get { defaults.string(forKey: "inkChoice").flatMap(InkChoice.init(rawValue:)) ?? .match }
        set { set(newValue.rawValue, "inkChoice") }
    }

    static var showToolbar: Bool {
        get { defaults.object(forKey: "showToolbar") as? Bool ?? true }
        set { set(newValue, "showToolbar") }
    }

    static var showInkButton: Bool {
        get { defaults.object(forKey: "showInkButton") as? Bool ?? true }
        set { set(newValue, "showInkButton") }
    }

    static let maxPinned = 8

    static var pinnedStyles: [PointerStyle] {
        get {
            guard let raw = defaults.stringArray(forKey: "pinnedStyles") else {
                return PointerStyle.defaultPinned
            }
            var seen = Set<PointerStyle>()
            let pinned = raw.compactMap(PointerStyle.init(rawValue:)).filter { seen.insert($0).inserted }
            return pinned.isEmpty ? PointerStyle.defaultPinned : pinned
        }
        set { set(newValue.map(\.rawValue), "pinnedStyles") }
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

    static func resetAll() {
        for key in ["shortcut.toggle", "shortcut.clear", "pointerSize", "showShadow", "fadeSeconds",
                    "sound.hands", "sound.laser", "interactKey", "interactKeepsHand", "doubleShiftClickThrough", "pinnedStyles", "pointerStyle",
                    "inkChoice", "showInkButton", "showToolbar", "tapSound", "inkTone", "penSize",
                    "realClicks", "ripple.on", "ripple.style", "ripple.color", "ripple.size", "ripple.speed"] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: nil)
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
