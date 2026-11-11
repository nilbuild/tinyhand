import Foundation

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
        // Keep the log small: once it passes 1 MB, start a fresh one.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? data.write(to: url)
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
