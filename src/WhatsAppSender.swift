import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Message sending: find the input element, paste text, click send.
/// All AX calls must happen on the main thread.
enum WhatsAppSender {

    // MARK: - Input / Send button discovery

    static func findInputElement(in window: AXUIElement) -> AXUIElement? {
        var result: AXUIElement?
        var bestY: CGFloat = .greatestFiniteMagnitude

        func search(_ element: AXUIElement, depth: Int) {
            if depth > 18 || result != nil { return }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            let isInputRole = (role == "AXTextArea" || role == "AXGroup")

            if isInputRole {
                var descRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
                let desc = (descRef as? String) ?? ""
                if desc.lowercased().contains("type a message") || desc.lowercased().contains("message") {
                    result = element; return
                }
                var placeholderRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &placeholderRef)
                let placeholder = (placeholderRef as? String) ?? ""
                if placeholder.lowercased().contains("type a message") || placeholder.lowercased().contains("message") {
                    result = element; return
                }
                var isEditable: AnyObject?
                if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &isEditable) == .success,
                   let editable = isEditable as? Bool, editable {
                    var positionRef: CFTypeRef?, windowSizeRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
                       AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &windowSizeRef) == .success {
                        var point = CGPoint.zero, size = CGSize.zero
                        AXValueGetValue(positionRef as! AXValue, .cgPoint, &point)
                        AXValueGetValue(windowSizeRef as! AXValue, .cgSize, &size)
                        if size.height > 0, point.y < size.height * 0.35, point.y < bestY {
                            bestY = point.y; result = element
                        }
                    }
                }
            }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return }
            for child in children { search(child, depth: depth + 1); if result != nil { return } }
        }
        search(window, depth: 0)
        return result
    }

    static func findSendButton(in window: AXUIElement) -> AXUIElement? {
        var result: AXUIElement?
        func search(_ element: AXUIElement, depth: Int) {
            if depth > 18 || result != nil { return }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXButton" {
                var descRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
                if let d = descRef as? String, d.lowercased().contains("send") { result = element; return }
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
                if let t = titleRef as? String, t.lowercased().contains("send") { result = element; return }
            }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return }
            for child in children { search(child, depth: depth + 1); if result != nil { return } }
        }
        search(window, depth: 0)
        return result
    }

    // MARK: - Browser activation

    static func activateBrowser() -> Bool {
        for bid in ["com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser"] {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bid && !$0.isTerminated
            }) else { continue }
            app.activate()
            return true
        }
        return false
    }

    // MARK: - PID targeting

    static var whatsappPID: pid_t {
        for bid in ["com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser"] {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bid && !$0.isTerminated
            }) { return app.processIdentifier }
        }
        return 0
    }

    // MARK: - Core send flow

    /// Type `text` into the WhatsApp input and send it.
    /// - Parameter text: reply to send
    /// - Parameter window: the WhatsApp AX window element
    /// - Returns: true if the message was sent (or likely sent).
    static func sendMessage(_ text: String, in window: AXUIElement) -> Bool {
        // 1. Activate browser.
        let activated = activateBrowser()
        cblog("WhatsAppSender: activate = \(activated)")
        Thread.sleep(forTimeInterval: 0.35)

        // 2. Focus the input field (retry once).
        var input: AXUIElement?
        for attempt in 0..<2 {
            input = findInputElement(in: window)
            if input != nil { break }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.4) }
        }
        if let inputEl = input {
            let ok = AXUIElementPerformAction(inputEl, kAXPressAction as CFString) == .success
            cblog("WhatsAppSender: input click = \(ok)")
            Thread.sleep(forTimeInterval: 0.25)
        } else {
            // Fallback: click bottom-center of window.
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
               AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success {
                var wp = CGPoint.zero, ws = CGSize.zero
                AXValueGetValue(posRef as! AXValue, .cgPoint, &wp)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &ws)
                let cx = wp.x + ws.width / 2, cy = wp.y + ws.height * 0.92
                cblog("WhatsAppSender: fallback click (\(cx), \(cy))")
                postMouseClick(x: cx, y: cy)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // 3. Paste (primary strategy — React contenteditable works with paste).
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        postKey(9, mask: .maskCommand)  // Cmd+V
        Thread.sleep(forTimeInterval: 0.2)

        // 4. Send.
        if let sendBtn = findSendButton(in: window) {
            let ok = AXUIElementPerformAction(sendBtn, kAXPressAction as CFString) == .success
            cblog("WhatsAppSender: send button = \(ok)")
            return ok
        } else {
            cblog("WhatsAppSender: pressing Enter")
            pressEnter()
            return true
        }
    }

    // MARK: - Keystroke helpers

    private static func pressEnter() { postKey(36, mask: []) }

    private static func postKey(_ keyCode: CGKeyCode, mask: CGEventFlags) {
        // No browser running means no WhatsApp to type into. The old fallback
        // posted to the global HID tap instead, which fired Return into
        // whatever app happened to be focused -- it was walking Nikxel's own
        // onboarding window through its default buttons.
        let pid = whatsappPID
        guard pid != 0 else { return }
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = mask; up?.flags = mask
        down?.postToPid(pid); up?.postToPid(pid)
    }

    private static func postMouseClick(x: CGFloat, y: CGFloat) {
        // Same reason as postKey: never click into an unrelated foreground app.
        let pid = whatsappPID
        guard pid != 0 else { return }
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let pt = CGPoint(x: x, y: y)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
        let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: pt, mouseButton: .left)
        down?.postToPid(pid); up?.postToPid(pid)
    }
}
