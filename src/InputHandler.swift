import Foundation
import CoreGraphics
import ApplicationServices
import QuartzCore
import Cocoa

class InputHandler {
    let stateMachine: StateMachine
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trustPollTimer: Timer?
    private var didShowAccessibilityAlert = false
    weak var nikxelView: NikxelView?

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
    }

    func startMonitoring() {
        // Trigger the system Accessibility prompt the first time the app needs it,
        // then either install the event tap or wait for the user to grant access.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if trusted {
            installEventTap()
        } else {
            showAccessibilityAlertOnce()
            startWaitingForTrust()
        }
    }

    func stopMonitoring() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil; runLoopSource = nil
    }

    private func installEventTap() {
        guard eventTap == nil else { return }
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
            // tapCreate can still return nil if the process was just untrusted at the moment of the call.
            // Fall back to polling — when the user actually flips the switch, we'll pick it up.
            startWaitingForTrust()
            return
        }
        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func startWaitingForTrust() {
        guard trustPollTimer == nil else { return }
        // Polls AXIsProcessTrusted() every 2 s. As soon as the user flips the switch
        // in System Settings, we install the event tap — no app restart needed.
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                self.trustPollTimer?.invalidate()
                self.trustPollTimer = nil
                self.installEventTap()
            }
        }
    }

    private func showAccessibilityAlertOnce() {
        guard !didShowAccessibilityAlert else { return }
        didShowAccessibilityAlert = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility access needed"
            alert.informativeText = "Nikxel needs Accessibility access to detect typing — that's what powers the typing animation and the overheat (red + steam) state when you type fast.\n\nOpen System Settings → Privacy & Security → Accessibility and enable Nikxel. The typing animation will start automatically once you grant access; no restart needed."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
