import AppKit
import WebKit

/// First-run (and reopenable-anytime, via the status bar) setup wizard: say
/// hello, tour what Nikxel does, pick an avatar, check the transcription tools,
/// connect WhatsApp and Google, and choose which coding agent Nikxel should
/// shell out to.
///
/// The window is a WKWebView (OnboardingPage.swift) animated with Framer
/// Motion's standalone DOM build, vendored at vendor/framer-motion-dom.js --
/// no React, no node at build time. This controller owns every bit of state
/// and every side effect; the page only draws `state()` and posts back the
/// buttons it was clicked. It is not SwiftUI on purpose: in newer SDKs `@State`
/// is a macro a bare `swiftc` build can't expand.
final class OnboardingWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    private enum Step: String {
        case welcome, tour, avatar, deps, whatsapp, google, agent, ready
    }

    private let momGenerator: MOMGenerator
    private let web: WKWebView
    private var pageLoaded = false
    private var step: Step = .welcome

    // Avatar step
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
    /// Running while the Terminal install is going, so the step fills itself
    /// in as whisper and ffmpeg land -- no Re-check click needed.
    private var depsPoll: Timer?
    private var agentCopied: CodingAgent?

    // WhatsApp step
    private var waConnecting = false
    private var waConnected = NikxelSettings.whatsappConnected
    private var waPollTimer: Timer?
    /// Set when Connect can't get anywhere. Without these the wizard sat on
    /// "Waiting for QR scan…" forever, which is indistinguishable from a hang:
    /// the browser never launched, so there was never going to be a QR.
    private var waNoBrowser = false
    private var waLaunchFailed = false

    // Agent step
    private var chosenAgent = NikxelSettings.connectedAgent
    /// Latest test result per agent; absent while that agent is still being tested.
    private var agentHealth: [CodingAgent: MOMGenerator.AgentHealth] = [:]
    private var agentTestRun = 0
    /// Set while the Terminal window installing (or signing in to) Claude Code
    /// is open; checks every few seconds until Claude answers.
    private var agentInstallPoll: Timer?
    /// The arrow at that Terminal window, saying what to do at each stage.
    private var installPointer: CoachPointer?
    private var installStage = ""
    private var googlePoll: Timer?

    /// The dashboard's paper (#f6f4ee), so nothing flashes white before the page paints.
    private static let paper = NSColor(srgbRed: 0.965, green: 0.957, blue: 0.933, alpha: 1)

    init(momGenerator: MOMGenerator) {
        self.momGenerator = momGenerator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Set up Nikxel"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The page is light-only, so keep the traffic lights light too.
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Self.paper
        window.minSize = NSSize(width: 980, height: 780)
        // Keep the controller (and window) alive across hide/show instead of
        // being deallocated on close, so "Setup Wizard…" can reopen the same
        // window with its current step/state intact.
        window.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        PageAssets.install(into: config.userContentController)
        web = WKWebView(frame: .zero, configuration: config)
        super.init(window: window)
        config.userContentController.add(self, name: "nx")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1160, height: 860))
        web.frame = content.bounds
        web.autoresizingMask = [.width, .height]
        content.addSubview(web)
        // The page runs under the transparent title bar, and a web view swallows
        // drags -- this strip gives the window back somewhere to be moved by.
        let strip = DragStrip(frame: NSRect(x: 0, y: content.bounds.height - 44, width: content.bounds.width, height: 44))
        strip.autoresizingMask = [.width, .minYMargin]
        content.addSubview(strip)
        window.contentView = content
        window.center()

        web.loadHTMLString(OnboardingPage.html, baseURL: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController does not support NSCoding")
    }

    deinit {
        waPollTimer?.invalidate()
    }

    func show() {
        refreshDeps()
        refreshAvailableAgents()
        // Reopened from the menu: start the page over so the splash plays
        // again. The step and everything set so far live here, so the page
        // comes back where the user left it.
        if pageLoaded, window?.isVisible == false {
            pageLoaded = false
            web.loadHTMLString(OnboardingPage.html, baseURL: nil)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Page bridge

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        pushFrames()
        push()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let index = body["index"] as? Int ?? -1
        switch type {
        case "go":
            guard let next = (body["step"] as? String).flatMap(Step.init(rawValue:)) else { return }
            if step == .welcome, let typed = (body["name"] as? String)?.trimmingCharacters(in: .whitespaces), !typed.isEmpty {
                NikxelSettings.userName = typed
            }
            if step == .agent && next == .ready { NikxelSettings.connectedAgent = chosenAgent }
            go(to: next)
        case "copyPrompt": copyPrompt()
        case "chooseSheet": chooseSheet()
        case "resetSheet": resetSheet()
        case "downloadModel": downloadModel()
        case "installDeps": installDeps()
        case "recheckDeps": refreshDeps()
        case "language":
            guard let code = body["code"] as? String else { return }
            NikxelSettings.transcriptionLanguage = code
            push()
        case "connectWhatsApp": startWhatsAppConnect()
        case "getChrome": openChromeDownload()
        case "connectGoogle": connectGoogle()
        case "pickAgent": pickAgent(index)
        case "copyAgent": copyInstallCommand(index)
        case "installAgent": installClaude()
        case "retestAgents": refreshAvailableAgents()
        case "finish": finishSetup()
        default: break
        }
    }

    /// Hands the page everything it draws. Cheap enough to send whole on every
    /// change; the page only animates when `step` moves.
    private func push() {
        guard pageLoaded, let json = PageAssets.json(state()) else { return }
        web.evaluateJavaScript("nx.state(\(json))")
    }

    /// Every row of the active sheet, as PNG data URIs: the page plays the
    /// row that fits each step (headphones while it listens, typing at the
    /// agent, the jump when it's done) and runs on row 5 between them. Idle is
    /// still what the avatar step previews -- a wrong row layout, the likeliest
    /// way a user's sheet is broken, shows up there immediately.
    private func pushFrames() {
        guard pageLoaded else { return }
        guard let json = PageAssets.json(PageAssets.spriteRows()) else { return }
        web.evaluateJavaScript("nx.frames(\(json))")
    }

    private func state() -> [String: Any] {
        let browser = ChromeBot.availableBrowser()
        let ready = whisperFound && ffmpegFound && (!usingWhisperCpp || modelInstalled)
        let agents: [[String: Any]] = CodingAgent.allCases.map { agent in
            let health = agentHealth[agent]
            let (text, tone, hint) = Self.describe(health, agent: agent)
            // Claude Code gets a button that does it all; the others keep a command to copy.
            var action = ""
            if agent == .claude {
                if case .notInstalled = health { action = "install" }
                if case .notLoggedIn = health { action = "login" }
                if agentInstallPoll != nil && !(health?.isWorking ?? false) { action = action.isEmpty ? "install" : action }
            }
            return [
                "name": agent.displayName, "text": text, "tone": tone, "hint": hint ?? "",
                "enabled": health != nil && health != .notInstalled,
                "chosen": agent == chosenAgent, "copied": agentCopied == agent,
                "action": action, "busy": agent == .claude && agentInstallPoll != nil,
            ]
        }
        return [
            "step": step.rawValue,
            "name": NikxelSettings.hasUserName ? NikxelSettings.userName : (NikxelSettings.accountFirstName ?? ""),
            "avatar": [
                "custom": usingCustomSheet, "error": sheetError ?? "", "copied": promptCopied, "importing": importing,
                "spec": "PNG, \(NikxelSprites.cols) columns × \(NikxelSprites.rows) rows of \(NikxelSprites.frameSize)px frames (\(NikxelSprites.cols * NikxelSprites.frameSize)×\(NikxelSprites.rows * NikxelSprites.frameSize)). One row per state: idle, typing, thinking, done, dragging, pounce, petted, alert, recording, MOM ready.",
            ],
            "deps": [
                "checked": depsChecked, "whisper": whisperFound, "ffmpeg": ffmpegFound, "brew": brewFound,
                "cpp": usingWhisperCpp, "model": modelInstalled, "downloading": modelDownloading,
                "progress": modelProgress, "modelError": modelError ?? "",
                "modelName": WhisperModel.defaultName, "modelSize": WhisperModel.defaultDownloadSize,
                "installing": depsPoll != nil, "ready": ready,
                "language": NikxelSettings.transcriptionLanguage,
                "languages": Self.languageOptions.map { ["title": $0.title, "note": $0.note, "code": $0.code] },
            ],
            "wa": [
                "browser": browser?.name ?? "browser", "noBrowser": waNoBrowser, "launchFailed": waLaunchFailed,
                "connected": waConnected, "connecting": waConnecting,
                "missing": ChromeBot.missingBrowserMessage, "port": ChromeBot.debugPort,
            ],
            "google": [
                "connected": GoogleAuth.shared.isAuthorized, "oneClick": GoogleAuth.shared.isOneClick,
                "waiting": googlePoll != nil,
            ],
            "agents": agents,
            "testing": agentHealth.count < CodingAgent.allCases.count,
        ]
    }

    private func go(to next: Step) {
        if step == .whatsapp { stopPolling() }
        if next == .agent { refreshAvailableAgents() }
        step = next
        push()
    }

    /// Status line, its tone, and an optional copyable terminal command.
    /// Login is fixed by running the agent itself, so that's the command shown.
    private static func describe(_ health: MOMGenerator.AgentHealth?, agent: CodingAgent) -> (String, String, String?) {
        let bin = agent.rawValue
        switch health {
        case nil:
            return ("Testing…", "muted", nil)
        case .notInstalled:
            return ("Not installed", "muted", agent.installCommand)
        case .broken(let why):
            return ("Installed but won't start: \(readable(why))", "red", agent.installCommand)
        case .notLoggedIn:
            return ("Installed, but not logged in", "orange", bin)
        case .failing(let why):
            return ("Installed, but a test request failed: \(readable(why))", "red", nil)
        case .working(let version):
            // "2.1.311 (Claude Code)" -> "2.1.311"; "codex-cli 0.145.0" stays.
            let v = version.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            return ("Installed, logged in and working" + (v.isEmpty ? "" : " (\(v))"), "green", nil)
        }
    }

    /// An agent's error as a person would say it. OpenCode fails with its raw
    /// JSON event ({"type":"error",…,"data":{"message":"Unexpected server
    /// error…"}}), which is one unbreakable line of braces; its "message" is
    /// the part worth showing.
    private static func readable(_ why: String) -> String {
        if let r = why.range(of: #""message"\s*:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
            let match = String(why[r])
            if let q = match.range(of: #":\s*""#, options: .regularExpression) {
                return String(match[q.upperBound...].dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
        }
        return why
    }

    // MARK: - Actions

    private func connectGoogle() {
        // Through the watcher so calendar polling starts the moment consent
        // finishes; this page just watches for the token to appear.
        (NSApp.delegate as? NikxelAppDelegate)?.calendarWatcher.reauthenticate()
        let started = Date()
        googlePoll?.invalidate()
        googlePoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if GoogleAuth.shared.isAuthorized || Date().timeIntervalSince(started) > 300 {
                t.invalidate(); self.googlePoll = nil
                self.push()
            }
        }
        push()
    }

    /// "en" handles all three cases and is what almost everyone should use.
    /// Measured on the small model: English stays clean, Hindi comes back as
    /// natural Hinglish with English words spelled properly ("Namaste, mai kal
    /// meeting me shamil nahi ho paunga"), and Hinglish resolves to English.
    /// Picking "hi" makes pure English come out as Devanagari gibberish, and
    /// auto-detect reads Indian-accented English as Hindi.
    static let languageOptions: [(title: String, note: String, code: String)] = [
        ("English", "Also Hindi & Hinglish", "en"),
        ("Hindi", "Breaks pure English", "hi"),
        ("Auto-detect", "Misreads Indian English", "auto"),
    ]

    private func copyInstallCommand(_ index: Int) {
        guard CodingAgent.allCases.indices.contains(index) else { return }
        let agent = CodingAgent.allCases[index]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.describe(agentHealth[agent], agent: agent).2 ?? agent.installCommand, forType: .string)
        agentCopied = agent
        push()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.step == .agent else { return }
            self.agentCopied = nil
            self.push()
        }
    }

    /// Installs Claude Code (if missing) and starts it to sign in, in a Terminal
    /// window the user can watch, while Nikxel's bubble says what to press.
    /// Checks in the background and turns the step green once Claude answers.
    private func installClaude() {
        guard agentInstallPoll == nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nikxel-install-claude.command")
        let script = """
        #!/bin/zsh
        export PATH="$HOME/.local/bin:$PATH"
        if ! command -v claude >/dev/null; then
          echo 'Installing Claude Code for Nikxel. This takes a minute…'
          echo
          curl -fsSL https://claude.ai/install.sh | bash
          export PATH="$HOME/.local/bin:$PATH"
        fi
        echo
        echo 'Now sign in: press Return to pick a look, choose your Claude account, and finish in the browser.'
        echo 'Nikxel notices when it works. You can close this window after that.'
        echo
        claude

        """
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
        cblog("Onboarding: opened Terminal to install/sign in to Claude Code")
        NikxelView.tell(icon: "🧑‍💻", title: "Setting up Claude Code", lines: [
            "In the Terminal window I opened, let it install.",
            "When Claude starts, press Return, choose your Claude account and sign in in your browser.",
            "I'll notice when it works.",
        ], lifetime: 180)

        let pointer = CoachPointer()
        installPointer = pointer
        installStage = ""
        pointer.onNext = { [weak self] in self?.closeInstallPointer() }
        pointer.onSkip = { [weak self] in self?.closeInstallPointer() }

        // Cheap file checks until it's installed, then a real test every 20 s
        // (it sends a tiny prompt) until it answers. Gives up after 20 minutes.
        let started = Date()
        var lastTest = Date.distantPast, testing = false
        agentInstallPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if Date().timeIntervalSince(started) > 1200 {
                t.invalidate(); self.agentInstallPoll = nil; self.closeInstallPointer(); self.push(); return
            }
            let installed = FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.local/bin/claude") || Self.onPath("claude")
            self.guideInstall(installed ? "login" : "installing")
            guard installed, !testing, Date().timeIntervalSince(lastTest) > 20 else { return }
            testing = true; lastTest = Date()
            DispatchQueue.global(qos: .userInitiated).async {
                let health = self.momGenerator.checkAgent(.claude)
                DispatchQueue.main.async {
                    testing = false
                    self.agentHealth[.claude] = health
                    if health.isWorking {
                        t.invalidate(); self.agentInstallPoll = nil
                        self.guideInstall("done")
                        self.chosenAgent = .claude
                        cblog("Onboarding: Claude Code installed and signed in")
                        NikxelView.tell(icon: "✅", title: "Claude Code is ready", lines: ["You can close the Terminal window. Click Next."], kind: .success)
                    }
                    self.push()
                }
            }
        }
        push()
    }

    /// Points at the Terminal window with what to do now. Re-placed every tick,
    /// so it follows the window if the user moves it.
    private func guideInstall(_ stage: String) {
        guard let pointer = installPointer, let target = CoachPointer.windowFrame(ofApp: "Terminal") else { return }
        if stage != installStage { cblog("Onboarding: Claude setup stage → \(stage)") }
        installStage = stage
        let card: CoachPointer.Card
        switch stage {
        case "installing":
            card = .init(title: "Installing Claude Code…", text: "<p>This window is installing it. Nothing to do yet; it takes a minute.</p>",
                         step: 0, total: 3, primary: "Hide")
        case "login":
            card = .init(title: "Now sign in to Claude",
                         text: "<p>In this window: press <kbd>Return</kbd> to pick a look, then choose your <b>Claude account</b>.</p><p>Your browser opens. Sign in there and click <b>Authorize</b>.</p>",
                         step: 1, total: 3, primary: "Hide")
        default:
            card = .init(title: "Claude Code is ready ✓", text: "<p>You can close this window. Back in setup, click <b>Next</b>.</p>",
                         step: 2, total: 3, primary: "Done")
        }
        pointer.show(at: target, card)
    }

    private func closeInstallPointer() {
        installPointer?.close()
        installPointer = nil
    }

    private func downloadModel() {
        modelDownloading = true
        modelProgress = 0
        modelError = nil
        push()
        WhisperModel.downloadDefault(progress: { [weak self] fraction in
            // Nudge the page's bar rather than resending the whole state on
            // every progress callback.
            guard let self = self else { return }
            self.modelProgress = fraction
            if self.pageLoaded { self.web.evaluateJavaScript("nx.progress(\(fraction))") }
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.modelDownloading = false
            if case .failure(let error) = result {
                self.modelError = "Download failed: \(error.localizedDescription)"
            }
            self.push()
            self.refreshDeps()
        })
    }

    private func pickAgent(_ index: Int) {
        guard CodingAgent.allCases.indices.contains(index) else { return }
        chosenAgent = CodingAgent.allCases[index]
        push()
    }

    private func finishSetup() {
        NikxelSettings.connectedAgent = chosenAgent
        NikxelSettings.onboardingCompleted = true
        stopPolling()
        close()
        // Then show them where everything is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { CoachTour.startIfNew() }
    }

    // MARK: - Avatar actions

    private func copyPrompt() {
        guard let path = Bundle.main.path(forResource: "sprite_prompt", ofType: "txt"),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            sheetError = "Couldn't find the bundled prompt."
            push()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        promptCopied = true
        push()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.step == .avatar else { return }
            self.promptCopied = false
            self.push()
        }
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
        push()

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
                    self.pushFrames()
                }
                self.push()
            }
        }
    }

    private func resetSheet() {
        try? FileManager.default.removeItem(at: NikxelSprites.customURL)
        sheetError = nil
        usingCustomSheet = NikxelSprites.hasCustom
        NotificationCenter.default.post(name: NikxelSprites.changedNotification, object: nil)
        pushFrames()
        push()
    }

    private func installDeps() {
        // A .command file so the install runs in Terminal, where the user can
        // watch progress and answer any prompt -- a silent background `brew
        // install` would look like a hang for several minutes.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nikxel-install-deps.command")
        // Homebrew's official installer when brew is missing, then its
        // shellenv: a fresh install isn't on this shell's PATH yet.
        // `sudo -v` takes the password up front so NONINTERACTIVE can skip
        // Homebrew's "Press RETURN" prompt -- without cached sudo it aborts.
        let script = """
        #!/bin/zsh
        set -e
        if ! command -v brew >/dev/null; then
          if [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
            echo 'Installing Homebrew. Enter your Mac password (nothing shows as you type):'
            sudo -v
            NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
          fi
          eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
        fi
        brew install whisper-cpp ffmpeg
        echo
        echo 'Done. You can close this window — Nikxel has picked it up.'

        """
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
        depsPoll?.invalidate()
        // Gives up after 20 min so a failed install brings the button back.
        let started = Date()
        depsPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            guard let self = self, self.step == .deps, Date().timeIntervalSince(started) < 1200 else {
                t.invalidate(); self?.depsPoll = nil
                if self?.step == .deps { self?.push() }
                return
            }
            self.refreshDeps()
        }
        push()
    }

    private func startWhatsAppConnect() {
        waNoBrowser = false
        waLaunchFailed = false
        guard ChromeBot.availableBrowser() != nil else {
            waNoBrowser = true
            push()
            return
        }
        waConnecting = true
        push()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = ChromeBot.launchIfNeeded()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok {
                    self.beginPolling()
                } else {
                    self.waConnecting = false
                    self.waLaunchFailed = true
                    self.push()
                }
            }
        }
    }

    private func openChromeDownload() {
        if let url = URL(string: "https://www.google.com/chrome/") {
            NSWorkspace.shared.open(url)
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
                let changed = !self.depsChecked || self.usingWhisperCpp != isCpp || self.modelInstalled != hasModel
                    || self.whisperFound != whisper || self.ffmpegFound != ffmpeg || self.brewFound != brew
                self.usingWhisperCpp = isCpp
                self.modelInstalled = hasModel
                self.whisperFound = whisper
                self.ffmpegFound = ffmpeg
                self.brewFound = brew
                self.depsChecked = true
                if whisper && ffmpeg { self.depsPoll?.invalidate(); self.depsPoll = nil }
                guard self.step == .deps else { return }
                // whisper.cpp with no model can't transcribe: fetch it now
                // instead of waiting for another click. Not after a failure --
                // that leaves the button up for a retry instead of looping.
                if isCpp && !hasModel && !self.modelDownloading && self.modelError == nil {
                    self.downloadModel()
                } else if changed {
                    self.push()
                }
            }
        }
    }

    /// Tests every agent in parallel: installed, starts, and answers a real
    /// prompt (which is what proves it's logged in). Results land one by one so
    /// a slow agent doesn't hold up the others; `agentTestRun` discards the
    /// answers of a superseded run.
    private func refreshAvailableAgents() {
        agentTestRun += 1
        let run = agentTestRun
        agentHealth = [:]
        if step == .agent { push() }
        for agent in CodingAgent.allCases {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let health = self.momGenerator.checkAgent(agent)
                DispatchQueue.main.async {
                    guard run == self.agentTestRun else { return }
                    self.agentHealth[agent] = health
                    // Land on the first agent that actually works, unless the
                    // user already picked one that does.
                    if self.agentHealth[self.chosenAgent]?.isWorking != true, health.isWorking {
                        self.chosenAgent = agent
                    }
                    if self.step == .agent { self.push() }
                }
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
                    self.push()
                }
            }
        }
    }

    private func stopPolling() {
        waPollTimer?.invalidate()
        waPollTimer = nil
    }

    // MARK: - Helpers

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
}
