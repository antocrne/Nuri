import WebKit

/// Thin, guarded wrappers around WebKit internals that have no public equivalent.
/// Every call checks `responds(to:)` first, so a future WebKit that removes one simply
/// makes the feature degrade instead of crashing.
enum WebKitSPI {
    /// Sets a WKPreferences flag through KVC (resolves to `_set<Key>:`).
    static func setPreference(_ prefs: WKPreferences, _ key: String, _ value: Bool) {
        let setter = "_set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard prefs.responds(to: NSSelectorFromString(setter)) else { return }
        prefs.setValue(value, forKey: key)
    }

    // MARK: Picture in Picture (the mechanism Safari uses for its own PiP menu)

    static func canTogglePictureInPicture(_ webView: WKWebView) -> Bool {
        boolValue(webView, "_canTogglePictureInPicture")
    }

    static func isPictureInPictureActive(_ webView: WKWebView) -> Bool {
        boolValue(webView, "_isPictureInPictureActive")
    }

    static func togglePictureInPicture(_ webView: WKWebView) {
        let sel = NSSelectorFromString("_togglePictureInPicture")
        guard webView.responds(to: sel) else { return }
        webView.perform(sel)
    }

    // MARK: Printing

    /// `frame`: the `_WKFrameHandle` a page's window.print() comes with.
    static func printOperation(_ webView: WKWebView, info: NSPrintInfo, frame: AnyObject?) -> NSPrintOperation {
        let sel = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        if let frame, webView.responds(to: sel),
           let operation = webView.perform(sel, with: info, with: frame)?.takeUnretainedValue() as? NSPrintOperation {
            return operation
        }
        return webView.printOperation(with: info)
    }

    // MARK: New windows

    /// WebKit can say whether a navigation comes from a click; without that, a page's windows stay
    /// with its own rule (only in answer to a click, without a word).
    static var knowsUserInitiated: Bool { WKNavigationAction.instancesRespond(to: NSSelectorFromString("_isUserInitiated")) }

    static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        boolValue(action, "_isUserInitiated")
    }

    // MARK: Web Inspector

    static func showInspector(_ webView: WKWebView, console: Bool) {
        guard let inspector = inspector(of: webView) else { return }
        let action = NSSelectorFromString(console ? "showConsole" : "show")
        if inspector.responds(to: action) { inspector.perform(action) }
    }

    /// The inspector's own web view while it is shown, docked beside the page or in its window.
    static func inspectorWebView(_ webView: WKWebView) -> WKWebView? {
        let getter = NSSelectorFromString("inspectorWebView")
        guard let inspector = inspector(of: webView), boolValue(inspector, "isVisible"),
              inspector.responds(to: getter) else { return nil }
        return inspector.perform(getter)?.takeUnretainedValue() as? WKWebView
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter) else { return nil }
        return webView.perform(getter)?.takeUnretainedValue() as? NSObject
    }

    // MARK: Closing

    /// Asks the page to close, running its beforeunload handlers: WebKit then calls
    /// `webViewDidClose` if it may go. Returns true when it is closed at once (no web process),
    /// nil when WebKit has no such method.
    static func tryClose(_ webView: WKWebView) -> Bool? {
        let sel = NSSelectorFromString("_tryClose")
        guard webView.responds(to: sel) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(webView.method(for: sel), to: Call.self)(webView, sel)
    }

    // MARK: Muting

    /// The page is making sound, whatever makes it (<audio>, <video>, Web Audio). WebKit keeps it
    /// up to date and it can be observed by key-value observing, so nothing has to poll.
    static let playingAudioKey = "_isPlayingAudio"

    static func isPlayingAudio(_ webView: WKWebView) -> Bool {
        boolValue(webView, playingAudioKey)
    }

    /// `_WKMediaAudioMuted`, the first bit of WebKit's muted state.
    static func isPageMuted(_ webView: WKWebView) -> Bool {
        let sel = NSSelectorFromString("_mediaMutedState")
        guard webView.responds(to: sel) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(webView.method(for: sel), to: Getter.self)(webView, sel) & 1 != 0
    }

    static func setPageMuted(_ webView: WKWebView, _ muted: Bool) {
        let sel = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: sel), to: Setter.self)(webView, sel, muted ? 1 : 0)
    }

    // MARK: Extension popups

    /// A popup's web view is laid out at its content's own size (up to 800 × 600): off, it is laid
    /// out at the size it is given, like a window. Returns false when WebKit has no such switch.
    @discardableResult
    static func disableSizeToContent(_ webView: WKWebView) -> Bool {
        let sel = NSSelectorFromString("_setSizeToContentAutoSizeMaximumSize:")
        guard webView.responds(to: sel) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, CGSize) -> Void
        unsafeBitCast(webView.method(for: sel), to: Setter.self)(webView, sel, .zero)
        return true
    }

    // MARK: Screen sharing

    /// Whether the page is capturing a screen or a window (`_displayCaptureState`: 0 none,
    /// 1 active, 2 muted); nil when WebKit doesn't tell.
    static func isCapturingDisplay(_ webView: WKWebView) -> Bool? {
        let sel = NSSelectorFromString("_displayCaptureState")
        guard webView.responds(to: sel) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(webView.method(for: sel), to: Getter.self)(webView, sel) != 0
    }

    private static func boolValue(_ object: NSObject, _ name: String) -> Bool {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let imp = object.method(for: sel)
        return unsafeBitCast(imp, to: Getter.self)(object, sel)
    }
}
