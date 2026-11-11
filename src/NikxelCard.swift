import AppKit

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
        let titleH = ceil(titleStr.size().height)

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
        let textW = min(M.maxWidth - M.pad * 2,
                        max(iconW + ceil(titleStr.size().width), widestBody + bulletIndent))

        var bodyH: CGFloat = 0
        for (i, m) in measured.enumerated() { bodyH += m.height + (i > 0 ? M.lineGap : 0) }

        let cardW = textW + M.pad * 2
        let cardH = titleH + (measured.isEmpty ? 0 : M.titleGap + bodyH) + M.pad * 2
        let cardX = cx - cardW / 2
        let cardY = headY(M.liftAboveHead + M.tailHeight, height: cardH)

        // --- Card + tail as one path, so the shadow wraps both and no seam
        //     shows where the tail meets the card ------------------------------
        ctx.saveGState()
        ctx.setAlpha(c.opacity)
        let path = NSBezierPath(roundedRect: NSRect(x: cardX, y: cardY, width: cardW, height: cardH),
                                xRadius: M.corner, yRadius: M.corner)
        // Offset left of centre, the way a speech tail sits.
        let tailMidX = cardX + min(cardW * 0.28, 46)
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
            iconStr.draw(at: NSPoint(x: cardX + M.pad, y: titleY - 1))
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
        ctx.restoreGState()

        // Hit rect covers the tail too, so a click just under the card still
        // counts rather than falling through to the desktop.
        c.hitRect = NSRect(x: cardX, y: bubblesBelow ? cardY : cardY - M.tailHeight,
                           width: cardW, height: cardH + M.tailHeight)
        card = c
    }
}
