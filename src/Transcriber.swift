import Foundation

class Transcriber {
    enum TranscriberError: Error {
        case binaryNotFound
        case failed(String)
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

    private func findBinary() -> String? {
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

    private func runWhisper(binary: String, input: URL, format: OutputFormat) throws -> URL {
        let outDir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let ext = format.rawValue
        let txtURL = outDir.appendingPathComponent("\(stem).\(ext)")
        let altTxtURL = outDir.appendingPathComponent("\(stem).wav.\(ext)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = [
            input.path,
            "--model", "base",
            "--output_format", ext,
            "--output_dir", outDir.path,
            "--fp16", "False"
        ]
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
        if fm.fileExists(atPath: txtURL.path) { return txtURL }
        // whisper.cpp writes <name>.wav.txt; rename to the expected <name>.txt path.
        if fm.fileExists(atPath: altTxtURL.path) {
            try? fm.removeItem(at: txtURL)
            try? fm.moveItem(at: altTxtURL, to: txtURL)
            if fm.fileExists(atPath: txtURL.path) { return txtURL }
            return altTxtURL
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
