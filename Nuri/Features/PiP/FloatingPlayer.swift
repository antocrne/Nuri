import AppKit
import WebKit

/// Plan B when the page refuses native PiP: the tab's own web view moves into a small
/// always-on-top panel and media.js makes the video fill it. Because it's the real page,
/// this also works for DRM-protected (EME/FairPlay) players, but the page keeps running
/// (it's heavier than native PiP) and the window is Nuri's, not the system's.
///
/// Meetings: the same window holds a video call's whole page (every participant, the page's
/// own mute and hang-up buttons), zoomed out so the site lays it out for a larger screen.
@MainActor
final class FloatingPlayer: NSObject, NSWindowDelegate {
    static let shared = FloatingPlayer()

    enum Mode { case video, meeting }

    private var panel: NSPanel?
    private(set) weak var tab: Tab?
    private(set) var mode: Mode = .video
    private var videoFrame: WKFrameInfo?
    /// The page's zoom before the meeting window zoomed it out.
    private var savedZoom: CGFloat?
    /// Where the user last left the meeting window, kept from one launch to the next.
    private var meetingFrame: NSRect? {
        get { UserDefaults.standard.string(forKey: "meetingWindowFrame").map(NSRectFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromRect), forKey: "meetingWindowFrame") }
    }

    static let meetingZoom: CGFloat = 0.75

    var isOpen: Bool { panel != nil }

    func open(_ tab: Tab, mode: Mode = .video) {
        close()
        guard let webView = tab.webView else { return }
        self.mode = mode
        if mode == .meeting {
            openMeeting(tab, webView)
            return
        }

        let size = NSSize(width: 480, height: 270)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = tab.displayTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Theme.videoBackgroundNS
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.videoBackgroundNS.cgColor
        tab.isInFloatingPlayer = true            // WebHost stops managing this web view
        webView.removeFromSuperview()
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)

        let back = NSButton(image: NSImage(systemSymbolName: "arrow.up.backward.and.arrow.down.forward", accessibilityDescription: L("Revenir à l'onglet", "Back to Tab"))!,
                            target: self, action: #selector(returnToTab))
        back.isBordered = false
        back.contentTintColor = Theme.videoControlNS
        back.frame = NSRect(x: size.width - 34, y: size.height - 30, width: 24, height: 22)
        back.autoresizingMask = [.minXMargin, .minYMargin]
        back.toolTip = L("Revenir à l'onglet", "Back to Tab")
        content.addSubview(back)

        panel.contentView = content
        panel.orderFrontRegardless()
        self.panel = panel
        self.tab = tab

        // Make the video fill the web view; if it lives in an iframe, float the iframe too.
        let frames = tab.mediaFrames.values.filter { $0.hasVideo }.sorted { $0.playing && !$1.playing }
        videoFrame = frames.first.flatMap { $0.frame.isMainFrame ? nil : $0.frame }
        Task {
            if let videoFrame {
                _ = await webView.nuriCall("return window.__nuriMedia ? window.__nuriMedia.float(true) : 'fail';", in: videoFrame)
            }
            _ = await webView.nuriCall("return window.__nuriMedia ? window.__nuriMedia.float(true) : 'fail';")
        }
    }

    private func openMeeting(_ tab: Tab, _ webView: WKWebView) {
        let size = NSSize(width: 420, height: 316)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        if let meetingFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(meetingFrame) }) {
            panel.setFrame(meetingFrame, display: false)
        }
        panel.title = tab.displayTitle
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentMinSize = NSSize(width: 280, height: 200)
        panel.backgroundColor = Theme.videoBackgroundNS
        panel.delegate = self

        let back = NSButton(image: NSImage(systemSymbolName: "arrow.up.backward.and.arrow.down.forward", accessibilityDescription: L("Revenir à l'onglet", "Back to Tab"))!,
                            target: self, action: #selector(returnToTab))
        back.isBordered = false
        back.toolTip = L("Revenir à l'onglet", "Back to Tab")
        back.frame = NSRect(x: 0, y: 0, width: 26, height: 18)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = back
        accessory.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(accessory)

        tab.isInFloatingPlayer = true            // WebHost stops managing this web view
        webView.removeFromSuperview()
        savedZoom = webView.pageZoom
        webView.pageZoom = webView.pageZoom * Self.meetingZoom
        let content = NSView(frame: NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size))
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        panel.contentView = content
        panel.orderFrontRegardless()
        self.panel = panel
        self.tab = tab
    }

    @objc private func returnToTab() {
        let tab = self.tab
        close()
        if let tab {
            tab.browser?.select(tab)
            tab.browser?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func close() {
        guard let panel else { return }
        if mode == .meeting { meetingFrame = panel.frame }
        self.panel = nil
        panel.delegate = nil
        restore()
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel else { return }
        if mode == .meeting { meetingFrame = panel.frame }
        self.panel = nil
        restore()
    }

    private func restore() {
        let frame = videoFrame
        let tab = self.tab
        let zoom = savedZoom
        self.tab = nil
        videoFrame = nil
        savedZoom = nil
        if mode == .meeting {
            if let zoom { tab?.webView?.pageZoom = zoom }
            tab?.webView?.removeFromSuperview()
            tab?.isInFloatingPlayer = false        // WebHost takes it back
            return
        }
        // Even when the tab was put to sleep meanwhile: nothing of this player is kept.
        if let webView = tab?.webView {
            Task {
                _ = await webView.nuriCall("return window.__nuriMedia ? window.__nuriMedia.float(false) : 'ok';")
                if let frame { _ = await webView.nuriCall("return window.__nuriMedia ? window.__nuriMedia.float(false) : 'ok';", in: frame) }
            }
            webView.removeFromSuperview()
        }
        tab?.isInFloatingPlayer = false            // WebHost takes it back
    }
}
