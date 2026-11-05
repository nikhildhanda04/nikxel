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

    private var frameIndex: Int = 0
    private var frameElapsed: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private let charSize: CGFloat = 156
    private let halfChar: CGFloat = 78
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
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 340))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.magnificationFilter = .nearest
        loadSprites()
        #if HAS_LIQUID_GLASS
        setupGlassContainer()
        #endif
        stateMachine.delegate = self
        lastTick = CACurrentMediaTime()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in self?.tick() }
        needsDisplay = true
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

    private func dmFont(size: CGFloat, bold: Bool = false) -> NSFont {
        let name = bold ? "DMSans-Bold" : "DMSans-Medium"
        if let f = NSFont(name: name, size: size) { return f }
        // Fallback to system if bundled font failed to register
        return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { animTimer?.invalidate() }

    func loadSprites() {
        if let path = Bundle.main.path(forResource: "nikxel_avatar", ofType: "png"),
           let img = NSImage(contentsOfFile: path) { fallbackAvatar = img }
        else {
            let fb = NSImage(size: NSSize(width: 64, height: 64))
            fb.lockFocus(); NSColor.systemPink.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); fb.unlockFocus()
            fallbackAvatar = fb
        }
        if let path = Bundle.main.path(forResource: "sprites", ofType: "png"),
           let sheet = NSImage(contentsOfFile: path) { spriteSheet = sheet }
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
        guard let sheet = spriteSheet,
              let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
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
        if hitTestAvatar(at: p) { return self }
        return nil
    }

    /// True only when `p` (in view coords) lands on an opaque pixel of the
    /// current sprite frame, matching the live transform (facing/scale/offset).
    func hitTestAvatar(at p: NSPoint) -> Bool {
        if avatarHiddenByPuff { return false }
        let cx = bounds.midX, cy = bounds.midY
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
        layoutBubbles(cx: bounds.midX, cy: bounds.midY)
        #endif

        needsDisplay = true
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

        let cx = bounds.midX, cy = bounds.midY
        let charBottom = cy - halfChar

        // Drop shadow
        if currentState != .dragging {
            let shadowY = charBottom
            let alpha = 0.12 - (bounce > 0 ? bounce / 400 : 0)
            let oval = NSRect(x: cx - 42, y: shadowY - 4, width: 84, height: 12)
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(CGFloat(alpha)).cgColor)
            NSBezierPath(ovalIn: oval).fill()
            ctx.restoreGState()
        }

        // Character (skipped while hidden by the puff)
        if avatarHiddenByPuff {
            // fall through to draw the dust cloud below
        } else if let sheet = spriteSheet {
            ctx.saveGState()
            ctx.translateBy(x: cx + wiggle, y: cy + bounce)
            ctx.scaleBy(x: facingRight ? scale : -scale, y: scale)
            ctx.translateBy(x: -halfChar, y: -halfChar)
            let mf = (currentState == .dragging) ? 1 : frameCount
            let fx = CGFloat(frameIndex % mf) * 64
            let fy = CGFloat(stateRow(currentState)) * 64
            if let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let cropped = cg.cropping(to: CGRect(x: fx, y: fy, width: 64, height: 64)) {
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
            let dotY = cy + halfChar + 16
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
            let dotY = cy + halfChar + 14
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
            let dotY = cy + halfChar + 22
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
            glass.frame.origin = NSPoint(x: cx - size.width / 2, y: cy + halfChar + 24)
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
            glass.frame.origin = NSPoint(x: cx - size.width / 2, y: cy + halfChar + 36)
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
        let baseY = cy + halfChar + 52
        let stepY = GlassMetrics.stepY

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
            let topY = baseY + CGFloat(visibleCount - 1) * stepY + 34
            glass.frame.origin = NSPoint(x: cx - size.width / 2, y: topY)
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
