import AppKit
import ApplicationServices

if let idx = CommandLine.arguments.firstIndex(of: "--render-test") {
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/armtest.png"
    RenderTest.run(outPath: out)
    exit(0)
}

// Reports whether THIS app identity holds Accessibility. Launch it the way macOS
// launches the real app:  open -n TinyHand.app --args --ax-status <file>
if let idx = CommandLine.arguments.firstIndex(of: "--ax-status") {
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/tinyhand-ax.txt"
    let mask: CGEventMask = 1 << CGEventType.leftMouseDown.rawValue
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil)
    let text = "trusted=\(AXIsProcessTrusted()) tap=\(tap != nil) bundle=\(Bundle.main.bundlePath)\n"
    try? text.write(toFile: out, atomically: true, encoding: .utf8)
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--toolbar-test") {
    _ = NSApplication.shared
    let bar = Toolbar()
    bar.select(.lavender)
    bar.setNeedsPermission(CommandLine.arguments.contains("--needs-permission"))
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/toolbar.png"
    if let data = bar.snapshot()?.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: out))
        print("rendered \(out)")
    }
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--settings-test") {
    _ = NSApplication.shared
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/settings.png"
    if let data = SettingsWindow().snapshot()?.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: out))
        print("rendered \(out)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--e2e-test") {
    E2ETest.run()
    exit(0)
}

if CommandLine.arguments.contains("--click-test") {
    _ = NSApplication.shared
    OverlayController().runClickTest()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory = menu-bar agent, no Dock icon, never steals focus from the browser.
app.setActivationPolicy(.accessory)
app.run()
