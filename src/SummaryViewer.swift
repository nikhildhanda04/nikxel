import AppKit
import WebKit

/// A summary page (meeting minutes, notes, a day or week) shown inside the
/// Nikxel window instead of the browser. The page is the same file the browser
/// would open, so its widgets (Share, Edit, Rename, Assign…) work unchanged:
/// they talk to PageShare on localhost, which only checks the token and the
/// path. This view stands in for the browser's parts the pages rely on --
/// confirm()/alert() sheets, window.open, links out, and the .ics download.
final class SummaryViewer: WKWebView, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    /// The page's title changed (load, rename); the dashboard's reader bar shows it.
    var onTitle: ((String) -> Void)?
    /// A page opened another summary page (the client view) or renamed itself.
    var onOpen: ((URL) -> Void)?

    init() {
        // The default data store: the pages' localStorage (task ticks, the
        // name bar's "keep date name", chat history) survives between opens.
        super.init(frame: .zero, configuration: WKWebViewConfiguration())
        uiDelegate = self
        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")
        addObserver(self, forKeyPath: #keyPath(title), options: .new, context: nil)
    }

    required init?(coder: NSCoder) { fatalError("SummaryViewer does not support NSCoding") }

    deinit { removeObserver(self, forKeyPath: #keyPath(title)) }

    private var asked = ""   // the file show() asked for, let through decidePolicyFor

    func show(_ file: URL) {
        asked = file.resolvingSymlinksInPath().path
        // Both resolved: a symlinked or iCloud ~/Documents puts the real files
        // elsewhere, and WebKit only lets the page read under the path it got.
        loadFileURL(file.resolvingSymlinksInPath(), allowingReadAccessTo: SummaryLibrary.root.resolvingSymlinksInPath())
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        onTitle?(title ?? "")
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if action.shouldPerformDownload || url.scheme == "data" { return decisionHandler(.download) }
        if url.isFileURL {
            // Same page: reload. location.replace after a rename: stays here,
            // loaded afresh (a plain navigation can miss WebKit's read access,
            // leaving the page on "Renaming…" with its file already moved).
            if action.targetFrame?.isMainFrame == true, DashboardWindowController.canRead(url) {
                let path = url.resolvingSymlinksInPath().path
                if path == asked || path == self.url?.resolvingSymlinksInPath().path { return decisionHandler(.allow) }
                decisionHandler(.cancel)
                onOpen?(url); show(url)
                return
            }
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        if action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }   // iframes
        NSWorkspace.shared.open(url)   // Google Calendar, ERP, any link out: the browser.
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - Browser stand-ins

    /// window.open / target=_blank: a summary page (the client view) opens here,
    /// anything else in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if url.isFileURL, DashboardWindowController.canRead(url) { show(url) }
            else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        sheet(message, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        sheet(message, buttons: ["OK", "Cancel"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    private func sheet(_ message: String, buttons: [String], done: @escaping (NSApplication.ModalResponse) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        guard let window = window else { return done(alert.runModal()) }
        alert.beginSheetModal(for: window, completionHandler: done)
    }

    // MARK: - Downloads (the meeting's .ics)

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = downloads.appendingPathComponent(suggestedFilename)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension, ext = (suggestedFilename as NSString).pathExtension
            dest = downloads.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
        }
        download.progress.setUserInfoObject(dest, forKey: .fileURLKey)
        completionHandler(dest)
    }

    /// Opened at once, so an .ics lands in Calendar the way it would from the browser.
    func downloadDidFinish(_ download: WKDownload) {
        if let dest = download.progress.userInfo[.fileURLKey] as? URL { NSWorkspace.shared.open(dest) }
    }
}
