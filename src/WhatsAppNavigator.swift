import Foundation
import AppKit
import ApplicationServices

/// WhatsApp Web window discovery & chat-list navigation.
/// All AX calls must happen on the main thread.i
enum WhatsAppNavigator {

    // MARK: - Window discovery

    /// Find the AX window element containing WhatsApp Web.
    /// Chrome supports kAXWindowsAttribute; Arc uses kAXFocusedWindowAttribute.
    static func findWhatsAppWindow() -> AXUIElement? {
        // --- Chrome (primary target) ---
        if let chrome = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.google.Chrome" && !$0.isTerminated
        }) {
            let axApp = AXUIElementCreateApplication(chrome.processIdentifier)
            var windowRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowRef) == .success,
                  let windows = windowRef as? [AXUIElement] else { return nil }
            for window in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                if let t = titleRef as? String, t.lowercased().contains("whatsapp") {
                    return window
                }
                // Also check AXDocument / AXURL for web.whatsapp.com
                var urlRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &urlRef) == .success,
                   let url = urlRef as? String, url.lowercased().contains("whatsapp") {
                    return window
                }
            }
        }

        // --- Brave ---
        if let brave = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.brave.Browser" && !$0.isTerminated
        }) {
            let axApp = AXUIElementCreateApplication(brave.processIdentifier)
            var windowRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowRef) == .success,
                  let windows = windowRef as? [AXUIElement] else { return nil }
            for window in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                if let t = titleRef as? String, t.lowercased().contains("whatsapp") { return window }
            }
        }

        // --- Arc (kAXWindowsAttribute returns empty) ---
        if let arc = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "company.thebrowser.Browser" && !$0.isTerminated
        }) {
            let axApp = AXUIElementCreateApplication(arc.processIdentifier)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
               let win = ref as! AXUIElement? {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                if let t = titleRef as? String, t.lowercased().contains("whatsapp") { return win }
            }
            if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref) == .success,
               let win = ref as! AXUIElement? {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                if let t = titleRef as? String, t.lowercased().contains("whatsapp") { return win }
            }
        }
        return nil
    }

    /// Switch Arc to the WhatsApp tab via AppleScript.  May fail if Automation
    /// permission is not granted.
    static func switchArcToWhatsAppTab() -> Bool {
        let script = """
        tell application "Arc"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "web.whatsapp.com" then
                        set active tab index of w to index of t
                        return "true"
                    end if
                end repeat
            end repeat
            return "false"
        end tell
        """
        return runAppleScript(script) == "true"
    }

    private static func runAppleScript(_ script: String) -> String? {
        guard let ascript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        return ascript.executeAndReturnError(&error).stringValue
    }

    // MARK: - Unread chat detection

    /// Return all AXRow elements that currently have unread indicators.
    static func findUnreadChats(in window: AXUIElement) -> [AXUIElement]? {
        var result: [AXUIElement] = []

        // Fast path: find AXTable desc='Chat list' and scan its rows.
        if let table = findElement(role: "AXTable", description: "Chat list", in: window) {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(table, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let rows = childrenRef as? [AXUIElement] {
                for row in rows {
                    var roleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(row, kAXRoleAttribute as CFString, &roleRef)
                    guard (roleRef as? String) == "AXRow" else { continue }
                    if WhatsAppParser.elementContainsUnread(row) { result.append(row) }
                }
            }
        }

        // Fallback: full recursive scan.
        if result.isEmpty {
            func traverse(_ element: AXUIElement, depth: Int) {
                if depth > 20 { return }
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                let role = roleRef as? String ?? ""
                if role == "AXStaticText" {
                    if WhatsAppParser.hasUnreadBadge(element),
                       let chatItem = findParentChatItem(element) { result.append(chatItem) }
                }
                if role == "AXRow" && WhatsAppParser.elementContainsUnread(element)
                    && WhatsAppParser.contactName(from: element) != nil { result.append(element) }
                var childrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                      let children = childrenRef as? [AXUIElement] else { return }
                for child in children { traverse(child, depth: depth + 1) }
            }
            traverse(window, depth: 0)
        }

        // Deduplicate by Objective-C object identity.
        var seen = Set<Int>()
        result = result.filter { el in
            let h = Int(bitPattern: ObjectIdentifier(el))
            if seen.contains(h) { return false }; seen.insert(h); return true
        }
        return result.isEmpty ? nil : result
    }

    /// Walk up from an AXStaticText (unread badge) to its parent AXRow.
    static func findParentChatItem(_ element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<12 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success else { break }
            current = parentRef as! AXUIElement
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXRow", WhatsAppParser.contactName(from: current) != nil { return current }
        }
        return nil
    }

    /// Recursively find a descendant by role and optional description.
    static func findElement(role: String, description: String? = nil, in parent: AXUIElement) -> AXUIElement? {
        var roleRef: CFTypeRef?, descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == role {
            if let expected = description {
                AXUIElementCopyAttributeValue(parent, kAXDescriptionAttribute as CFString, &descRef)
                if (descRef as? String) == expected { return parent }
            } else { return parent }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findElement(role: role, description: description, in: child) { return found }
        }
        return nil
    }

    /// Find the AXWebArea inside a window (web content only, no browser chrome).
    static func findWebArea(in window: AXUIElement) -> AXUIElement? {
        return findElement(role: "AXWebArea", in: window)
    }

    // MARK: - Selection verification

    /// Click an AXRow (chat list item) and block until the UI is likely ready.
    static func clickChat(_ chatElement: AXUIElement) -> Bool {
        return AXUIElementPerformAction(chatElement, kAXPressAction as CFString) == .success
    }

    /// After clicking a chat, verify the conversation header matches the
    /// expected contact name.  Returns true on match, false on mismatch.
    /// Tolerates case- and whitespace-insensitive comparison.
    static func verifyChatSelection(in window: AXUIElement, expectedContact: String) -> Bool {
        guard let header = WhatsAppParser.currentConversationName(in: window) else {
            return false
        }
        let a = header.lowercased().trimmingCharacters(in: .whitespaces)
        let b = expectedContact.lowercased().trimmingCharacters(in: .whitespaces)
        // Fuzzy: also accept if one is a prefix of the other (groups often truncate).
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }
}
