import Foundation
import CoreGraphics
import QuartzCore

class InputHandler {
    let stateMachine: StateMachine
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    weak var nikxelView: NikxelView?

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
    }

    func startMonitoring() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let handler = Unmanaged<InputHandler>.fromOpaque(refcon).takeUnretainedValue()
                if type == .keyDown {
                    handler.stateMachine.triggerTyping()
                    handler.nikxelView?.recordKeystroke()
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap. Accessibility permission needed.")
            return
        }
        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stopMonitoring() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil; runLoopSource = nil
    }
}
