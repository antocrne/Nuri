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
        if navigationAction.shouldPerformDownload {
            return await mayDownload(navigationAction.request.url, in: webView) ? .download : .cancel
        }
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""

        // An extension's page leading to the web: its web view can't go there (see Tab.load).
        if Extensions.isExtensionPage(webView.url), !Extensions.isExtensionPage(url), navigationAction.targetFrame?.isMainFrame == true,
           scheme == "http" || scheme == "https" {
            tab?.load(url)
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        var download = !navigationResponse.canShowMIMEType
        // "attachment" in any frame: Google Drive and others download through a hidden frame,
        // where a PDF or an image would otherwise be shown to nobody.
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            download = true
        }
        let response = navigationResponse.response
        guard download else {
            guard navigationResponse.isForMainFrame, PlainHTTP.needsWarning(response.url, in: browser) else { return .allow }
            tab?.insecurePage = response.url
            return .cancel
        }
        return await mayDownload(response.url, file: response.suggestedFilename, in: webView) ? .download : .cancel
    }

    /// Asked only of a site saving several files in a row (DownloadPermission). The site is the page's; a tab opened just for the
    /// file has none yet, then it's the file's. A refused download leaves no empty tab behind.
    private func mayDownload(_ url: URL?, file: String? = nil, in webView: WKWebView) async -> Bool {
        // A tab opened for the file has no page yet: the site is the one that opened it.
        let opener = webView.backForwardList.currentItem == nil ? tab?.openerHost : nil
        let host = (opener ?? webView.url?.host() ?? url?.host() ?? "").nuriNormalizedHost
        let file = file ?? url?.lastPathComponent
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
        tab?.loadError = ns.localizedDescription
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

    // MARK: - New windows → new tabs

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let flags = navigationAction.modifierFlags
        // ⌘-click or middle click on a target=_blank link: behind, like any other link. The
        // context menu's "Ouvrir … dans un nouvel onglet" too: the page stays on screen.
        let fromContextMenu = (webView as? NuriWebView)?.consumeContextMenuOpen() == true
        // Not asked for by a click: refused, and said (a frame of another site, an ad most of the
        // time, isn't worth a word).
        if !fromContextMenu, WebKitSPI.knowsUserInitiated, !WebKitSPI.isUserInitiated(navigationAction),
           navigationAction.navigationType != .linkActivated {
            let host = webView.url?.host()?.nuriNormalizedHost ?? ""
            guard PopupPermission.isAllowed(host, in: browser) else {
                if navigationAction.sourceFrame.isMainFrame, let tab, tab.request == nil, !host.isEmpty {
                    let url = navigationAction.request.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
                    tab.request = .popup(url: url, host: host)
                }
                return nil
            }
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
        return newTab.ensureWebView()
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
        guard let tab, tab.browser?.selectedTab === tab, let window = webView.window ?? browser.window else { return .deny }
        let host = origin.host.nuriNormalizedHost
        return await MediaPermission.decide(host: host, type: type, in: browser) {
            let alert = NSAlert()
            alert.messageText = L("Autoriser « \(host) » à utiliser \(MediaPermission.devices(type)) ?", "Allow “\(host)” to use \(MediaPermission.devices(type))?")
            alert.informativeText = self.browser.isPrivate ? L("Jusqu'à ce que vous quittiez Nuri ou fermiez cette fenêtre privée.", "Until you quit Nuri or close this private window.")
                                                           : L("Jusqu'à ce que vous quittiez Nuri.", "Until you quit Nuri.")
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
        guard let tab, tab.browser?.selectedTab === tab, let window = webView.window ?? browser.window else { return decisionHandler(0) }
        let alert = NSAlert()
        alert.messageText = L("Partager votre écran ?", "Share your screen?")
        alert.informativeText = L("« \(origin.host.nuriNormalizedHost) » le demande. Montrez une seule fenêtre, ou tout un écran : macOS vous laissera ensuite choisir laquelle.", "“\(origin.host.nuriNormalizedHost)” is asking. Show a single window, or a whole screen: macOS will then let you pick which one.")
        // WebKit never captures the sound: Nuri adds it (ShareAudio).
        let sound = NSButton(checkboxWithTitle: L("Partager aussi le son (vidéos, autres apps)", "Share sound too (videos, other apps)"), target: nil, action: nil)
        sound.state = AppSettings.shared.shareScreenAudio ? .on : .off
        sound.toolTip = L("Le son de vos apps et des autres onglets de Nuri, sans celui de l'appel.", "The sound of your apps and Nuri's other tabs, without the call's.")
        alert.accessoryView = sound
        alert.addButton(withTitle: L("Partager une fenêtre…", "Share a Window…"))
        alert.addButton(withTitle: L("Partager l'écran entier…", "Share Entire Screen…"))
        alert.addButton(withTitle: L("Refuser", "Deny")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak tab] response in
            let decision = switch response {
            case .alertFirstButtonReturn: 2
            case .alertSecondButtonReturn: 1
            default: 0
            }
            if decision != 0 {
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
        guard let tab, tab.browser?.selectedTab === tab, let window = webView.window ?? browser.window else { return decisionHandler(.deny) }
        let host = origin.host.nuriNormalizedHost
        let isPrivate = browser.isPrivate
        Task {
            let decision = await MediaPermission.decideLocation(host: host, in: browser) {
                let alert = NSAlert()
                alert.messageText = L("Autoriser « \(host) » à connaître votre position ?", "Allow “\(host)” to know your location?")
                alert.informativeText = isPrivate ? L("Jusqu'à ce que vous quittiez Nuri ou fermiez cette fenêtre privée.", "Until you quit Nuri or close this private window.")
                                                  : L("Jusqu'à ce que vous quittiez Nuri.", "Until you quit Nuri.")
                alert.addButton(withTitle: L("Autoriser", "Allow"))
                alert.addButton(withTitle: L("Refuser", "Deny"))
                return await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
                }
            }
            decisionHandler(decision)
        }
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
