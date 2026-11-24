import AppKit
import WebKit

/// What the onboarding and dashboard pages share: Framer Motion's standalone
/// DOM build and the dashboard's dithered clouds injected before the page
/// runs, the user's sprite sheet cut into data URIs, and the drag strip that
/// gives a hidden-title-bar window something to be moved by.
enum PageAssets {
    /// window.Motion (vendor/framer-motion-dom.js) and --clouds (vendor/clouds.png),
    /// both copied into the bundle by build.sh.
    static func install(into controller: WKUserContentController) {
        if let path = Bundle.main.path(forResource: "framer-motion-dom", ofType: "js"),
           let motion = try? String(contentsOfFile: path, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: motion, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let path = Bundle.main.path(forResource: "clouds", ofType: "png"),
           let png = FileManager.default.contents(atPath: path) {
            controller.addUserScript(WKUserScript(
                source: "document.documentElement.style.setProperty('--clouds', 'url(data:image/png;base64,\(png.base64EncodedString()))')",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    /// Every row of the active sheet as PNG data URIs. The avatar actually
    /// drawn on screen comes from this sheet -- nikxel_avatar.png is only the
    /// no-sprite-sheet fallback (one frame), so showing that would greet the
    /// user with a different character than the app runs.
    static func spriteRows() -> [[String]] {
        let f = NikxelSprites.frameSize
        if let path = NikxelSprites.activePath,
           let sheet = NSImage(contentsOfFile: path),
           let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (0..<NikxelSprites.rows).map { row in
                (0..<NikxelSprites.cols).compactMap { col in
                    cg.cropping(to: CGRect(x: col * f, y: row * f, width: f, height: f)).flatMap(dataURI)
                }
            }
        }
        if let path = Bundle.main.path(forResource: "nikxel_avatar", ofType: "png"),
           let image = NSImage(contentsOfFile: path),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let uri = dataURI(cg) {
            return [[uri]]
        }
        return []
    }

    static func json(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func dataURI(_ cg: CGImage) -> String? {
        NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            .map { "data:image/png;base64," + $0.base64EncodedString() }
    }
}

/// Transparent band across the top of a window that drags it, since a web
/// view under the hidden title bar would otherwise eat every mouse-down.
final class DragStrip: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
