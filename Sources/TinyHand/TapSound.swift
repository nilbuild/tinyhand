import AppKit

enum TapSoundChoice: String, CaseIterable {
    case thock, click, pop, wood, boop, squeak

    var title: String {
        switch self {
        case .thock: return "Thock"
        case .click: return "Click"
        case .pop: return "Pop"
        case .wood: return "Wood block"
        case .boop: return "Boop"
        case .squeak: return "Squeak"
        }
    }
}

final class TapSound {
    private var sound: NSSound?
    private var loadedChoice: TapSoundChoice?

    var enabled = true

    init(_ choice: TapSoundChoice = Preferences.tapSound) {
        load(choice)
    }

    func load(_ choice: TapSoundChoice) {
        guard choice != loadedChoice else {
            return
        }
        loadedChoice = choice
        sound = TapSound.find(choice) ?? NSSound(named: NSSound.Name("Pop"))
        warmUp()
    }

    func play() {
        guard enabled, let sound = sound else {
            return
        }
        if sound.isPlaying {
            sound.stop()
        }
        sound.play()
    }

    private static func find(_ choice: TapSoundChoice) -> NSSound? {
        let name = "tap_\(choice.rawValue)"
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "wav"),
            exeDir.appendingPathComponent("\(name).wav"),
            exeDir.appendingPathComponent("assets/sounds/\(name).wav"),
            URL(fileURLWithPath: "assets/sounds/\(name).wav"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let s = NSSound(contentsOf: url, byReference: false) {
                return s
            }
        }
        return nil
    }

    private func warmUp() {
        guard let sound = sound else {
            return
        }
        sound.volume = 0
        sound.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            sound.stop()
            sound.volume = 1
        }
    }
}
