import Cocoa
import CoreGraphics

enum NikxelState: Equatable {
    case idle, walk, typing, thinking, done, dragging, pounce, petted
    case alert, recording, momReady, writingMOM
}

protocol StateMachineDelegate: AnyObject {
    func stateDidChange(_ state: NikxelState)
    func facingRightDidChange(_ facingRight: Bool)
}

class StateMachine {
    weak var delegate: StateMachineDelegate?

    var state: NikxelState = .idle { didSet { if oldValue != state { delegate?.stateDidChange(state) }}}
    var facingRight: Bool = true { didSet { if oldValue != facingRight { delegate?.facingRightDidChange(facingRight) }}}
    var position: CGPoint = .zero

    private var typingTimer: Timer?
    private var doneTimer: Timer?
    private var pounceTimer: Timer?
    private var pettedTimer: Timer?
    private var alertTimer: Timer?
    private var momReadyTimer: Timer?

    func setState(_ s: NikxelState) {
        // Recording (headphone) has priority over everything: no dragging, thinking,
        // typing, alert, etc. while recording. Only stopRecording() can leave .recording,
        // and it bypasses this filter by writing `state` directly.
        if state == .recording && s != .recording { return }
        // writingMOM is sticky for the same reason — OCM seeing opencode CPU would
        // otherwise flip it to .thinking. Only endWritingMOM() can leave.
        if state == .writingMOM && s != .writingMOM { return }
        // While the user is actively typing, AgentMonitor would otherwise stomp
        // the .typing state with .thinking every 1.5 s (any running claude/opencode
        // is high CPU). Block that so typing animation gets to play its frames.
        // The 0.5 s typing timer falls back to .idle, after which AgentMonitor's
        // next tick correctly sets .thinking.
        if state == .typing && s == .thinking { return }
        state = s
    }
    func updateMouse(_ pos: CGPoint) { facingRight = pos.x > self.position.x }

    func triggerTyping() {
        if state == .recording { return }
        setState(.typing)
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }

    func triggerDone() {
        guard state != .recording else { return }
        setState(.done)
        doneTimer?.invalidate()
        doneTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }

    func triggerPounce() {
        guard state != .recording else { return }
        setState(.pounce)
        pounceTimer?.invalidate()
        pounceTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }

    func triggerPetted() {
        guard state != .recording else { return }
        setState(.petted)
        pettedTimer?.invalidate()
        pettedTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }

    func triggerAlert() {
        if state == .recording { return }
        setState(.alert)
        alertTimer?.invalidate()
        alertTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }

    func startRecording() { state = .recording }
    func stopRecording() { if state == .recording { state = .idle } }

    func startWritingMOM() { state = .writingMOM }
    func endWritingMOM() { if state == .writingMOM { state = .idle } }

    func triggerMomReady() {
        setState(.momReady)
        momReadyTimer?.invalidate()
        momReadyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }
}
