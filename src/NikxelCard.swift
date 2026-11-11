import AppKit
import ApplicationServices

/// Draws NikxelView's notification card -- the white speech bubble above the
/// avatar used for "MOM ready", failures, and the end-of-day digest.
///
/// Plain CoreGraphics on purpose. The Liquid Glass bubbles in NikxelView only
/// compile against the macOS 26 SDK and silently render nothing without it, so
/// anything that has to be seen on every build is drawn here instead.
extension NikxelView {

    enum CardMetrics {
        static let maxWidth: CGFloat = 272
        static let pad: CGFloat = 14
        static let corner: CGFloat = 18
        static let titleSize: CGFloat = 13.5
        static let bodySize: CGFloat = 12.5
        static let titleGap: CGFloat = 7
        static let lineGap: CGFloat = 5
        static let iconGap: CGFloat = 7
        static let bulletDiameter: CGFloat = 4
        static let bulletGap: CGFloat = 9
        static let tailWidth: CGFloat = 16
        static let tailHeight: CGFloat = 9
        /// Gap between the tail's tip and the top of the sprite.
        static let liftAboveHead: CGFloat = 8
        /// Cards are capped so a long error message can't grow past the top of
        /// the window and get clipped. Overflow is truncated per line.
        static let maxLines = 5
        static let buttonHeight: CGFloat = 24
        static let buttonPadX: CGFloat = 12
        static let buttonGap: CGFloat = 6
    }

    func drawCard(ctx: CGContext, cx: CGFloat, cy: CGFloat) {
        guard var c = card, c.opacity > 0.001 else {
            if card != nil { card?.hitRect = .zero }
            return
        }
        typealias M = CardMetrics

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: dmFont(size: M.titleSize, bold: true),
            .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
        ]
        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineBreakMode = .byWordWrapping
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: dmFont(size: M.bodySize),
            .foregroundColor: NSColor(calibratedWhite: 0.26, alpha: 1),
            .paragraphStyle: bodyPara,
        ]

        // --- Measure -------------------------------------------------------
        let iconStr: NSAttributedString? = c.icon.map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: M.titleSize + 1)])
        }
        let iconW = iconStr.map { ceil($0.size().width) + M.iconGap } ?? 0

        let titleStr = NSAttributedString(string: c.title, attributes: titleAttrs)

        // Body text starts after the bullet column when bulleted.
        let bulletIndent = c.bulleted ? M.bulletDiameter + M.bulletGap : 0
        let maxBodyW = M.maxWidth - M.pad * 2 - bulletIndent

        struct Measured { let str: NSAttributedString; let height: CGFloat; let width: CGFloat }
        var measured: [Measured] = []
        for raw in c.lines.prefix(M.maxLines) {
            let str = NSAttributedString(string: raw, attributes: bodyAttrs)
            let r = str.boundingRect(with: NSSize(width: maxBodyW, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
            measured.append(Measured(str: str, height: ceil(r.height), width: ceil(r.width)))
        }

        let widestBody = measured.map(\.width).max() ?? 0
        let btnStrs = c.buttons.enumerated().map { i, b in
            NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: M.bodySize, weight: .semibold),
                .foregroundColor: i == 0 ? NSColor.white : NSColor(calibratedWhite: 0.15, alpha: 1)])
        }
        let btnWs = btnStrs.map { ceil($0.size().width) + M.buttonPadX * 2 }
        let rowW = btnWs.reduce(0, +) + CGFloat(max(0, btnWs.count - 1)) * M.buttonGap
        let rowH = c.buttons.isEmpty ? 0 : M.buttonHeight + M.titleGap + 3
        // Buttons win over the width cap: a button hanging off the card is
        // worse than a slightly wider card.
        let textW = max(rowW, min(M.maxWidth - M.pad * 2,
                                  max(iconW + ceil(titleStr.size().width), widestBody + bulletIndent)))
        // Titles wrap rather than clip ("Send this meeting's tasks to Go…").
        let titleH = ceil(titleStr.boundingRect(with: NSSize(width: textW - iconW, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)

        var bodyH: CGFloat = 0
        for (i, m) in measured.enumerated() { bodyH += m.height + (i > 0 ? M.lineGap : 0) }

        let cardW = textW + M.pad * 2
        let cardH = titleH + (measured.isEmpty ? 0 : M.titleGap + bodyH) + rowH + M.pad * 2
        // Centred on the avatar, but slid sideways to stay on screen when the
        // avatar sits at an edge -- otherwise a card's buttons end up off it.
        var cardX = cx - cardW / 2
        if let win = window, let scr = win.screen ?? NSScreen.main {
            let lo = scr.visibleFrame.minX - win.frame.minX + 8
            let hi = scr.visibleFrame.maxX - win.frame.minX - 8 - cardW
            cardX = max(lo, min(cardX, hi))
        }
        cardX = max(bounds.minX, min(cardX, bounds.maxX - cardW))
        let cardY = headY(M.liftAboveHead + M.tailHeight, height: cardH)

        // --- Card + tail as one path, so the shadow wraps both and no seam
        //     shows where the tail meets the card ------------------------------
        ctx.saveGState()
        ctx.setAlpha(c.opacity)
        let path = NSBezierPath(roundedRect: NSRect(x: cardX, y: cardY, width: cardW, height: cardH),
                                xRadius: M.corner, yRadius: M.corner)
        // Offset left of centre, the way a speech tail sits.
        // Slid cards keep the tail over the avatar.
        let tailMidX = abs(cardX - (cx - cardW / 2)) < 1
            ? cardX + min(cardW * 0.28, 46)
            : max(cardX + 18, min(cx, cardX + cardW - 18))
        // The tail points at the avatar: down from the card's bottom edge, or
        // up from its top when the card hangs below the feet.
        let (edge, dir): (CGFloat, CGFloat) = bubblesBelow ? (cardY + cardH, 1) : (cardY, -1)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: tailMidX - M.tailWidth / 2, y: edge - dir))
        tail.line(to: NSPoint(x: tailMidX + M.tailWidth / 2, y: edge - dir))
        tail.line(to: NSPoint(x: tailMidX - M.tailWidth / 2 + 3, y: edge + dir * M.tailHeight))
        tail.close()
        path.append(tail)
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14,
                      color: NSColor.black.withAlphaComponent(0.20).cgColor)
        NSColor.white.setFill()
        path.fill()
        ctx.restoreGState()

        // --- Text, outside the shadowed state so it isn't blurred with the card
        ctx.saveGState()
        ctx.setAlpha(c.opacity)

        let titleY = cardY + cardH - M.pad - titleH
        if let iconStr = iconStr {
            // Nudged down a touch: emoji sit high on their line box next to text.
            // On the first line of a wrapped title, not the last.
            let firstLineH = ceil(NSAttributedString(string: " ", attributes: titleAttrs).size().height)
            iconStr.draw(at: NSPoint(x: cardX + M.pad, y: titleY + titleH - firstLineH - 1))
        }
        titleStr.draw(with: NSRect(x: cardX + M.pad + iconW, y: titleY,
                                   width: textW - iconW, height: titleH),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])

        var lineTop = titleY - M.titleGap
        for m in measured {
            let lineY = lineTop - m.height
            if c.bulleted {
                // Centred on the first line of text, not on the whole block, so
                // a wrapped bullet keeps its dot beside the first line.
                let firstLineH = ceil(m.str.size().height)
                let dotY = lineY + m.height - firstLineH / 2 - M.bulletDiameter / 2
                ctx.setFillColor(c.kind.accent.cgColor)
                ctx.fillEllipse(in: NSRect(x: cardX + M.pad + 1, y: dotY,
                                           width: M.bulletDiameter, height: M.bulletDiameter))
            }
            m.str.draw(with: NSRect(x: cardX + M.pad + bulletIndent, y: lineY,
                                    width: textW - bulletIndent, height: m.height),
                       options: [.usesLineFragmentOrigin, .usesFontLeading])
            lineTop = lineY - M.lineGap
        }

        // Buttons along the bottom, left to right; the first is the primary.
        var bx = cardX + M.pad
        c.buttonRects = []
        for (i, s) in btnStrs.enumerated() {
            let r = NSRect(x: bx, y: cardY + M.pad, width: btnWs[i], height: M.buttonHeight)
            let pill = NSBezierPath(roundedRect: r, xRadius: M.buttonHeight / 2, yRadius: M.buttonHeight / 2)
            (i == 0 ? c.kind.accent : NSColor(calibratedWhite: 0.90, alpha: 1)).setFill()
            pill.fill()
            let sz = s.size()
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
            c.buttonRects.append(r)
            bx += btnWs[i] + M.buttonGap
        }
        ctx.restoreGState()

        // Hit rect covers the tail too, so a click just under the card still
        // counts rather than falling through to the desktop.
        c.hitRect = NSRect(x: cardX, y: bubblesBelow ? cardY : cardY - M.tailHeight,
                           width: cardW, height: cardH + M.tailHeight)
        card = c
    }
}

extension NikxelView {
    /// A question as a card with buttons above the avatar, instead of a modal
    /// NSAlert. A modal from a menu-bar app opens behind whatever is in front
    /// and blocks the main thread, so Nikxel froze until someone went looking
    /// for it. Falls back to an on-top alert when the avatar is hidden.
    static func ask(icon: String? = nil, title: String, lines: [String], bulleted: Bool = false,
                    kind: CardKind = .info, buttons: [(String, () -> Void)]) {
        DispatchQueue.main.async {
            guard let v = main, v.window?.isVisible == true else {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = lines.joined(separator: "\n")
                buttons.forEach { alert.addButton(withTitle: $0.0) }
                let i = alert.runOnTop().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if buttons.indices.contains(i) { buttons[i].1() }
                return
            }
            v.showCard(icon: icon, title: title, lines: lines, bulleted: bulleted, kind: kind,
                       lifetime: .infinity, buttons: buttons.map { CardButton(title: $0.0, action: $0.1) })
        }
    }

    /// A notice that needs no answer: a card that fades, tap to dismiss.
    static func tell(icon: String? = nil, title: String, lines: [String], kind: CardKind = .info,
                     lifetime: TimeInterval = 20, action: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            guard let v = main, v.window?.isVisible == true else {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = lines.joined(separator: "\n")
                alert.runOnTop()
                return
            }
            v.showCard(icon: icon, title: title, lines: lines, kind: kind, lifetime: lifetime, action: action)
        }
    }
}

extension NSAlert {
    /// For the dialogs that stay real windows (ones with a text field, long
    /// help text): bring Nikxel forward first so it doesn't open behind.
    @discardableResult
    func runOnTop() -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        window.level = .floating
        return runModal()
    }
}

/// The macOS permissions Nikxel runs on, asked for from one bubble.
enum Permissions {
    /// What's missing right now, as (label, TCC service).
    static var missing: [(String, String)] {
        var m: [(String, String)] = []
        if !AXIsProcessTrusted() { m.append(("Accessibility — typing animation, window titles", "Accessibility")) }
        if !CGPreflightScreenCaptureAccess() { m.append(("Screen & audio recording — meeting capture", "ScreenCapture")) }
        return m
    }

    /// Bubble listing what's missing, with one Allow button. No-op when all granted.
    static func offer() {
        let m = missing
        guard !m.isEmpty else { return }
        NikxelView.ask(icon: "🔐", title: "Allow Nikxel's permissions",
                       lines: m.map(\.0) + ["Tap Allow, then switch Nikxel on in each window that opens."],
                       kind: .warning,
                       buttons: [("Allow", { request(m.map(\.1)) }), ("Later", {})])
    }

    /// Clears the dead rows an earlier build left (a toggle that's on but
    /// belongs to an old signature, so the new build stays refused), then
    /// raises macOS's own prompts, which add a fresh row and offer to open
    /// System Settings. Accessibility applies live; for Screen Recording macOS
    /// itself offers "Quit & Reopen" once it's switched on.
    static func request(_ services: [String]) {
        let id = Bundle.main.bundleIdentifier ?? "com.nikxel.Nikxel"
        for s in services {
            let p = Process()
            p.launchPath = "/usr/bin/tccutil"
            p.arguments = ["reset", s, id]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        if services.contains("Accessibility") {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if services.contains("ScreenCapture") { _ = CGRequestScreenCaptureAccess() }
    }
}
