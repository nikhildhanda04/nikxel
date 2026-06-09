import Cocoa
import CoreGraphics

enum NikxelState: Equatable {
    case idle, walk, typing, thinking, done, dragging, pounce, petted
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

    func setState(_ s: NikxelState) { state = s }
    func updateMouse(_ pos: CGPoint) { facingRight = pos.x > self.position.x }

    func triggerTyping() {
        setState(.typing)
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }

    func triggerDone() {
        setState(.done)
        doneTimer?.invalidate()
        doneTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }

    func triggerPounce() {
        setState(.pounce)
        pounceTimer?.invalidate()
        pounceTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }

    func triggerPetted() {
        setState(.petted)
        pettedTimer?.invalidate()
        pettedTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.setState(.idle) }
    }
}
