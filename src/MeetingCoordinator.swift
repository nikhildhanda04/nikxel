import Foundation
import Cocoa
import UserNotifications

class MeetingCoordinator: AudioRecorderDelegate {
    let stateMachine: StateMachine
    let recorder = AudioRecorder()
    let transcriber = Transcriber()
    let momGen = MOMGenerator()
    weak var nikxelView: NikxelView?

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
        recorder.delegate = self
        requestNotificationPermission()
    }

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
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
                let alert = NSAlert()
                alert.messageText = "Recording Error"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Settings")
                if alert.runModal() == .alertSecondButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            return
        }

        guard let artifacts = artifacts else {
            notify(title: "Recording failed", body: "No audio file produced.")
            return
        }

        let startedAt = recorder.startedAt ?? Date()
        let durationSec = max(1, Int(Date().timeIntervalSince(startedAt)))

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
                    self.stateMachine.endWritingMOM()
                    let alert = NSAlert()
                    alert.messageText = mode == .notes ? "Notes Generation Failed" : "MOM Generation Failed"
                    alert.informativeText = "\(err)"
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                case .success(let outURL):
                    self.stateMachine.endWritingMOM()
                    let title = mode == .notes ? "Notes ready" : "MOM ready"
                    self.notify(title: title, body: outURL.lastPathComponent, openOnTap: outURL)
                    cleanup()
                }
            }
        }
    }

    private func reportTranscribeFailure(_ err: Error) {
        DispatchQueue.main.async {
            self.stateMachine.endWritingMOM()
            let alert = NSAlert()
            alert.messageText = "Transcription Failed"
            alert.informativeText = "\(err)"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
