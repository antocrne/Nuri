import Foundation
import WebKit
import AppKit

/// Picture in Picture for Nuri.
///
/// Entering PiP tries, in order:
///  1. media.js in every frame that reported a video (playing frames first, then the main
///     frame): `requestPictureInPicture()`, then `webkitSetPresentationMode()`. The call goes
///     through `callAsyncJavaScript`, which WebKit runs *with* a user gesture, so the
///     "PiP requires a user gesture" rule is satisfied from a shortcut or toolbar button.
///  2. WebKit's own PiP toggle (the mechanism behind Safari's PiP menu), which acts on the
///     page's main video wherever it is, including cross-origin iframes.
///  3. Plan B (manual only): Nuri's floating window above other apps.
///
/// Auto PiP: when the user leaves a tab whose video is playing with sound, PiP is requested
/// for that tab; the web view stays attached to the window (see WebHost) so playback never
/// pauses. Coming back to the tab exits PiP.
///
/// Meetings (Mac): a tab using the camera or the microphone goes whole into the floating window
/// instead — every participant, and the page's own buttons (mute, hang up) — since the video PiP
/// would show a single stream. Manually (⌘⇧P) or on leaving the tab (Settings → Général).
@MainActor
final class PiPController {
    static let shared = PiPController()

    enum Method: String {
        case standard = "API standard (requestPictureInPicture)"
        case webkit = "API WebKit (webkitSetPresentationMode)"
        case native = "WebKit natif (_togglePictureInPicture)"
        case floating = "Fenêtre flottante Nuri (plan B)"
    }

    enum Outcome: Equatable {
        case entered(Method)
        case failed(String)
    }

    /// Tabs for which *we* are currently exiting PiP (so the "leave" event isn't treated
    /// as the user clicking "back to tab" in the PiP window).
    private var exiting: Set<UUID> = []

    // MARK: - Reports from media.js

    func handleReport(_ body: [String: Any], frame: WKFrameInfo, tab: Tab) {
        let key = frameKey(body, frame)
        if body["type"] as? String == "gone" {
            // The frame's page went away (media.js, pagehide): nothing of it plays any more.
            tab.mediaFrames[key] = nil
        } else {
            tab.mediaFrames[key] = MediaFrameState(frame: frame,
                                                   hasVideo: body["hasVideo"] as? Bool ?? false,
                                                   playing: body["playing"] as? Bool ?? false,
                                                   audible: body["audible"] as? Bool ?? false,
                                                   inPiP: body["inPiP"] as? Bool ?? false)
        }
        let wasInPiP = tab.isInPiP
        recompute(tab)

        if wasInPiP && !tab.isInPiP {
            let initiatedByNuri = exiting.contains(tab.id)
            tab.autoPiPEngaged = false
            // PiP window closed with "back to tab" (video keeps playing): bring the tab back.
            // Closed with ✕ (video pauses): do nothing.
            if !initiatedByNuri, tab.isPlayingVideo, let browser = tab.browser, browser.selectedTab !== tab {
                browser.select(tab)
                NSApp.activate(ignoringOtherApps: true)
                browser.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func resetFrames(of tab: Tab) {
        // Keep the state if the page is in PiP: WebKit keeps the PiP window across same-page updates.
        guard !tab.isInPiP else { return }
        tab.mediaFrames = [:]
        recompute(tab)
    }

    private func recompute(_ tab: Tab) {
        let frames = tab.mediaFrames.values
        tab.hasVideo = frames.contains { $0.hasVideo }
        tab.isPlayingVideo = frames.contains { $0.playing }
        recomputeSound(of: tab)
        let spiActive = tab.webView.map(WebKitSPI.isPictureInPictureActive) ?? false
        tab.isInPiP = frames.contains { $0.inPiP } || spiActive
    }

    /// What the speaker on the tab shows: a video with its sound on, or anything WebKit hears.
    func recomputeSound(of tab: Tab) {
        let audible = tab.webKitPlayingAudio || tab.mediaFrames.values.contains { $0.audible }
        if tab.isAudible != audible { tab.isAudible = audible }
    }

    /// media.js gives each document its own id; the frame's URL changes without a new document.
    private func frameKey(_ body: [String: Any], _ frame: WKFrameInfo) -> String {
        if let id = body["frame"] as? String { return id }
        return (frame.isMainFrame ? "main|" : "sub|") + (frame.request.url?.absoluteString ?? "") + "|" + frame.securityOrigin.host
    }

    // MARK: - Actions

    func isActive(_ tab: Tab) -> Bool {
        if tab.isInFloatingPlayer { return true }
        if tab.isInPiP { return true }
        return tab.webView.map(WebKitSPI.isPictureInPictureActive) ?? false
    }

    /// ⌘⇧P / toolbar button.
    func toggle(_ tab: Tab) async {
        if isActive(tab) {
            await exit(tab)
            return
        }
        if tab.isInCall {
            FloatingPlayer.shared.open(tab, mode: .meeting)
            return
        }
        let outcome = await enter(tab, allowFloatingFallback: true)
        switch outcome {
        case .entered(.floating):
            tab.browser?.showToast("rectangle.on.rectangle", L("PiP refusé par le site : lecteur flottant Nuri", "PiP refused by the site: Nuri's floating player"))
        case .entered:
            break
        case .failed(let reason):
            tab.browser?.showToast("pip.exit", reason.contains("no-video") ? L("Aucune vidéo dans cette page", "No video on this page") : L("Picture in Picture impossible sur cette page", "Picture in Picture isn't possible on this page"))
        }
    }

    func enter(_ tab: Tab, allowFloatingFallback: Bool) async -> Outcome {
        guard let webView = tab.webView else { return .failed("fail:asleep") }
        var lastError = "fail:no-video"

        // 1. Standard / WebKit API inside the frame that holds the video.
        for frame in candidateFrames(of: tab) {
            let result = await webView.nuriCall("return await window.__nuriMedia ? window.__nuriMedia.enterPiP() : 'fail:no-script';", in: frame) as? String ?? "fail:js-error"
            if result.hasPrefix("ok") {
                tab.isInPiP = true
                return .entered(result == "ok:webkit" ? .webkit : .standard)
            }
            lastError = result
        }

        // 2. WebKit's native toggle (Safari's mechanism).
        if WebKitSPI.canTogglePictureInPicture(webView) {
            WebKitSPI.togglePictureInPicture(webView)
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if WebKitSPI.isPictureInPictureActive(webView) {
                    tab.isInPiP = true
                    return .entered(.native)
                }
            }
            lastError += " native:timeout"
        }

        // 3. Plan B.
        if allowFloatingFallback, tab.hasVideo {
            FloatingPlayer.shared.open(tab)
            return .entered(.floating)
        }
        return .failed(lastError)
    }

    func exit(_ tab: Tab) async {
        if tab.isInFloatingPlayer { FloatingPlayer.shared.close() }
        guard let webView = tab.webView else { return }
        exiting.insert(tab.id)
        defer { exiting.remove(tab.id) }
        for frame in candidateFrames(of: tab) {
            _ = await webView.nuriCall("return window.__nuriMedia ? await window.__nuriMedia.exitPiP() : 'ok';", in: frame)
        }
        if WebKitSPI.isPictureInPictureActive(webView) { WebKitSPI.togglePictureInPicture(webView) }
        try? await Task.sleep(for: .milliseconds(300))
        tab.isInPiP = false
        tab.autoPiPEngaged = false
    }

    /// Synchronous best effort, used when a tab is being closed.
    func forceExit(_ webView: WKWebView) {
        if WebKitSPI.isPictureInPictureActive(webView) { WebKitSPI.togglePictureInPicture(webView) }
        webView.evaluateJavaScript("document.pictureInPictureElement && document.exitPictureInPicture()", in: nil, in: WebViewFactory.world)
    }

    /// Frames to try, most promising first. `nil` = main frame.
    private func candidateFrames(of tab: Tab) -> [WKFrameInfo?] {
        let frames = tab.mediaFrames.values
        let playing = frames.filter { $0.playing }.sorted { $0.frame.isMainFrame && !$1.frame.isMainFrame }
        let withVideo = frames.filter { $0.hasVideo && !$0.playing }
        let present = frames.filter { !$0.hasVideo && !$0.playing }   // <video> not loaded yet
        var result: [WKFrameInfo?] = (playing + withVideo + present).map { $0.frame.isMainFrame ? nil : $0.frame }
        if !result.contains(where: { $0 == nil }) { result.append(nil) }
        return result
    }

    // MARK: - Automatic PiP

    func selectionChanged(from old: Tab?, to new: Tab?) {
        visibleTabsChanged(from: old.map { [$0] } ?? [], to: new.map { [$0] } ?? [])
    }

    /// The pages on screen changed (a tab selected, or side by side shown or ended): tabs coming
    /// back leave the PiP they were sent to, tabs going away may enter it.
    func visibleTabsChanged(from before: [Tab], to after: [Tab]) {
        for new in after where new.autoPiPEngaged && !before.contains(where: { $0 === new }) {
            new.autoPiPEngaged = false
            if isActive(new) { Task { await exit(new) } }
        }
        for old in before where !after.contains(where: { $0 === old }) {
            guard old.webView != nil, !isActive(old) else { continue }
            if old.isInCall {
                if AppSettings.shared.autoMeetingPiP {
                    FloatingPlayer.shared.open(old, mode: .meeting)
                    old.autoPiPEngaged = true
                }
                continue
            }
            guard AppSettings.shared.autoPiP, old.isPlayingVideo, old.isAudible else { continue }
            Task {
                let outcome = await enter(old, allowFloatingFallback: false)
                if case .entered = outcome { old.autoPiPEngaged = true }
            }
        }
    }

    /// The call of a tab in the floating window ended (hung up): the page goes back to its tab.
    /// After a moment, since some sites stop and restart their tracks (camera turned off).
    func callStateChanged(_ tab: Tab) {
        guard !tab.isInCall, tab.isInFloatingPlayer, FloatingPlayer.shared.mode == .meeting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !tab.isInCall, tab.isInFloatingPlayer, FloatingPlayer.shared.tab === tab,
                  FloatingPlayer.shared.mode == .meeting else { return }
            FloatingPlayer.shared.close()
        }
    }
}
