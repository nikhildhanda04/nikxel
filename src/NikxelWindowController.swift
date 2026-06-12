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
        let sz: CGFloat = 340
        let frame = NSRect(x: screen.frame.midX - sz/2, y: screen.frame.midY - sz/2, width: sz, height: sz)

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 2)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NikxelView(stateMachine: stateMachine)
        contentView = view
        nikxelView = view
        acceptsMouseMovedEvents = true

        view.onMoveTo = { [weak self] p in self?.setFrameOrigin(p) }
    }

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
        if let scr = screen {
            origin.x = max(0, min(origin.x, scr.frame.width - frame.width))
            origin.y = max(0, min(origin.y, scr.frame.height - frame.height))
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
