import AppKit
import SwiftUI

/// First-run (and reopenable-anytime, via the status bar) setup wizard:
/// connect WhatsApp, then pick which coding agent Nikxel should shell out to.
final class OnboardingWindowController: NSWindowController {
    private let momGenerator: MOMGenerator

    init(momGenerator: MOMGenerator) {
        self.momGenerator = momGenerator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Set up Nikxel"
        window.center()
        // Keep the controller (and window) alive across hide/show instead of
        // being deallocated on close, so "Setup Wizard…" can reopen the same
        // window with its current step/state intact.
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let rootView = OnboardingView(momGenerator: momGenerator, onFinish: { [weak self] in
            self?.close()
        })
        window.contentView = NSHostingView(rootView: rootView)
    }

    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController does not support NSCoding")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct OnboardingView: View {
    enum Step { case welcome, avatar, deps, whatsapp, agent }

    let momGenerator: MOMGenerator
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var waConnecting = false
    @State private var waConnected = NikxelSettings.whatsappConnected
    @State private var waPollTimer: Timer?
    @State private var chosenAgent: CodingAgent = NikxelSettings.connectedAgent
    @State private var availableAgents: Set<CodingAgent> = []
    @State private var whisperFound = false
    @State private var ffmpegFound = false
    @State private var brewFound = false
    @State private var depsChecked = false
    @State private var previewFrames: [NSImage] = []
    @State private var previewIndex = 0
    @State private var previewTimer: Timer?
    @State private var usingCustomSheet = NikxelSprites.hasCustom
    @State private var sheetError: String?
    @State private var promptCopied = false
    @State private var importing = false

    var body: some View {
        Group {
            switch step {
            case .welcome: welcomeStep
            case .avatar: avatarStep
            case .deps: depsStep
            case .whatsapp: whatsappStep
            case .agent: agentStep
            }
        }
        .padding(28)
        .frame(width: 440, height: 420)
        .onAppear { refreshAvailableAgents(); refreshDeps() }
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            if let img = Self.avatarImage() {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)   // keep the pixel art crisp when scaled up
                    .frame(width: 96, height: 96)
            }
            Text("Welcome to Nikxel").font(.title2).bold()
            Text("Let's check the transcription tools, connect WhatsApp auto-replies, and pick which coding agent Nikxel should use — takes about a minute.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { step = .avatar }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var whatsappStep: some View {
        VStack(spacing: 16) {
            Text("Connect WhatsApp").font(.title2).bold()
            Text("Nikxel can reply on your behalf while you're in a meeting. Click Connect, then scan the QR code in the Chrome window that opens.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if waConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if waConnecting {
                ProgressView("Waiting for QR scan…")
            } else {
                Button("Connect WhatsApp") { startWhatsAppConnect() }
            }

            Spacer()
            HStack {
                Button("Back") { stopPolling(); step = .deps }
                Button("Skip for now") { stopPolling(); step = .agent }
                Spacer()
                if waConnected {
                    Button("Next") { stopPolling(); step = .agent }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onDisappear(perform: stopPolling)
    }

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your coding agent").font(.title2).bold()
            Text("Nikxel shells out to this to write meeting notes/MOMs and WhatsApp replies.")
                .foregroundStyle(.secondary)

            ForEach(CodingAgent.allCases, id: \.self) { agent in
                let available = availableAgents.contains(agent)
                Button {
                    if available { chosenAgent = agent }
                } label: {
                    HStack {
                        Image(systemName: chosenAgent == agent ? "largecircle.fill.circle" : "circle")
                        Text(agent.displayName)
                        Spacer()
                        if !available {
                            Text("not installed").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .opacity(available ? 1 : 0.5)
            }

            Spacer()
            HStack {
                Button("Back") { step = .whatsapp }
                Spacer()
                Button("Finish") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // The sprite sheet drives every animation state, so a user-supplied one has
    // to match the grid exactly. Showing the idle row animating is the only
    // honest preview -- a single static frame hides a wrong row layout.
    private var avatarStep: some View {
        VStack(spacing: 14) {
            Text("Your avatar").font(.title2).bold()

            if let frame = previewFrames.isEmpty ? nil : previewFrames[previewIndex % previewFrames.count] {
                Image(nsImage: frame)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 128, height: 128)
            }

            Text(usingCustomSheet ? "Using your own sprite sheet." : "Using the avatar that ships with Nikxel.")
                .foregroundStyle(.secondary)

            if let err = sheetError {
                Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            HStack {
                Button(promptCopied ? "Prompt copied ✓" : "Copy Gemini prompt") { copyPrompt() }
                Button("Use my own sprite sheet…") { chooseSheet() }
                    .disabled(importing)
                if usingCustomSheet {
                    Button("Reset to default") { resetSheet() }
                }
            }

            if importing {
                ProgressView("Processing sheet…")
            }

            Text("Paste the prompt into Gemini along with a photo of yourself, then load the PNG it gives you straight back here — Nikxel removes the magenta background and re-frames it for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("PNG, \(NikxelSprites.cols) columns x \(NikxelSprites.rows) rows of \(NikxelSprites.frameSize)px frames (\(NikxelSprites.cols * NikxelSprites.frameSize)x\(NikxelSprites.rows * NikxelSprites.frameSize)). One row per state: idle, typing, thinking, done, dragging, pounce, petted, alert, recording, MOM ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            HStack {
                Button("Back") { step = .welcome }
                Spacer()
                Button("Next") { step = .deps }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear(perform: startPreview)
        .onDisappear(perform: stopPreview)
    }

    private func copyPrompt() {
        guard let path = Bundle.main.path(forResource: "sprite_prompt", ofType: "txt"),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            sheetError = "Couldn't find the bundled prompt."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        promptCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { promptCopied = false }
    }

    private func chooseSheet() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["png"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Pick the sprite sheet Gemini gave you"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        sheetError = nil
        importing = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Keys out the magenta, re-frames every cell and resizes to
                // 256x640 -- whatever Gemini returned, this is what makes it
                // usable, so the user never has to run remove_magenta.py.
                let data = try SpriteSheetImporter.process(url: url)
                try? FileManager.default.removeItem(at: NikxelSprites.customURL)
                try data.write(to: NikxelSprites.customURL)
                DispatchQueue.main.async {
                    importing = false
                    usingCustomSheet = true
                    NotificationCenter.default.post(name: NikxelSprites.changedNotification, object: nil)
                    startPreview()
                }
            } catch {
                DispatchQueue.main.async {
                    importing = false
                    sheetError = error.localizedDescription
                }
            }
        }
    }

    private func resetSheet() {
        try? FileManager.default.removeItem(at: NikxelSprites.customURL)
        sheetError = nil
        usingCustomSheet = NikxelSprites.hasCustom
        NotificationCenter.default.post(name: NikxelSprites.changedNotification, object: nil)
        startPreview()
    }

    private func startPreview() {
        previewFrames = Self.idleFrames()
        previewIndex = 0
        previewTimer?.invalidate()
        // 3 fps, same rate NikxelView animates the idle row at.
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 3, repeats: true) { _ in
            previewIndex += 1
        }
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    /// Row 0 of the active sheet -- the idle animation.
    private static func idleFrames() -> [NSImage] {
        guard let path = NikxelSprites.activePath,
              let sheet = NSImage(contentsOfFile: path),
              let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let f = NikxelSprites.frameSize
        return (0..<NikxelSprites.cols).compactMap { col in
            cg.cropping(to: CGRect(x: col * f, y: 0, width: f, height: f))
                .map { NSImage(cgImage: $0, size: NSSize(width: f, height: f)) }
        }
    }

    // Meeting transcription shells out to whisper (speech-to-text) and ffmpeg
    // (audio decode). Neither ships with the app, and without them recording
    // produces an audio file and nothing else — so surface it during setup
    // instead of letting the first meeting fail silently.
    private var depsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription tools").font(.title2).bold()
            Text("Nikxel records meetings, transcribes them with whisper, then has your coding agent write the summary. These two are needed for transcription.")
                .foregroundStyle(.secondary)

            depRow("whisper", found: whisperFound, note: "speech-to-text")
            depRow("ffmpeg", found: ffmpegFound, note: "audio decoding")

            if depsChecked && !(whisperFound && ffmpegFound) {
                if brewFound {
                    Button("Install with Homebrew") { installDeps() }
                    Text("Opens Terminal and runs: brew install whisper-cpp ffmpeg")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Homebrew not found. Install it from brew.sh, then run:\nbrew install whisper-cpp ffmpeg")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Re-check") { refreshDeps() }
            }

            Spacer()
            HStack {
                Button("Back") { step = .avatar }
                Spacer()
                Button(whisperFound && ffmpegFound ? "Next" : "Skip for now") { step = .whatsapp }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func depRow(_ name: String, found: Bool, note: String) -> some View {
        HStack {
            Image(systemName: found ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(found ? Color.green : Color.secondary)
            Text(name)
            Text("— \(note)").foregroundStyle(.secondary)
            Spacer()
            if !found { Text("not installed").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func refreshDeps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let whisper = Transcriber().findBinary() != nil
            let ffmpeg = Self.onPath("ffmpeg")
            let brew = Self.onPath("brew")
            DispatchQueue.main.async {
                whisperFound = whisper
                ffmpegFound = ffmpeg
                brewFound = brew
                depsChecked = true
            }
        }
    }

    private func installDeps() {
        // A .command file so the install runs in Terminal, where the user can
        // watch progress and answer any prompt — a silent background `brew
        // install` would look like a hang for several minutes.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nikxel-install-deps.command")
        let script = "#!/bin/zsh\nset -e\nbrew install whisper-cpp ffmpeg\necho\necho 'Done. Go back to Nikxel and click Re-check.'\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    /// The avatar actually drawn on screen is frame (0,0) of the sprite sheet —
    /// nikxel_avatar.png is only the no-sprite-sheet fallback, so showing it here
    /// meant onboarding greeted the user with a different character than the app.
    private static func avatarImage() -> NSImage? {
        if let path = NikxelSprites.activePath,
           let sheet = NSImage(contentsOfFile: path),
           let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let frame = cg.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 64)) {
            return NSImage(cgImage: frame, size: NSSize(width: 64, height: 64))
        }
        if let path = Bundle.main.path(forResource: "nikxel_avatar", ofType: "png") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }

    private static func onPath(_ name: String) -> Bool {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") { return true }
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-ilc", "which \(name) 2>/dev/null"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !out.isEmpty && FileManager.default.isExecutableFile(atPath: out)
    }

    private func refreshAvailableAgents() {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: Set<CodingAgent> = []
            for agent in CodingAgent.allCases where momGenerator.findBinary(for: agent) != nil {
                found.insert(agent)
            }
            DispatchQueue.main.async {
                availableAgents = found
                if !found.contains(chosenAgent), let firstAvailable = CodingAgent.allCases.first(where: { found.contains($0) }) {
                    chosenAgent = firstAvailable
                }
            }
        }
    }

    private func startWhatsAppConnect() {
        waConnecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ChromeBot.launchIfNeeded()
            DispatchQueue.main.async { beginPolling() }
        }
    }

    private func beginPolling() {
        waPollTimer?.invalidate()
        waPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                guard ChromeWhatsApp.isLoggedIn() else { return }
                DispatchQueue.main.async {
                    waConnected = true
                    waConnecting = false
                    NikxelSettings.whatsappConnected = true
                    stopPolling()
                }
            }
        }
    }

    private func stopPolling() {
        waPollTimer?.invalidate()
        waPollTimer = nil
    }

    private func finish() {
        NikxelSettings.connectedAgent = chosenAgent
        NikxelSettings.onboardingCompleted = true
        onFinish()
    }
}
