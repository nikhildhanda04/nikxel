import Cocoa

class NikxelWindow: NSWindow {
    let stateMachine: StateMachine
    var nikxelView: NikxelView?
    private var dragOffset: NSPoint = .zero
    private var dragging = false
    private var prevDragPos: NSPoint = .zero
    private var prevDragTime: TimeInterval = 0

    var onDoubleClick: (() -> Void)?

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
        let screen = NSScreen.main ?? NSScreen.screens.first!
        // Taller than wide: room for notification cards above the avatar, or
        // below it near the top of the screen. Starts with the avatar centred.
        let w = NikxelView.viewWidth, h = NikxelView.viewHeight
        let frame = NSRect(x: screen.frame.midX - w/2,
                           y: screen.frame.midY - NikxelView.avatarBottomInset,
                           width: w, height: h)

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NikxelView(stateMachine: stateMachine)
        contentView = view
        nikxelView = view
        acceptsMouseMovedEvents = true

        view.onMoveTo = { [weak self] p in self?.setFrameOrigin(p) }
    }

    /// Borderless windows still get pushed down out of the menu bar; the
    /// avatar's own clamp in mouseDragged is the only limit wanted.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func mouseDown(with event: NSEvent) {
        // Reminder bubble hit-test takes priority over drag/double-click so a tap
        // on a bubble completes the reminder without engaging the recording toggle.
        if let view = nikxelView {
            let pInView = view.convert(event.locationInWindow, from: nil)
            if let id = view.hitTestReminderBubble(at: pInView) {
                view.onReminderTapped?(id)
                view.dismissReminder(id: id)
                return
            }
            // Same priority for the end-of-day card: tapping it opens the
            // summary instead of picking Nikxel up.
            if view.hitTestCard(at: pInView) {
                if let c = view.card, !c.buttons.isEmpty {
                    // A question: only its buttons answer it.
                    guard let i = view.cardButton(at: pInView) else { return }
                    view.card = nil   // before the action, which may ask the next question
                    view.needsDisplay = true
                    c.buttons[i].action()
                    return
                }
                view.card?.action?()
                view.dismissCard()
                return
            }
            // Only engage drag / double-click when the click actually lands on the
            // character. Clicks in the surrounding transparent padding are ignored
            // so they don't accidentally pick Nikxel up.
            if !view.hitTestAvatar(at: pInView) {
                dragging = false
                return
            }
        }

        if event.clickCount >= 2 {
            dragging = false
            onDoubleClick?()
            return
        }
        dragOffset = event.locationInWindow
        dragging = true
        stateMachine.setState(.dragging)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let loc = NSEvent.mouseLocation
        let now = CACurrentMediaTime()

        // Velocity tracking for inertia wiggle
        let dt = now - prevDragTime
        if dt > 0.001 {
            nikxelView?.dragVelocity = CGPoint(
                x: (loc.x - prevDragPos.x) / CGFloat(dt),
                y: (loc.y - prevDragPos.y) / CGFloat(dt)
            )
        }
        prevDragPos = loc
        prevDragTime = now

        var origin = NSPoint(x: loc.x - dragOffset.x, y: loc.y - dragOffset.y)
        // Clamp the avatar, not the window: the window has 90+ pt of empty
        // padding round the sprite, which kept Nikxel well off the edges.
        // Sides by half the sprite (its 64 px frame is mostly transparent at
        // the sides), feet on the bottom edge, head under the menu bar.
        if let scr = screen, let view = nikxelView {
            let a = view.avatarCenter, h = view.halfChar
            let f = scr.frame
            origin.x = max(f.minX - a.x + h / 2, min(origin.x, f.maxX - a.x - h / 2))
            // Top stops under the menu bar: visibleFrame leaves it out.
            let top = scr.visibleFrame.maxY
            origin.y = max(f.minY - a.y + h, min(origin.y, top - a.y - h))
            // Under ~220 pt of headroom (a 5-line card plus its tail), the
            // bubbles go under the feet instead.
            view.bubblesBelow = top - (origin.y + a.y + h) < 220
        }
        setFrameOrigin(origin)
        stateMachine.position = origin
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        // Don't disturb the recording (headphone) animation when releasing a drag.
        if stateMachine.state == .recording { return }
        stateMachine.setState(.idle)
        nikxelView?.triggerSpringBack()
    }

    override func mouseMoved(with event: NSEvent) {
        // Cursor facing handled by view's tick loop
    }
}
