import Foundation

/// Tiny file logger for diagnosing runtime behaviour without Console.app
/// filtering surprises. Writes to ~/.nikxel/debug.log AND mirrors to NSLog.
/// Persists across launches (append). Truncate manually if it gets big.
enum Diag {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let queue = DispatchQueue(label: "nikxel.diag")
    private static let dfmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var logURL: URL { url }

    static func log(_ tag: String, _ msg: String) {
        let line = "[\(dfmt.string(from: Date()))] [\(tag)] \(msg)\n"
        NSLog("[%@] %@", tag, msg)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
    }
}
