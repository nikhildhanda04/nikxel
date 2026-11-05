import Foundation
import AppKit
import ApplicationServices

/// Stateless WhatsApp Web AX element parsers.  Every function is pure —
/// it reads attributes from the passed-in AXUIElement and returns a value.
enum WhatsAppParser {

    // MARK: - Contact name

    /// Extract the contact / group name from an AXRow (chat list item).
    /// The row title is:  "{N} unread message(s) {contact} {time} {preview}"
    static func contactName(from chatElement: AXUIElement) -> String? {
        // 1. Try the AXRow title first (fastest path).
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(chatElement, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String, title.lowercased().contains("unread") {
            let pattern = try? NSRegularExpression(pattern: #"\d+\s*unread\s*messages?\s*"#, options: .caseInsensitive)
            let range = NSRange(location: 0, length: title.utf16.count)
            if let match = pattern?.firstMatch(in: title, range: range) {
                let after = title[Range(match.range(at: 0), in: title)!.upperBound...]
                let parts = after.split(separator: " ", maxSplits: 1)
                if let name = parts.first, !name.isEmpty {
                    let n = String(name)
                    if n.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) == nil,
                       !["yesterday", "today"].contains(n.lowercased()),
                       n.count > 1 { return n }
                }
            }
        }

        // 2. Fallback: walk children for an AXStaticText that looks like a name.
        //    In the tree: … → AXGroup → AXStaticText val='ContactName'
        return findName(in: chatElement)
    }

    private static func findName(in element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXStaticText" {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            guard let val = valueRef as? String, !val.isEmpty else { return nil }
            let t = val.trimmingCharacters(in: .whitespaces)
            if t.lowercased().contains("unread") { return nil }
            if Int(t) != nil && t.count <= 3 { return nil }
            if t.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return nil }
            if ["you", "today", "yesterday"].contains(t.lowercased()) { return nil }
            if t.count > 1 && t.count <= 40 { return t }
            return nil
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let name = findName(in: child) { return name }
        }
        return nil
    }

    // MARK: - Unread count

    /// "{N} unread message(s) …"  →  N
    static func unreadCount(from chatElement: AXUIElement) -> Int {
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(chatElement, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            let pattern = try? NSRegularExpression(pattern: #"^(\d+)\s*unread"#, options: .caseInsensitive)
            let range = NSRange(location: 0, length: title.utf16.count)
            if let match = pattern?.firstMatch(in: title, range: range),
               let nr = Range(match.range(at: 1), in: title) { return Int(title[nr]) ?? 0 }
        }
        return findUnreadCount(in: chatElement)
    }

    private static func findUnreadCount(in element: AXUIElement) -> Int {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXStaticText" {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let val = valueRef as? String, val.lowercased().contains("unread") {
                let pattern = try? NSRegularExpression(pattern: #"^(\d+)"#)
                let range = NSRange(location: 0, length: val.utf16.count)
                if let match = pattern?.firstMatch(in: val, range: range),
                   let nr = Range(match.range(at: 1), in: val) { return Int(val[nr]) ?? 0 }
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return 0 }
        for child in children {
            let c = findUnreadCount(in: child)
            if c > 0 { return c }
        }
        return 0
    }

    // MARK: - Message preview

    /// Extract the message preview from the AXRow title:
    ///   "{N} unread message(s) {contact} {time} {preview}"
    static func messagePreview(from chatElement: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(chatElement, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        let pattern = try? NSRegularExpression(pattern: #"\d+\s*unread\s*messages?\s*"#, options: .caseInsensitive)
        let range = NSRange(location: 0, length: title.utf16.count)
        guard let match = pattern?.firstMatch(in: title, range: range) else { return nil }
        let after = title[Range(match.range(at: 0), in: title)!.upperBound...]
        let parts = after.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if parts.count >= 3 {
            let preview = String(parts[2])
            if !preview.isEmpty { return preview }
        }
        return after.isEmpty ? nil : String(after)
    }

    // MARK: - Conversation header

    /// After a chat is opened, read the contact name shown in the conversation
    /// header (top of the main panel).  Used to verify we're about to send into
    /// the correct chat.
    static func currentConversationName(in window: AXUIElement) -> String? {
        // WhatsApp conversation header is in the right portion of the window,
        // at the highest Y position (top of the message area, below the top bar).
        // We look for substantial AXStaticText in the right 65 % of the window.

        var winSize = CGSize.zero
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &winSize)
        }
        let splitX = winSize.width > 0 ? winSize.width * 0.35 : 0

        struct Candidate { let y: CGFloat; let val: String }
        var candidates: [Candidate] = []

        func collect(_ element: AXUIElement, depth: Int) {
            if depth > 16 || candidates.count >= 100 { return }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXStaticText" {
                var pos = CGPoint.zero
                var posRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success {
                    AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                }
                guard pos.x >= splitX else { return }
                var valueRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
                if let val = valueRef as? String {
                    let t = val.trimmingCharacters(in: .whitespaces)
                    if t.count > 1 && t.count <= 40
                        && !t.lowercased().contains("unread")
                        && t.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) == nil
                        && !["you", "today", "yesterday", "type a message"].contains(t.lowercased()) {
                        candidates.append(Candidate(y: pos.y, val: t))
                    }
                }
            }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return }
            for child in children { collect(child, depth: depth + 1) }
        }
        collect(window, depth: 0)

        // The header is near the top of the conversation panel (lowest Y).
        candidates.sort { $0.y < $1.y }
        candidates = candidates.prefix(3).filter { $0.val != "Message yourself" }
        return candidates.first?.val
    }

    // MARK: - Unread badge detection

    static func hasUnreadBadge(_ element: AXUIElement) -> Bool {
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        if let value = valueRef as? String, !value.isEmpty {
            let lower = value.lowercased()
            if lower.contains("unread") { return true }
            let t = value.trimmingCharacters(in: .whitespaces)
            if let _ = Int(t), t.count <= 2 { return true }
        }
        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        if let desc = descRef as? String, desc.lowercased().contains("unread") { return true }
        return false
    }

    static func elementContainsUnread(_ element: AXUIElement) -> Bool {
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            var ref: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
            if let s = ref as? String, s.lowercased().contains("unread") { return true }
        }
        return false
    }
}
