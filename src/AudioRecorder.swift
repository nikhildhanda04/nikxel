import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

enum RecordingArtifacts {
    case merged(URL)
    case split(mic: URL?, sys: URL)
}

protocol AudioRecorderDelegate: AnyObject {
    func recorderDidStart()
    func recorderDidStop(artifacts: RecordingArtifacts?, error: Error?)
}

class AudioRecorder: NSObject {
    weak var delegate: AudioRecorderDelegate?
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    // Write raw Float32 interleaved via ExtAudioFile to avoid AVAudioFile format mismatch
    private var extAudioFile: ExtAudioFileRef?
    private var sysURL: URL?     // raw system audio capture
    private var outputURL: URL?  // final merged WAV passed to delegate (notes mode only)
    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// Set by the coordinator before start(). Captured at start time; mid-recording
    /// menu toggles do not affect an in-flight session.
    var captureMode: CaptureMode = .notes
    private var activeMode: CaptureMode = .notes

    let mic = MicRecorder()
    private var micURL: URL?
    var isMicMuted: Bool {
        get { mic.isMuted }
        set {
            mic.isMuted = newValue
            UserDefaults.standard.set(newValue, forKey: "nikxel.micMuted")
        }
    }

    override init() {
        super.init()
        mic.isMuted = UserDefaults.standard.bool(forKey: "nikxel.micMuted")
    }

    // Call this on app launch to trigger the TCC prompt once, before user hits record.
    func warmUpPermission() {
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        MicRecorder.warmUpPermission()
    }

    func start() {
        guard !isRecording else { return }
        self.activeMode = self.captureMode
        Task { await beginCapture() }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        let sysURL = self.sysURL
        let micURL = self.micURL
        let finalURL = self.outputURL
        let mode = self.activeMode
        Task { [weak self] in
            guard let self = self else { return }
            do { try await self.stream?.stopCapture() } catch { print("stop: \(error)") }
            self.stream = nil
            self.streamOutput = nil
            if let ef = self.extAudioFile { ExtAudioFileDispose(ef) }
            self.extAudioFile = nil
            self.mic.stop()

            let artifacts: RecordingArtifacts?
            switch mode {
            case .notes:
                // Mix mic + system into one WAV (or fall back to system-only).
                if let merged = self.mergeIfPossible(sys: sysURL, mic: micURL, out: finalURL) {
                    artifacts = .merged(merged)
                } else {
                    artifacts = nil
                }
            case .meeting:
                // Keep tracks separate for per-speaker transcription. The placeholder
                // merged file path is unused — remove it if it somehow exists.
                if let finalURL = finalURL { try? FileManager.default.removeItem(at: finalURL) }
                if let sys = sysURL, FileManager.default.fileExists(atPath: sys.path) {
                    let mic = (micURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
                    artifacts = .split(mic: mic, sys: sys)
                } else {
                    artifacts = nil
                }
            }
            DispatchQueue.main.async { self.delegate?.recorderDidStop(artifacts: artifacts, error: nil) }
        }
    }

    private func mergeIfPossible(sys: URL?, mic: URL?, out: URL?) -> URL? {
        guard let sys = sys, let out = out else { return out ?? sys }
        let fm = FileManager.default
        guard fm.fileExists(atPath: sys.path), let micURL = mic, fm.fileExists(atPath: micURL.path) else {
            // No mic file → just rename sys to final.
            try? fm.removeItem(at: out)
            try? fm.moveItem(at: sys, to: out)
            return out
        }
        guard let ffmpeg = findFfmpeg() else {
            print("ffmpeg not found — using system audio only")
            try? fm.removeItem(at: out)
            try? fm.moveItem(at: sys, to: out)
            try? fm.removeItem(at: micURL)
            return out
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffmpeg)
        task.arguments = [
            "-y", "-loglevel", "error",
            "-i", sys.path,
            "-i", micURL.path,
            "-filter_complex", "[0:a]aformat=channel_layouts=stereo[a0];[1:a]aformat=channel_layouts=stereo,volume=1.5[a1];[a0][a1]amix=inputs=2:duration=longest:dropout_transition=0[a]",
            "-map", "[a]",
            "-ac", "2", "-ar", "48000",
            out.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        task.environment = env
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("ffmpeg mix failed to launch: \(error)")
            try? fm.removeItem(at: out)
            try? fm.moveItem(at: sys, to: out)
            try? fm.removeItem(at: micURL)
            return out
        }
        if task.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            print("ffmpeg mix failed: \(String(data: errData, encoding: .utf8) ?? "exit \(task.terminationStatus)")")
            try? fm.removeItem(at: out)
            try? fm.moveItem(at: sys, to: out)
            try? fm.removeItem(at: micURL)
            return out
        }
        // Mix succeeded — clean up the per-track temp files.
        try? fm.removeItem(at: sys)
        try? fm.removeItem(at: micURL)
        return out
    }

    private func findFfmpeg() -> String? {
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func beginCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw err("No display") }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            // Minimal video — required by SCStream but we discard it
            config.width = 2; config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let finalURL = makeOutputURL()
            self.outputURL = finalURL
            // System audio goes to a temp track that gets ffmpeg-mixed with mic.
            let stem = finalURL.deletingPathExtension().lastPathComponent
            let dir = finalURL.deletingLastPathComponent()
            let sysTrack = dir.appendingPathComponent("\(stem)_sys.wav")
            let micTrack = dir.appendingPathComponent("\(stem)_mic.wav")
            self.sysURL = sysTrack
            self.micURL = micTrack
            let url = sysTrack

            // Create output file: 16-bit PCM WAV via ExtAudioFile (handles Float32→Int16 internally)
            var fileRef: ExtAudioFileRef?
            var wavFmt = AudioStreamBasicDescription(
                mSampleRate: 48000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            let status = ExtAudioFileCreateWithURL(
                url as CFURL, kAudioFileWAVEType, &wavFmt, nil,
                AudioFileFlags.eraseFile.rawValue, &fileRef
            )
            guard status == noErr, let ef = fileRef else {
                throw err("ExtAudioFile create failed: \(status)")
            }

            // Tell ExtAudioFile what format the client (us) will provide — Float32 non-interleaved
            var clientFmt = AudioStreamBasicDescription(
                mSampleRate: 48000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            ExtAudioFileSetProperty(ef, kExtAudioFileProperty_ClientDataFormat,
                                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFmt)
            self.extAudioFile = ef

            let output = AudioStreamOutput()
            output.recorder = self
            streamOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "nikxel.audio"))
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "nikxel.vid"))
            self.stream = stream

            try await stream.startCapture()
            // Mic capture runs in parallel. Failure to start is non-fatal —
            // recording continues with system audio only.
            if let micURL = self.micURL {
                do { try self.mic.start(outputURL: micURL) }
                catch { print("Mic capture unavailable: \(error). Recording system audio only.") }
            }
            isRecording = true
            startedAt = Date()
            DispatchQueue.main.async { [weak self] in self?.delegate?.recorderDidStart() }
        } catch {
            print("AudioRecorder error: \(error)")
            DispatchQueue.main.async { [weak self] in self?.delegate?.recorderDidStop(artifacts: nil, error: error) }
        }
    }

    fileprivate func handleAudio(buffer: CMSampleBuffer) {
        guard let ef = extAudioFile else { return }
        guard let fmt = CMSampleBufferGetFormatDescription(buffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }

        let fc = CMSampleBufferGetNumSamples(buffer)
        guard fc > 0 else { return }

        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        var len: Int = 0
        var srcPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &len, dataPointerOut: &srcPtr) == noErr,
              let src = srcPtr else { return }

        let inCh = Int(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        // Deinterleave into two Float32 buffers for ExtAudioFile
        var ch0 = [Float](repeating: 0, count: fc)
        var ch1 = [Float](repeating: 0, count: fc)

        if isFloat {
            src.withMemoryRebound(to: Float.self, capacity: len / 4) { fp in
                for i in 0..<fc {
                    ch0[i] = fp[isInterleaved ? i * inCh + 0 : i]
                    ch1[i] = inCh > 1 ? fp[isInterleaved ? i * inCh + 1 : fc + i] : fp[isInterleaved ? i * inCh + 0 : i]
                }
            }
        } else {
            src.withMemoryRebound(to: Int16.self, capacity: len / 2) { ip in
                let scale: Float = 1.0 / 32768.0
                for i in 0..<fc {
                    ch0[i] = Float(ip[isInterleaved ? i * inCh + 0 : i]) * scale
                    ch1[i] = inCh > 1 ? Float(ip[isInterleaved ? i * inCh + 1 : fc + i]) * scale * scale
                                      : Float(ip[isInterleaved ? i * inCh + 0 : i]) * scale
                }
            }
        }

        // Use AudioBufferList.allocate for multi-buffer layout (Swift can't init >1 mBuffers inline)
        ch0.withUnsafeMutableBufferPointer { p0 in
            ch1.withUnsafeMutableBufferPointer { p1 in
                let abl = AudioBufferList.allocate(maximumBuffers: 2)
                abl.count = 2
                abl[0] = AudioBuffer(mNumberChannels: 1,
                                     mDataByteSize: UInt32(fc * 4),
                                     mData: UnsafeMutableRawPointer(p0.baseAddress!))
                abl[1] = AudioBuffer(mNumberChannels: 1,
                                     mDataByteSize: UInt32(fc * 4),
                                     mData: UnsafeMutableRawPointer(p1.baseAddress!))
                ExtAudioFileWrite(ef, UInt32(fc), abl.unsafeMutablePointer)
                abl.unsafeMutablePointer.deallocate()
            }
        }
    }

    private func makeOutputURL() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return dir.appendingPathComponent("\(fmt.string(from: Date())).wav")
    }

    private func err(_ msg: String) -> Error {
        NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

private class AudioStreamOutput: NSObject, SCStreamOutput {
    weak var recorder: AudioRecorder?
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        recorder?.handleAudio(buffer: sampleBuffer)
    }
}
