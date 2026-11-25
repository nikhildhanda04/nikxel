import AppKit
import WebKit

/// A pointer card (CoachPage.swift) in a small borderless window beside
/// something on screen, with an arrow at it: the avatar, the menu bar icon, a
/// Terminal window. It picks the side with room. One at a time; `show` again
/// moves it.
final class CoachPointer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Card: Equatable { var title: String; var text: String; var step = 0; var total = 1; var primary = "Next" }

    var onNext: (() -> Void)?
    var onSkip: (() -> Void)?

    private let panel: NSPanel
    private let web: WKWebView
    private var loaded = false
    private var pending: (NSRect, Card)?
    private var target = NSRect.zero, card = Card(title: "", text: "")
    private var size = NSSize(width: 380, height: 200)

    private final class Panel: NSPanel { override var canBecomeKey: Bool { true } }

    override init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "nx")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        // Above the avatar and the menu bar, on every Space, never in the way of Mission Control.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = web
        web.loadHTMLString(CoachPage.html, baseURL: nil)
    }

    func show(at target: NSRect, _ card: Card) {
        guard loaded else { pending = (target, card); return }
        if target == self.target && card == self.card && panel.isVisible { return }
        self.target = target; self.card = card
        place()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "nx")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let (t, c) = pending { pending = nil; show(at: t, c) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "next": onNext?()
        case "skip": onSkip?()
        case "size":
            let s = NSSize(width: body["w"] as? Double ?? 380, height: body["h"] as? Double ?? 200)
            if abs(s.height - size.height) > 1 || abs(s.width - size.width) > 1 { size = s; place(send: false) }
        default: break
        }
    }

    /// Below the target if there's room (arrow up), else above, else beside.
    private func place(send: Bool = true) {
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.frame, gap: CGFloat = 4, w = size.width, h = size.height
        var dir = "up", frame = NSRect.zero, at: CGFloat = 0
        // Near a left or right edge the card can't sit centred under the
        // target, and the arrow would hang off its side: go beside it instead.
        let nearEdge = target.midX - v.minX < 60 || v.maxX - target.midX < w - 60
        if nearEdge, v.maxX - target.maxX > w + 20 {
            dir = "left"
            frame = NSRect(x: target.maxX + gap, y: target.midY + 40 - h, width: w, height: h)
        } else if nearEdge, target.minX - v.minX > w + 20 {
            dir = "right"
            frame = NSRect(x: target.minX - gap - w, y: target.midY + 40 - h, width: w, height: h)
        } else if target.minY - v.minY > h + 40 {
            dir = "up"
            frame = NSRect(x: target.midX - 40, y: target.minY - gap - h, width: w, height: h)
        } else if v.maxY - target.maxY > h + 40 {
            dir = "down"
            frame = NSRect(x: target.midX - 40, y: target.maxY + gap, width: w, height: h)
        } else if v.maxX - target.maxX > w + 20 {
            dir = "left"
            frame = NSRect(x: target.maxX + gap, y: target.midY + 40 - h, width: w, height: h)
        } else {
            dir = "right"
            frame = NSRect(x: target.minX - gap - w, y: target.midY + 40 - h, width: w, height: h)
        }
        frame.origin.x = min(max(frame.minX, v.minX + 8), v.maxX - w - 8)
        frame.origin.y = min(max(frame.minY, v.minY + 8), v.maxY - h - 8)
        at = dir == "up" || dir == "down" ? target.midX - frame.minX : frame.maxY - target.midY
        at = min(max(at, 48), (dir == "up" || dir == "down" ? w : h) - 48)
        panel.setFrame(frame, display: true)
        web.frame = NSRect(origin: .zero, size: frame.size)
        guard send, let json = PageAssets.json([
            "dir": dir, "at": Double(at), "title": card.title, "text": card.text,
            "step": card.step, "total": card.total, "primary": card.primary,
        ]) else { return }
        web.evaluateJavaScript("nx.show(\(json))")
    }

    /// The frontmost window of `app` (e.g. "Terminal"), in screen coordinates.
    /// Window bounds need no permission; only titles would.
    static func windowFrame(ofApp app: String) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let w = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == app && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let primary = NSScreen.screens.first else { return nil }
        let height = b["Height"] ?? 0
        // CoreGraphics counts y down from the top of the main screen.
        return NSRect(x: b["X"] ?? 0, y: primary.frame.maxY - (b["Y"] ?? 0) - height, width: b["Width"] ?? 0, height: height)
    }
}

/// The first-run tour: arrows at the avatar and at the menu bar icon, then the
/// Nikxel window, where the page's own tour points at its sections
/// (DashboardPage, `tour` in its state). Once; Advanced → "Show me around
/// again" replays it.
enum CoachTour {
    private static var pointer: CoachPointer?

    /// Not in the middle of a call or a recording: it waits until both are over.
    static func startIfNew() {
        guard !NikxelSettings.tourDone else { return }
        if let app = NSApp.delegate as? NikxelAppDelegate,
           MeetingDetector.shared.isInMeeting || app.meetingCoordinator?.isRecording == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { startIfNew() }
            return
        }
        start()
    }

    static func start() {
        guard pointer == nil, let app = NSApp.delegate as? NikxelAppDelegate else { return }
        if !app.window.isVisible { app.toggleVisibility() }
        let p = CoachPointer()
        pointer = p
        var step = 0
        let total = 3
        func avatarRect() -> NSRect {
            guard let view = app.window.nikxelView else { return app.window.frame }
            let f = app.window.frame, a = view.avatarCenter, h = view.halfChar
            return NSRect(x: f.minX + a.x - h, y: f.minY + a.y - h, width: 2 * h, height: 2 * h)
        }
        let menuIcon = {
            app.statusItem.button?.window?.frame
                ?? NSRect(x: (NSScreen.main?.frame.maxX ?? 0) - 200, y: (NSScreen.main?.frame.maxY ?? 0) - 24, width: 24, height: 24)
        }
        func finish() {
            NikxelSettings.tourDone = true
            p.close(); pointer = nil
            cblog("CoachTour: finished at step \(step + 1) of \(total)")
        }
        func render() {
            switch step {
            case 0:
                p.show(at: avatarRect(), .init(title: "This is me, Nikxel",
                    text: "<p><b>Click</b> me to chat. <b>Double-click</b> me to record a meeting.</p><p><b>Drag</b> me anywhere you like.</p>",
                    step: 0, total: total))
            case 1:
                p.show(at: menuIcon(), .init(title: "Find me up here",
                    text: "<p>My icon in the menu bar. Click it to record, mute, or open everything else.</p><p>Shortcut: <kbd>⌘</kbd> <kbd>,</kbd></p>",
                    step: 1, total: total))
            default:
                p.show(at: menuIcon(), .init(title: "Everything else is in the Nikxel window",
                    text: "<p>Your meeting notes, chat, tasks and settings. Let me show you around it.</p>",
                    step: 2, total: total, primary: "Open it"))
            }
        }
        p.onNext = {
            step += 1
            if step < total { render(); return }
            finish()
            DashboardWindowController.show(section: "home")
        }
        p.onSkip = { finish() }
        render()
    }

    /// Replays both tours, from Advanced → "Show me around again".
    static func replay() {
        NikxelSettings.tourDone = false
        NikxelSettings.dashboardTourDone = false
        start()
    }
}
