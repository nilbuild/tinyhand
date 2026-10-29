import Foundation

// A small diagnostic log at ~/Library/Logs/TinyHand.log: launch, permission and
// event-tap state, and press/drag/release counts. Enough to tell "no permission"
// from "events not arriving" without a debugger.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TinyHand.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) [\(getpid())] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            return
        }
        try? data.write(to: url)
    }
}
