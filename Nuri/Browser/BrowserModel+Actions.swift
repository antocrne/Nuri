import AppKit
import WebKit

/// Told when a print panel is gone; keeps itself alive until then.
private final class PrintEnd: NSObject {
    private let done: () -> Void
    private var keptAlive: PrintEnd?

    init(_ done: @escaping () -> Void) {
        self.done = done
        super.init()
        keptAlive = self
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        done()
        keptAlive = nil
    }
}

/// What menus, shortcuts and the top bar ask of a window.
extension BrowserModel {
    func goBack() { selectedTab?.webView?.goBack() }
    func goForward() { selectedTab?.webView?.goForward() }

    func reload(ignoringCache: Bool = false) {
        guard let tab = selectedTab else { return }
        let failed = tab.loadError != nil
        tab.loadError = nil
        if tab.isAsleep { tab.ensureWebView(); return }
        // The load failed, or no page has come yet: WebKit has nothing to reload, it asks again.
        if failed || tab.webView?.url == nil, let url = tab.url ?? tab.requestedURL {
            tab.load(url)
            return
        }
        if ignoringCache { tab.webView?.reloadFromOrigin() } else { tab.webView?.reload() }
    }

    func stopLoading() { selectedTab?.webView?.stopLoading() }

    /// `delta`: 0 goes back to 100 %. Remembered by site; private windows record nothing.
    func zoom(_ delta: Double) {
        guard let tab = selectedTab, let webView = tab.webView, let host = webView.url?.host() else { return }
        let target = delta == 0 ? 1 : min(3, max(0.3, Double(webView.pageZoom) + delta))
        webView.pageZoom = target
        if !isPrivate { AppSettings.shared.setSiteZoom(target, for: host) }
        showToast("plus.magnifyingglass", "\(Int((target * 100).rounded())) %")
    }

    func toggleReader() {
        if let tab = selectedTab { ReaderMode.toggle(tab) }
    }

    func togglePiP() {
        guard let tab = selectedTab else { return }
        Task { await PiPController.shared.toggle(tab) }
    }

    func toggleMute() {
        guard let tab = selectedTab else { return }
        tab.setMuted(!tab.isMuted)
    }

    func toggleAdBlockForCurrentSite() {
        guard let tab = selectedTab, let host = tab.url?.host() else { return }
        let settings = AppSettings.shared
        settings.toggleAdBlock(for: host)
        Task {
            await ContentRules.shared.reloadNow()
            tab.webView?.reload()
        }
        showToast("shield", settings.isAdBlockActive(on: host)
                  ? L("Bloqueur actif sur \(host.nuriNormalizedHost)", "Blocker on for \(host.nuriNormalizedHost)")
                  : L("Bloqueur coupé sur \(host.nuriNormalizedHost)", "Blocker off for \(host.nuriNormalizedHost)"))
    }

    func toggleInspector(console: Bool) {
        if let webView = selectedTab?.webView { WebKitSPI.showInspector(webView, console: console) }
    }

    func copyAddress() {
        guard let url = selectedTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast("link", L("Adresse copiée", "Address copied"))
    }

    func printPage() {
        guard let webView = selectedTab?.webView else { return }
        print(webView) {}
    }

    /// `frame`: what the page asked to print (window.print() in a frame), the whole page otherwise.
    /// `done`: once the print panel has gone, or at once if it can't show.
    func print(_ webView: WKWebView, frame: AnyObject? = nil, done: @escaping () -> Void) {
        guard let window, window.attachedSheet == nil else { return done() }
        let operation = WebKitSPI.printOperation(webView, info: .shared, frame: frame)
        operation.view?.frame = webView.bounds
        let end = PrintEnd(done)
        operation.runModal(for: window, delegate: end, didRun: #selector(PrintEnd.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    func toggleTopBarAutoHide() {
        let settings = AppSettings.shared
        settings.autoHideTopBar.toggle()
        topBarRevealed = false
    }

    // MARK: Find in page

    func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty, let webView = selectedTab?.webView else { return }
        lastFindText = text
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(text, configuration: configuration) { _ in }
    }

    func findAgain(backwards: Bool) {
        if lastFindText.isEmpty { findBarVisible = true } else { find(lastFindText, backwards: backwards) }
    }
}
