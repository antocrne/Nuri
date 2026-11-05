import AppKit
import WebKit

/// chrome.identity.launchWebAuthFlow: an extension's sign-in page, opened with the cookies of the
/// front window's space (where the user signed in to the site), until it comes back to the
/// extension's own address (https://<id>.chromiumapp.org/…), which is given back to it. Out of
/// sight when the extension says the user won't be asked anything (Claude renews its sign-in that
/// way at each launch); otherwise in a small window of its own, which the user may close.
@available(macOS 15.4, *)
@MainActor
final class ExtensionAuthFlow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private static var running: Set<ExtensionAuthFlow> = []

    static func handle(_ body: [String: Any], from context: WKWebExtensionContext) async -> Any {
        guard let address = body["url"] as? String, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return ["error": "Authorization page could not be loaded."]
        }
        let redirect = "https://\(context.uniqueIdentifier.lowercased()).chromiumapp.org/"
        let interactive = body["interactive"] as? Bool ?? false
        let timeout = ((body["timeout"] as? Double).flatMap { $0 > 0 ? $0 / 1000 : nil }) ?? 15
        let flow = ExtensionAuthFlow(url: url, redirect: redirect, interactive: interactive, timeout: timeout,
                                     abortOnLoad: body["abortOnLoad"] as? Bool ?? false, name: context.webExtension.displayName ?? "")
        running.insert(flow)
        defer { running.remove(flow) }
        switch await flow.run() {
        case .success(let landed): return ["url": landed.absoluteString]
        case .failure(let error): return ["error": error.message]
        }
    }

    private struct Failure: Error { let message: String }

    private let url: URL
    private let redirect: String
    private let interactive: Bool
    private let timeout: TimeInterval
    private let abortOnLoad: Bool
    private let name: String
    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Result<URL, Failure>, Never>?

    private init(url: URL, redirect: String, interactive: Bool, timeout: TimeInterval, abortOnLoad: Bool, name: String) {
        self.url = url
        self.redirect = redirect
        self.interactive = interactive
        self.timeout = timeout
        self.abortOnLoad = abortOnLoad
        self.name = name
    }

    private func run() async -> Result<URL, Failure> {
        let configuration = WKWebViewConfiguration()
        let space = BrowserWindows.shared.normalTarget.currentSpace
        configuration.websiteDataStore = space.dataStore
        WebCryptoMasterKey.shared.attach(to: configuration.websiteDataStore)
        ExtensionProxy.shared.attach(to: configuration.websiteDataStore)
        configuration.applicationNameForUserAgent = WebViewFactory.userAgentSuffix
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if interactive { show(webView) }
            webView.load(URLRequest(url: url))
            if !interactive {
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(Failure(message: "User interaction required.")))
                }
            }
        }
    }

    private func show(_ webView: WKWebView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = name.isEmpty ? L("Connexion", "Sign In") : L("Connexion à \(name)", "Sign In to \(name)")
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let parent = BrowserWindows.shared.normalTarget.window {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - 240, y: parent.frame.midY - 320))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func finish(_ result: Result<URL, Failure>) {
        guard let continuation else { return }
        self.continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
        continuation.resume(returning: result)
    }

    private func isRedirect(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.absoluteString.lowercased().hasPrefix(redirect)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame != false, isRedirect(navigationAction.request.url), let landed = navigationAction.request.url {
            decisionHandler(.cancel)
            return finish(.success(landed))
        }
        decisionHandler(.allow)
    }

    /// A server redirect to the extension's address.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if isRedirect(webView.url), let landed = webView.url { finish(.success(landed)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page that stays there wants something of the user.
        if !interactive, abortOnLoad { finish(.failure(Failure(message: "User interaction required."))) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let failing = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL, isRedirect(failing) {
            return finish(.success(failing))
        }
        if (error as NSError).code == NSURLErrorCancelled { return }
        if !interactive { finish(.failure(Failure(message: "Authorization page could not be loaded."))) }
    }

    /// A page it opens stays in the same window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        finish(.failure(Failure(message: "The user did not approve access.")))
    }
}
