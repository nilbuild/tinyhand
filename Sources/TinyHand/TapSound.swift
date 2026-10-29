import AppKit

// The screen-tap sound. Loads a bundled tap.wav/aiff if present, else falls back
// to a crisp system sound so there's always something. One reused instance keeps
// rapid taps low-latency.
final class TapSound {
    private let sound: NSSound?

    var enabled = true

    init() {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.url(forResource: "tap", withExtension: "wav"),
            Bundle.main.url(forResource: "tap", withExtension: "aiff"),
            exeDir.appendingPathComponent("tap.wav"),
            exeDir.appendingPathComponent("assets/tap.wav"),
            URL(fileURLWithPath: "assets/tap.wav"),
            URL(fileURLWithPath: "tap.wav")
        ].compactMap { $0 }

        var loaded: NSSound?
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let s = NSSound(contentsOf: url, byReference: false) {
                loaded = s
                break
            }
        }
        sound = loaded ?? NSSound(named: NSSound.Name("Pop"))
        warmUp()
    }

    // The first play spins up the audio device (~100 ms). Do that silently at
    // launch so the first real tap is instant.
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

    func play() {
        guard enabled, let sound = sound else {
            return
        }
        if sound.isPlaying {
            sound.stop()
        }
        sound.play()
    }
}
