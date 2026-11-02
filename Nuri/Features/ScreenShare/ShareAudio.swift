import AppKit
import WebKit

/// Sound in screen sharing. WebKit's getDisplayMedia only ever captures the picture (Safari's
/// too): in a call, a video shown on a shared screen was heard by nobody. When the user ticks
/// « Partager aussi le son » in the sharing question, the page gets an audio track made by Nuri
/// (shareaudio-page.js, shareaudio.js), fed with:
/// - the sound of the other apps (macOS 14.2+, SystemAudioTap). Nuri's own sound is left out:
///   the call's voices would otherwise go back to the other participants;
/// - the sound of Nuri's other tabs, read in their pages (shareaudio.js), which therefore never
///   includes the call itself.
/// It stops with the sharing: the page stops it, the user stops it in macOS, or the tab goes.
final class ShareAudio: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = ShareAudio()
    static let messageName = "nuriShareAudio"

    /// Self-tests leave the other apps out (macOS would ask for the permission).
    @MainActor var includesOtherApps = true

    private struct Receiver {
        weak var tab: Tab?
        let frame: WKFrameInfo
        var failures = 0
    }

    private struct Source {
        weak var tab: Tab?
        let frame: WKFrameInfo
    }

    /// Tabs whose user just accepted sharing their screen with its sound, and when.
    @MainActor private var consents: [ObjectIdentifier: Date] = [:]
    @MainActor private var receiver: Receiver?
    /// Frames that have played a sound (the only ones Nuri can reach: see shareaudio.js).
    @MainActor private var sources: [Source] = []
    @MainActor private var otherApps: AnyObject?
    @MainActor private var watch: Timer?

    @MainActor var isSharing: Bool { receiver != nil }

    /// The user accepted to share the screen of `tab` with its sound: the page may ask for it once,
    /// once macOS's picker is closed.
    @MainActor func allow(_ tab: Tab) {
        consents[ObjectIdentifier(tab)] = Date()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard let webView = message.webView as? NuriWebView, let tab = webView.tab,
                  let body = message.body as? [String: Any] else { return replyHandler(nil, nil) }
            switch body["type"] as? String {
            case "start":
                replyHandler(start(tab, frame: message.frameInfo), nil)
            case "stop":
                if receiver?.tab === tab { stop() }
                replyHandler(nil, nil)
            case "media":
                addSource(tab, frame: message.frameInfo)
                replyHandler(nil, nil)
            case "chunk":
                if let rate = body["rate"] as? Double, let data = body["data"] as? String, receiver?.tab !== tab {
                    forward(data, rate: rate, from: "tab-\(ObjectIdentifier(tab).hashValue)")
                }
                replyHandler(nil, nil)
            default:
                replyHandler(nil, nil)
            }
        }
    }

    // MARK: Sharing

    @MainActor private func start(_ tab: Tab, frame: WKFrameInfo) -> Bool {
        let key = ObjectIdentifier(tab)
        guard let date = consents.removeValue(forKey: key), Date().timeIntervalSince(date) < 180,
              let webView = tab.webView, WebKitSPI.isCapturingDisplay(webView) != false else { return false }
        stop()
        receiver = Receiver(tab: tab, frame: frame)
        // The sharing ends without the page saying so (closed tab, page gone, macOS's own button).
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let shared = ShareAudio.shared
                guard let tab = shared.receiver?.tab, !tab.isClosed, let webView = tab.webView,
                      WebKitSPI.isCapturingDisplay(webView) != false else { return shared.stop() }
            }
        }
        sources.removeAll { $0.tab == nil || $0.tab?.isClosed == true }
        for source in sources { setCapturing(true, source) }
        if includesOtherApps, #available(macOS 14.2, *) {
            otherApps = SystemAudioTap { data, rate in
                DispatchQueue.main.async { ShareAudio.shared.forward(data, rate: rate, from: "system") }
            }
        }
        tab.browser?.showToast("speaker.wave.2", otherApps == nil && includesOtherApps
                               ? L("Son des onglets partagé (macOS 14.2 ou plus récent pour celui des autres apps)", "Tabs' sound shared (macOS 14.2 or later for other apps')")
                               : L("Son partagé avec l'écran", "Sound shared with the screen"))
        return true
    }

    @MainActor func stop() {
        guard receiver != nil else { return }
        receiver = nil
        watch?.invalidate()
        watch = nil
        if #available(macOS 14.2, *) { (otherApps as? SystemAudioTap)?.stop() }
        otherApps = nil
        for source in sources { setCapturing(false, source) }
    }

    @MainActor private func addSource(_ tab: Tab, frame: WKFrameInfo) {
        sources.removeAll { $0.tab == nil || $0.tab?.isClosed == true }
        // A tab that reloads or plays in several frames: its most recent frames only.
        if sources.filter({ $0.tab === tab }).count >= 8, let oldest = sources.firstIndex(where: { $0.tab === tab }) {
            sources.remove(at: oldest)
        }
        let source = Source(tab: tab, frame: frame)
        sources.append(source)
        if receiver != nil { setCapturing(true, source) }
    }

    /// The call's own tab is never listened to.
    @MainActor private func setCapturing(_ on: Bool, _ source: Source) {
        guard let tab = source.tab, let webView = tab.webView, !(on && (tab === receiver?.tab || tab.isInCall)) else { return }
        webView.evaluateJavaScript("window.__nuriShareAudio && window.__nuriShareAudio.capture(\(on))",
                                   in: source.frame, in: WebViewFactory.world) { _ in }
    }

    /// `data`: 16-bit stereo PCM, base64 (only letters, digits, + / =: safe in a JS string).
    @MainActor private func forward(_ data: String, rate: Double, from source: String) {
        guard let current = receiver, let webView = current.tab?.webView else { return }
        let script = "window.__nuriShareAudio ? window.__nuriShareAudio.play('\(source)', \(rate), '\(data)') : false"
        webView.evaluateJavaScript(script, in: current.frame, in: WebViewFactory.world) { result in
            MainActor.assumeIsolated {
                let shared = ShareAudio.shared
                guard shared.receiver?.frame === current.frame else { return }
                // The page is gone, or has already stopped its track.
                if case .success(let value) = result, value as? Bool == true {
                    shared.receiver?.failures = 0
                } else {
                    shared.receiver?.failures += 1
                    if (shared.receiver?.failures ?? 0) >= 5 { shared.stop() }
                }
            }
        }
    }
}
