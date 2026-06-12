import Foundation
import AVFoundation

class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
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
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw MicError.engineStartFailed("no input device") }

        do {
            self.file = try AVAudioFile(
                forWriting: outputURL,
                settings: fmt.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MicError.fileCreateFailed
        }
        self.url = outputURL

        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self = self, let f = self.file else { return }
            if self.isMuted {
                // Write a zero-filled buffer to keep the mic timeline aligned with
                // the system-audio timeline. ffmpeg amix can then mix cleanly.
                guard let silence = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return }
                silence.frameLength = buf.frameLength
                if let chans = silence.floatChannelData {
                    let ch = Int(silence.format.channelCount)
                    for c in 0..<ch {
                        memset(chans[c], 0, Int(buf.frameLength) * MemoryLayout<Float>.size)
                    }
                }
                try? f.write(from: silence)
            } else {
                try? f.write(from: buf)
            }
        }

        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw MicError.engineStartFailed(error.localizedDescription)
        }
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        isRecording = false
    }
}
