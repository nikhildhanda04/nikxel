import Foundation

class Transcriber {
    enum TranscriberError: Error {
        case binaryNotFound
        case modelMissing
        case failed(String)
    }

    /// Which whisper CLI we found. The two take completely different flags, so
    /// passing one's arguments to the other just prints a usage dump -- which is
    /// exactly what happened when the setup wizard's Homebrew button installed
    /// whisper.cpp on a machine and the Python flags were sent to it.
    enum Flavor {
        /// openai-whisper, the Python one: `whisper file --model base ...`
        case python
        /// whisper.cpp: `whisper-cli -m model.bin -f file -osrt -of stem`
        case cpp

        static func of(binary: String) -> Flavor {
            let name = (binary as NSString).lastPathComponent
            return name.contains("whisper-cli") || name.contains("whisper-cpp") ? .cpp : .python
        }
    }

    enum OutputFormat: String {
        case txt, srt
    }

    private var candidateBinaries: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper",
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
            "\(home)/.local/bin/whisper",
            "\(home)/Library/Python/3.9/bin/whisper",
            "\(home)/Library/Python/3.10/bin/whisper",
            "\(home)/Library/Python/3.11/bin/whisper",
            "\(home)/Library/Python/3.12/bin/whisper",
            "\(home)/Library/Python/3.13/bin/whisper",
        ]
    }

    func transcribe(audioURL: URL, outputFormat: OutputFormat = .txt, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let bin = self.findBinary() else {
                completion(.failure(TranscriberError.binaryNotFound))
                return
            }
            do {
                let outputURL = try self.runWhisper(binary: bin, input: audioURL, format: outputFormat)
                completion(.success(outputURL))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func findBinary() -> String? {
        for path in candidateBinaries where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fallback: ask shell
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-l", "-c", "which whisper 2>/dev/null || which whisper-cli 2>/dev/null"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = path, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// Rewrites a transcript in Latin letters if whisper returned Devanagari.
    /// Hindi is wanted as Hinglish, not Devanagari, in both the saved
    /// transcript and anything built from it.
    private func romanized(_ url: URL) -> URL {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              Devanagari.contains(text) else { return url }
        let converted = Devanagari.romanize(text)
        try? converted.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runWhisper(binary: String, input: URL, format: OutputFormat) throws -> URL {
        let outDir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let ext = format.rawValue
        let txtURL = outDir.appendingPathComponent("\(stem).\(ext)")
        let altTxtURL = outDir.appendingPathComponent("\(stem).wav.\(ext)")

        let flavor = Flavor.of(binary: binary)
        let outStem = outDir.appendingPathComponent(stem).path

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        switch flavor {
        case .python:
            var args = [
                input.path,
                "--model", "base",
                "--output_format", ext,
                "--output_dir", outDir.path,
                "--fp16", "False"
            ]
            // Python whisper auto-detects when --language is omitted.
            let lang = NikxelSettings.transcriptionLanguage
            if lang.lowercased() != "auto" { args += ["--language", lang] }
            task.arguments = args
        case .cpp:
            // whisper.cpp needs an explicit ggml model -- Homebrew ships the
            // binaries without one. It decodes our 48 kHz recordings directly
            // (miniaudio), so no resampling step is needed. -np keeps stdout to
            // just the transcript.
            guard let model = WhisperModel.installedPath() else { throw TranscriberError.modelMissing }
            // whisper.cpp defaults to -l en, which would push Hindi and
            // Hinglish speech through English. "auto" detects per recording.
            task.arguments = [
                "-m", model,
                "-f", input.path,
                format == .srt ? "-osrt" : "-otxt",
                "-of", outStem,
                "-l", NikxelSettings.transcriptionLanguage,
                "-np"
            ]
        }
        // whisper shells out to ffmpeg for audio decoding. Apps launched from Finder
        // don't inherit the shell PATH, so we extend it explicitly. Without this,
        // whisper prints "Skipping ... FileNotFoundError: ffmpeg" and exits 0,
        // producing no transcript file.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        task.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        try? outData.write(to: outDir.appendingPathComponent("\(stem).whisper.stdout.log"))
        try? errData.write(to: outDir.appendingPathComponent("\(stem).whisper.stderr.log"))

        let fm = FileManager.default
        if fm.fileExists(atPath: txtURL.path) { return romanized(txtURL) }
        // whisper.cpp writes <name>.wav.txt; rename to the expected <name>.txt path.
        if fm.fileExists(atPath: altTxtURL.path) {
            try? fm.removeItem(at: txtURL)
            try? fm.moveItem(at: altTxtURL, to: txtURL)
            if fm.fileExists(atPath: txtURL.path) { return romanized(txtURL) }
            return romanized(altTxtURL)
        }

        let errStr = String(data: errData, encoding: .utf8) ?? ""
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let combined = !errStr.isEmpty ? errStr : outStr
        let detail = combined.isEmpty
            ? "whisper exited \(task.terminationStatus) but produced no transcript file."
            : String(combined.suffix(600))
        throw TranscriberError.failed("\(detail)\n\nExpected: \(txtURL.path)\nBinary: \(binary)\nLogs: \(outDir.path)/\(stem).whisper.{stdout,stderr}.log")
    }
}


/// The ggml model whisper.cpp needs. Homebrew installs the binaries without
/// one, so Nikxel keeps its own under ~/.nikxel/models.
enum WhisperModel {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".nikxel/models", isDirectory: true)

    /// Small, not base: the base model cannot do Hindi at all -- it transcribes
    /// it into Urdu script even when told -l hi. Small gets it right. Must be a
    /// multilingual build (not a .en variant), which can't do Hindi either.
    static let defaultName = "ggml-small.bin"
    static let defaultSourceURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
    static let defaultDownloadSize = "466 MB"

    /// Bigger models transcribe Hindi noticeably better, so prefer whichever
    /// the user has: dropping a ggml-medium.bin in the folder is all it takes.
    private static let preference = [
        "ggml-large-v3-turbo.bin", "ggml-large-v3.bin", "ggml-medium.bin",
        "ggml-small.bin", "ggml-base.bin",
    ]

    static func installedPath() -> String? {
        let fm = FileManager.default
        for name in preference {
            let url = directory.appendingPathComponent(name)
            if fm.isReadableFile(atPath: url.path) { return url.path }
        }
        // Any other ggml-*.bin the user dropped in, English-only ones last.
        guard let all = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        let candidates = all.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
            .sorted { a, b in a.contains(".en.") == b.contains(".en.") ? a < b : !a.contains(".en.") }
        guard let first = candidates.first else { return nil }
        return directory.appendingPathComponent(first).path
    }

    static var isInstalled: Bool { installedPath() != nil }

    /// Downloads the default model. `progress` gets 0...1 on the main queue.
    static func downloadDefault(
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(defaultName)
        let delegate = DownloadDelegate(destination: destination, progress: progress, completion: completion)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        // Keep a reference alive for the lifetime of the transfer; the delegate
        // invalidates the session once it finishes.
        delegate.session = session
        session.downloadTask(with: defaultSourceURL).resume()
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let destination: URL
        let progress: (Double) -> Void
        let completion: (Result<URL, Error>) -> Void
        var session: URLSession?

        init(destination: URL, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
            self.destination = destination
            self.progress = progress
            self.completion = completion
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async { self.progress(fraction) }
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let fm = FileManager.default
            do {
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: location, to: destination)
                DispatchQueue.main.async { self.completion(.success(self.destination)) }
            } catch {
                DispatchQueue.main.async { self.completion(.failure(error)) }
            }
            s.invalidateAndCancel()
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                DispatchQueue.main.async { self.completion(.failure(error)) }
                s.invalidateAndCancel()
            }
        }
    }
}
