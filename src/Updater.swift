import Foundation
import AppKit

/// Self-update: fetch `origin/main`, and on request pull, rebuild and relaunch.
///
/// Nikxel is built from source in a clone, so "update" is `git pull` plus
/// `./build.sh` -- exactly what the README tells you to run by hand. The only
/// real problem is that **the app cannot do this to itself while running**:
/// build.sh replaces the very binary the process is executing, and `open` on an
/// already-running app just brings it to the front. So the work is handed to a
/// detached script that outlives the app -- it waits for Nikxel to quit, does
/// the update, and launches the new build.
///
/// That script keeps a copy of the previous binary and puts it back if the pull
/// or the build fails. A failed update must never leave somebody with no app.
enum Updater {

    struct Status {
        let repo: URL
        /// How many commits `origin/main` is ahead of the running build.
        let behind: Int
        /// Their subject lines, newest first.
        let subjects: [String]
        /// The commit this build came from.
        let currentCommit: String
        let branch: String
        /// Uncommitted changes to tracked files, which would stop a pull.
        let dirty: Bool

        var isUpToDate: Bool { behind == 0 }
        /// A fast-forward pull only works from main with a clean tree.
        var canAutoUpdate: Bool { !dirty && branch == "main" }
    }

    enum Failure: LocalizedError {
        case notAClone
        case git(String)

        var errorDescription: String? {
            switch self {
            case .notAClone:
                return """
                Nikxel isn't running from a git clone, so it can't update itself.

                Clone the repo and run ./setup.command from there:
                git clone https://github.com/nikhildhanda04/nikxel.git
                """
            case .git(let message):
                return message
            }
        }
    }

    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("update.log")
    }()

    /// The clone this app was built in: the directory holding `Nikxel.app`.
    /// Checked for both `.git` and `build.sh`, because a bundle copied to
    /// /Applications has neither and must not be offered an update.
    static var repoRoot: URL? {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent(".git").path),
              fm.isExecutableFile(atPath: root.appendingPathComponent("build.sh").path)
        else { return nil }
        return root
    }

    // MARK: - Checking

    /// Fetches and compares, off the main thread. Completion is on main.
    static func check(_ completion: @escaping (Result<Status, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = checkSync()
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func checkSync() -> Result<Status, Failure> {
        guard let repo = repoRoot else { return .failure(.notAClone) }

        let fetch = git(repo, ["fetch", "origin", "main"])
        guard fetch.ok else {
            return .failure(.git("Couldn't reach GitHub.\n\n\(fetch.output)"))
        }

        let count = git(repo, ["rev-list", "--count", "HEAD..origin/main"])
        guard count.ok, let behind = Int(count.output) else {
            return .failure(.git("Couldn't compare against origin/main.\n\n\(count.output)"))
        }

        let subjects = behind == 0 ? [] :
            git(repo, ["log", "--pretty=format:%s", "HEAD..origin/main"])
                .output
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }

        return .success(Status(
            repo: repo,
            behind: behind,
            subjects: subjects,
            currentCommit: git(repo, ["rev-parse", "--short", "HEAD"]).output,
            branch: git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]).output,
            // --porcelain lists untracked files too; -uno drops them, since the
            // built binary and anything else ignored can't block a pull.
            dirty: !git(repo, ["status", "--porcelain", "-uno"]).output.isEmpty))
    }

    @discardableResult
    private static func git(_ repo: URL, _ args: [String]) -> (ok: Bool, output: String) {
        let task = Process()
        task.launchPath = "/usr/bin/git"
        task.arguments = ["-C", repo.path] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        // A clone made over SSH, or a credential helper wanting input, would
        // otherwise hang the fetch forever behind a prompt nobody can see.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        task.environment = env
        do { try task.run() } catch { return (false, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (task.terminationStatus == 0, out)
    }

    // MARK: - Updating

    /// Hands the update to a detached script and quits. Returns false if the
    /// script couldn't be started, in which case nothing has happened yet.
    @discardableResult
    static func updateAndRestart(repo: URL) -> Bool {
        let script = """
        #!/bin/zsh
        # Written by Nikxel's "Check for Updates". Runs after Nikxel quits,
        # because build.sh replaces the binary the app is executing.
        exec >> "\(logURL.path)" 2>&1
        echo ""
        echo "=== update started $(date)"
        cd "\(repo.path)" || { echo "repo gone: \(repo.path)"; exit 1; }

        # Back up the whole signed bundle, not just the binary. Restoring only
        # the executable left it unsigned, and re-signing it ad-hoc downgraded
        # a bundle that had been signed with the stable "Nikxel" certificate --
        # measured: Authority=Nikxel before a failed update, Signature=adhoc
        # after. macOS reads that as a different app, so a failed update cost
        # the user every permission they had granted. `ditto` is the macOS tool
        # for copying bundles and keeps the signature intact, so nothing has to
        # be re-signed at all.
        BACKUP="$(mktemp -d -t nikxel-prev)"
        ditto Nikxel.app "$BACKUP/Nikxel.app"

        restore() {
            echo "--- update failed; restoring the previous build"
            if [ -d "$BACKUP/Nikxel.app" ]; then
                rm -rf Nikxel.app
                ditto "$BACKUP/Nikxel.app" Nikxel.app
                echo "--- restored: $(codesign -dvv Nikxel.app 2>&1 | grep -E 'Authority=|Signature=' | head -1)"
            fi
            rm -rf "$BACKUP"
            open Nikxel.app
            exit 1
        }

        # Wait for the old process to go away (up to 30s) so the running binary
        # isn't swapped underneath it.
        for i in {1..60}; do
            pgrep -f "Nikxel.app/Contents/MacOS/Nikxel" > /dev/null || break
            sleep 0.5
        done

        echo "--- before: $(git log --oneline -1)"
        git pull --ff-only || restore
        echo "--- after:  $(git log --oneline -1)"
        ./build.sh || restore

        rm -rf "$BACKUP"
        echo "=== update complete"
        open Nikxel.app
        """

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nikxel-update-\(UUID().uuidString).sh")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return false
        }

        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = [url.path]
        // The script redirects itself into update.log; detach ours so nothing
        // is tied to this process's file handles.
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try task.run() } catch { return false }
        return true
    }
}
