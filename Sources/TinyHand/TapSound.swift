import AppKit
import AVFoundation

enum TapSoundChoice: String, CaseIterable {
    case thock, click, tock, clack, typewriter, snap, wood, pop, boop, blip, coin, pew, squeak, quack, chirp

    var title: String {
        switch self {
        case .thock: return "Thock"
        case .click: return "Click"
        case .wood: return "Wood block"
        case .pop: return "Pop"
        case .boop: return "Boop"
        case .tock: return "Tock"
        case .clack: return "Clack"
        case .typewriter: return "Typewriter"
        case .snap: return "Snap"
        case .blip: return "Blip"
        case .coin: return "Coin"
        case .pew: return "Pew"
        case .squeak: return "Squeak"
        case .quack: return "Quack"
        case .chirp: return "Chirp"
        }
    }
}

struct CustomSound: Codable {
    let id: String
    var name: String
}

/// Sounds the user added. Each is converted once on import to `TapSound.format`, trimmed,
/// and stored as a .caf file next to a list file, like custom hands.
enum CustomSounds {
    static let maxSeconds = 2.0

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TinyHand/Sounds", isDirectory: true)
    }

    private static var listURL: URL {
        directory.appendingPathComponent("sounds.json")
    }

    private static var loaded: [CustomSound]?

    static var all: [CustomSound] {
        if let loaded = loaded {
            return loaded
        }
        let list = (try? Data(contentsOf: listURL)).flatMap { try? JSONDecoder().decode([CustomSound].self, from: $0) } ?? []
        loaded = list
        return list
    }

    static func sound(_ id: String) -> CustomSound? {
        guard id.hasPrefix("custom-") else {
            return nil
        }
        return all.first { $0.id == id }
    }

    static func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).caf")
    }

    static func add(from url: URL) throws -> CustomSound {
        guard let buffer = TapSound.normalized(url, trim: true) else {
            throw HandMaker.Problem(message: "TinyHand couldn't read that sound.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        do {
            let file = try AVAudioFile(forWriting: fileURL(id), settings: buffer.format.settings,
                                       commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
            try file.write(from: buffer)
        } catch {
            throw HandMaker.Problem(message: "TinyHand couldn't save that sound.")
        }
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        var list = all
        let sound = CustomSound(id: id, name: base.isEmpty ? "My sound \(list.count + 1)" : String(base.prefix(16)))
        list.append(sound)
        try save(list)
        return sound
    }

    static func remove(_ id: String) {
        guard sound(id) != nil else {
            return
        }
        try? FileManager.default.removeItem(at: fileURL(id))
        try? save(all.filter { $0.id != id })
    }

    private static func save(_ list: [CustomSound]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: listURL, options: .atomic)
        loaded = list
    }
}

/// Plays the tap sound. Every AVAudioEngine call runs on `queue`, never on the main thread:
/// when another app reshapes the output device (Google Meet sharing a tab or screen with audio),
/// the engine can fail every render cycle, and calls that wait on the render thread then stall
/// for seconds. Off the main thread such a stall costs a missing tap sound, not a frozen pointer.
final class TapSound {
    private static let players = 4
    private static let maxFramesToRender: AUAudioFrameCount = 4096
    /// Every buffer is converted to this, since all player nodes share one connection format.
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    /// An import may be a whole song: read only this much of it, which leaves room for leading
    /// silence before the kept part, so a long file doesn't fill memory or stall Settings.
    private static let importReadSeconds = 10.0

    private let queue = DispatchQueue(label: "TinyHand tap sound", qos: .userInteractive)

    // Touched only on `queue`.
    private var buffers: [String: AVAudioPCMBuffer]
    private var choice: String
    private var engine: AVAudioEngine?
    private var nodes: [AVAudioPlayerNode] = []
    private var next = 0
    private var generation = 0
    private var configObserver: NSObjectProtocol?
    private var idleStop: DispatchWorkItem?

    /// Read and written on the main thread.
    var enabled = true

    init(_ choice: String = Preferences.tapSound) {
        self.choice = choice
        var buffers: [String: AVAudioPCMBuffer] = [:]
        for c in TapSoundChoice.allCases {
            if let buffer = TapSound.read(c) {
                buffers[c.rawValue] = buffer
            }
        }
        self.buffers = buffers
        loadCustom(choice)
    }

    func load(_ choice: String) {
        queue.async { [weak self] in
            self?.choice = choice
            self?.loadCustom(choice)
        }
    }

    /// Runs on `queue`, so it checks the file rather than `CustomSounds.all`, which the main thread owns.
    private func loadCustom(_ id: String) {
        guard buffers[id] == nil, id.hasPrefix("custom-"),
              let buffer = TapSound.normalized(CustomSounds.fileURL(id), trim: false) else {
            return
        }
        buffers[id] = buffer
    }

    func warm() {
        queue.async { [weak self] in
            self?.start()
        }
    }

    func play() {
        guard enabled else {
            return
        }
        queue.async { [weak self] in
            self?.playNow()
        }
    }

    private func playNow() {
        guard let buffer = buffers[choice], start(), !nodes.isEmpty else {
            return
        }
        let node = nodes[next % nodes.count]
        next += 1
        let gen = generation
        var rendered = false
        let lock = NSLock()
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataRendered) { _ in
            lock.withLock { rendered = true }
        }
        if !node.isPlaying {
            node.play()
        }
        // A broken render loop never reaches the player, so the buffer is never rendered:
        // throw the engine away and build a fresh one on the next tap.
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        queue.asyncAfter(deadline: .now() + duration + 1) { [weak self] in
            guard let self = self, gen == self.generation, !lock.withLock({ rendered }) else {
                return
            }
            Log.write("tap sound was not rendered; rebuilding the audio engine")
            self.teardown()
        }
    }

    /// Makes sure a running engine exists. Builds a fresh one rather than resuming an old one,
    /// so it picks up the output device's current buffer size. Returns false if it can't start.
    @discardableResult
    private func start() -> Bool {
        scheduleIdleStop()
        if let engine = engine, engine.isRunning {
            return true
        }
        teardown()

        let engine = AVAudioEngine()
        var nodes: [AVAudioPlayerNode] = []
        for _ in 0..<TapSound.players {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: TapSound.format)
            nodes.append(node)
        }
        // Leave headroom for output devices that ask for more frames per cycle than the engine
        // sized itself for (the cause of kAudioUnitErr_TooManyFramesToProcess).
        for unit in nodes.map(\.auAudioUnit) + [engine.mainMixerNode.auAudioUnit]
        where !unit.renderResourcesAllocated && unit.maximumFramesToRender < TapSound.maxFramesToRender {
            unit.maximumFramesToRender = TapSound.maxFramesToRender
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async {
                guard let self = self, self.engine === engine else {
                    return
                }
                Log.write("audio configuration changed; rebuilding the audio engine")
                self.teardown()
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.write("audio engine failed to start: \(error.localizedDescription)")
            if let observer = configObserver {
                NotificationCenter.default.removeObserver(observer)
                configObserver = nil
            }
            return false
        }
        self.engine = engine
        self.nodes = nodes
        return true
    }

    private func teardown() {
        generation += 1
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        guard let engine = engine else {
            return
        }
        self.engine = nil
        nodes = []
        engine.stop()
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in
            self?.teardown()
        }
        idleStop = stop
        queue.asyncAfter(deadline: .now() + 30, execute: stop)
    }

    private static func read(_ choice: TapSoundChoice) -> AVAudioPCMBuffer? {
        let name = "tap_\(choice.rawValue)"
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "wav"),
            exeDir.appendingPathComponent("\(name).wav"),
            exeDir.appendingPathComponent("assets/sounds/\(name).wav"),
            URL(fileURLWithPath: "assets/sounds/\(name).wav"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let buffer = normalized(url, trim: false) {
                return buffer
            }
        }
        return nil
    }

    /// Reads any file AVAudioFile can open (WAV, AIFF, CAF, MP3, M4A…) and converts it to `format`.
    /// With `trim`, drops leading silence so the sound starts right on the tap, caps the length
    /// at `CustomSounds.maxSeconds`, and fades out the end if it was cut.
    static func normalized(_ url: URL, trim: Bool) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            return nil
        }
        let limit = trim ? AVAudioFramePosition(importReadSeconds * file.processingFormat.sampleRate) : file.length
        let frames = AVAudioFrameCount(min(file.length, limit))
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: input, frameCount: frames)) != nil, input.frameLength > 0 else {
            return nil
        }
        var output = input
        if input.format != format {
            guard let converter = AVAudioConverter(from: input.format, to: format) else {
                return nil
            }
            converter.downmix = true
            let ratio = format.sampleRate / input.format.sampleRate
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096) else {
                return nil
            }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, converted.frameLength > 0 else {
                return nil
            }
            output = converted
        }
        return trim ? trimmed(output) : output
    }

    private static func trimmed(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let samples = buffer.floatChannelData?[0] else {
            return buffer
        }
        let count = Int(buffer.frameLength)
        let start = (0..<count).first { abs(samples[$0]) > 0.003 } ?? count
        let maxFrames = Int(CustomSounds.maxSeconds * format.sampleRate)
        let length = min(count - start, maxFrames)
        guard length > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let dest = out.floatChannelData?[0] else {
            return nil
        }
        dest.update(from: samples + start, count: length)
        out.frameLength = AVAudioFrameCount(length)
        if count - start > maxFrames {
            let fade = min(length, Int(0.05 * format.sampleRate))
            for k in 0..<fade {
                dest[length - fade + k] *= Float(fade - k) / Float(fade)
            }
        }
        return out
    }
}
