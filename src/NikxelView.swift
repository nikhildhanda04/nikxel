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

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 340))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.magnificationFilter = .nearest
        loadSprites()
        stateMachine.delegate = self
        lastTick = CACurrentMediaTime()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in self?.tick() }
        needsDisplay = true
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

        // Character
        if let sheet = spriteSheet {
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
        } else { return }

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

        // Reminder bubble (calendar)
        if let text = reminderText, reminderOpacity > 0.01 {
            ctx.saveGState()
            ctx.setAlpha(reminderOpacity)
            let pad: CGFloat = 10
            let fontSize: CGFloat = 13
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let textSize = attrStr.size()
            let bw = min(260, textSize.width + pad * 2)
            let bh = textSize.height + pad * 2
            let bx = cx - bw/2
            let by = cy + halfChar + 24
            let rect = NSRect(x: bx, y: by, width: bw, height: bh)
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
            path.fill()
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.2).cgColor)
            path.lineWidth = 1
            path.stroke()
            attrStr.draw(at: NSPoint(x: bx + pad, y: by + pad))
            ctx.restoreGState()
        }

        // Reminders bubbles (Apple Reminders due today, tap-to-complete)
        if !reminderBubbles.isEmpty {
            drawReminderBubbles(ctx: ctx, cx: cx, cy: cy)
        }

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

    func drawReminderBubbles(ctx: CGContext, cx: CGFloat, cy: CGFloat) {
        // Visible window: 3 most recent. Newest at the top, oldest of the visible
        // 3 closest to the avatar (lowest y). Stack above the calendar bubble lane
        // (which sits at cy + halfChar + 24).
        let visibleCount = min(3, reminderBubbles.count)
        let startIdx = reminderBubbles.count - visibleCount
        let baseY = cy + halfChar + 70
        let stepY: CGFloat = 40
        let pad: CGFloat = 10
        let fontSize: CGFloat = 13
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.black
        ]

        // First clear all hit rects so off-screen entries can't catch clicks.
        for i in reminderBubbles.indices { reminderBubbles[i].hitRect = .zero }

        for displayIdx in 0..<visibleCount {
            let i = startIdx + displayIdx
            let b = reminderBubbles[i]
            let centerY = baseY + CGFloat(displayIdx) * stepY
            let titleText = "📋 \(b.title)"
            let attrStr = NSAttributedString(string: titleText, attributes: attrs)
            let textSize = attrStr.size()
            let bw = min(260, textSize.width + pad * 2)
            let bh = textSize.height + pad * 2
            let bx = cx - bw / 2
            let by = centerY - bh / 2
            let rect = NSRect(x: bx, y: by, width: bw, height: bh)

            ctx.saveGState()
            ctx.setAlpha(b.opacity)
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
            path.fill()
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.2).cgColor)
            path.lineWidth = 1
            path.stroke()
            // Truncate the text horizontally to fit the bubble width.
            let textRect = NSRect(x: bx + pad, y: by + pad, width: bw - pad * 2, height: textSize.height)
            let truncated = NSMutableAttributedString(attributedString: attrStr)
            let pstyle = NSMutableParagraphStyle()
            pstyle.lineBreakMode = .byTruncatingTail
            truncated.addAttribute(.paragraphStyle, value: pstyle, range: NSRange(location: 0, length: truncated.length))
            truncated.draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
            ctx.restoreGState()

            reminderBubbles[i].hitRect = rect
        }

        // Overflow pill above the top bubble.
        let overflow = reminderBubbles.count - visibleCount
        if overflow > 0 {
            let label = "+\(overflow) more"
            let pillAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let pillStr = NSAttributedString(string: label, attributes: pillAttrs)
            let sz = pillStr.size()
            let bw = sz.width + 16
            let bh = sz.height + 6
            let topY = baseY + CGFloat(visibleCount - 1) * stepY + 30
            let bx = cx - bw / 2
            let rect = NSRect(x: bx, y: topY, width: bw, height: bh)
            ctx.saveGState()
            let path = NSBezierPath(roundedRect: rect, xRadius: bh / 2, yRadius: bh / 2)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            path.fill()
            pillStr.draw(at: NSPoint(x: bx + 8, y: topY + 3))
            ctx.restoreGState()
        }
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
