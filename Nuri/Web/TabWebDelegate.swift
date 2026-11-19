import AppKit
import WebKit
import UniformTypeIdentifiers

/// Navigation + UI delegate of one tab's web view.
@MainActor
final class TabWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var tab: Tab?
    /// The window owning the tab (private windows keep links and pop-ups private).
    private var browser: BrowserModel { tab?.browser ?? .shared }

    init(tab: Tab) { self.tab = tab }

    private static let internalSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript", "view-source", Extensions.pageScheme]

    // MARK: - Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        // Who asked for this page: a redirect keeps the answer of the navigation it continues.
        if isMainFrame, !WebKitSPI.isRedirect(navigationAction) {
            mainFrameNavigationAsked = Self.isAsked(navigationAction, in: webView)
        }
        if navigationAction.shouldPerformDownload {
            let asked = isMainFrame ? mainFrameNavigationAsked : Self.isAsked(navigationAction, in: webView)
            return await mayDownload(navigationAction.request.url, asked: asked, in: webView) ? .download : .cancel
        }
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""

        // A WebKit bug (seen 2026-11-19 with "youtube.com" typed in a new tab): when a redirect
        // comes from the disk cache (youtube.com → www.youtube.com), WebKit makes the next request
        // without cookies. The site then sees a stranger: signed out, its cookie banner again. The
        // same request, with cookies, goes out instead.
        if isMainFrame, !navigationAction.request.httpShouldHandleCookies, scheme == "http" || scheme == "https",
           (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET", mayRetryWithCookies() {
            Log.web.error("Redirection du cache sans cookies : page redemandée avec ses cookies")
            var request = navigationAction.request
            request.httpShouldHandleCookies = true
            webView.load(request)
            // Asked for as much as the navigation it replaces, no more: a page sending itself to a
            // file doesn't become a typed address.
            if !mainFrameNavigationAsked { _ = (webView as? NuriWebView)?.consumeAppLoad() }
            return .cancel
        }

        // A blank window a page opened after a click, now sent somewhere: an ad's, if that's
        // another site than the click was for (PopupGuard).
        if isMainFrame, let check = tab?.blankPopupCheck, scheme == "http" || scheme == "https" {
            tab?.blankPopupCheck = nil
            if PopupGuard.isPopunder(request: url, opener: check.openerURL, clickedLink: check.clickedLink, pressedControl: check.pressedControl, sized: false) {
                refusePopup(url, from: check.opener, openerURL: check.openerURL)
                if let tab { DispatchQueue.main.async { [weak self] in self?.browser.close(tab) } }
                return .cancel
            }
        }

        // An extension's page leading to the web: its web view can't go there (see Tab.load).
        if Extensions.isExtensionPage(webView.url), !Extensions.isExtensionPage(url), navigationAction.targetFrame?.isMainFrame == true,
           scheme == "http" || scheme == "https" {
            tab?.load(url)
            return .cancel
        }

        // WebKit has no view-source: of its own: the source opens in a tab of Nuri's.
        if scheme == "view-source" {
            // Only for a click: a script can't open tabs that way.
            if navigationAction.navigationType == .linkActivated, let page = URLResolver.viewSourceTarget(url.absoluteString) { browser.showSource(of: page) }
            return .cancel
        }

        if !Self.internalSchemes.contains(scheme) {
            // mailto:, tel:, zoommtg:, … → hand over to macOS from the page itself: on a click, at
            // once for the usual system apps, after asking for the others; from a script, asked
            // for the tab on screen only (ExternalURLPolicy).
            let policy = ExternalURLPolicy.decide(scheme: scheme, userClick: navigationAction.navigationType == .linkActivated,
                                                  fromMainFrame: navigationAction.sourceFrame.isMainFrame,
                                                  tabShown: tab.map { shown in browser.visibleTabs.contains { $0 === shown } } ?? false)
            switch policy {
            case .open: NSWorkspace.shared.open(url)
            case .ask: ExternalURLPolicy.confirmAndOpen(url, from: navigationAction.sourceFrame.securityOrigin.host, in: webView.window)
            case .refuse: break
            }
            return .cancel
        }

        // ⌘-click / middle-click → new tab (⌘⇧ = in the foreground). Only a click made in this very
        // page: the first load of a tab opened by WebKit (the context menu's "Ouvrir le lien dans un
        // nouvel onglet", a target=_blank link) comes with the click that opened it, and sending it
        // to yet another tab would leave this one empty.
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame != nil,
           navigationAction.sourceFrame.webView === webView {
            let flags = navigationAction.modifierFlags
            if flags.contains(.command) || navigationAction.buttonNumber == Self.middleButton {
                browser.openTab(url: TrackingParameters.cleaned(url), background: !flags.contains(.shift), after: tab)
                return .cancel
            }
            // ⌥-click: a glance at the link, in a Porthole over this page.
            if flags.contains(.option), ["http", "https"].contains(scheme) {
                browser.openPorthole(TrackingParameters.cleaned(url), from: tab)
                return .cancel
            }
            // A link clicked in the page: its tracking parameters stay behind.
            if navigationAction.targetFrame?.isMainFrame == true, navigationAction.request.httpMethod == "GET" {
                let clean = TrackingParameters.cleaned(url)
                if clean != url {
                    // The same request, Referer included: only its address changes.
                    var request = navigationAction.request
                    request.url = clean
                    webView.load(request)
                    return .cancel
                }
            }
        }
        return .allow
    }

    /// `WKNavigationAction.buttonNumber` is a mask: 1 the left button, 2 the right one, 4 the middle one.
    private static let middleButton = 4

    /// Whether the user asked for the page the main frame is going to: a click, a typed address, a
    /// reload. A page sending itself somewhere (a timer, a script of an ad) did not.
    private var mainFrameNavigationAsked = true

    /// A click, as WebKit tells it (a script's own `a.click()` or form submission isn't one), going
    /// back or forward, a reload, or a load Nuri made. Only the main frame's navigation can be
    /// Nuri's: a frame's never takes that mark from it.
    private static func isAsked(_ action: WKNavigationAction, in webView: WKWebView) -> Bool {
        // Without WebKit's word on clicks: as before, every download goes ahead.
        guard WebKitSPI.knowsUserInitiated else { return true }
        if WebKitSPI.isUserInitiated(action) { return true }
        if [.backForward, .reload].contains(action.navigationType) { return true }
        return action.targetFrame?.isMainFrame == true && (webView as? NuriWebView)?.consumeAppLoad() == true
    }

    /// Three tries in ten seconds: a page always redirected without cookies can't loop.
    private var cookieRetries: [Date] = []
    private func mayRetryWithCookies() -> Bool {
        cookieRetries.removeAll { $0.timeIntervalSinceNow < -10 }
        guard cookieRetries.count < 3 else { return false }
        cookieRetries.append(Date())
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // "attachment" in any frame: Google Drive and others download through a hidden frame,
        // where a PDF or an image would otherwise be shown to nobody.
        var download = !navigationResponse.canShowMIMEType || isAttachment(navigationResponse.response)
        let response = navigationResponse.response
        if download, !navigationResponse.canShowMIMEType, navigationResponse.isForMainFrame, !isAttachment(response) {
            if Self.isLostResponse(response) {
                // A WebKit bug, seen with YouTube typed in a new tab (journal of 2026-11-12): the first
                // visit after launch finds the site's service worker asleep, WebKit asks the network
                // itself meanwhile, hands that answer to the page's process, then moves the page to a
                // new process (Cross-Origin-Opener-Policy) which gets an empty answer: no address, no
                // type. Said "can't be shown", it used to land in Téléchargements as
                // "www.youtube.com.html". Asked again, the worker is awake and the page comes normally.
                if let target = webView.url ?? tab?.url, ["http", "https"].contains(target.scheme?.lowercased() ?? ""), mayRetryLostResponse() {
                    Log.downloads.error("Réponse vide de WebKit pour la page (changement de processus) : page redemandée")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak webView] in webView?.nuriLoad(target) }
                    return .cancel
                }
                // Still empty after two tries: shown as it comes, never saved as a file nobody asked for.
                Log.downloads.error("Réponse vide de WebKit pour la page, encore : laissée à l'affichage")
                download = false
            } else if Self.isWebPage(response) {
                // HTML that WebKit says it can't show: it reads what it gets, so it is shown.
                Log.downloads.error("Page HTML donnée comme impossible à afficher (type « \(response.mimeType ?? "aucun", privacy: .public) ») : affichée")
                download = false
            }
        }
        StrictTransport.record(response, in: browser)
        guard download else {
            guard navigationResponse.isForMainFrame, PlainHTTP.needsWarning(response.url, in: browser) else { return .allow }
            tab?.insecurePage = response.url
            return .cancel
        }
        // A frame's own navigation isn't followed: a press of the mouse or a key in the page just
        // before stands for its click (a hidden frame fetching the file of a button).
        let asked = navigationResponse.isForMainFrame ? mainFrameNavigationAsked : (webView as? NuriWebView)?.hadRecentInput() ?? true
        return await mayDownload(response.url, file: response.suggestedFilename, asked: asked, in: webView) ? .download : .cancel
    }

    private func isAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        return disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
    }

    /// The answer of a page always has an address: one without is an answer WebKit lost on the way.
    static func isLostResponse(_ response: URLResponse) -> Bool { response.url == nil }

    /// Two tries in a quarter of a minute, so that a page always answered empty can't loop.
    private var lostResponseRetries: [Date] = []
    private func mayRetryLostResponse() -> Bool {
        lostResponseRetries.removeAll { $0.timeIntervalSinceNow < -15 }
        guard lostResponseRetries.count < 2 else { return false }
        lostResponseRetries.append(Date())
        return true
    }

    /// HTML by its type, or with no type at all and a name WebKit gave it from what it read.
    static func isWebPage(_ response: URLResponse) -> Bool {
        let type = response.mimeType?.lowercased() ?? ""
        if ["text/html", "application/xhtml+xml"].contains(type) { return true }
        guard type.isEmpty, let name = response.suggestedFilename else { return false }
        return ["html", "htm"].contains((name as NSString).pathExtension.lowercased())
    }

    /// Asked only of a site saving several files in a row (DownloadPermission). The site is the page's; a tab opened just for the
    /// file has none yet, then it's the file's. A refused download leaves no empty tab behind.
    private func mayDownload(_ url: URL?, file: String? = nil, asked: Bool, in webView: WKWebView) async -> Bool {
        // A tab opened for the file has no page yet: the site is the one that opened it.
        let opener = webView.backForwardList.currentItem == nil ? tab?.openerHost : nil
        let host = (opener ?? webView.url?.host() ?? url?.host() ?? "").nuriNormalizedHost
        let file = file ?? url?.lastPathComponent

        // A file of another site that nobody asked for: an ad's window, or a page sending itself
        // there without a click. Asked each time, never remembered. The page is the one shown
        // (webView.url already says where the file comes from).
        let page = webView.backForwardList.currentItem?.url ?? opener.flatMap { URL(string: "https://\($0)") } ?? tab?.url
        let fromPagePopup = tab.map { $0.openedByPage && !$0.openedFromClickedLink } ?? false
        if PopupGuard.isUnrequestedDownload(file: url, page: page, asked: asked, fromPagePopup: fromPagePopup) {
            let pageHost = (page?.host() ?? host).nuriNormalizedHost
            Log.downloads.error("Téléchargement non demandé depuis \(pageHost, privacy: .public) : question posée")
            let allowed = await DownloadPermission.confirmUnrequested(file: file, from: url, page: pageHost, in: browser, window: webView.window)
            if !allowed {
                browser.showToast("arrow.down.circle", L("Téléchargement non demandé refusé", "Unrequested download refused"))
                // The ad's tab goes with its file.
                if fromPagePopup, let tab { browser.close(tab) } else { closeIfEmpty(webView) }
            }
            return allowed
        }

        let allowed = await DownloadPermission.request(host, file: file, in: browser, window: webView.window)
        if !allowed {
            browser.showToast("arrow.down.circle", L("Téléchargement refusé depuis \(host)", "Download refused from \(host)"))
            closeIfEmpty(webView)
        }
        return allowed
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, from: navigationAction.request.url, in: browser)
        closeIfEmpty(webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download, from: navigationResponse.response.url, in: browser)
        closeIfEmpty(webView)
    }

    /// "Download Linked File / Image / Video" from the context menu: WebKit starts the download
    /// itself and hands it over here (WKUIDelegatePrivate). Without this method the download
    /// gets no delegate and nothing happens.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreate download: WKDownload) {
        DownloadManager.shared.adopt(download, from: download.originalRequest?.url, in: browser)
    }

    /// The download button of WebKit's PDF viewer hands the document over here (WKUIDelegatePrivate).
    /// Without this method the button does nothing.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(_ webView: WKWebView, saveDataToFile data: Data, suggestedFilename: String, mimeType: String?, originatingURL: URL?) {
        DownloadManager.shared.save(data, filename: suggestedFilename, mimeType: mimeType, from: originatingURL ?? webView.url, in: browser)
    }

    /// A link opened in a new tab that turned out to be a download leaves an empty tab behind.
    func closeIfEmpty(_ webView: WKWebView) {
        guard let tab, webView.backForwardList.currentItem == nil else { return }
        browser.close(tab)
    }

    // MARK: - Navigation progress

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.loadError = nil
        tab?.untrustedCertificate = nil
        tab?.insecurePage = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab else { return }
        tab.didCommit(webView.url)
        tab.takePageIdentity(of: webView)
        tab.applySiteZoom()
        tab.reader = nil
        tab.hasUserInput = false
        tab.dropRequest()
        WebNotifications.shared.pageCommitted(tab)
        PiPController.shared.resetFrames(of: tab)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab else { return }
        if tab.keepsHistory, let url = webView.url, let space = tab.space {
            HistoryStore.shared.record(url: url, title: webView.title ?? "", space: space.id)
            tab.lastRecordedURL = url
        }
        if tab.showsSourceWhenLoaded, let url = webView.url {
            tab.showsSourceWhenLoaded = false
            Task {
                if let source = await BrowserModel.source(in: webView) { tab.showSource(source, of: url) }
            }
            return
        }
        FaviconLoader.load(for: tab)
        tab.restorePendingScroll()
        browser.setNeedsSave()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        // Cancelled / interrupted by policy (downloads, ⌘-click) are not errors.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        if tab?.recoverTypedAddress(from: ns) == true { return }
        Log.web.error("Page en échec : \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        // The address that failed, for « Réessayer »: the tab's own is still the page before it.
        let failing = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        tab?.failedURL = failing
        tab?.loadError = ns.localizedDescription
        // Through a VPN extension, its password may have expired: asked again, and the page with it.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorUserAuthenticationRequired, ExtensionProxy.shared.isRouting,
           let tab, let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? tab.url {
            Task { if await ExtensionProxy.shared.renewAfterFailure(), tab.loadError != nil { tab.load(url) } }
        }
    }

    // MARK: - HTTP authentication

    /// Methods for which the user types a name and a password. Kerberos (Negotiate) and client
    /// certificates stay with WebKit's default handling.
    private static let passwordMethods: Set<String> = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                                                      NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodDefault]

    /// Sites behind HTTP authentication (routers, NAS, intranets): without this, WebKit never asks
    /// and shows the server's 401 page.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust {
            return await CertificateExceptions.decide(host: space.host, trust: trust, tab: tab)
        }
        // A VPN extension's server: its password comes from the extension, never from a dialog.
        if let answer = await ExtensionProxy.shared.answer(challenge) { return answer }
        // Refused three times: the server's own error page.
        guard Self.passwordMethods.contains(space.authenticationMethod), challenge.previousFailureCount < 3 else {
            return (.performDefaultHandling, nil)
        }
        // Only over the tab being shown (like JS dialogs); a hidden tab gets the 401 page, which a reload asks again.
        guard let tab, tab.browser?.visibleTabs.contains(where: { $0 === tab }) == true, let window = webView.window else {
            return (.performDefaultHandling, nil)
        }
        let port = [80, 443].contains(space.port) ? "" : ":\(space.port)"
        let alert = NSAlert()
        alert.messageText = L("Connexion à \(space.host)\(port)", "Sign in to \(space.host)\(port)")
        var info = space.realm.map { L("« \($0) » demande un nom d'utilisateur et un mot de passe.", "“\($0)” asks for a user name and password.") }
            ?? L("Ce site demande un nom d'utilisateur et un mot de passe.", "This site asks for a user name and password.")
        if challenge.previousFailureCount > 0 { info = L("Nom d'utilisateur ou mot de passe incorrect.", "Wrong user name or password.") + " " + info }
        if !space.receivesCredentialSecurely { info += "\n\n" + L("La connexion n'est pas chiffrée : le mot de passe sera envoyé en clair.", "This connection isn't encrypted: the password will be sent in the clear.") }
        alert.informativeText = info
        let user = NSTextField(string: challenge.proposedCredential?.user ?? "")
        user.placeholderString = L("Nom d'utilisateur", "User name")
        let password = NSSecureTextField(string: "")
        password.placeholderString = L("Mot de passe", "Password")
        let fields = NSStackView(views: [user, password])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        for field in [user, password] { field.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        alert.accessoryView = fields
        alert.addButton(withTitle: L("Se connecter", "Sign In"))
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
    }

    /// Last automatic reload after a crash of the page's process (at most one per 30 s).
    private var lastCrashReload: Date?

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab else { return }
        Log.web.error("Le processus d'une page s'est arrêté")
        // Not shown: no reload now (after memory pressure, every tab reloading at once would
        // make it worse). It comes back when selected.
        guard tab.browser?.visibleTabs.contains(where: { $0 === tab }) == true else { tab.sleepKeepingHistory(); return }
        if let last = lastCrashReload, Date().timeIntervalSince(last) < 30 {
            // Crashed again right away: stop here instead of looping.
            tab.isLoading = false
            tab.loadError = L("La page a cessé de fonctionner.", "This page stopped working.")
            return
        }
        lastCrashReload = Date()
        webView.reload()
    }

    // MARK: - Link under the pointer

    /// The pointer over a link, or off it (WKUIDelegatePrivate): its address shows at the bottom of
    /// the page, as in every browser. `element` is a _WKHitTestResult.
    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    func webView(_ webView: WKWebView, mouseDidMoveOverElement element: AnyObject?, withFlags flags: UInt, userInfo: AnyObject?) {
        let selector = NSSelectorFromString("absoluteLinkURL")
        let link = (element as? NSObject).flatMap { $0.responds(to: selector) ? $0.value(forKey: "absoluteLinkURL") as? URL : nil }
        if tab?.hoveredLink != link { tab?.hoveredLink = link }
    }

    // MARK: - New windows → new tabs

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let flags = navigationAction.modifierFlags
        // ⌘-click or middle click on a target=_blank link: behind, like any other link. The
        // context menu's "Ouvrir … dans un nouvel onglet" too: the page stays on screen.
        let fromContextMenu = (webView as? NuriWebView)?.consumeContextMenuOpen() == true
        let host = webView.url?.host()?.nuriNormalizedHost ?? ""
        let allowedSite = PopupPermission.isAllowed(host, in: browser)
        let request = navigationAction.request.url
        // Not asked for by a click: refused, and said (a frame of another site, an ad most of the
        // time, isn't worth a word).
        if !fromContextMenu, WebKitSPI.knowsUserInitiated, !WebKitSPI.isUserInitiated(navigationAction),
           navigationAction.navigationType != .linkActivated {
            guard allowedSite else {
                if navigationAction.sourceFrame.isMainFrame { refusePopup(request, from: tab, openerURL: webView.url) }
                return nil
            }
        }
        // ⌘-click, middle click, the context menu: the user's own new tab.
        let byHand = fromContextMenu || flags.contains(.command) || flags.contains(.option) || navigationAction.buttonNumber == Self.middleButton
        // After a press of the mouse: a pop-under, unless the window is what was pressed (PopupGuard).
        let press = byHand || allowedSite ? nil : (webView as? NuriWebView)?.recentPointerDown()
        let sized = windowFeatures.width != nil || windowFeatures.height != nil
        if let press, PopupGuard.isPopunder(request: request, opener: webView.url, clickedLink: press.link, pressedControl: press.control, sized: sized) {
            Log.web.error("Fenêtre publicitaire après un clic bloquée (\(PopupGuard.site(of: request) ?? "?", privacy: .public))")
            if navigationAction.sourceFrame.isMainFrame { refusePopup(request, from: tab, openerURL: webView.url) }
            return nil
        }
        // ⌥-click on a target=_blank link: a glance, as for any other link.
        if flags.contains(.option), let url = navigationAction.request.url, !fromContextMenu,
           navigationAction.navigationType == .linkActivated {
            browser.openPorthole(TrackingParameters.cleaned(url), from: tab)
            return nil
        }
        let background = fromContextMenu
            || ((flags.contains(.command) || navigationAction.buttonNumber == Self.middleButton) && !flags.contains(.shift))
        let newTab = browser.openTab(url: nil, background: background, after: tab, popupConfiguration: configuration)
        // Not its address yet: until a page commits, the opener can write in this tab whatever it wants.
        newTab.requestedURL = navigationAction.request.url
        newTab.openerHost = webView.url?.host()
        if byHand {
            newTab.openedFromClickedLink = true
        } else if let press {
            // The link pressed, opened in a new tab (target=_blank): its file downloads as any link's.
            newTab.openedFromClickedLink = press.link != nil && PopupGuard.sameSite(request, press.link)
            // A blank window, sent somewhere later: judged then.
            if PopupGuard.site(of: request) == nil, !sized {
                newTab.blankPopupCheck = BlankPopupCheck(opener: tab, openerURL: webView.url, clickedLink: press.link, pressedControl: press.control)
            }
        }
        return newTab.ensureWebView()
    }

    /// A window refused: said over the page that asked, with where it would have gone.
    private func refusePopup(_ request: URL?, from opener: Tab?, openerURL: URL?) {
        let host = openerURL?.host()?.nuriNormalizedHost ?? ""
        guard let opener, opener.request == nil, !host.isEmpty else { return }
        let url = request.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        opener.request = .popup(url: url, host: host)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab { browser.close(tab) }
    }

    // MARK: - JavaScript panels

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        return await present(alert, in: webView) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        return await present(alert, in: webView) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// "Quitter cette page ?" (beforeunload): leaving it, reloading it or closing its tab while the
    /// page says something would be lost (WKUIDelegatePrivate; without it WebKit never asks).
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let tab, let browser = tab.browser, let window = webView.window else { return completionHandler(true) }
        if browser.selectedTab !== tab {
            // Asked about a tab the user is closing from the list: show it while asking.
            guard tab.closeRequested else { return completionHandler(true) }
            browser.select(tab)
        }
        tab.isAskingToStay = true
        let alert = NSAlert()
        alert.messageText = L("Quitter cette page ?", "Leave this page?")
        let host = frame.securityOrigin.host
        alert.informativeText = host.isEmpty
            ? L("Cette page indique que les modifications que vous avez faites pourraient ne pas être enregistrées.", "This page says your changes may not be saved.")
            : L("\(host) indique que les modifications que vous avez faites pourraient ne pas être enregistrées.", "\(host) says your changes may not be saved.")
        alert.addButton(withTitle: L("Quitter la page", "Leave Page"))
        alert.addButton(withTitle: L("Rester", "Stay"))
        alert.beginSheetModal(for: window) { [weak tab] response in
            let leave = response == .alertFirstButtonReturn
            tab?.isAskingToStay = false
            if !leave { tab?.closeRequested = false }
            completionHandler(leave)
        }
    }

    // MARK: - window.print()

    /// A page's own "Imprimer" button (WKUIDelegatePrivate; without it WebKit does nothing). The
    /// page waits for the answer, so it always comes.
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject, pdfFirstPageSize: CGSize, completionHandler: @escaping () -> Void) {
        printFromPage(webView, frame, completionHandler)
    }

    @objc(_webView:printFrame:)
    func webView(_ webView: WKWebView, printFrame frame: AnyObject) {
        printFromPage(webView, frame) {}
    }

    /// Only for the tab on screen, and not in a loop: like any dialog of a page.
    private func printFromPage(_ webView: WKWebView, _ frame: AnyObject, _ done: @escaping () -> Void) {
        guard let tab, let browser = tab.browser, browser.visibleTabs.contains(where: { $0 === tab }), mayShowDialog() else { return done() }
        browser.print(webView, frame: frame, done: done)
    }

    // MARK: - Notifications

    /// Notification.requestPermission() (WKUIDelegatePrivate): answered "denied" by WebKit without it.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func webViewRequestNotifications(_ webView: WKWebView, for origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
        WebNotifications.shared.request(host: origin.host, tab: tab, webView: webView, answer: decisionHandler)
    }

    /// Recent dialogs of this tab, to stop a page that opens them in a loop.
    private var recentDialogs: [Date] = []

    private func mayShowDialog() -> Bool {
        let now = Date()
        recentDialogs = recentDialogs.filter { now.timeIntervalSince($0) < 10 } + [now]
        return recentDialogs.count <= 3
    }

    /// Shows a JavaScript dialog as a sheet over the tab. Returns nil — the page gets the answer
    /// of a dismissed dialog — when the tab isn't the one shown (an app-wide modal window from an
    /// invisible tab would block all of Nuri) or when the page keeps opening dialogs.
    private func present(_ alert: NSAlert, in webView: WKWebView) async -> NSApplication.ModalResponse? {
        guard let tab, tab.browser?.visibleTabs.contains(where: { $0 === tab }) == true || tab.browser?.porthole === tab, let window = webView.window else {
            let host = alert.messageText.isEmpty ? L("Un onglet", "A tab") : alert.messageText
            tab?.browser?.showToast("exclamationmark.bubble", L("\(host) a voulu afficher une alerte en arrière-plan", "\(host) tried to show an alert in the background"))
            return nil
        }
        guard mayShowDialog() else { return nil }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Camera, microphone, screen

    /// The async name WebKit looks for (WKUIDelegate.h): under any other name it never calls this
    /// and refuses every request by itself.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        // Both sides of a split are on screen: either may ask.
        guard let tab, isShown(tab), let window = webView.window ?? browser.window else { return .deny }
        let host = origin.host.nuriNormalizedHost
        // A call may share its screen next, with its sound: the frame gets what adds it (ShareAudio).
        await ShareAudio.shared.prepare(tab, frame: frame)
        return await MediaPermission.decide(host: host, type: type, in: browser) {
            let alert = NSAlert()
            alert.messageText = L("Autoriser « \(host) » à utiliser \(MediaPermission.devices(type)) ?", "Allow “\(host)” to use \(MediaPermission.devices(type))?")
            alert.informativeText = MediaPermission.scope(in: self.browser)
            alert.addButton(withTitle: L("Autoriser", "Allow"))
            alert.addButton(withTitle: L("Refuser", "Deny"))
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
    }

    /// Screen sharing (getDisplayMedia) in a video call (WKUIDelegatePrivate). The answer
    /// (WKDisplayCapturePermissionDecision) opens the system's picker of windows (2) or of screens
    /// (1), never both at once: as Safari does, the question asks which. 0 refuses. WebKit calls it
    /// by its selector: its Swift name stays apart from the public delegate's, which it would
    /// otherwise seem to misspell.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func webViewRequestDisplayCapture(_ webView: WKWebView, for origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                                      withSystemAudio: Bool, decisionHandler: @escaping (Int) -> Void) {
        guard let tab, isShown(tab), let window = webView.window ?? browser.window else { return decisionHandler(0) }
        let alert = NSAlert()
        alert.messageText = L("Partager votre écran ?", "Share your screen?")
        alert.informativeText = L("« \(origin.host.nuriNormalizedHost) » le demande. Montrez une seule fenêtre, ou tout un écran : macOS vous laissera ensuite choisir laquelle.", "“\(origin.host.nuriNormalizedHost)” is asking. Show a single window, or a whole screen: macOS will then let you pick which one.")
        // WebKit never captures the sound: Nuri adds it (ShareAudio), to a frame that asked for the
        // camera or the microphone first (a call), the only ones given the script that does it.
        let sound = NSButton(checkboxWithTitle: L("Partager aussi le son (vidéos, autres apps)", "Share sound too (videos, other apps)"), target: nil, action: nil)
        let canAddSound = ShareAudio.shared.isPrepared(tab, frame: frame)
        sound.state = AppSettings.shared.shareScreenAudio && canAddSound ? .on : .off
        sound.toolTip = L("Le son de vos apps et des autres onglets de Nuri, sans celui de l'appel.", "The sound of your apps and Nuri's other tabs, without the call's.")
        if canAddSound { alert.accessoryView = sound }
        alert.addButton(withTitle: L("Partager une fenêtre…", "Share a Window…"))
        alert.addButton(withTitle: L("Partager l'écran entier…", "Share Entire Screen…"))
        alert.addButton(withTitle: L("Refuser", "Deny")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak tab] response in
            let decision = switch response {
            case .alertFirstButtonReturn: 2
            case .alertSecondButtonReturn: 1
            default: 0
            }
            if decision != 0, canAddSound {
                AppSettings.shared.shareScreenAudio = sound.state == .on
                if sound.state == .on, let tab { ShareAudio.shared.allow(tab) }
            }
            decisionHandler(decision)
        }
    }

    // MARK: - Location

    /// navigator.geolocation (WKUIDelegatePrivate): on the Mac, WebKit refuses every request by
    /// itself unless its delegate answers this (on iOS it asks on its own).
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webViewRequestGeolocation(_ webView: WKWebView, for origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                                   decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let tab, isShown(tab), let window = webView.window ?? browser.window else { return decisionHandler(.deny) }
        let host = origin.host.nuriNormalizedHost
        let browser = browser
        Task {
            let decision = await MediaPermission.decideLocation(host: host, in: browser) {
                let alert = NSAlert()
                alert.messageText = L("Autoriser « \(host) » à connaître votre position ?", "Allow “\(host)” to know your location?")
                alert.informativeText = MediaPermission.scope(in: browser)
                alert.addButton(withTitle: L("Autoriser", "Allow"))
                alert.addButton(withTitle: L("Refuser", "Deny"))
                return await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
                }
            }
            decisionHandler(decision)
        }
    }

    /// On screen: the selected tab, or the other side of its split.
    private func isShown(_ tab: Tab) -> Bool {
        tab.browser?.visibleTabs.contains { $0 === tab } == true
    }

    // MARK: - File upload

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else { return panel.runModal() == .OK ? panel.urls : nil }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }
}
