import AppKit
import WebKit
import Observation

/// Last known media state of one frame of a tab, as reported by media.js.
struct MediaFrameState {
    let frame: WKFrameInfo
    var hasVideo: Bool
    var playing: Bool
    var audible: Bool
    var inPiP: Bool
}

/// A browser tab. The WKWebView is created lazily and can be released ("sleep")
/// while keeping the URL, title and favicon: a tab not shown costs next to nothing until it's used.
@MainActor @Observable
final class Tab: Identifiable {
    let id: UUID
    let isPrivate: Bool

    var title: String
    var url: URL?
    /// What a page asked this tab to open (window.open, target=_blank), for « Réessayer »: never shown
    /// as its address, which only a committed page gives.
    @ObservationIgnored var requestedURL: URL?
    var favicon: NSImage?
    @ObservationIgnored var faviconData: Data?
    /// The site the icon belongs to: a page of another site that has none shows none.
    @ObservationIgnored private var faviconHost: String?

    private(set) var webView: NuriWebView?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var loadError: String?
    /// The address whose load failed: « Réessayer » asks for it again, not for the page before it.
    var failedURL: URL?
    /// Opened by "view-source:": once its page has loaded, the page's source takes its place.
    @ObservationIgnored var showsSourceWhenLoaded = false
    /// The link under the pointer, shown at the bottom of the page.
    var hoveredLink: URL?
    /// Frames of the page given shareaudio-page.js (ShareAudio.prepare), until another page commits.
    @ObservationIgnored var shareAudioFrames: Set<String> = []
    /// What the page asks, in a capsule above it (a window it wasn't allowed to open, notifications).
    var request: TabRequest?
    /// A local device's certificate that couldn't be checked: its error page offers to go on.
    var untrustedCertificate: CertificateExceptions.Pending?
    /// A page over plain HTTP, stopped before showing (PlainHTTP): the tab asks whether to go on.
    var insecurePage: URL?
    /// The address typed without `https://` being loaded, until it commits (TypedAddressFallback).
    @ObservationIgnored var typedAddress: TypedAddressFallback.Typed?
    /// Every resource of the page came over an encrypted connection (the lock in the address field).
    var hasOnlySecureContent = true

    // Media / Picture in Picture
    var hasVideo = false
    var isPlayingVideo = false
    var isAudible = false
    /// WebKit says the page is making sound (see AudioObserver): any kind of sound, where
    /// media.js only sees videos. `isAudible` takes both.
    @ObservationIgnored var webKitPlayingAudio = false
    @ObservationIgnored private var audioObserver: AudioObserver?
    /// The speaker on the tab: kept through sleeps and page changes.
    var isMuted = false
    var isInPiP = false
    var isInFloatingPlayer = false
    /// The page is using the camera or the microphone (a video call): see PiPController.
    var isInCall = false
    /// A video (or any element) of the page is fullscreen: WebKit has moved the web view into its
    /// own window and left a placeholder in ours; nothing may move either until it's back.
    var isInElementFullscreen = false
    @ObservationIgnored var autoPiPEngaged = false
    @ObservationIgnored var mediaFrames: [String: MediaFrameState] = [:]

    // Reader mode
    var reader: ReaderArticle?

    /// The user typed into a field of the current page (activity.js): the tab must stay awake.
    @ObservationIgnored var hasUserInput = false {
        didSet { if !hasUserInput { typedFrame = nil } }
    }
    /// The frame typed in last: what's asked before leaving (holdsTypedText).
    @ObservationIgnored var typedFrame: WKFrameInfo?
    /// Created by the page (window.open / target=_blank): asleep, its opener would lose it. It
    /// stays awake only while that link is really there (see sleepKeepingPlace).
    @ObservationIgnored var openedByPage = false
    /// Site of the page that opened this tab: a tab opened just to fetch a file asks for the
    /// download permission of that site, not of the file's server.
    @ObservationIgnored var openerHost: String?
    /// Back/forward list saved by a sleep, restored at wake-up.
    @ObservationIgnored private var savedInteractionState: Any?
    /// Scroll position read just before an automatic sleep, put back after the wake-up load
    /// (WebKit's saved state can lag behind the last scroll).
    @ObservationIgnored var pendingScroll: CGPoint?

    /// Last address written to the history (a page load, or a web app changing its address).
    @ObservationIgnored var lastRecordedURL: URL?
    @ObservationIgnored private var historyWork: DispatchWorkItem?

    /// What this tab looks like to extensions (see ExtensionHost).
    @ObservationIgnored var extensionAdapter: AnyObject?
    /// Closed for good (not asleep).
    @ObservationIgnored var isClosed = false
    /// The user asked to close the tab and its page is being asked (BrowserModel.requestClose).
    @ObservationIgnored var closeRequested = false
    /// The page's "Quitter cette page ?" sheet is up.
    @ObservationIgnored var isAskingToStay = false
    @ObservationIgnored weak var space: Space?
    /// The window model owning this tab.
    var browser: BrowserModel? { space?.browser }
    @ObservationIgnored var lastAccess = Date()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: TabWebDelegate?
    @ObservationIgnored private var popupConfiguration: WKWebViewConfiguration?
    @ObservationIgnored private var webViewBeingCreated: NuriWebView?

    /// `interactionState`: a back/forward list to come back with (a tab reopened by ⌘⇧T).
    init(id: UUID = UUID(), url: URL?, title: String = "", isPrivate: Bool = false, faviconData: Data? = nil,
         popupConfiguration: WKWebViewConfiguration? = nil, interactionState: Any? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.isPrivate = isPrivate
        self.faviconData = faviconData
        self.favicon = faviconData.flatMap(NSImage.init(data:))
        self.faviconHost = faviconData == nil ? nil : url?.host()?.nuriNormalizedHost
        self.popupConfiguration = popupConfiguration
        self.openedByPage = popupConfiguration != nil
        self.savedInteractionState = interactionState
    }

    /// The back/forward list as it is now: the web view's, or the one kept by a sleep.
    var currentInteractionState: Any? {
        takeStateFromSession()
        return webView?.interactionState ?? savedInteractionState
    }

    /// Restored from the session: its back/forward list is on disk (TabStates) until it's needed.
    @ObservationIgnored var isFromSession = false
    /// The list in its web view holds pages erased from the history: it isn't written any more.
    @ObservationIgnored private(set) var historyWasErased = false

    private func takeStateFromSession() {
        guard isFromSession else { return }
        isFromSession = false
        if savedInteractionState == nil { savedInteractionState = TabStates.read(id) }
    }

    /// What goes on disk; nil when the file there is still right.
    var stateToSave: Data? { (webView?.interactionState ?? savedInteractionState) as? Data }

    /// The history was erased: this tab starts its list again from its page.
    func forgetHistory() {
        isFromSession = false
        savedInteractionState = nil
        historyWasErased = true
    }

    /// What a zoom is remembered by: the site, or "file://" for every file of the Mac.
    static func zoomKey(_ url: URL) -> String? {
        url.isFileURL ? "file://" : url.host()
    }

    /// The zoom chosen for this site (⌘+ ⌘− ⌘0), set again at each page of it.
    func applySiteZoom() {
        guard let webView, let host = webView.url.flatMap(Self.zoomKey) else { return }
        let zoom = AppSettings.shared.siteZoom(for: host)
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return host.nuriNormalizedHost }
        return L("Nouvel onglet", "New tab")
    }

    var isAsleep: Bool { webView == nil }

    /// What the address field shows: the site's host, or the whole URL when it has none.
    var addressText: String {
        guard let url else { return "" }
        if let name = Extensions.name(ofPage: url) { return name }
        if let host = url.host() { return host.nuriNormalizedHost }
        return url.absoluteString
    }

    /// Returns the tab's web view, creating it (and loading `url`) if the tab was asleep.
    @discardableResult
    func ensureWebView() -> NuriWebView {
        if let webView { return webView }
        // Setting `webView` notifies observers *before* the value is stored; an observer can then
        // re-enter here synchronously and must get this same web view.
        if let webViewBeingCreated { return webViewBeingCreated }
        takeStateFromSession()
        let isPopup = popupConfiguration != nil
        let configuration = popupConfiguration ?? WebViewFactory.configuration(for: space, isPrivate: isPrivate, url: url)
        popupConfiguration = nil

        let wv = WebViewFactory.makeWebView(configuration: configuration)
        wv.tab = self
        let delegate = TabWebDelegate(tab: self)
        self.delegate = delegate
        wv.navigationDelegate = delegate
        wv.uiDelegate = delegate
        observe(wv)
        audioObserver = AudioObserver(webView: wv) { [weak self] playing in
            guard let self else { return }
            self.webKitPlayingAudio = playing
            PiPController.shared.recomputeSound(of: self)
        }
        webViewBeingCreated = wv
        webView = wv
        webViewBeingCreated = nil
        if isMuted { WebKitSPI.setPageMuted(wv, true) }

        if let state = savedInteractionState {
            // Woken from sleep: same history (and place, see restorePendingScroll).
            savedInteractionState = nil
            let page = url
            Extensions.whenPagesMayLoad { [weak wv] in
                wv?.interactionState = state
                // A list this WebKit can't read (a file from another version): at least its page.
                if wv?.backForwardList.currentItem == nil, let page { wv?.nuriLoad(page) }
            }
        } else if !isPopup, let url {
            Extensions.whenPagesMayLoad { [weak wv] in wv?.nuriLoad(url) }
        }
        return wv
    }

    func load(_ url: URL) {
        if let webView, Extensions.needsOtherWebView(webView, for: url) { sleep(force: true) }
        takeStateFromSession()
        self.url = url
        loadError = nil
        failedURL = nil
        untrustedCertificate = nil
        insecurePage = nil
        typedAddress = nil
        reader = nil
        let asleep = webView == nil
        let restoring = asleep && savedInteractionState != nil
        let isPopup = popupConfiguration != nil
        let wv = ensureWebView()
        if !asleep || isPopup {
            wv.nuriLoad(url)
        } else if restoring {
            // Its history comes back first (ensureWebView), then the new page goes on top of it.
            Extensions.whenPagesMayLoad { [weak wv] in wv?.nuriLoad(url) }
        }
        // Otherwise ensureWebView has just asked for `url`, once the blocker's rules are in: a
        // second load here would cancel that one and go out before the rules.
    }

    /// The page that asked is going: so does its question, unanswered.
    func dropRequest() {
        if case .notifications(_, let answer) = request { answer(nil) }
        request = nil
    }

    /// The speaker: the page plays on, silently.
    func setMuted(_ muted: Bool) {
        isMuted = muted
        if let webView { WebKitSPI.setPageMuted(webView, muted) }
    }

    /// Releases the web view. Never while in PiP, unless `force` (the tab is being closed, or its
    /// page is gone): PiP must then already have been exited.
    func sleep(force: Bool = false) {
        // Fullscreen first: WebKit must put the web view back in the window before it's released,
        // or its fullscreen window would stay behind, black.
        if isInElementFullscreen, let webView {
            webView.closeAllMediaPresentations { [weak self] in
                self?.isInElementFullscreen = false
                self?.sleep(force: force)
            }
            return
        }
        if force { isInPiP = false; isInFloatingPlayer = false; autoPiPEngaged = false }
        guard let webView, !isInPiP, !isInFloatingPlayer else { return }
        dropRequest()
        observations.forEach { $0.invalidate() }
        observations = []
        audioObserver = nil
        webKitPlayingAudio = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        delegate = nil
        isLoading = false
        progress = 0
        hasVideo = false
        isPlayingVideo = false
        isAudible = false
        isInCall = false
        mediaFrames = [:]
        reader = nil
        hasUserInput = false
        hoveredLink = nil
        shareAudioFrames = []
        // What described the released page: the next web view reports its own.
        canGoBack = false
        canGoForward = false
        hasOnlySecureContent = true
        isInElementFullscreen = false
        closeRequested = false
        isAskingToStay = false
        insecurePage = nil
        historyWork?.cancel()
    }

    /// Automatic sleep: remembers the scroll position, then releases the web view (unless the
    /// tab was shown or became busy in the meantime).
    func sleepKeepingPlace(idleFor interval: TimeInterval) async {
        guard let webView else { return }
        // A tab a page opened keeps its web view while it can still talk with that page
        // (window.opener: a sign-in or a payment answering it). A link opened in a new tab has none
        // (noopener, the default for target=_blank), nor has a tab whose opener has gone.
        let state = await webView.nuriCall("return [window.scrollX, window.scrollY, !!(window.opener && !window.opener.closed)];") as? [Any]
        guard browser?.visibleTabs.contains(where: { $0 === self }) != true, canAutoSleep(idleFor: interval) else { return }
        if openedByPage, state?.last as? Bool != false { return }
        if let state, state.count == 3, let x = state[0] as? Double, let y = state[1] as? Double { pendingScroll = CGPoint(x: x, y: y) }
        savedInteractionState = webView.interactionState
        sleep()
    }

    /// Releases the web view now, PiP included, keeping its back/forward list for the next wake-up.
    func sleepKeepingHistory() {
        guard let webView else { return }
        savedInteractionState = webView.interactionState
        sleep(force: true)
    }

    /// The load of an address typed without `https://` failed: the same address over HTTP when
    /// nothing answered over HTTPS, or a search when no such site exists. True when another load
    /// takes the place of the error.
    func recoverTypedAddress(from error: NSError) -> Bool {
        guard let typed = typedAddress else { return false }
        typedAddress = nil
        switch TypedAddressFallback.decide(typed, error: error) {
        case .http(let url):
            load(url)
            return true
        case .search(let text):
            guard let url = AppSettings.shared.searchURL(for: text) else { return false }
            load(url)
            browser?.showToast("magnifyingglass", L("Aucun site « \(text) » : recherche lancée", "No site called “\(text)”: searching"))
            return true
        case nil:
            return false
        }
    }

    /// « Continuer » on the warning about a page over plain HTTP.
    func continueToInsecurePage() {
        guard let page = insecurePage, let browser else { return }
        PlainHTTP.accept(page, in: browser)
        load(page)
    }

    /// « Retour » on that warning: the page underneath, unless it shows nothing, as a link shim
    /// that only sent here. Then the page before it, or the tab goes if it has no other.
    func leaveInsecurePage() async {
        guard let webView, webView.backForwardList.currentItem != nil else {
            browser?.close(self)
            return
        }
        let script = "return !document.body || (!document.body.innerText.trim() && !document.querySelector('img, video, canvas, svg, iframe'));"
        let empty = await webView.nuriCall(script, timeout: 1) as? Bool ?? false
        insecurePage = nil
        guard empty else { return }
        if webView.canGoBack { webView.goBack() } else { browser?.close(self) }
    }

    /// « Réessayer » on the error page, and ⌘R after a failure: the address that failed (a link
    /// followed from a page that loaded), else the tab's own.
    func retryAfterError() {
        let target = failedURL ?? url ?? requestedURL
        loadError = nil
        failedURL = nil
        if let target { load(target) }
    }

    /// Shows the text of a page, escaped, in this tab: no script of it runs.
    func showSource(_ source: String, of page: URL) {
        let escaped = source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let title = "view-source:" + page.absoluteString
        let titleEscaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
            <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(titleEscaped)</title>
            <style>body { margin: 0; } pre { margin: 0; padding: 14px 16px; font: 12px/1.5 ui-monospace, Menlo, monospace; white-space: pre-wrap; word-break: break-all; }</style>
            <pre>\(escaped)</pre>
            """
        ensureWebView().loadHTMLString(html, baseURL: URL(string: "about:blank"))
    }

    /// A page committed: its title and icon, not those of the page before. Its title is empty until
    /// it sets one (the tab then shows its site), and the icon of another site goes until this one's
    /// is found (FaviconLoader, at the end of the load).
    func takePageIdentity(of webView: WKWebView) {
        let newTitle = webView.title ?? ""
        if title != newTitle {
            title = newTitle
            Extensions.tabChanged(self, .title)
        }
        failedURL = nil
        hoveredLink = nil
        shareAudioFrames = []
        let host = webView.url?.host()?.nuriNormalizedHost
        if favicon != nil, host != faviconHost {
            favicon = nil
            faviconData = nil
            faviconHost = nil
            browser?.setNeedsSave()
        }
    }

    /// A navigation committed: the page now shown is the one at `url`.
    func didCommit(_ url: URL?) {
        typedAddress = nil
        guard let url, url != self.url else { return }
        self.url = url
        browser?.setNeedsSave()
        Extensions.tabChanged(self, .url)
    }

    /// Whether this tab's visits may be written down.
    var keepsHistory: Bool { !isPrivate && browser?.isEphemeralSession != true && !Extensions.isExtensionPage(url) }

    /// A web app changing its address without loading a page (pushState): no didFinish, so the
    /// visit is written here — once the address has stayed a moment, and unless the page load
    /// under way writes it anyway.
    private func recordInHistoryIfStill(_ url: URL) {
        guard keepsHistory else { return }
        historyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let webView = self.webView, !webView.isLoading, webView.url == url,
                  self.lastRecordedURL != url, let space = self.space else { return }
            HistoryStore.shared.record(url: url, title: webView.title ?? self.title, space: space.id)
            self.lastRecordedURL = url
        }
        historyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// After waking up: puts the page back where it was if WebKit didn't.
    func restorePendingScroll() {
        guard let point = pendingScroll, let webView else { return }
        pendingScroll = nil
        let script = "if (Math.abs(window.scrollY - y) > 40) window.scrollTo(x, y); return window.scrollY;"
        Task {
            for delay in [0, 600] {   // late layout (images, fonts) can shorten the page at first
                try? await Task.sleep(for: .milliseconds(delay))
                _ = await webView.nuriCall(script, arguments: ["x": point.x, "y": point.y])
            }
        }
    }

    /// There is still text in a field of the frame typed in: what the page would lose. A search field
    /// or a password isn't that, and in a rich editor (they keep their whole document in the field,
    /// and save it themselves) only the one being used counts.
    func holdsTypedText() async -> Bool {
        guard hasUserInput, let webView else { return false }
        let script = """
            const skipped = /^(checkbox|radio|range|color|file|submit|button|reset|image|hidden|password|search)$/i;
            for (const field of document.querySelectorAll('textarea, input')) {
              if (field.tagName === 'INPUT' && skipped.test(field.type || '')) continue;
              if (field.getAttribute('role') === 'searchbox') continue;
              if (field.value.trim() && field.value !== field.defaultValue) return true;
            }
            let active = document.activeElement;
            return !!(active && active.isContentEditable && active.innerText.trim());
            """
        return await webView.nuriCall(script, in: typedFrame, timeout: 1) as? Bool ?? false
    }

    /// Automatic sleep: only idle tabs. Tabs playing sound, in a call (camera/microphone), with
    /// typed text, in PiP or reader mode stay awake; so does one a page opened that still talks with
    /// it, which only its page can tell (sleepKeepingPlace).
    func canAutoSleep(idleFor interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let webView, reader == nil else { return false }
        guard now.timeIntervalSince(lastAccess) >= interval else { return false }
        if isAudible || isPlayingVideo || isInPiP || isInFloatingPlayer || isInElementFullscreen || hasUserInput { return false }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return false }
        return true
    }

    private func observe(_ wv: WKWebView) {
        observations = [
            wv.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let t = wv.title, !t.isEmpty else { return }
                    self.title = t
                    Extensions.tabChanged(self, .title)
                    if self.keepsHistory, let url = wv.url, let space = self.space {
                        HistoryStore.shared.updateTitle(url: url, title: t, space: space.id)
                    }
                }
            },
            wv.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    // WebKit reports the URL of a navigation as soon as it starts. Showing it
                    // before it commits would let a page display "bank.com" (and a lock) over its
                    // own content with a navigation that never completes: only same-origin
                    // changes (pushState, anchors) are taken here, the rest at commit. A tab opened
                    // by a page has no origin to compare with: it takes what isn't a navigation
                    // under way (the opener writing in it: the page then is the opener's).
                    guard let self, let u = wv.url, u != self.url else { return }
                    guard self.url == nil ? !wv.isLoading : u.nuriSameOrigin(as: self.url) else { return }
                    self.url = u
                    self.browser?.setNeedsSave()
                    self.recordInHistoryIfStill(u)
                    Extensions.tabChanged(self, .url)
                }
            },
            wv.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.hasOnlySecureContent = wv.hasOnlySecureContent }
            },
            wv.observe(\.fullscreenState, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    let fullscreen = wv.fullscreenState != .notInFullscreen
                    if self?.isInElementFullscreen != fullscreen { self?.isInElementFullscreen = fullscreen }
                }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = wv.isLoading
                    Extensions.tabChanged(self, .loading)
                }
            },
            wv.observe(\.cameraCaptureState, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.updateCallState(wv) }
            },
            wv.observe(\.microphoneCaptureState, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.updateCallState(wv) }
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
            },
            wv.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            wv.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
        ]
    }

    private func updateCallState(_ wv: WKWebView) {
        let inCall = wv.cameraCaptureState != .none || wv.microphoneCaptureState != .none
        guard inCall != isInCall else { return }
        isInCall = inCall
        PiPController.shared.callStateChanged(self)
    }

    func setFavicon(_ image: NSImage, data: Data, host: String? = nil) {
        favicon = image
        faviconData = data
        faviconHost = (host ?? webView?.url?.host())?.nuriNormalizedHost
        browser?.setNeedsSave()
    }
}

/// Tells when a page starts or stops making sound. WebKit's property is private, hence the string
/// key; if it ever goes away, the speaker only shows for videos (media.js).
private final class AudioObserver: NSObject {
    private weak var webView: WKWebView?
    private let changed: @MainActor (Bool) -> Void

    @MainActor
    init?(webView: WKWebView, changed: @escaping @MainActor (Bool) -> Void) {
        guard webView.responds(to: NSSelectorFromString(WebKitSPI.playingAudioKey)) else { return nil }
        self.webView = webView
        self.changed = changed
        super.init()
        webView.addObserver(self, forKeyPath: WebKitSPI.playingAudioKey, options: [.new], context: nil)
    }

    deinit { webView?.removeObserver(self, forKeyPath: WebKitSPI.playingAudioKey) }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let playing = change?[.newKey] as? Bool ?? false
        MainActor.assumeIsolated { changed(playing) }
    }
}

extension URL {
    /// Same scheme, host and port.
    func nuriSameOrigin(as other: URL?) -> Bool {
        guard let other else { return false }
        return scheme?.lowercased() == other.scheme?.lowercased() && host()?.lowercased() == other.host()?.lowercased()
            && port == other.port
    }
}
