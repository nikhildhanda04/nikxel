import Foundation
import AVFoundation

/// The user's side of a recording. Follows the default input across device changes: AirPods
/// joining mid-meeting, or a Bluetooth headset dropping to its call profile (16/24 kHz) when
/// the meeting app opens its mic. Each change stops the engine; it used to stay stopped, so the
/// rest of the meeting had no mic. Now it restarts on the new device, and the file is one fixed
/// format (48 kHz mono) whatever the device gives, with any gap filled with silence so the mic
/// stays aligned with the system-audio track.
class MicRecorder {
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var observer: NSObjectProtocol?
    private let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    /// File writes and engine restarts, in order.
    private let queue = DispatchQueue(label: "nikxel.mic")
    private var startedAt = Date()
    private var framesWritten: AVAudioFramePosition = 0
    private(set) var url: URL?
    private(set) var isRecording = false
    var isMuted: Bool = false

    enum MicError: Error { case permissionDenied, fileCreateFailed, engineStartFailed(String) }

    static func warmUpPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func start(outputURL: URL) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MicError.permissionDenied
        }
        do {
            file = try AVAudioFile(forWriting: outputURL, settings: fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw MicError.fileCreateFailed
        }
        url = outputURL
        startedAt = Date(); framesWritten = 0
        do { try startEngine() } catch { file = nil; throw error }
        isRecording = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] n in
            guard let self, (n.object as AnyObject?) === self.engine else { return }
            self.queue.async { self.restart(attempt: 1) }
        }
    }

    /// A fresh engine on whatever the default input is now. A reused engine keeps the input
    /// format it first saw, and installTap then throws a format-mismatch NSException that
    /// Swift can't catch.
    private func startEngine() throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0, let converter = AVAudioConverter(from: fmt, to: fileFormat) else {
            throw MicError.engineStartFailed("no input device")
        }
        converter.downmix = true
        cblog("MicRecorder: input \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch")
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self, let out = self.convert(buf, converter) else { return }
            self.queue.async { self.write(out) }
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw MicError.engineStartFailed(error.localizedDescription)
        }
    }

    /// The device changed under a running engine. Right after a Bluetooth switch there can be
    /// no input for a moment, so a few tries a second apart.
    private func restart(attempt: Int) {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
            cblog("MicRecorder: restarted after a device change")
        } catch {
            cblog("MicRecorder: restart \(attempt) failed: \(error)")
            if attempt < 5 { queue.asyncAfter(deadline: .now() + 1) { self.restart(attempt: attempt + 1) } }
        }
    }

    private func convert(_ buf: AVAudioPCMBuffer, _ converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * fileFormat.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return nil }
        var fed = false, error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// On `queue`. A gap of half a second or more (a device switch) is filled with silence first.
    private func write(_ buf: AVAudioPCMBuffer) {
        guard let f = file else { return }
        let due = AVAudioFramePosition(Date().timeIntervalSince(startedAt) * fileFormat.sampleRate) - AVAudioFramePosition(buf.frameLength)
        if due - framesWritten >= AVAudioFramePosition(fileFormat.sampleRate / 2),
           let gap = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(due - framesWritten)) {
            gap.frameLength = gap.frameCapacity
            memset(gap.floatChannelData![0], 0, Int(gap.frameLength) * MemoryLayout<Float>.size)
            try? f.write(from: gap)
            framesWritten += AVAudioFramePosition(gap.frameLength)
        }
        // Muted: silence, which keeps the mic timeline aligned with the system-audio one.
        if isMuted, let ch = buf.floatChannelData { memset(ch[0], 0, Int(buf.frameLength) * MemoryLayout<Float>.size) }
        try? f.write(from: buf)
        framesWritten += AVAudioFramePosition(buf.frameLength)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        queue.sync {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            file = nil
        }
    }
}
