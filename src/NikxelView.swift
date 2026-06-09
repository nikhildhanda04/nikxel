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
        case .typing: return 1
        case .thinking: return 2
        case .done: return 3
        case .dragging: return 4
        case .pounce: return 5
        case .petted: return 6
        }
    }

    func triggerSpringBack() { springActive = true; springStart = CACurrentMediaTime() }
    func recordKeystroke() { keyTimestamps.append(CACurrentMediaTime()) }
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
        }

        // Spring-back scale
        if springActive {
            let elapsed = t - springStart
            let progress = elapsed / springDuration
            if progress >= 1.0 { springActive = false }
            else { scale = 1.2 + CGFloat(easeOutBounce(progress)) * (1.0 - 1.2) }
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
