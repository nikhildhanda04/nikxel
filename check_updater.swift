// Checks the self-updater's decisions: when a tap to update is offered at all,
// and how a commit subject is shortened for the card.
//
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/cu \
//     check_updater.swift src/Updater.swift
import Foundation

@main
struct CheckUpdater {
    static func status(behind: Int, branch: String = "main", dirty: Bool = false) -> Updater.Status {
        Updater.Status(repo: URL(fileURLWithPath: "/tmp/repo"),
                       behind: behind, subjects: [], currentCommit: "abc1234",
                       branch: branch, dirty: dirty)
    }

    static func main() {
        // --- When the tap is offered -------------------------------------
        assert(status(behind: 0).isUpToDate)
        assert(!status(behind: 1).isUpToDate)

        // A fast-forward pull needs main AND a clean tree. Offering a tap that
        // cannot work means the update script discovers it, fails, and rolls
        // back -- a wasted quit and rebuild for something knowable up front.
        assert(status(behind: 2).canAutoUpdate)
        assert(!status(behind: 2, branch: "experiment").canAutoUpdate,
               "a branch other than main can't fast-forward to origin/main")
        assert(!status(behind: 2, dirty: true).canAutoUpdate,
               "uncommitted changes block the pull")
        assert(!status(behind: 2, branch: "experiment", dirty: true).canAutoUpdate)
        // Being up to date says nothing about whether a pull *could* run; the
        // two are independent, and presentUpdate checks isUpToDate first.
        assert(status(behind: 0).canAutoUpdate)

        // --- Shortening a subject for a card line -------------------------
        let short = "Fix the thing"
        assert(Updater.shortSubject(short) == short, "a short subject is untouched")
        assert(!Updater.shortSubject(short).hasSuffix("…"))

        let long = "Don't abort the build on a Mac that lacks the signing certificate"
        let cut = Updater.shortSubject(long, limit: 56)
        assert(cut.count <= 57, "within the limit plus the ellipsis — got \(cut.count)")
        assert(cut.hasSuffix("…"))
        assert(!cut.hasSuffix(" …"), "no space left dangling before the ellipsis")
        // The whole point: never slice a word in half.
        let body = String(cut.dropLast())
        assert(long.hasPrefix(body), "the kept text is a real prefix of the subject")
        assert(long.dropFirst(body.count).first == " ",
               "the cut landed on a word boundary — got '\(body)'")

        // Exactly at the limit is not truncated.
        let exact = String(repeating: "a", count: 20)
        assert(Updater.shortSubject(exact, limit: 20) == exact)
        assert(Updater.shortSubject(exact, limit: 19).hasSuffix("…"))

        // One long token with no space to back up to still has to be cut.
        let token = String(repeating: "x", count: 100)
        let tokenCut = Updater.shortSubject(token, limit: 10)
        assert(tokenCut == String(repeating: "x", count: 10) + "…", "got \(tokenCut)")

        // Leading/trailing whitespace is trimmed, not counted.
        assert(Updater.shortSubject("   padded   ") == "padded")

        print("check_updater: OK")
    }
}
