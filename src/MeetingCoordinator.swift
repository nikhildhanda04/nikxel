import Foundation
import Cocoa
import UserNotifications

class MeetingCoordinator: AudioRecorderDelegate {
    let stateMachine: StateMachine
    let recorder = AudioRecorder()
    let transcriber = Transcriber()
    let momGen = MOMGenerator()
    weak var nikxelView: NikxelView?

    /// Set while a recording is being transcribed/summarized. A double-click on
    /// the avatar used to start a fresh recording here, which buried the work in
    /// progress: the .writingMOM animation got clobbered by .recording, the new
    /// (near-empty) recording raised its own "generation failed" alert, and the
    /// two runs overwrote each other's logs.
    private(set) var isProcessing = false

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
        recorder.delegate = self
        requestNotificationPermission()
    }

    /// `force` comes from the menu bar, which stays unguarded as the deliberate
    /// way to record while a summary is still being written. The avatar's
    /// double-click does not, because that is the accidental path.
    func toggleRecording(force: Bool = false) {
        if recorder.isRecording {
            recorder.stop()
            return
        }
        if isProcessing && !force {
            nikxelView?.pushReminder(id: "nikxel.busy", title: "Still writing your notes…")
            return
        }
        recorder.captureMode = CaptureMode.current
        recorder.start()
    }

    func recorderDidStart() {
        stateMachine.startRecording()
        nikxelView?.recordingStartedAt = CACurrentMediaTime()
    }

    func recorderDidStop(artifacts: RecordingArtifacts?, error: Error?) {
        stateMachine.stopRecording()
        nikxelView?.recordingStartedAt = nil

        if let error = error {
            DispatchQueue.main.async {
                self.nikxelView?.showCard(
                    icon: "⚠️",
                    title: "Couldn't record",
                    lines: [String(error.localizedDescription.prefix(160)),
                            "Tap to open Screen Recording permissions."],
                    kind: .error,
                    lifetime: .infinity,
                    action: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    })
            }
            return
        }

        guard let artifacts = artifacts else {
            isProcessing = false
            notify(title: "Recording failed", body: "No audio file produced.")
            return
        }

        let startedAt = recorder.startedAt ?? Date()
        let durationSec = max(1, Int(Date().timeIntervalSince(startedAt)))

        isProcessing = true
        stateMachine.startWritingMOM()
        switch artifacts {
        case .merged(let audioURL):
            runNotesPipeline(audioURL: audioURL, startedAt: startedAt, durationSec: durationSec)
        case .split(let mic, let sys):
            runMeetingPipeline(micURL: mic, sysURL: sys, startedAt: startedAt, durationSec: durationSec)
        }
    }

    // MARK: - Notes pipeline

    private func runNotesPipeline(audioURL: URL, startedAt: Date, durationSec: Int) {
        transcriber.transcribe(audioURL: audioURL, outputFormat: .txt) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                self.reportTranscribeFailure(err)
            case .success(let txtURL):
                guard let text = try? String(contentsOf: txtURL, encoding: .utf8) else {
                    self.reportTranscribeFailure(Transcriber.TranscriberError.failed("could not read transcript at \(txtURL.path)"))
                    return
                }
                self.generate(transcript: text, mode: .notes, startedAt: startedAt, durationSec: durationSec,
                              cleanup: { try? FileManager.default.removeItem(at: audioURL) })
            }
        }
    }

    // MARK: - Meeting pipeline

    private func runMeetingPipeline(micURL: URL?, sysURL: URL, startedAt: Date, durationSec: Int) {
        let group = DispatchGroup()
        var micSRT: URL?
        var sysSRT: URL?
        var firstError: Error?

        group.enter()
        transcriber.transcribe(audioURL: sysURL, outputFormat: .srt) { result in
            switch result {
            case .success(let url): sysSRT = url
            case .failure(let err): if firstError == nil { firstError = err }
            }
            group.leave()
        }
        if let micURL = micURL {
            group.enter()
            transcriber.transcribe(audioURL: micURL, outputFormat: .srt) { result in
                switch result {
                case .success(let url): micSRT = url
                case .failure(let err): if firstError == nil { firstError = err }
                }
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self = self else { return }
            if let err = firstError, sysSRT == nil && micSRT == nil {
                self.reportTranscribeFailure(err)
                return
            }
            let merged = TranscriptMerger.merge(micSRT: micSRT, sysSRT: sysSRT)
            self.generate(transcript: merged, mode: .meeting, startedAt: startedAt, durationSec: durationSec, cleanup: {
                let fm = FileManager.default
                if let url = micURL { try? fm.removeItem(at: url) }
                try? fm.removeItem(at: sysURL)
            })
        }
    }

    // MARK: - Shared generate step

    private func generate(transcript: String, mode: CaptureMode, startedAt: Date, durationSec: Int, cleanup: @escaping () -> Void) {
        momGen.generate(transcript: transcript, mode: mode, startedAt: startedAt, durationSec: durationSec) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    self.isProcessing = false
                    self.stateMachine.endWritingMOM()
                    // A card rather than a modal: a failure here costs nothing
                    // -- the transcript was written before generation ran and
                    // "Regenerate Unfinished Summary" picks it back up -- so
                    // stealing focus mid-work is the wrong trade. It stays put
                    // until clicked, and clicking opens the run's logs.
                    self.showFailureCard(
                        title: mode == .notes ? "Couldn't write your notes" : "Couldn't write the minutes",
                        error: err,
                        hint: "Your transcript is saved — menu bar → Regenerate Unfinished Summary.")
                case .success(let outURL):
                    self.isProcessing = false
                    // endWritingMOM first: .writingMOM is sticky in setState,
                    // so triggerMomReady would be swallowed while it's held.
                    self.stateMachine.endWritingMOM()
                    self.stateMachine.triggerMomReady()
                    let title = mode == .notes ? "Notes ready" : "MOM ready"
                    self.notify(title: title, body: outURL.lastPathComponent, openOnTap: outURL)
                    self.showReadyCard(mode: mode, outURL: outURL)
                    cleanup()
                    // Meetings only -- a lecture or podcast has no owners and
                    // nothing to put in anyone's calendar. No-ops unless the
                    // user has connected Google, and always asks first.
                    if mode == .meeting { GoogleSync.offer(noteURL: outURL) }
                }
            }
        }
    }

    private func reportTranscribeFailure(_ err: Error) {
        DispatchQueue.main.async {
            self.isProcessing = false
            self.stateMachine.endWritingMOM()
            self.showFailureCard(title: "Couldn't transcribe the recording",
                                 error: err,
                                 hint: "Check that whisper is installed and working in a terminal.")
        }
    }

    // MARK: - Cards

    /// "MOM ready" with the note's own action items as bullets -- the first
    /// thing anyone opens the note for, so it goes straight on the card.
    /// Reuses GoogleSync's parser rather than a second one.
    private func showReadyCard(mode: CaptureMode, outURL: URL) {
        let mdURL = outURL.pathExtension.lowercased() == "md"
            ? outURL
            : outURL.deletingPathExtension().appendingPathExtension("md")
        let md = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""

        var lines: [String] = []
        if mode == .meeting {
            lines = GoogleSync.parseActionItems(md).prefix(3).map(\.title)
            if lines.isEmpty { lines = ["No tasks came out of this one."] }
        } else {
            lines = Self.firstBullets(in: GoogleSync.section(md, heading: "Key Points"), limit: 3)
            if lines.isEmpty { lines = [mdURL.lastPathComponent] }
        }

        nikxelView?.showCard(
            icon: "📄",
            title: mode == .notes ? "Notes ready" : "Minutes ready",
            lines: lines,
            bulleted: true,
            kind: .success,
            lifetime: 25,
            action: { NSWorkspace.shared.open(outURL) })
    }

    private func showFailureCard(title: String, error: Error, hint: String) {
        // Agent errors carry a "Logs: /path" tail; pull it out so tapping the
        // card lands somewhere useful, and keep it out of the visible text.
        let full = "\(error)"
        var logPath: String?
        if let r = full.range(of: "Logs: ") {
            logPath = String(full[r.upperBound...])
                .components(separatedBy: .newlines).first?
                .trimmingCharacters(in: .whitespaces)
        }
        let reason = full.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("Logs: ") } ?? "Unknown error."

        nikxelView?.showCard(
            icon: "⚠️",
            title: title,
            lines: [String(reason.prefix(160)), hint],
            kind: .error,
            lifetime: .infinity,   // stays until clicked
            action: {
                if let p = logPath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
            })
    }

    /// Leading "- " / "* " bullets from a Markdown section, trimmed of inline
    /// markers, for the notes card.
    static func firstBullets(in section: String, limit: Int) -> [String] {
        var out: [String] = []
        for raw in section.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let text = String(line.dropFirst(2))
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.lowercased() != "none." , text.lowercased() != "none" else { continue }
            out.append(text)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String, openOnTap: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let url = openOnTap {
            content.userInfo = ["openPath": url.path]
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
