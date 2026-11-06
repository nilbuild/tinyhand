import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

enum CaptureError: Error {
    case permission
    case noDisplay
    case failed(String)
}

/// Snapshots and screen recordings that include the hand and the ink, but leave out
/// TinyHand's own toolbar, hints and other windows.
final class Capture {
    private var recorder: Recorder?
    var isRecording: Bool { recorder != nil }

    /// Called on the main queue when the system stops a recording by itself
    /// (for example, the display went away or permission was taken back).
    var onStoppedBySystem: (() -> Void)?

    static let shutter = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    private static let askedKey = "screenRecordingAsked"

    /// True when TinyHand may capture the screen. The first time it isn't, macOS shows its own prompt
    /// and this returns false with `shouldExplain` false; after that, the caller should explain.
    static func checkPermission() -> (granted: Bool, shouldExplain: Bool) {
        if CGPreflightScreenCaptureAccess() {
            return (true, false)
        }
        let asked = UserDefaults.standard.bool(forKey: askedKey)
        UserDefaults.standard.set(true, forKey: askedKey)
        CGRequestScreenCaptureAccess()
        return (false, asked)
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: Snapshot

    func snapshot(screen: NSScreen, keep: [Int]) async throws -> CGImage {
        let (filter, display) = try await Capture.filter(for: screen, keeping: keep)
        let config = Capture.configuration(display: display, scale: screen.backingScaleFactor, maxPixels: nil)
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        return try await OneFrame().grab(filter: filter, config: config)
    }

    // MARK: Recording

    func startRecording(screen: NSScreen, keep: [Int], to url: URL) async throws {
        guard recorder == nil else {
            return
        }
        let (filter, display) = try await Capture.filter(for: screen, keeping: keep)
        // H.264 tops out around 4K, so big Retina screens are scaled down to fit.
        let config = Capture.configuration(display: display, scale: screen.backingScaleFactor, maxPixels: 3840 * 2160)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let r = try Recorder(url: url, filter: filter, config: config)
        r.onStoppedBySystem = { [weak self] in
            self?.onStoppedBySystem?()
        }
        try await r.start()
        recorder = r
    }

    /// Finishes the video file and returns where it was saved, or nil if nothing was recorded.
    func stopRecording() async -> URL? {
        guard let r = recorder else {
            return nil
        }
        recorder = nil
        return await r.stop()
    }

    // MARK: Files

    static func newFileURL(ext: String) -> URL {
        let folder = Preferences.captureFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "TinyHand \(f.string(from: Date()))"
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return url
    }

    static var folderName: String {
        FileManager.default.displayName(atPath: Preferences.captureFolder.path)
    }

    // MARK: Helpers

    private static func filter(for screen: NSScreen, keeping keep: [Int]) async throws -> (SCContentFilter, SCDisplay) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            Log.write("screen capture content failed: \(error.localizedDescription)")
            throw CaptureError.permission
        }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == number }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let me = getpid()
        let keepIDs = Set(keep.map { CGWindowID($0) })
        let hide = content.windows.filter { $0.owningApplication?.processID == me && !keepIDs.contains($0.windowID) }
        return (SCContentFilter(display: display, excludingWindows: hide), display)
    }

    private static func configuration(display: SCDisplay, scale: CGFloat, maxPixels: CGFloat?) -> SCStreamConfiguration {
        var w = CGFloat(display.width) * scale
        var h = CGFloat(display.height) * scale
        if let maxPixels = maxPixels, w * h > maxPixels {
            let k = (maxPixels / (w * h)).squareRoot()
            w *= k
            h *= k
        }
        let config = SCStreamConfiguration()
        config.width = max(2, Int(w) / 2 * 2)
        config.height = max(2, Int(h) / 2 * 2)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            return false
        }
        return status == .complete
    }
}

/// macOS 13 has no SCScreenshotManager, so take the first frame of a short stream instead.
private final class OneFrame: NSObject, SCStreamOutput {
    private let queue = DispatchQueue(label: "tinyhand.capture.frame")
    private var continuation: CheckedContinuation<CGImage, Error>?

    func grab(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let image: CGImage = try await withCheckedThrowingContinuation { c in
            queue.sync { continuation = c }
            stream.startCapture { [weak self] error in
                if let error = error {
                    self?.finish(.failure(error))
                }
            }
        }
        try? await stream.stopCapture()
        return image
    }

    private func finish(_ result: Result<CGImage, Error>) {
        queue.async {
            let c = self.continuation
            self.continuation = nil
            c?.resume(with: result)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, continuation != nil, Capture.isComplete(sample),
              let pixels = CMSampleBufferGetImageBuffer(sample) else {
            return
        }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let image = CIContext().createCGImage(ci, from: ci.extent) else {
            return
        }
        let c = continuation
        continuation = nil
        c?.resume(returning: image)
    }
}

/// Writes ScreenCaptureKit frames into a .mov file.
private final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let url: URL
    var onStoppedBySystem: (() -> Void)?

    private let filter: SCContentFilter
    private let config: SCStreamConfiguration
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "tinyhand.capture.record")
    private var started = false
    private var finishing = false
    private var firstTime = CMTime.invalid
    private var firstClock: CFTimeInterval = 0

    init(url: URL, filter: SCContentFilter, config: SCStreamConfiguration) throws {
        self.url = url
        self.filter = filter
        self.config = config
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let pixels = config.width * config.height
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(6_000_000, pixels * 2),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CaptureError.failed("can't add a video track")
        }
        writer.add(input)
        super.init()
    }

    func start() async throws {
        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.failed("couldn't start the video file")
        }
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = s
        do {
            try await s.startCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        Log.write("recording started \(config.width)x\(config.height) -> \(url.path)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finishing, Capture.isComplete(sample) else {
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if !started {
            writer.startSession(atSourceTime: time)
            firstTime = time
            firstClock = CACurrentMediaTime()
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sample)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("recording stopped by the system: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.onStoppedBySystem?()
        }
    }

    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        return await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            queue.async {
                self.finishing = true
                guard self.started, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.url)
                    Log.write("recording had no frames; nothing saved")
                    c.resume(returning: nil)
                    return
                }
                self.input.markAsFinished()
                // Frames only arrive when something changes, so end the video at the moment
                // Stop was pressed rather than at the last frame.
                let elapsed = CMTime(seconds: CACurrentMediaTime() - self.firstClock, preferredTimescale: 600)
                self.writer.endSession(atSourceTime: CMTimeAdd(self.firstTime, elapsed))
                self.writer.finishWriting {
                    let ok = self.writer.status == .completed
                    Log.write(ok ? "recording saved \(self.url.path)"
                                 : "recording failed: \(self.writer.error?.localizedDescription ?? "?")")
                    c.resume(returning: ok ? self.url : nil)
                }
            }
        }
    }
}
