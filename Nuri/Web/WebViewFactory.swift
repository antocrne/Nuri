import WebKit

/// Builds web view configurations. One shared WKUserContentController holds Nuri's scripts, message
/// handlers and content rule lists for every tab: nothing is parsed again per tab. Private windows
/// have their own: WebKit adds an extension's scripts to the content controller of the pages it
/// reaches, so on a shared one they would run in private windows too.
@MainActor
enum WebViewFactory {
    /// Isolated JavaScript world: pages can't see or tamper with Nuri's scripts.
    static let world = WKContentWorld.world(name: "Nuri")

    static let contentController = makeContentController()

    private static var madePrivateContentController: WKUserContentController?

    static var privateContentController: WKUserContentController {
        if let madePrivateContentController { return madePrivateContentController }
        let made = makeContentController()
        if let list = ContentRules.shared.installedAdBlockList { made.add(list) }
        madePrivateContentController = made
        return made
    }

    /// Those in use, for what goes on all of them (the blocker's list).
    static var contentControllers: [WKUserContentController] {
        [contentController] + (madePrivateContentController.map { [$0] } ?? [])
    }

    private static func makeContentController() -> WKUserContentController {
        let ucc = WKUserContentController()
        let router = ScriptMessageRouter.shared
        for name in ScriptMessageRouter.names {
            ucc.add(router, contentWorld: world, name: name)
        }
        ucc.addUserScript(WKUserScript(source: Scripts.core, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        ucc.addUserScript(WKUserScript(source: Scripts.media, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        ucc.addUserScript(WKUserScript(source: Scripts.activity, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        // Sound in screen sharing.
        ucc.addScriptMessageHandler(ShareAudio.shared, contentWorld: world, name: ShareAudio.messageName)
        ucc.addUserScript(WKUserScript(source: Scripts.shareAudio, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        // Its page-side half (shareaudio-page.js) only goes to frames that ask for the camera or the
        // microphone: see ShareAudio.prepare.
        return ucc
    }

    /// "Version/x Safari/605.1.15": without it many sites (video players, Google) serve a degraded page.
    static let userAgentSuffix: String = {
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        return "Version/\(safari ?? "18.0") Safari/605.1.15"
    }()

    /// `url`: what it will show first (an extension's own page needs the configuration made for it).
    static func configuration(for space: Space?, isPrivate: Bool, url: URL? = nil) -> WKWebViewConfiguration {
        if !isPrivate, let page = Extensions.configuration(forPage: url) { return page }
        let config = WKWebViewConfiguration()
        config.userContentController = isPrivate ? privateContentController : contentController
        Extensions.attach(to: config, isPrivate: isPrivate)
        // Normal windows: the space's persistent store. Private windows: their space's in-memory
        // store, shared by all the window's tabs and gone when the window closes.
        if let space {
            config.websiteDataStore = space.dataStore
        } else {
            config.websiteDataStore = isPrivate ? .nonPersistent() : BrowserModel.shared.currentSpace.dataStore
        }
        WebCryptoMasterKey.shared.attach(to: config.websiteDataStore)
        ExtensionProxy.shared.attach(to: config.websiteDataStore)
        config.applicationNameForUserAgent = userAgentSuffix
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = AppSettings.shared.blockAutoplayWithSound ? .audio : []
        let prefs = config.preferences
        prefs.isElementFullscreenEnabled = true
        // New windows only in answer to a click, as in Safari (WebKit's default on macOS lets a page
        // open tabs at load or from a timer: pop-unders). Decided in the UI delegate when WebKit lets
        // it know, so that a window refused can be told about: its own refusal is silent.
        prefs.javaScriptCanOpenWindowsAutomatically = WebKitSPI.knowsUserInitiated
        prefs.isFraudulentWebsiteWarningEnabled = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // PiP: on macOS there is no public switch. WebKit's internal preference defaults to YES;
        // set it explicitly when available.
        WebKitSPI.setPreference(prefs, "allowsPictureInPictureMediaPlayback", true)
        // Adds "Inspect Element" to the context menu.
        WebKitSPI.setPreference(prefs, "developerExtrasEnabled", true)
        return config
    }

    static func makeWebView(configuration: WKWebViewConfiguration) -> NuriWebView {
        let wv = NuriWebView(frame: .zero, configuration: configuration)
        wv.isInspectable = true
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = true
        wv.allowsMagnification = true
        wv.autoresizingMask = [.width, .height]
        wv.underPageBackgroundColor = .clear
        return wv
    }
}

extension WKWebView {
    /// Loads an address. A file of the Mac also gets to read its folder (a page's images and styles
    /// beside it): `load` alone gives a file page no access at all.
    func nuriLoad(_ url: URL) {
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.hasDirectoryPath ? url : url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }

    /// Calls an async JS function body in Nuri's world. Never throws and never hangs:
    /// returns nil on error or after `timeout` (a page promise may never settle).
    func nuriCall(_ body: String, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil,
                  world: WKContentWorld = WebViewFactory.world, timeout: TimeInterval = 5) async -> Any? {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return await withCheckedContinuation { continuation in
            let finish: (Any?) -> Void = { value in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            callAsyncJavaScript(body, arguments: arguments, in: frame, in: world) { result in
                switch result {
                case .success(let value): finish(value)
                case .failure: finish(nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}
