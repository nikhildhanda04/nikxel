import AppKit

/// First-run (and reopenable-anytime, via the status bar) setup wizard: pick an
/// avatar, check the transcription tools, connect WhatsApp, and choose which
/// coding agent Nikxel should shell out to.
///
/// Deliberately AppKit, like the rest of the app. The SwiftUI version of this
/// screen only compiled on some Macs: in newer SDKs `@State` is a macro, and a
/// bare `swiftc` build (no Xcode project, no SwiftPM) can't find the
/// SwiftUIMacros plugin, so every property failed to expand and this file threw
/// ~30 errors on a fresh clone. AppKit has no such toolchain dependency.
final class OnboardingWindowController: NSWindowController {
    private enum Step: Int {
        case welcome, avatar, deps, whatsapp, agent
    }

    private let momGenerator: MOMGenerator
    private var step: Step = .welcome

    // Welcome step
    private var nameField: NSTextField?

    // Avatar step
    private var previewFrames: [NSImage] = []
    private var previewIndex = 0
    private var previewTimer: Timer?
    private var previewImageView: NSImageView?
    private var usingCustomSheet = NikxelSprites.hasCustom
    private var sheetError: String?
    private var promptCopied = false
    private var importing = false

    // Dependency step
    private var whisperFound = false
    private var ffmpegFound = false
    private var brewFound = false
    private var depsChecked = false
    private var modelInstalled = false
    private var usingWhisperCpp = false
    private var modelDownloading = false
    private var modelProgress: Double = 0
    private var modelError: String?
    private var modelProgressBar: NSProgressIndicator?
    private var agentCopied: CodingAgent?

    // WhatsApp step
    private var waConnecting = false
    private var waConnected = NikxelSettings.whatsappConnected
    private var waPollTimer: Timer?

    // Agent step
    private var chosenAgent = NikxelSettings.connectedAgent
    private var availableAgents: Set<CodingAgent> = []

    private static let contentWidth: CGFloat = 440
    private static let contentHeight: CGFloat = 440
    private static let padding: CGFloat = 28

    init(momGenerator: MOMGenerator) {
        self.momGenerator = momGenerator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.contentHeight),
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
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.contentHeight))
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController does not support NSCoding")
    }

    deinit {
        previewTimer?.invalidate()
        waPollTimer?.invalidate()
    }

    func show() {
        refreshDeps()
        refreshAvailableAgents()
        if step == .avatar { startPreview() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Rendering

    private func go(to next: Step) {
        if step == .avatar { stopPreview() }
        if step == .whatsapp { stopPolling() }
        step = next
        if next == .avatar { startPreview() }
        render()
    }

    private func render() {
        guard let content = window?.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        previewImageView = nil
        nameField = nil

        let body = NSStackView()
        body.orientation = .vertical
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false

        let nav = NSStackView()
        nav.orientation = .horizontal
        nav.spacing = 8
        nav.translatesAutoresizingMaskIntoConstraints = false

        switch step {
        case .welcome: buildWelcome(body: body, nav: nav)
        case .avatar: buildAvatar(body: body, nav: nav)
        case .deps: buildDeps(body: body, nav: nav)
        case .whatsapp: buildWhatsApp(body: body, nav: nav)
        case .agent: buildAgent(body: body, nav: nav)
        }

        content.addSubview(body)
        content.addSubview(nav)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.padding),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            body.bottomAnchor.constraint(lessThanOrEqualTo: nav.topAnchor, constant: -12),

            nav.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.padding),
            nav.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.padding),
            nav.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.padding),
        ])
    }

    // MARK: - Steps

    private func buildWelcome(body: NSStackView, nav: NSStackView) {
        body.alignment = .centerX
        body.spacing = 16

        if let img = Self.avatarFrame(0) {
            body.addArrangedSubview(imageView(img, size: 96))
        }
        body.addArrangedSubview(label("Welcome to Nikxel", size: 20, bold: true))
        body.addArrangedSubview(label(
            "Let's pick your avatar, check the transcription tools, connect WhatsApp auto-replies, and choose which coding agent Nikxel should use — takes about a minute.",
            secondary: true
        ))

        // Meeting summaries label the mic channel with this name. Without it
        // the summary has to call the user something generic, and a wrong
        // name is worse than none.
        body.addArrangedSubview(label("What should Nikxel call you in your notes?", size: 12, secondary: true))
        let field = NSTextField(string: NikxelSettings.hasUserName ? NikxelSettings.userName : (NikxelSettings.accountFirstName ?? ""))
        field.placeholderString = "Your first name (optional)"
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        nameField = field
        body.addArrangedSubview(field)

        nav.addArrangedSubview(spacer())
        nav.addArrangedSubview(defaultButton("Get Started", #selector(nextFromWelcome)))
    }

    private func buildAvatar(body: NSStackView, nav: NSStackView) {
        body.alignment = .centerX
        body.spacing = 10

        body.addArrangedSubview(label("Your avatar", size: 20, bold: true))

        let preview = imageView(previewFrames.first ?? Self.avatarFrame(0), size: 112)
        previewImageView = preview
        body.addArrangedSubview(preview)

        body.addArrangedSubview(label(
            usingCustomSheet ? "Using your own sprite sheet." : "Using the avatar that ships with Nikxel.",
            secondary: true
        ))

        if let err = sheetError {
            body.addArrangedSubview(label(err, size: 11, color: .systemRed))
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button(promptCopied ? "Prompt copied ✓" : "Copy Gemini prompt", #selector(copyPrompt)))
        let chooser = button("Use my own sprite sheet…", #selector(chooseSheet))
        chooser.isEnabled = !importing
        buttons.addArrangedSubview(chooser)
        if usingCustomSheet {
            buttons.addArrangedSubview(button("Reset to default", #selector(resetSheet)))
        }
        body.addArrangedSubview(buttons)

        if importing {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.addArrangedSubview(spinner)
            row.addArrangedSubview(label("Processing sheet…", size: 11, secondary: true))
            body.addArrangedSubview(row)
        }

        body.addArrangedSubview(label(
            "Paste the prompt into Gemini along with a photo of yourself, then load the PNG it gives you straight back here — Nikxel removes the magenta background and re-frames it for you.",
            size: 11, secondary: true
        ))
        body.addArrangedSubview(label(
            "PNG, \(NikxelSprites.cols) columns x \(NikxelSprites.rows) rows of \(NikxelSprites.frameSize)px frames (\(NikxelSprites.cols * NikxelSprites.frameSize)x\(NikxelSprites.rows * NikxelSprites.frameSize)). One row per state: idle, typing, thinking, done, dragging, pounce, petted, alert, recording, MOM ready.",
            size: 11, secondary: true
        ))

        nav.addArrangedSubview(button("Back", #selector(backToWelcome)))
        nav.addArrangedSubview(spacer())
        nav.addArrangedSubview(defaultButton("Next", #selector(avatarToDeps)))
    }

    // Meeting transcription shells out to whisper (speech-to-text) and ffmpeg
    // (audio decode). Neither ships with the app, and without them recording
    // produces an audio file and nothing else — so surface it during setup
    // instead of letting the first meeting fail silently.
    private func buildDeps(body: NSStackView, nav: NSStackView) {
        body.alignment = .leading
        body.spacing = 12

        body.addArrangedSubview(label("Transcription tools", size: 20, bold: true, align: .left))
        body.addArrangedSubview(label(
            "Nikxel records meetings, transcribes them with whisper, then has your coding agent write the summary. These two are needed for transcription.",
            secondary: true, align: .left
        ))
        body.addArrangedSubview(depRow("whisper", found: whisperFound, note: "speech-to-text"))
        body.addArrangedSubview(depRow("ffmpeg", found: ffmpegFound, note: "audio decoding"))

        // whisper.cpp (what Homebrew installs) ships no model of its own, so
        // transcription silently can't run until one is downloaded.
        if usingWhisperCpp {
            body.addArrangedSubview(depRow("speech model", found: modelInstalled, note: "needed by whisper.cpp"))
            if modelDownloading {
                let bar = NSProgressIndicator()
                bar.style = .bar
                bar.isIndeterminate = false
                bar.minValue = 0
                bar.maxValue = 1
                bar.doubleValue = modelProgress
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.widthAnchor.constraint(equalToConstant: 240).isActive = true
                modelProgressBar = bar
                body.addArrangedSubview(bar)
                body.addArrangedSubview(label("Downloading \(WhisperModel.defaultName)…", size: 11, secondary: true, align: .left))
            } else if !modelInstalled {
                body.addArrangedSubview(button("Download speech model (\(WhisperModel.defaultDownloadSize))", #selector(downloadModel)))
            }
            if let err = modelError {
                body.addArrangedSubview(label(err, size: 11, color: .systemRed, align: .left))
            }
        }

        body.addArrangedSubview(label("Spoken language", bold: true, align: .left))
        body.addArrangedSubview(label(
            "Leave this on English unless your meetings are mostly Hindi — English also transcribes Hindi, as Hinglish, and keeps English words spelled correctly.",
            size: 11, secondary: true, align: .left
        ))
        for (i, option) in Self.languageOptions.enumerated() {
            let radio = NSButton(radioButtonWithTitle: option.title, target: self, action: #selector(pickLanguage(_:)))
            radio.tag = i
            radio.state = option.code == NikxelSettings.transcriptionLanguage ? .on : .off
            body.addArrangedSubview(radio)
        }

        if depsChecked && !(whisperFound && ffmpegFound) {
            if brewFound {
                body.addArrangedSubview(button("Install with Homebrew", #selector(installDeps)))
                body.addArrangedSubview(label(
                    "Opens Terminal and runs: brew install whisper-cpp ffmpeg",
                    size: 11, secondary: true, align: .left
                ))
            } else {
                body.addArrangedSubview(label(
                    "Homebrew not found. Install it from brew.sh, then run:\nbrew install whisper-cpp ffmpeg",
                    size: 11, secondary: true, align: .left
                ))
            }
        }
        body.addArrangedSubview(button("Re-check", #selector(recheckDeps)))

        nav.addArrangedSubview(button("Back", #selector(backToAvatar)))
        nav.addArrangedSubview(spacer())
        let ready = whisperFound && ffmpegFound && (!usingWhisperCpp || modelInstalled)
        nav.addArrangedSubview(defaultButton(ready ? "Next" : "Skip for now", #selector(depsToWhatsApp)))
    }

    private func buildWhatsApp(body: NSStackView, nav: NSStackView) {
        body.alignment = .centerX
        body.spacing = 16

        body.addArrangedSubview(label("Connect WhatsApp", size: 20, bold: true))
        body.addArrangedSubview(label(
            "Nikxel can reply on your behalf while you're in a meeting. Click Connect, then scan the QR code in the Chrome window that opens.",
            secondary: true
        ))

        if waConnected {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            if let check = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) {
                row.addArrangedSubview(symbol(check, color: .systemGreen))
            }
            row.addArrangedSubview(label("Connected", color: .systemGreen))
            body.addArrangedSubview(row)
        } else if waConnecting {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.addArrangedSubview(spinner)
            row.addArrangedSubview(label("Waiting for QR scan…", secondary: true))
            body.addArrangedSubview(row)
        } else {
            body.addArrangedSubview(button("Connect WhatsApp", #selector(startWhatsAppConnect)))
        }

        nav.addArrangedSubview(button("Back", #selector(backToDeps)))
        nav.addArrangedSubview(button("Skip for now", #selector(whatsappToAgent)))
        nav.addArrangedSubview(spacer())
        if waConnected {
            nav.addArrangedSubview(defaultButton("Next", #selector(whatsappToAgent)))
        }
    }

    private func buildAgent(body: NSStackView, nav: NSStackView) {
        body.alignment = .leading
        body.spacing = 12

        body.addArrangedSubview(label("Choose your coding agent", size: 20, bold: true, align: .left))
        body.addArrangedSubview(label(
            "Nikxel shells out to this to write meeting notes/MOMs and WhatsApp replies.",
            secondary: true, align: .left
        ))

        for (i, agent) in CodingAgent.allCases.enumerated() {
            let available = availableAgents.contains(agent)
            let title = available ? agent.displayName : "\(agent.displayName) — not installed"
            let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(pickAgent(_:)))
            radio.tag = i
            radio.state = (agent == chosenAgent) ? .on : .off
            radio.isEnabled = available
            body.addArrangedSubview(radio)

            // Someone with none of these installed would otherwise hit a dead
            // end here, so show exactly what to run and let them copy it.
            if !available {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 8
                let cmd = label(agent.installCommand, size: 11, secondary: true, align: .left)
                cmd.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                cmd.isSelectable = true
                row.addArrangedSubview(cmd)
                let copy = NSButton(
                    title: agentCopied == agent ? "Copied ✓" : "Copy",
                    target: self, action: #selector(copyInstallCommand(_:))
                )
                copy.bezelStyle = .rounded
                copy.controlSize = .small
                copy.tag = i
                row.addArrangedSubview(copy)
                row.addArrangedSubview(spacer())
                body.addArrangedSubview(row)
            }
        }

        body.addArrangedSubview(label(
            "Run the command in a terminal, then click Re-check.",
            size: 11, secondary: true, align: .left
        ))
        body.addArrangedSubview(button("Re-check", #selector(recheckAgents)))

        nav.addArrangedSubview(button("Back", #selector(backToWhatsApp)))
        nav.addArrangedSubview(spacer())
        nav.addArrangedSubview(defaultButton("Finish", #selector(finishSetup)))
    }

    private func depRow(_ name: String, found: Bool, note: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        let symbolName = found ? "checkmark.circle.fill" : "xmark.circle"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            row.addArrangedSubview(symbol(img, color: found ? .systemGreen : .secondaryLabelColor))
        }
        row.addArrangedSubview(label(name, align: .left))
        row.addArrangedSubview(label("— \(note)", secondary: true, align: .left))
        if !found {
            row.addArrangedSubview(label("not installed", size: 11, secondary: true, align: .left))
        }
        row.addArrangedSubview(spacer())
        return row
    }

    // MARK: - Navigation actions

    @objc private func nextFromWelcome() {
        let typed = nameField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        if !typed.isEmpty { NikxelSettings.userName = typed }
        go(to: .avatar)
    }
    @objc private func backToWelcome() { go(to: .welcome) }
    @objc private func avatarToDeps() { go(to: .deps) }
    @objc private func backToAvatar() { go(to: .avatar) }
    @objc private func depsToWhatsApp() { go(to: .whatsapp) }
    @objc private func backToDeps() { go(to: .deps) }
    @objc private func whatsappToAgent() { go(to: .agent) }
    @objc private func backToWhatsApp() { go(to: .whatsapp) }
    @objc private func recheckDeps() { refreshDeps() }
    @objc private func recheckAgents() { refreshAvailableAgents() }

    /// "en" handles all three cases and is what almost everyone should use.
    /// Measured on the small model: English stays clean, Hindi comes back as
    /// natural Hinglish with English words spelled properly ("Namaste, mai kal
    /// meeting me shamil nahi ho paunga"), and Hinglish resolves to English.
    /// Picking "hi" makes pure English come out as Devanagari gibberish, and
    /// auto-detect reads Indian-accented English as Hindi.
    static let languageOptions: [(title: String, code: String)] = [
        ("English — handles Hindi and Hinglish too (recommended)", "en"),
        ("Hindi — only for heavy Hindi; breaks pure English", "hi"),
        ("Auto-detect — not recommended, misreads Indian English as Hindi", "auto"),
    ]

    @objc private func pickLanguage(_ sender: NSButton) {
        guard sender.tag < Self.languageOptions.count else { return }
        NikxelSettings.transcriptionLanguage = Self.languageOptions[sender.tag].code
        render()
    }

    @objc private func copyInstallCommand(_ sender: NSButton) {
        guard sender.tag < CodingAgent.allCases.count else { return }
        let agent = CodingAgent.allCases[sender.tag]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agent.installCommand, forType: .string)
        agentCopied = agent
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.step == .agent else { return }
            self.agentCopied = nil
            self.render()
        }
    }

    @objc private func downloadModel() {
        modelDownloading = true
        modelProgress = 0
        modelError = nil
        render()
        WhisperModel.downloadDefault(progress: { [weak self] fraction in
            // Nudge the existing bar rather than re-rendering the whole step on
            // every progress callback.
            self?.modelProgress = fraction
            self?.modelProgressBar?.doubleValue = fraction
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.modelDownloading = false
            if case .failure(let error) = result {
                self.modelError = "Download failed: \(error.localizedDescription)"
            }
            self.refreshDeps()
        })
    }

    @objc private func pickAgent(_ sender: NSButton) {
        guard sender.tag < CodingAgent.allCases.count else { return }
        chosenAgent = CodingAgent.allCases[sender.tag]
        render()
    }

    @objc private func finishSetup() {
        NikxelSettings.connectedAgent = chosenAgent
        NikxelSettings.onboardingCompleted = true
        stopPreview()
        stopPolling()
        close()
    }

    // MARK: - Avatar actions

    @objc private func copyPrompt() {
        guard let path = Bundle.main.path(forResource: "sprite_prompt", ofType: "txt"),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            sheetError = "Couldn't find the bundled prompt."
            render()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        promptCopied = true
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.step == .avatar else { return }
            self.promptCopied = false
            self.render()
        }
    }

    @objc private func chooseSheet() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["png"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Pick the sprite sheet Gemini gave you"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        sheetError = nil
        importing = true
        render()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do {
                // Keys out the magenta, finds the real grid and re-frames every
                // cell -- whatever Gemini returned, this is what makes it
                // usable, so the user never has to run remove_magenta.py.
                let data = try SpriteSheetImporter.process(url: url)
                try? FileManager.default.removeItem(at: NikxelSprites.customURL)
                try data.write(to: NikxelSprites.customURL)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.importing = false
                self.sheetError = failure
                if failure == nil {
                    self.usingCustomSheet = true
                    NotificationCenter.default.post(name: NikxelSprites.changedNotification, object: nil)
                    self.startPreview()
                }
                self.render()
            }
        }
    }

    @objc private func resetSheet() {
        try? FileManager.default.removeItem(at: NikxelSprites.customURL)
        sheetError = nil
        usingCustomSheet = NikxelSprites.hasCustom
        NotificationCenter.default.post(name: NikxelSprites.changedNotification, object: nil)
        startPreview()
        render()
    }

    @objc private func installDeps() {
        // A .command file so the install runs in Terminal, where the user can
        // watch progress and answer any prompt -- a silent background `brew
        // install` would look like a hang for several minutes.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nikxel-install-deps.command")
        let script = "#!/bin/zsh\nset -e\nbrew install whisper-cpp ffmpeg\necho\necho 'Done. Go back to Nikxel and click Re-check.'\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    @objc private func startWhatsAppConnect() {
        waConnecting = true
        render()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ChromeBot.launchIfNeeded()
            DispatchQueue.main.async { self?.beginPolling() }
        }
    }

    // MARK: - Background checks

    private func refreshDeps() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let whisperPath = Transcriber().findBinary()
            let whisper = whisperPath != nil
            let isCpp = whisperPath.map { Transcriber.Flavor.of(binary: $0) == .cpp } ?? false
            let hasModel = WhisperModel.isInstalled
            let ffmpeg = Self.onPath("ffmpeg")
            let brew = Self.onPath("brew")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.usingWhisperCpp = isCpp
                self.modelInstalled = hasModel
                self.whisperFound = whisper
                self.ffmpegFound = ffmpeg
                self.brewFound = brew
                self.depsChecked = true
                if self.step == .deps { self.render() }
            }
        }
    }

    private func refreshAvailableAgents() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var found: Set<CodingAgent> = []
            for agent in CodingAgent.allCases where self.momGenerator.findBinary(for: agent) != nil {
                found.insert(agent)
            }
            DispatchQueue.main.async {
                self.availableAgents = found
                if !found.contains(self.chosenAgent),
                   let firstAvailable = CodingAgent.allCases.first(where: { found.contains($0) }) {
                    self.chosenAgent = firstAvailable
                }
                if self.step == .agent { self.render() }
            }
        }
    }

    private func beginPolling() {
        waPollTimer?.invalidate()
        waPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                guard ChromeWhatsApp.isLoggedIn() else { return }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.waConnected = true
                    self.waConnecting = false
                    NikxelSettings.whatsappConnected = true
                    self.stopPolling()
                    self.render()
                }
            }
        }
    }

    private func stopPolling() {
        waPollTimer?.invalidate()
        waPollTimer = nil
    }

    // MARK: - Avatar preview

    /// Animates row 0 (idle) of the active sheet. A single static frame would
    /// hide a wrong row layout, which is the most likely way a user's sheet is
    /// broken -- the animation shows it immediately.
    private func startPreview() {
        previewFrames = Self.idleFrames()
        previewIndex = 0
        previewTimer?.invalidate()
        previewImageView?.image = previewFrames.first
        guard previewFrames.count > 1 else { return }
        // 3 fps, same rate NikxelView animates the idle row at.
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 3, repeats: true) { [weak self] _ in
            guard let self = self, !self.previewFrames.isEmpty else { return }
            self.previewIndex = (self.previewIndex + 1) % self.previewFrames.count
            self.previewImageView?.image = self.previewFrames[self.previewIndex]
        }
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    /// Row 0 of the active sheet -- the idle animation.
    private static func idleFrames() -> [NSImage] {
        (0..<NikxelSprites.cols).compactMap { avatarFrame($0) }
    }

    /// One frame of the active sheet. The avatar actually drawn on screen comes
    /// from this sheet -- nikxel_avatar.png is only the no-sprite-sheet
    /// fallback, so showing that here would greet the user with a different
    /// character than the app runs.
    private static func avatarFrame(_ col: Int) -> NSImage? {
        let f = NikxelSprites.frameSize
        if let path = NikxelSprites.activePath,
           let sheet = NSImage(contentsOfFile: path),
           let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let frame = cg.cropping(to: CGRect(x: col * f, y: 0, width: f, height: f)) {
            return NSImage(cgImage: frame, size: NSSize(width: f, height: f))
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

    // MARK: - View helpers

    private func label(
        _ text: String,
        size: CGFloat = 13,
        bold: Bool = false,
        secondary: Bool = false,
        color: NSColor? = nil,
        align: NSTextAlignment = .center
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.textColor = color ?? (secondary ? .secondaryLabelColor : .labelColor)
        field.alignment = align
        field.isSelectable = false
        field.preferredMaxLayoutWidth = Self.contentWidth - Self.padding * 2
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return field
    }

    private func imageView(_ image: NSImage?, size: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.wantsLayer = true
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        // Nearest-neighbour, so the pixel art stays crisp when scaled up.
        view.layer?.magnificationFilter = .nearest
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size),
            view.heightAnchor.constraint(equalToConstant: size),
        ])
        return view
    }

    private func symbol(_ image: NSImage, color: NSColor) -> NSImageView {
        let view = NSImageView()
        view.image = image
        view.contentTintColor = color
        return view
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func defaultButton(_ title: String, _ action: Selector) -> NSButton {
        let b = button(title, action)
        b.keyEquivalent = "\r"
        return b
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }
}
