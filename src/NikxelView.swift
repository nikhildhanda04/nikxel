import Cocoa

class NikxelView: NSView, StateMachineDelegate {
    let stateMachine: StateMachine
    private var fallbackAvatar: NSImage?
    private var currentState: NikxelState = .idle
    private var facingRight = true
    private var bounce: CGFloat = 0
    private var wiggle: CGFloat = 0
    private var scale: CGFloat = 1
    private var animTimer: Timer?
    private var animHz: Double = 0
    /// The sheet decoded once. Cropping the NSImage's own CGImage re-ran the
    /// PNG decoder on every draw -- most of Nikxel's CPU, at 60 fps.
    private var sheetCG: CGImage?
    /// What the last frame showed; tick() only redraws when it changes.
    private var drawnKey: [CGFloat] = []

    private var frameIndex: Int = 0
    private var frameElapsed: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    /// Sprite size: 156 pt times the user's Avatar Size. Cached, not read
    /// from settings per frame -- draw runs at 60 fps and settings is a file.
    private(set) var charSize = 156 * CGFloat(NikxelSettings.avatarSize)
    var halfChar: CGFloat { charSize / 2 }
    func applyAvatarSize() { charSize = 156 * CGFloat(NikxelSettings.avatarSize); needsDisplay = true }
    /// The window is taller than it is wide so notification cards have room
    /// above the avatar's head -- or, with `bubblesBelow`, the same room under
    /// its feet. The avatar sits in the middle.
    /// Wider than any card so a card can slide sideways to stay on screen when
    /// the avatar is at an edge. The empty part lets clicks through.
    static let viewWidth: CGFloat = 640
    static let viewHeight: CGFloat = 700
    static let avatarBottomInset: CGFloat = 350

    /// Set by the window when the avatar is too near the top of the screen
    /// for anything to fit above its head.
    var bubblesBelow = false { didSet { if bubblesBelow != oldValue { needsDisplay = true } } }

    /// Y for something `off` above the head -- or, with `bubblesBelow`, the
    /// same distance under the feet. Pass `height` when the y is the item's
    /// origin, so a flipped item hangs down from that point.
    func headY(_ off: CGFloat, height h: CGFloat = 0) -> CGFloat {
        bubblesBelow ? avatarCenter.y - halfChar - off - h : avatarCenter.y + halfChar + off
    }

    /// Avatar centre. Sprite, shadow, bubbles and hit testing are all
    /// positioned from here, so this is the only place the anchor is defined.
    var avatarCenter: NSPoint {
        NSPoint(x: bounds.midX, y: bounds.minY + NikxelView.avatarBottomInset)
    }

    private let frameCount = 4
    private var spriteSheet: NSImage?

    var onMoveTo: ((CGPoint) -> Void)?
    private var springActive = false
    private var springStart: TimeInterval = 0
    private var springDuration: TimeInterval = 0.45

    // Drag inertia
    var dragVelocity: CGPoint = .zero
    private var dragLagX: CGFloat = 0
    private var dragLagY: CGFloat = 0

    // Overheat
    private var keyTimestamps: [TimeInterval] = []
    private let overheatWPM: Double = 30
    private let wpmWindow: TimeInterval = 5.0

    private var bubbleOpacity: CGFloat = 0
    private var bubbleScale: CGFloat = 1
    private var bubbleTargetOpacity: CGFloat = 0

    // Reminder bubble
    var reminderText: String? = nil
    private var reminderOpacity: CGFloat = 0
    private var reminderTargetOpacity: CGFloat = 0
    var onReminderDismissed: (() -> Void)?

    // Meeting indicator (yellow dot)
    var isInMeeting = false
    private var meetingDotOpacity: CGFloat = 0
    private var meetingDotTargetOpacity: CGFloat = 0

    // Active texter bubble (chatbot)
    var activeTexterName: String? = nil
    private var texterOpacity: CGFloat = 0
    private var texterTargetOpacity: CGFloat = 0

    // Recording timer
    var recordingStartedAt: TimeInterval? = nil

    // Apple Reminders bubbles (transient, tap-to-complete)
    struct ReminderBubble {
        let id: String
        let title: String
        let addedAt: TimeInterval
        var opacity: CGFloat = 0
        var hitRect: NSRect = .zero
    }
    private var reminderBubbles: [ReminderBubble] = []
    var onReminderTapped: ((String) -> Void)?
    private let reminderBubbleLifetime: TimeInterval = 30
    private let reminderFadeOut: TimeInterval = 0.4
    private let reminderFadeIn: TimeInterval = 0.3

    // Notification card. Drawn with CoreGraphics rather than
    // NSGlassEffectView: the glass bubbles only exist when built against the
    // macOS 26 SDK, and these have to show up on every build.
    //
    // One card at a time, newest replacing the last. The things that raise one
    // -- a summary finishing, a failure, the 10pm digest -- can't overlap in
    // practice, and a stack would cost layout and hit-testing for a case that
    // doesn't happen. Rendering lives in NikxelCard.swift.
    enum CardKind {
        case info, success, warning, error

        var accent: NSColor {
            switch self {
            case .info:    return NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.90, alpha: 1)
            case .success: return NSColor(calibratedRed: 0.17, green: 0.62, blue: 0.36, alpha: 1)
            case .warning: return NSColor(calibratedRed: 0.85, green: 0.58, blue: 0.10, alpha: 1)
            case .error:   return NSColor(calibratedRed: 0.80, green: 0.22, blue: 0.20, alpha: 1)
            }
        }
    }

    struct Card {
        let icon: String?
        let title: String
        let lines: [String]
        let bulleted: Bool
        let kind: CardKind
        let addedAt: TimeInterval
        let lifetime: TimeInterval
        let action: (() -> Void)?
        /// Answers drawn on the card, in place of a modal dialog. First is primary.
        var buttons: [CardButton] = []
        var buttonRects: [NSRect] = []
        var opacity: CGFloat = 0
        var hitRect: NSRect = .zero
    }
    struct CardButton {
        let title: String
        let action: () -> Void
    }
    /// The one avatar, for code with no view at hand (GoogleSync, GoogleAuth)
    /// to ask through. Set in init.
    static weak var main: NikxelView?
    var card: Card?
    let cardFadeIn: TimeInterval = 0.45
    let cardFadeOut: TimeInterval = 0.6

    // Liquid Glass bubble views (macOS 26+). Gated behind HAS_LIQUID_GLASS so the
    // app still builds against pre-macOS-26 SDKs (where these types don't exist);
    // without the flag the bubbles simply don't render.
    #if HAS_LIQUID_GLASS
    private var glassContainer: NSGlassEffectContainerView!
    private var reminderGlassViews: [String: NSGlassEffectView] = [:]
    private var calendarGlassView: NSGlassEffectView?
    private var texterGlassView: NSGlassEffectView?
    private var overflowGlassView: NSGlassEffectView?
    #endif

    // Cloud puff (appearance animation)
    private var puffActive = false
    private var puffStart: TimeInterval = 0
    private let puffDuration: TimeInterval = 1.3
    private let puffRevealAt: CGFloat = 0.54 // 0.54 * 1.3 ≈ 0.7s of dust before Nikxel
    private var avatarHiddenByPuff = false

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
        super.init(frame: NSRect(x: 0, y: 0, width: NikxelView.viewWidth, height: NikxelView.viewHeight))
        NikxelView.main = self
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.magnificationFilter = .nearest
        layer?.contentsFormat = .RGBA8Uint   // not the default 16-bit float: half the backing store
        loadSprites()
        NotificationCenter.default.addObserver(
            forName: NikxelSprites.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.loadSprites()
            self?.needsDisplay = true
        }
        #if HAS_LIQUID_GLASS
        setupGlassContainer()
        #endif
        stateMachine.delegate = self
        lastTick = CACurrentMediaTime()
        runTimer(hz: 30)
        needsDisplay = true
    }

    private func runTimer(hz: Double) {
        guard hz != animHz else { return }
        animHz = hz
        animTimer?.invalidate(); animTimer = nil
        if hz > 0 {
            animTimer = Timer.scheduledTimer(withTimeInterval: 1 / hz, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let w = window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: w)
    }

    /// Hidden, on a locked screen or behind a sleeping display: no frames.
    @objc private func occlusionChanged() {
        if window?.occlusionState.contains(.visible) == true {
            lastTick = CACurrentMediaTime()
            runTimer(hz: 30)
            needsDisplay = true
        } else {
            runTimer(hz: 0)
        }
    }

    #if HAS_LIQUID_GLASS
    private func setupGlassContainer() {
        let container = NSGlassEffectContainerView(frame: bounds)
        container.autoresizingMask = [.width, .height]
        // Spacing controls the proximity at which adjacent glass views fluidly
        // merge into one blob (the "liquid" in Liquid Glass). Set wider than the
        // pixel gap between stacked bubbles so they actually merge on screen.
        container.spacing = 24
        container.contentView = NSView(frame: bounds)
        container.contentView?.autoresizingMask = [.width, .height]
        addSubview(container)
        glassContainer = container
    }
    #endif

    // Not private: NikxelCard.swift's extension draws with it too.
    func dmFont(size: CGFloat, bold: Bool = false) -> NSFont {
        let name = bold ? "DMSans-Bold" : "DMSans-Medium"
        if let f = NSFont(name: name, size: size) { return f }
        // Fallback to system if bundled font failed to register
        return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { animTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    func loadSprites() {
        if let path = Bundle.main.path(forResource: "nikxel_avatar", ofType: "png"),
           let img = NSImage(contentsOfFile: path) { fallbackAvatar = img }
        else {
            let fb = NSImage(size: NSSize(width: 64, height: 64))
            fb.lockFocus(); NSColor.systemPink.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); fb.unlockFocus()
            fallbackAvatar = fb
        }
        if let path = NikxelSprites.activePath,
           let sheet = NSImage(contentsOfFile: path) { spriteSheet = sheet }
        sheetCG = spriteSheet.flatMap(Self.decoded)
        // A swapped sheet invalidates the cached per-frame alpha mask, which is
        // what hit-testing uses -- stale masks would make the new avatar
        // clickable in the old one's silhouette.
        alphaMask = nil
        alphaMaskKey = -1
    }

    /// `img` drawn into a plain bitmap, so it stays decoded.
    private static func decoded(_ img: NSImage) -> CGImage? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    func stateRow(_ s: NikxelState) -> Int {
        switch s {
        case .idle, .walk: return 0
        case .typing, .writingMOM: return 1
        case .thinking: return 2
        case .done: return 3
        case .dragging: return 4
        case .pounce: return 5
        case .petted: return 6
        case .alert: return 7
        case .recording: return 8
        case .momReady: return 9
        }
    }

    func triggerSpringBack() { springActive = true; springStart = CACurrentMediaTime() }
    func recordKeystroke() { keyTimestamps.append(CACurrentMediaTime()) }

    /// Pixel dust cloud appearance. Avatar is hidden for the first ~45% of
    /// the animation, then pops in with a small spring-back bounce while the
    /// dust continues outward and fades.
    func triggerPuff() {
        puffActive = true
        puffStart = CACurrentMediaTime()
        avatarHiddenByPuff = true
        needsDisplay = true
    }

    func pushReminder(id: String, title: String) {
        // Dedup: ignore if already on screen.
        if reminderBubbles.contains(where: { $0.id == id }) { return }
        reminderBubbles.append(ReminderBubble(id: id, title: title, addedAt: CACurrentMediaTime()))
        needsDisplay = true
    }

    /// Shows a notification card above the avatar. Replaces any card already
    /// on screen.
    ///
    /// `lifetime` is per-card on purpose: a MOM-ready nudge can go after a few
    /// seconds, but the 10pm digest fires when nobody is watching and has to
    /// still be there when they come back, and an error should wait to be read.
    func showCard(icon: String? = nil,
                  title: String,
                  lines: [String],
                  bulleted: Bool = false,
                  kind: CardKind = .info,
                  lifetime: TimeInterval = 20,
                  action: (() -> Void)? = nil,
                  buttons: [CardButton] = []) {
        // A question waiting on an answer isn't knocked off by a passing notice.
        // ponytail: that notice is dropped, not queued; queue if it matters.
        if card?.buttons.isEmpty == false && buttons.isEmpty { return }
        card = Card(icon: icon, title: title, lines: lines, bulleted: bulleted,
                    kind: kind, addedAt: CACurrentMediaTime(), lifetime: lifetime,
                    action: action, buttons: buttons)
        needsDisplay = true
    }

    func dismissCard() {
        guard card != nil else { return }
        card = nil
        needsDisplay = true
    }

    /// Index of the card button under `p`, if any.
    func cardButton(at p: NSPoint) -> Int? {
        guard let c = card, c.opacity > 0.05 else { return nil }
        return c.buttonRects.firstIndex { $0.contains(p) }
    }

    func hitTestCard(at p: NSPoint) -> Bool {
        guard let c = card, c.opacity > 0.05 else { return false }
        return c.hitRect.contains(p)
    }

    func dismissReminder(id: String) {
        if let i = reminderBubbles.firstIndex(where: { $0.id == id }) {
            reminderBubbles.remove(at: i)
            needsDisplay = true
        }
    }

    func hitTestReminderBubble(at p: NSPoint) -> String? {
        for b in reminderBubbles.reversed() where b.hitRect.contains(p) { return b.id }
        return nil
    }

    // MARK: - Avatar hit testing
    // The view is 340x340 but the character only occupies a 156pt sprite in the
    // centre. We alpha-sample the current sprite frame so a click only counts as
    // "on Nikxel" when it lands on an opaque pixel — clicks in the surrounding
    // padding (or the transparent corners of the sprite) are ignored.
    private var alphaMask: [UInt8]?
    private var alphaMaskKey: Int = -1
    // A few points of slack around opaque pixels so clicking the very edge of the
    // character still registers, without re-engaging the empty padding.
    private let hitTolerancePx: Int = 2

    private func ensureAlphaMask() -> [UInt8]? {
        guard let cg = sheetCG else { return nil }
        let mf = (currentState == .dragging) ? 1 : frameCount
        let col = frameIndex % mf
        let row = stateRow(currentState)
        let key = row * 100 + col
        if key == alphaMaskKey, let m = alphaMask { return m }

        guard let cropped = cg.cropping(to: CGRect(x: col * 64, y: row * 64, width: 64, height: 64)) else { return nil }
        var buf = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let cctx = CGContext(
            data: &buf, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        cctx.interpolationQuality = .none
        // Drawn the same way as draw(): an unflipped bottom-left context, so the
        // buffer orientation matches what's on screen (scaled down to 64x64).
        cctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        alphaMask = buf
        alphaMaskKey = key
        return buf
    }

    /// Make the transparent padding around Nikxel click-through: only the
    /// character and its interactive bubbles consume mouse events, so clicks
    /// anywhere else fall through to whatever app is behind the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if hitTestReminderBubble(at: p) != nil { return self }
        if hitTestCard(at: p) { return self }
        if hitTestAvatar(at: p) { return self }
        return nil
    }

    /// True only when `p` (in view coords) lands on an opaque pixel of the
    /// current sprite frame, matching the live transform (facing/scale/offset).
    func hitTestAvatar(at p: NSPoint) -> Bool {
        if avatarHiddenByPuff { return false }
        let c = avatarCenter
        let cx = c.x, cy = c.y
        let signX: CGFloat = facingRight ? 1 : -1
        let s = max(scale, 0.01)
        // Invert the draw transform back into sprite-rect space [0, charSize].
        let qx = (p.x - (cx + wiggle)) / (signX * s) + halfChar
        let qy = (p.y - (cy + bounce)) / s + halfChar
        guard qx >= 0, qx <= charSize, qy >= 0, qy <= charSize else { return false }

        // No sprite sheet -> fall back to the bounding box.
        guard let mask = ensureAlphaMask() else { return true }

        // Map into the 64x64 mask. qy is measured from the bottom of the rect;
        // bitmap row 0 is the top, hence the (63 - row) flip.
        let mx = Int(qx / charSize * 64)
        let myFromBottom = Int(qy / charSize * 64)
        let baseCol = min(63, max(0, mx))
        let baseRow = min(63, max(0, 63 - myFromBottom))
        for dr in -hitTolerancePx...hitTolerancePx {
            for dc in -hitTolerancePx...hitTolerancePx {
                let r = baseRow + dr, c = baseCol + dc
                guard r >= 0, r < 64, c >= 0, c < 64 else { continue }
                if mask[(r * 64 + c) * 4 + 3] > 24 { return true }
            }
        }
        return false
    }
    func isOverheated() -> Bool {
        let count = keyTimestamps.filter { CACurrentMediaTime() - $0 < wpmWindow }.count
        return Double(count) / 5.0 * (60.0 / wpmWindow) > overheatWPM
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now

        // Always face cursor
        if currentState != .dragging {
            stateMachine.updateMouse(NSEvent.mouseLocation)
        }

        // Let clicks fall through to apps behind us whenever the cursor isn't on
        // Nikxel or one of the bubbles. Polled here (not via hitTest) because
        // ignoresMouseEvents=true stops the window receiving events at all, so we
        // must decide from the global cursor position each frame.
        if let win = window {
            let screenPt = NSEvent.mouseLocation
            let viewPt = NSPoint(x: screenPt.x - win.frame.minX,
                                 y: screenPt.y - win.frame.minY)
            let interactive = currentState == .dragging
                || hitTestReminderBubble(at: viewPt) != nil
                || hitTestCard(at: viewPt)
                || hitTestAvatar(at: viewPt)
            win.ignoresMouseEvents = !interactive
        }

        // Overheat decay (prune old keystrokes)
        keyTimestamps = keyTimestamps.filter { now - $0 < wpmWindow }

        // Frame animation
        let fps: Double = {
            switch currentState {
            case .idle: return 3
            case .walk: return 8
            case .typing: return 8
            case .thinking: return 2.5
            case .done: return 6
            case .dragging: return 0
            case .pounce: return 8
            case .petted: return 3
            case .alert: return 6
            case .recording: return 4
            case .momReady: return 6
            case .writingMOM: return 8
            }
        }()
        if fps > 0, spriteSheet != nil {
            let mf = (currentState == .dragging) ? 1 : frameCount
            frameElapsed += dt
            let interval = 1.0 / fps
            while frameElapsed >= interval { frameElapsed -= interval; frameIndex = (frameIndex + 1) % mf }
        }

        // Transform animation
        let t = now
        switch currentState {
        case .idle: bounce = CGFloat(sin(t * 3) * 2); scale = 1; wiggle = 0
        case .walk: bounce = CGFloat(sin(t * 8) * 3); scale = 1; wiggle = 0
        case .typing: wiggle = CGFloat(sin(t * 25) * 2.5); bounce = CGFloat(sin(t * 6) * 1.5); scale = 1
        case .thinking: bounce = CGFloat(sin(t * 1.5) * 1); scale = 1; wiggle = 0
        case .done:
            let p = t.truncatingRemainder(dividingBy: 0.5)
            bounce = p < 0.25 ? CGFloat(p * 4 * 40) : CGFloat((0.5 - p) * 4 * 40)
            scale = 1.1; wiggle = 0
        case .dragging:
            scale = 1.2
            wiggle = max(-18, min(18, dragLagX))
            bounce = max(-12, min(12, dragLagY))
        case .pounce:
            let pT = t.truncatingRemainder(dividingBy: 0.7)
            let phase = pT / 0.7
            if phase < 0.3 { scale = 1.0; bounce = 0 }
            else if phase < 0.5 { scale = 1.15; bounce = CGFloat((phase - 0.3) * 80) }
            else if phase < 0.8 { scale = 1.05; bounce = CGFloat((0.8 - phase) * 40) }
            else { scale = 1.0; bounce = 0 }
            wiggle = 0
        case .petted: bounce = CGFloat(sin(t * 2.5) * 1.5); scale = 1; wiggle = 0
        case .alert:
            bounce = CGFloat(abs(sin(t * 8)) * 4)
            wiggle = CGFloat(sin(t * 12) * 1.5)
            scale = 1
        case .recording:
            bounce = CGFloat(sin(t * 2) * 1.2)
            scale = 1; wiggle = 0
        case .momReady:
            let p = t.truncatingRemainder(dividingBy: 0.6)
            bounce = p < 0.3 ? CGFloat(p * 4 * 30) : CGFloat((0.6 - p) * 4 * 30)
            scale = 1.08; wiggle = 0
        case .writingMOM:
            wiggle = CGFloat(sin(t * 25) * 2.5)
            bounce = CGFloat(sin(t * 6) * 1.5)
            scale = 1
        }

        // Spring-back scale
        if springActive {
            let elapsed = t - springStart
            let progress = elapsed / springDuration
            if progress >= 1.0 { springActive = false }
            else { scale = 1.2 + CGFloat(easeOutBounce(progress)) * (1.0 - 1.2) }
        }

        // Reminder bubble fade
        reminderTargetOpacity = (reminderText != nil) ? 1 : 0
        let reminderFadeSpeed: CGFloat = 5.0
        if reminderTargetOpacity > reminderOpacity {
            reminderOpacity = min(1, reminderOpacity + CGFloat(dt) * reminderFadeSpeed)
        } else if reminderTargetOpacity < reminderOpacity {
            reminderOpacity = max(0, reminderOpacity - CGFloat(dt) * reminderFadeSpeed)
        }

        // Active texter bubble fade
        texterTargetOpacity = (activeTexterName != nil) ? 1 : 0
        let texterFadeSpeed: CGFloat = 6.0
        if texterTargetOpacity > texterOpacity {
            texterOpacity = min(1, texterOpacity + CGFloat(dt) * texterFadeSpeed)
        } else if texterTargetOpacity < texterOpacity {
            texterOpacity = max(0, texterOpacity - CGFloat(dt) * texterFadeSpeed)
        }

        // Meeting yellow dot fade
        meetingDotTargetOpacity = isInMeeting ? 1 : 0
        let meetingDotFadeSpeed: CGFloat = 4.0
        if meetingDotTargetOpacity > meetingDotOpacity {
            meetingDotOpacity = min(1, meetingDotOpacity + CGFloat(dt) * meetingDotFadeSpeed)
        } else if meetingDotTargetOpacity < meetingDotOpacity {
            meetingDotOpacity = max(0, meetingDotOpacity - CGFloat(dt) * meetingDotFadeSpeed)
        }

        // Reminders bubbles fade + GC
        if !reminderBubbles.isEmpty {
            var changed = false
            for i in reminderBubbles.indices {
                let age = now - reminderBubbles[i].addedAt
                let target: CGFloat
                if age < 0 {
                    target = 0
                } else if age < reminderFadeIn {
                    target = CGFloat(age / reminderFadeIn)
                } else if age > reminderBubbleLifetime - reminderFadeOut {
                    let r = (reminderBubbleLifetime - age) / reminderFadeOut
                    target = CGFloat(max(0, min(1, r)))
                } else {
                    target = 1
                }
                if abs(reminderBubbles[i].opacity - target) > 0.001 {
                    reminderBubbles[i].opacity = target
                    changed = true
                }
            }
            let before = reminderBubbles.count
            reminderBubbles.removeAll { now - $0.addedAt > reminderBubbleLifetime }
            if reminderBubbles.count != before || changed { needsDisplay = true }
        }

        if var c = card {
            let age = now - c.addedAt
            // A non-finite lifetime means "stay until clicked" -- used by errors.
            let target: CGFloat
            if age < cardFadeIn {
                target = CGFloat(age / cardFadeIn)
            } else if c.lifetime.isFinite && age > c.lifetime - cardFadeOut {
                target = max(0, CGFloat((c.lifetime - age) / cardFadeOut))
            } else {
                target = 1
            }
            if c.lifetime.isFinite && age > c.lifetime {
                card = nil
                needsDisplay = true
            } else if abs(c.opacity - target) > 0.001 {
                c.opacity = target
                card = c
                needsDisplay = true
            }
        }

        // Bubble animation (thinking dots only)
        let shouldShow = (currentState == .thinking)
        bubbleTargetOpacity = shouldShow ? 1 : 0
        if bubbleTargetOpacity != bubbleOpacity {
            let fadeSpeed: CGFloat = 6.0
            if bubbleTargetOpacity > bubbleOpacity {
                bubbleOpacity = min(bubbleTargetOpacity, bubbleOpacity + CGFloat(dt) * fadeSpeed)
                if bubbleOpacity >= 1 { bubbleOpacity = 1 }
                let p = bubbleOpacity
                bubbleScale = 0.8 + 0.2 * p + 0.15 * sin(p * .pi) * (1 - p)
            } else {
                bubbleOpacity = max(bubbleTargetOpacity, bubbleOpacity - CGFloat(dt) * fadeSpeed)
                bubbleScale = bubbleOpacity
            }
        }

        // Reconcile Liquid Glass bubble views with model state.
        #if HAS_LIQUID_GLASS
        layoutBubbles(cx: avatarCenter.x, cy: avatarCenter.y)
        #endif

        // Redraw only when something on screen moved. Offsets are rounded to
        // half a point -- one Retina pixel, where nearest-neighbour drawing
        // snaps them anyway. The idle bob alone used to repaint 60 times a second.
        let animating = puffActive || springActive || currentState == .dragging
            || currentState == .recording || currentState == .momReady
            || bubbleOpacity > 0 || isOverheated()
        let key: [CGFloat] = [CGFloat(frameIndex), (bounce * 2).rounded(), (wiggle * 2).rounded(), scale,
                              reminderOpacity, texterOpacity, meetingDotOpacity]
        if animating || key != drawnKey { drawnKey = key; needsDisplay = true }
        runTimer(hz: puffActive || springActive || currentState == .dragging ? 60 : 30)
    }

    func easeOutBounce(_ t: Double) -> Double {
        let t = max(0, min(1, t))
        let n1 = 7.5625, d1 = 2.75
        if t < 1/d1 { return n1 * t * t }
        else if t < 2/d1 { let t2 = t - 1.5/d1; return n1 * t2 * t2 + 0.75 }
        else if t < 2.5/d1 { let t2 = t - 2.25/d1; return n1 * t2 * t2 + 0.9375 }
        else { let t2 = t - 2.625/d1; return n1 * t2 * t2 + 0.984375 }
    }

    func stateDidChange(_ s: NikxelState) { currentState = s; frameIndex = 0; frameElapsed = 0; needsDisplay = true }
    func facingRightDidChange(_ f: Bool) { facingRight = f; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none

        let c = avatarCenter
        let cx = c.x, cy = c.y
        let charBottom = cy - halfChar

        // Drop shadow
        if currentState != .dragging {
            let shadowY = charBottom
            let alpha = 0.12 - (bounce > 0 ? bounce / 400 : 0)
            let oval = NSRect(x: cx - halfChar * 0.54, y: shadowY - 4, width: halfChar * 1.08, height: 12)
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(CGFloat(alpha)).cgColor)
            NSBezierPath(ovalIn: oval).fill()
            ctx.restoreGState()
        }

        // Character (skipped while hidden by the puff)
        if avatarHiddenByPuff {
            // fall through to draw the dust cloud below
        } else if let cg = sheetCG {
            ctx.saveGState()
            ctx.translateBy(x: cx + wiggle, y: cy + bounce)
            ctx.scaleBy(x: facingRight ? scale : -scale, y: scale)
            ctx.translateBy(x: -halfChar, y: -halfChar)
            let mf = (currentState == .dragging) ? 1 : frameCount
            let fx = CGFloat(frameIndex % mf) * 64
            let fy = CGFloat(stateRow(currentState)) * 64
            if let cropped = cg.cropping(to: CGRect(x: fx, y: fy, width: 64, height: 64)) {
                ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: charSize, height: charSize))
            }
            ctx.restoreGState()
        } else if let fb = fallbackAvatar {
            ctx.saveGState()
            ctx.translateBy(x: cx + wiggle, y: cy + bounce)
            ctx.scaleBy(x: facingRight ? scale : -scale, y: scale)
            ctx.translateBy(x: -halfChar, y: -halfChar)
            if let cg = fb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: charSize, height: charSize))
            }
            ctx.restoreGState()
        } else if !avatarHiddenByPuff { return }

        // Pixel dust puff (appearance animation, drawn on top of avatar)
        if puffActive { drawPixelPuff(ctx: ctx, cx: cx, cy: cy) }

        // Overheat red tint + steam
        if currentState != .dragging {
            let isHot = isOverheated()
            if isHot {
            let wpm = Double(keyTimestamps.count) / 5.0 * (60.0 / wpmWindow)
            let intensity = CGFloat(min(1.0, (wpm - overheatWPM) / 30.0))
            ctx.saveGState()
            ctx.translateBy(x: cx + wiggle, y: cy + bounce)
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(NSColor.red.withAlphaComponent(intensity * 0.5).cgColor)
            ctx.fill(CGRect(x: -halfChar, y: -halfChar, width: charSize, height: charSize))
            ctx.restoreGState()
            drawSteam(ctx: ctx, cx: cx, cy: cy)
            }
        }

        // Recording indicator (red pulsing dot + elapsed timer)
        if currentState == .recording, let started = recordingStartedAt {
            let elapsed = CACurrentMediaTime() - started
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            let timer = String(format: "%d:%02d", mins, secs)

            let pulse = 0.7 + 0.3 * sin(CACurrentMediaTime() * 4)
            let dotRadius: CGFloat = 5
            let dotX = cx - 28
            let dotY = headY(16)
            ctx.saveGState()
            ctx.setFillColor(NSColor.red.withAlphaComponent(CGFloat(pulse)).cgColor)
            ctx.fillEllipse(in: NSRect(x: dotX - dotRadius, y: dotY - dotRadius, width: dotRadius*2, height: dotRadius*2))
            ctx.restoreGState()

            // Timer text
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black,
                .strokeWidth: -3
            ]
            let str = NSAttributedString(string: timer, attributes: attrs)
            let textSize = str.size()
            str.draw(at: NSPoint(x: dotX + 10, y: dotY - textSize.height/2))
        }

        // Meeting indicator (yellow dot above avatar)
        if meetingDotOpacity > 0.01 {
            let dotRadius: CGFloat = 6
            let dotX = cx
            let dotY = headY(14)
            ctx.saveGState()
            // Outer glow
            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(meetingDotOpacity * 0.3).cgColor)
            ctx.fillEllipse(in: NSRect(x: dotX - dotRadius - 3, y: dotY - dotRadius - 3, width: (dotRadius+3)*2, height: (dotRadius+3)*2))
            // Inner dot
            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(meetingDotOpacity).cgColor)
            ctx.fillEllipse(in: NSRect(x: dotX - dotRadius, y: dotY - dotRadius, width: dotRadius*2, height: dotRadius*2))
            ctx.restoreGState()
        }

        // (Calendar bubble + Apple Reminders bubbles are now real NSGlassEffectView
        // subviews managed in layoutBubbles(), called from tick().)

        drawCard(ctx: ctx, cx: cx, cy: cy)

        // MOM ready sparkle
        if currentState == .momReady {
            let now = CACurrentMediaTime()
            for i in 0..<5 {
                let phase = (now * 3 + Double(i) * 0.7).truncatingRemainder(dividingBy: 1.0)
                let angle = Double(i) * .pi * 2 / 5
                let dist: CGFloat = 30 + CGFloat(phase * 25)
                let sx = cx + CGFloat(cos(angle)) * dist
                let sy = cy + CGFloat(sin(angle)) * dist + 10
                let alpha = CGFloat(1.0 - phase) * 0.9
                let size: CGFloat = 4
                ctx.saveGState()
                ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(alpha).cgColor)
                ctx.fillEllipse(in: NSRect(x: sx - size/2, y: sy - size/2, width: size, height: size))
                ctx.restoreGState()
            }
        }

        // Thinking dots (on top of character)
        if currentState == .thinking, bubbleOpacity > 0.01 {
            ctx.saveGState()
            ctx.setAlpha(CGFloat(bubbleOpacity))
            let dotY = headY(22)
            let dotSpacing: CGFloat = 16
            let dotRadius: CGFloat = 5
            let dotCount = min(3, frameIndex + 1)
            for i in 0..<dotCount {
                let dx = cx + CGFloat(i - 1) * dotSpacing
                let dotRect = NSRect(x: dx - dotRadius, y: dotY - dotRadius, width: dotRadius*2, height: dotRadius*2)
                ctx.saveGState()
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: dotRect.insetBy(dx: -2, dy: -2))
                ctx.restoreGState()
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: dotRect)
            }
            ctx.restoreGState()
        }
    }

    // MARK: - Liquid Glass bubble layout
    #if HAS_LIQUID_GLASS

    private struct GlassMetrics {
        static let pad: CGFloat = 16
        static let fontSize: CGFloat = 14
        static let dotDiameter: CGFloat = 7
        static let dotGap: CGFloat = 10
        static let maxWidth: CGFloat = 280
        static let stepY: CGFloat = 48
    }

    private func makeBubbleContent(title: String, dotColor: NSColor) -> (NSView, NSSize) {
        let pad = GlassMetrics.pad
        let dotDiameter = GlassMetrics.dotDiameter
        let dotGap = GlassMetrics.dotGap
        let maxWidth = GlassMetrics.maxWidth

        let font = dmFont(size: GlassMetrics.fontSize, bold: false)
        // White text with subtle shadow for legibility against varied wallpapers
        // showing through the clear glass.
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        textShadow.shadowOffset = NSSize(width: 0, height: -1)
        textShadow.shadowBlurRadius = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 0.1,
            .shadow: textShadow
        ]
        let attrStr = NSAttributedString(string: title, attributes: attrs)
        let textSize = attrStr.size()
        let contentW = min(maxWidth - pad * 2, dotDiameter + dotGap + textSize.width)
        let contentH = max(dotDiameter, textSize.height)
        let bw = contentW + pad * 2
        let bh = contentH + pad * 2

        let content = NSView(frame: NSRect(x: 0, y: 0, width: bw, height: bh))
        content.wantsLayer = true

        // Accent dot
        let dotY = (bh - dotDiameter) / 2
        let dot = NSView(frame: NSRect(x: pad, y: dotY, width: dotDiameter, height: dotDiameter))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = dotDiameter / 2
        content.addSubview(dot)

        // Title label
        let labelX = pad + dotDiameter + dotGap
        let labelW = bw - labelX - pad
        let label = NSTextField(labelWithAttributedString: attrStr)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.frame = NSRect(
            x: labelX,
            y: (bh - textSize.height) / 2,
            width: labelW,
            height: textSize.height
        )
        content.addSubview(label)

        return (content, NSSize(width: bw, height: bh))
    }

    private func makeGlassBubble(title: String, dotColor: NSColor) -> (NSGlassEffectView, NSSize) {
        let (content, size) = makeBubbleContent(title: title, dotColor: dotColor)
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        // .clear samples the screen backdrop for the refractive look. .regular
        // expects an opaque UI material backdrop and renders dark on a
        // transparent borderless window.
        glass.style = .clear
        glass.cornerRadius = size.height / 2 // full pill shape
        glass.tintColor = nil
        glass.contentView = content
        return (glass, size)
    }

    private func makeOverflowPill(count: Int) -> (NSGlassEffectView, NSSize) {
        let font = dmFont(size: 11, bold: true)
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        textShadow.shadowOffset = NSSize(width: 0, height: -1)
        textShadow.shadowBlurRadius = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 0.3,
            .shadow: textShadow
        ]
        let str = NSAttributedString(string: "+\(count) more", attributes: attrs)
        let sz = str.size()
        let bw = sz.width + 22
        let bh = sz.height + 12

        let content = NSView(frame: NSRect(x: 0, y: 0, width: bw, height: bh))
        content.wantsLayer = true
        let label = NSTextField(labelWithAttributedString: str)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.frame = NSRect(x: (bw - sz.width) / 2, y: (bh - sz.height) / 2, width: sz.width, height: sz.height)
        content.addSubview(label)

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: NSSize(width: bw, height: bh)))
        glass.style = .clear
        glass.cornerRadius = bh / 2
        glass.tintColor = nil
        glass.contentView = content
        return (glass, NSSize(width: bw, height: bh))
    }

    private func layoutBubbles(cx: CGFloat, cy: CGFloat) {
        guard let host = glassContainer.contentView else { return }

        // --- Calendar bubble (single, beneath the reminder stack) ---
        if let text = reminderText, reminderOpacity > 0.001 {
            let glass: NSGlassEffectView
            if let existing = calendarGlassView {
                glass = existing
            } else {
                let (g, _) = makeGlassBubble(title: text, dotColor: .systemBlue)
                host.addSubview(g)
                calendarGlassView = g
                glass = g
            }
            // Refresh content if text changed
            if let label = glass.contentView?.subviews.compactMap({ $0 as? NSTextField }).first,
               label.stringValue != text {
                let (newContent, newSize) = makeBubbleContent(title: text, dotColor: .systemBlue)
                glass.contentView = newContent
                glass.frame = NSRect(origin: glass.frame.origin, size: newSize)
            }
            let size = glass.frame.size
            glass.frame.origin = NSPoint(x: cx - size.width / 2, y: headY(24, height: size.height))
            glass.alphaValue = reminderOpacity
        } else if let g = calendarGlassView {
            g.removeFromSuperview()
            calendarGlassView = nil
        }

        // --- Texter bubble (who's texting via chatbot, above avatar) ---
        if let name = activeTexterName, texterOpacity > 0.001 {
            let dotColor = NSColor.systemGreen
            let displayText = "💬 \(name) is texting..."
            let glass: NSGlassEffectView
            if let existing = texterGlassView {
                glass = existing
            } else {
                let (g, _) = makeGlassBubble(title: displayText, dotColor: dotColor)
                host.addSubview(g)
                texterGlassView = g
                glass = g
            }
            if let label = glass.contentView?.subviews.compactMap({ $0 as? NSTextField }).first,
               label.stringValue != displayText {
                let (newContent, newSize) = makeBubbleContent(title: displayText, dotColor: dotColor)
                glass.contentView = newContent
                glass.frame = NSRect(origin: glass.frame.origin, size: newSize)
            }
            let size = glass.frame.size
            glass.frame.origin = NSPoint(x: cx - size.width / 2, y: headY(36, height: size.height))
            glass.alphaValue = texterOpacity
        } else if let g = texterGlassView {
            g.removeFromSuperview()
            texterGlassView = nil
        }

        // --- Apple Reminders stack (3 visible, newest top) ---
        // baseY is the bottom-most visible bubble's centerY. Tuned to fit within
        // the 340pt window above the calendar bubble lane.
        let visibleCount = min(3, reminderBubbles.count)
        let startIdx = reminderBubbles.count - visibleCount
        let baseY = headY(52)
        // Below the feet the stack grows downward.
        let stepY = GlassMetrics.stepY * (bubblesBelow ? -1 : 1)

        // Clear hit rects on the model first; we'll repopulate for visible ones.
        for i in reminderBubbles.indices { reminderBubbles[i].hitRect = .zero }

        var aliveIds = Set<String>()
        for displayIdx in 0..<visibleCount {
            let i = startIdx + displayIdx
            let b = reminderBubbles[i]
            aliveIds.insert(b.id)

            let glass: NSGlassEffectView
            if let existing = reminderGlassViews[b.id] {
                glass = existing
            } else {
                let (g, _) = makeGlassBubble(title: b.title, dotColor: .systemOrange)
                host.addSubview(g)
                reminderGlassViews[b.id] = g
                glass = g
            }
            let size = glass.frame.size
            let centerY = baseY + CGFloat(displayIdx) * stepY
            let origin = NSPoint(x: cx - size.width / 2, y: centerY - size.height / 2)
            glass.frame.origin = origin
            glass.alphaValue = b.opacity
            reminderBubbles[i].hitRect = NSRect(origin: origin, size: size)
        }

        // Remove views whose model is gone OR which fell off the visible window.
        for (id, view) in reminderGlassViews where !aliveIds.contains(id) {
            view.removeFromSuperview()
            reminderGlassViews.removeValue(forKey: id)
        }

        // --- Overflow pill above the top bubble ---
        let overflow = reminderBubbles.count - visibleCount
        if overflow > 0, visibleCount > 0 {
            let (glass, size): (NSGlassEffectView, NSSize) = {
                if let existing = overflowGlassView {
                    // Rebuild if count changed (label is baked into content).
                    if let label = existing.contentView?.subviews.compactMap({ $0 as? NSTextField }).first,
                       label.stringValue != "+\(overflow) more" {
                        let (g, s) = makeOverflowPill(count: overflow)
                        existing.removeFromSuperview()
                        host.addSubview(g)
                        overflowGlassView = g
                        return (g, s)
                    }
                    return (existing, existing.frame.size)
                }
                let (g, s) = makeOverflowPill(count: overflow)
                host.addSubview(g)
                overflowGlassView = g
                return (g, s)
            }()
            let lastY = baseY + CGFloat(visibleCount - 1) * stepY
            glass.frame.origin = NSPoint(x: cx - size.width / 2,
                                         y: bubblesBelow ? lastY - 34 - size.height : lastY + 34)
            glass.alphaValue = 1
        } else if let g = overflowGlassView {
            g.removeFromSuperview()
            overflowGlassView = nil
        }
    }
    #endif

    /// Chunky pixel-art dust cloud. Particles are integer-aligned filled
    /// squares (not soft ellipses) to match the pixel sprite aesthetic.
    /// Phases:
    ///   0% – 45%: avatar is hidden, dust expands from a tight cluster
    ///   45%: avatar pops in with a spring-back bounce
    ///   45% – 100%: dust continues outward and fades
    func drawPixelPuff(ctx: CGContext, cx: CGFloat, cy: CGFloat) {
        let now = CACurrentMediaTime()
        let raw = (now - puffStart) / puffDuration
        if raw >= 1 {
            puffActive = false
            if avatarHiddenByPuff { avatarHiddenByPuff = false } // safety
            needsDisplay = true
            return
        }
        let progress = CGFloat(max(0, raw))
        // Ease-out cubic for outward expansion.
        let eased = 1 - pow(1 - progress, 2.5)

        let baseRadius: CGFloat = 4
        let maxRadius: CGFloat = 104
        let radius = baseRadius + (maxRadius - baseRadius) * eased

        // Reveal avatar partway, kick a small spring-back bounce.
        if avatarHiddenByPuff, progress >= puffRevealAt {
            avatarHiddenByPuff = false
            triggerSpringBack()
        }

        // Pixel palette — clean whites for cartoon-dust feel.
        let palette: [NSColor] = [
            NSColor.white,
            NSColor(calibratedWhite: 0.96, alpha: 1),
            NSColor(calibratedWhite: 0.86, alpha: 1),
            NSColor(calibratedWhite: 0.74, alpha: 1)
        ]
        let baseAlpha = max(0, 1 - progress) * 0.95

        // Outer ring of 14 large pixels, slight angle + radius jitter so it
        // doesn't read as a perfect circle.
        let outerCount = 14
        for i in 0..<outerCount {
            let baseAngle = (CGFloat(i) / CGFloat(outerCount)) * .pi * 2
            let angleJ = CGFloat((i * 47) % 11 - 5) * 0.045
            let angle = baseAngle + angleJ
            let radJ = CGFloat((i * 31) % 9 - 4) * 2.5
            let r = radius + radJ
            let pxCenter = cx + cos(angle) * r
            let pyCenter = cy + sin(angle) * r

            let size = floor(max(3, 9 - progress * 5)) // 9px → 4px
            let px = floor(pxCenter - size / 2)
            let py = floor(pyCenter - size / 2)

            ctx.saveGState()
            let color = palette[i % palette.count].withAlphaComponent(baseAlpha)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: px, y: py, width: size, height: size))
            ctx.restoreGState()
        }

        // Inner scatter — denser early, sparse late. Deterministic by index so
        // particles stay put frame to frame (no flickering chaos).
        let scatterCount = Int((1 - progress) * 18) + 8
        for i in 0..<scatterCount {
            let seedA = Double((i * 73) % 360) * .pi / 180
            let seedR = CGFloat((i * 53) % 100) / 100.0 * radius * 0.8 + 4
            let pxCenter = cx + CGFloat(cos(seedA)) * seedR
            let pyCenter = cy + CGFloat(sin(seedA)) * seedR
            let size: CGFloat = (i % 4 == 0) ? 6 : 4
            let px = floor(pxCenter - size / 2)
            let py = floor(pyCenter - size / 2)
            let alphaJ = CGFloat((i * 19) % 100) / 100.0 * 0.5 + 0.5
            let alpha = baseAlpha * alphaJ
            ctx.saveGState()
            ctx.setFillColor(palette[i % palette.count].withAlphaComponent(alpha).cgColor)
            ctx.fill(CGRect(x: px, y: py, width: size, height: size))
            ctx.restoreGState()
        }

        // Bright dense core for the first beat — visually obscures the avatar
        // while it's hidden so the reveal feels like it emerges from the cloud.
        if progress < 0.35 {
            let coreFade = 1 - (progress / 0.35)
            let coreSize: CGFloat = floor(64 * coreFade + 28)
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.withAlphaComponent(coreFade * 0.9).cgColor)
            ctx.fill(CGRect(
                x: floor(cx - coreSize / 2),
                y: floor(cy - coreSize / 2),
                width: coreSize,
                height: coreSize
            ))
            ctx.restoreGState()
        }

        needsDisplay = true
    }

    func drawSteam(ctx: CGContext, cx: CGFloat, cy: CGFloat) {
        let now = CACurrentMediaTime()
        let steamY = cy + halfChar - 15
        for i in 0..<3 {
            let phase = (now * 2.5 + Double(i) * 1.1).truncatingRemainder(dividingBy: 2.2)
            let x = cx + CGFloat(i - 1) * 14 + CGFloat(sin(now + Double(i)) * 6)
            let y = steamY + CGFloat(phase * 25)
            let alpha = CGFloat(1.0 - phase / 2.2) * 0.7
            let size: CGFloat = 3 + CGFloat(phase * 4)
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: NSRect(x: x - size/2, y: y - size/2, width: size, height: size))
            ctx.restoreGState()
        }
    }

}
