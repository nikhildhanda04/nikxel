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
    /// Neither the call nor the mic has had any sound for a while, even after a restart.
    func recorderHearsNothing(micMuted: Bool)
}

/// Peak levels for the logs and the silence check.
enum AudioLevel {
    /// About -54 dBFS: under any real room or voice, over a digitally silent stream.
    static let soundFloor: Float = 0.002
    static func peak(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        var m: Float = 0
        for i in 0..<n { m = max(m, abs(p[i])) }
        return m
    }
    static func db(_ peak: Float) -> String { peak > 0 ? String(format: "%.0f dBFS", 20 * log10(peak)) : "silent" }
}

class AudioRecorder: NSObject {
    weak var delegate: AudioRecorderDelegate?
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    /// Kept so a stream macOS stops mid-meeting (a phone call or headset taking
    /// over the audio device) can be restarted onto the same file.
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private let audioQueue = DispatchQueue(label: "nikxel.audio")
    /// Frames written to the system track; any shortfall against the wall clock
    /// is filled with silence so it stays aligned with the mic and Meet's speakers.
    private var sysFrames: Int64 = 0
    private var lastSampleAt = Date()
    private var watchdog: DispatchSourceTimer?
    private var lastSysSound = Date()
    private var sysSoundFrames: Int64 = 0
    private var sysPeak: Float = 0
    /// Once per stretch of total silence: restart both captures at 45 s, warn at 90 s.
    private var silenceRestarted = false
    private var silenceWarned = false
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

    /// Tracks the in-flight stop teardown. The next start() awaits this before
    /// kicking off beginCapture so the two Tasks don't race on self.stream /
    /// self.extAudioFile / self.mic.
    private var teardownTask: Task<Void, Never>?

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
        // If a previous stop() is still tearing down the SCStream / ExtAudioFile /
        // mic, wait for it to finish before we start the new capture. Otherwise
        // the teardown Task can nil out the new stream after beginCapture set it.
        let priorTeardown = self.teardownTask
        Task { [weak self] in
            if let prior = priorTeardown { await prior.value }
            await self?.beginCapture()
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        watchdog?.cancel(); watchdog = nil
        let secs = Int(Date().timeIntervalSince(startedAt ?? Date()))
        let sysLine = audioQueue.sync { "\(sysFrames / 48000) s, sound in \(sysSoundFrames / 48000) s, peak \(AudioLevel.db(sysPeak))" }
        cblog("AudioRecorder: stopped after \(secs) s — call audio: \(sysLine); mic: \(mic.isRecording ? mic.summary : "not recording")")
        let sysURL = self.sysURL
        let micURL = self.micURL
        let finalURL = self.outputURL
        let mode = self.activeMode
        let task = Task<Void, Never> { [weak self] in
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
        self.teardownTask = task
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

            self.filter = filter
            self.config = config
            audioQueue.sync { self.sysFrames = 0; self.sysSoundFrames = 0; self.sysPeak = 0 }
            lastSysSound = Date(); silenceRestarted = false; silenceWarned = false
            startedAt = nil
            let stream = try makeStream(filter: filter, config: config)
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
            lastSampleAt = Date()
            startWatchdog()
            DispatchQueue.main.async { [weak self] in self?.delegate?.recorderDidStart() }
        } catch {
            print("AudioRecorder error: \(error)")
            DispatchQueue.main.async { [weak self] in self?.delegate?.recorderDidStop(artifacts: nil, error: error) }
        }
    }

    private func makeStream(filter: SCContentFilter, config: SCStreamConfiguration) throws -> SCStream {
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(streamOutput!, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: DispatchQueue(label: "nikxel.vid"))
        return stream
    }

    /// No system audio for 4 s means the stream died quietly (macOS doesn't
    /// always report it), so start a fresh one. Retries every 4 s until it takes.
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self = self, self.isRecording else { return }
            if Date().timeIntervalSince(self.lastSampleAt) > 4 { self.restartStream(why: "no system audio for 4 s") }
            self.checkSilence()
        }
        t.resume()
        watchdog = t
    }

    /// Both tracks silent. A capture can run dead silent with nothing reporting
    /// an error (a whole 17-minute meeting came out empty that way) and a fresh
    /// start brought it back, so restart both; if that doesn't help, tell the
    /// user while the call is still on.
    private func checkSilence() {
        let quiet = Date().timeIntervalSince(max(lastSysSound, mic.isRecording ? mic.lastSound : .distantPast))
        if quiet < 45 { silenceRestarted = false; silenceWarned = false; return }
        if !silenceRestarted {
            silenceRestarted = true
            cblog("AudioRecorder: no sound from the call or the mic for \(Int(quiet)) s — restarting both")
            restartStream(why: "silent")
            if mic.isRecording { mic.restartNow() }
        } else if quiet >= 90 && !silenceWarned {
            silenceWarned = true
            cblog("AudioRecorder: still silent after \(Int(quiet)) s — warning the user (mic muted: \(mic.isMuted))")
            delegate?.recorderHearsNothing(micMuted: mic.isMuted)
        }
    }

    private func restartStream(why: String) {
        guard isRecording, let filter = filter, let config = config else { return }
        lastSampleAt = Date()
        cblog("AudioRecorder: restarting system audio (\(why))")
        let old = stream
        Task { [weak self] in
            try? await old?.stopCapture()
            guard let self = self, self.isRecording else { return }
            do {
                let s = try self.makeStream(filter: filter, config: config)
                try await s.startCapture()
                guard self.isRecording else { try? await s.stopCapture(); return }
                self.stream = s
                cblog("AudioRecorder: system audio restarted")
            } catch {
                cblog("AudioRecorder: system audio restart failed: \(error)")
            }
        }
    }

    /// On audioQueue. Writes `frames` of silence in 1 s blocks.
    private func writeSilence(_ ef: ExtAudioFileRef, frames: Int64) {
        var left = frames
        var zeros = [Float](repeating: 0, count: 48000)
        while left > 0 {
            let n = Int(min(left, 48000))
            zeros.withUnsafeMutableBufferPointer { z in
                let abl = AudioBufferList.allocate(maximumBuffers: 2)
                abl.count = 2
                for i in 0..<2 {
                    abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(z.baseAddress!))
                }
                ExtAudioFileWrite(ef, UInt32(n), abl.unsafeMutablePointer)
                abl.unsafeMutablePointer.deallocate()
            }
            left -= Int64(n)
        }
        sysFrames += frames
    }

    fileprivate func handleAudio(buffer: CMSampleBuffer) {
        guard let ef = extAudioFile else { return }
        lastSampleAt = Date()
        guard let fmt = CMSampleBufferGetFormatDescription(buffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }

        let fc = CMSampleBufferGetNumSamples(buffer)
        guard fc > 0 else { return }

        // A gap of half a second or more (the stream was down) becomes silence.
        if let started = startedAt {
            let due = Int64(Date().timeIntervalSince(started) * 48000) - Int64(fc)
            if due - sysFrames >= 24000 { writeSilence(ef, frames: due - sysFrames) }
        }

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
                    ch1[i] = inCh > 1 ? Float(ip[isInterleaved ? i * inCh + 1 : fc + i]) * scale
                                      : Float(ip[isInterleaved ? i * inCh + 0 : i]) * scale
                }
            }
        }

        let p = max(AudioLevel.peak(ch0, fc), AudioLevel.peak(ch1, fc))
        sysPeak = max(sysPeak, p)
        if p >= AudioLevel.soundFloor { lastSysSound = Date(); sysSoundFrames += Int64(fc) }

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
        sysFrames += Int64(fc)
    }

    private func makeOutputURL() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nikxel/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Seconds in the stem so back-to-back recordings within the same minute
        // don't collide on the merged WAV path or the per-track sys/mic temp files.
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return dir.appendingPathComponent("\(fmt.string(from: Date())).wav")
    }

    private func err(_ msg: String) -> Error {
        NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

extension AudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        cblog("AudioRecorder: system audio stopped by macOS: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, stream === self.stream else { return }
            self.restartStream(why: "stopped by macOS")
        }
    }
}

private class AudioStreamOutput: NSObject, SCStreamOutput {
    weak var recorder: AudioRecorder?
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        recorder?.handleAudio(buffer: sampleBuffer)
    }
}
