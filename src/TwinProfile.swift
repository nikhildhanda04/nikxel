import Foundation

/// What Nikxel has learned about the user over time, kept in
/// ~/.nikxel/twin/profile.md (0600, like the ERP session). Separate from the
/// user's own `userContext`, which this never touches.
enum TwinProfile {
    private static var file: String { NSHomeDirectory() + "/.nikxel/twin/profile.md" }

    static var learned: String {
        get { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
        set {
            if !newValue.isEmpty {
                try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                try? newValue.write(toFile: file, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
            } else {
                try? FileManager.default.removeItem(atPath: file)
            }
        }
    }

    /// The learned profile as a prompt block, or "" when empty. The
    /// <!--corrections--> region is machine data and never goes into prompts.
    static var injectedBlock: String {
        var t = learned
        if let a = t.range(of: "<!--corrections-->"),
           let b = t.range(of: "<!--/corrections-->", range: a.upperBound..<t.endIndex) {
            t.removeSubrange(a.lowerBound..<b.upperBound)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        return "What Nikxel has learned about this user over time — their work, the correct names and terms they use, and how they talk and write. Match it.\n\(t)"
    }
}
