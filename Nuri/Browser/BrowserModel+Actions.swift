import AppKit
import UniformTypeIdentifiers
import WebKit

/// The save panel's format menu: the file's extension follows it.
@MainActor
private final class SaveFormatChooser: NSObject {
    private weak var panel: NSSavePanel?
    init(panel: NSSavePanel) { self.panel = panel }

    @objc func changed(_ sender: NSPopUpButton) {
        panel?.allowedContentTypes = [sender.indexOfSelectedItem == 1 ? .pdf : .webArchive]
    }
}

/// What the find bar says: how many matches, or none.
struct FindResult: Equatable {
    var count: Int
    @MainActor var label: String {
        switch count {
        case 0: L("Aucun résultat", "No results")
        case 1: L("1 résultat", "1 match")
        case 1000...: L("1000+ résultats", "1000+ matches")
        default: L("\(count) résultats", "\(count) matches")
        }
    }
}

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
        if tab.isAsleep { tab.loadError = nil; tab.ensureWebView(); return }
        // The load failed, or no page has come yet: WebKit has nothing to reload, it asks again
        // (for the address that failed, not the page before it).
        if failed || tab.webView?.url == nil, tab.failedURL ?? tab.url ?? tab.requestedURL != nil {
            tab.retryAfterError()
            return
        }
        if ignoringCache { tab.webView?.reloadFromOrigin() } else { tab.webView?.reload() }
    }

    func stopLoading() { selectedTab?.webView?.stopLoading() }

    /// `delta`: 0 goes back to 100 %. Remembered by site (files of the Mac together); private
    /// windows record nothing.
    func zoom(_ delta: Double) {
        guard let tab = selectedTab, let webView = tab.webView, let host = webView.url.flatMap(Tab.zoomKey) else { return }
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
        guard !text.isEmpty, let webView = selectedTab?.webView else {
            findResult = nil
            return
        }
        lastFindText = text
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(text, configuration: configuration) { [weak self, weak webView] result in
            guard let self, let webView else { return }
            guard result.matchFound else {
                if self.lastFindText == text { self.findResult = FindResult(count: 0) }
                return
            }
            // WebKit only says whether there is one: the page's visible text says how many.
            Task {
                let count = await webView.nuriCall("""
                    const text = (document.body && document.body.innerText || '').toLocaleLowerCase();
                    const word = needle.toLocaleLowerCase();
                    let n = 0, i = text.indexOf(word);
                    while (i >= 0 && n < 1000) { n++; i = text.indexOf(word, i + word.length); }
                    return n;
                    """, arguments: ["needle": text], timeout: 1) as? Int
                if self.lastFindText == text { self.findResult = FindResult(count: max(1, count ?? 1)) }
            }
        }
    }

    /// ⌘F: the bar, and the keyboard in its field even when it's already out.
    func showFindBar() {
        findBarVisible = true
        findFieldFocus += 1
    }

    func findAgain(backwards: Bool) {
        if lastFindText.isEmpty { showFindBar() } else { find(lastFindText, backwards: backwards) }
    }

    // MARK: Dropped links

    /// Links dropped on the tab bar, each in a new tab, the last one shown. Only web pages and files
    /// of the Mac: no `javascript:` to run.
    @discardableResult
    func openDroppedLinks(_ urls: [URL]) -> Bool {
        let pages = urls.filter { ["http", "https", "file"].contains($0.scheme?.lowercased() ?? "") }
        for (index, url) in pages.enumerated() { openTab(url: url, background: index < pages.count - 1) }
        return !pages.isEmpty
    }

    // MARK: Source

    /// ⌥⌘U: the source of the page shown, as the server sent it, in a new tab. Read by the page
    /// itself (same site, its cookies, WebKit's cache), never sent anywhere else.
    func showSource() {
        guard let tab = selectedTab, let webView = tab.webView, let url = webView.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task {
            guard let source = await Self.source(in: webView) else {
                showToast("exclamationmark.triangle", L("La source de cette page n'a pas pu être lue", "This page's source couldn't be read"))
                return
            }
            let shown = openTab(url: nil, after: tab)
            shown.showSource(source, of: url)
        }
    }

    /// "view-source:" typed: the page opens, and its source takes its place once it has loaded.
    func showSource(of url: URL) {
        let tab = openTab(url: url)
        tab.showsSourceWhenLoaded = true
    }

    /// The text the server sent for the page in `webView`.
    static func source(in webView: WKWebView) async -> String? {
        await webView.nuriCall("""
            const response = await fetch(location.href, { cache: 'force-cache', credentials: 'include' });
            return await response.text();
            """, timeout: 8) as? String
    }

    // MARK: Files

    /// ⌘S: the page as a web archive (everything in one file, opened by Safari and Nuri) or a PDF.
    func savePage() {
        guard let tab = selectedTab, let webView = tab.webView, webView.url != nil, let window else { return }
        let panel = NSSavePanel()
        let base = DownloadManager.sanitizedFilename(tab.displayTitle)
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: [L("Archive web", "Web Archive"), "PDF"])
        let label = NSTextField(labelWithString: L("Format :", "Format:"))
        let accessory = NSStackView(views: [label, format])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        panel.allowedContentTypes = [.webArchive]
        panel.nameFieldStringValue = base
        panel.canCreateDirectories = true
        let chooser = SaveFormatChooser(panel: panel)
        format.target = chooser
        format.action = #selector(SaveFormatChooser.changed(_:))
        panel.beginSheetModal(for: window) { [weak self] response in
            _ = chooser
            guard response == .OK, let file = panel.url else { return }
            Task { await self?.savePage(of: webView, to: file, asPDF: format.indexOfSelectedItem == 1) }
        }
    }

    /// Writes the page; false when WebKit couldn't make it.
    @discardableResult
    func savePage(of webView: WKWebView, to file: URL, asPDF: Bool) async -> Bool {
        let made: Data? = await withCheckedContinuation { continuation in
            if asPDF {
                webView.createPDF { continuation.resume(returning: try? $0.get()) }
            } else {
                webView.createWebArchiveData { continuation.resume(returning: try? $0.get()) }
            }
        }
        guard let made, (try? made.write(to: file, options: .atomic)) != nil else {
            Log.storage.error("Enregistrement de la page impossible")
            showToast("exclamationmark.triangle", L("La page n'a pas pu être enregistrée", "The page couldn't be saved"))
            return false
        }
        showToast("checkmark.circle", L("Page enregistrée : \(file.lastPathComponent)", "Page saved: \(file.lastPathComponent)"))
        return true
    }

    /// ⌘O: a file of the Mac (a page, a PDF, an image, a web archive) in a new tab.
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("Ouvrir", "Open")
        let open = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK else { return }
            for url in panel.urls { self?.openTab(url: url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: open) } else { open(panel.runModal()) }
    }
}
