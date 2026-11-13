import AppKit
import SwiftUI

/// A browser window: blurred glass behind everything, the SwiftUI chrome above it.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let browser: BrowserModel
    private var monitors: [Any] = []
    private var buttonObservers: [NSObjectProtocol] = []
    private var applyPending = false
    /// When the window last became key: the click that does it counts as its first.
    private var becameKeyAt: TimeInterval = 0
    /// What a first click landed on, until its release.
    private var firstClick: (point: CGPoint, tab: Tab?, onNewTab: Bool)?

    /// `reference`: the window to cascade from (the new window takes its size).
    init(browser: BrowserModel, cascadingFrom reference: NSWindow?) {
        self.browser = browser
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = "Nuri"
        // The bar is also the title bar: tabs must never move the window (see TitleBarDragArea).
        window.isMovable = false
        window.acceptsMouseMovedEvents = true
        // A private window is always dark, whatever the Mac's appearance: its light text stays on
        // dark glass, tabs, fields and panels included. Its pages keep the Mac's (see WebHostView).
        if browser.isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        // Final frame first, *then* the SwiftUI content: a hosting view laid out at one size and
        // then resized by the window before its first layout would "correct" the window in a loop.
        if let saved = browser.frameToReopen {
            window.setFrame(saved, display: false)
        } else if let reference, reference.isVisible {
            var frame = reference.frame
            frame.origin.x += 26
            frame.origin.y -= 26
            window.setFrame(frame, display: false)
        } else if browser === BrowserModel.shared, let saved = UserDefaults.standard.string(forKey: "mainWindowFrame") {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.center()
        }
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
        glass.blendingMode = .behindWindow
        // The most see-through of the materials: the veil above it (FrameBackground) does the rest.
        glass.material = .sidebar
        // Stays frosted in an inactive window; "Réduire la transparence" makes it opaque.
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        let hosting = ChromeHostingView(rootView: BrowserRootView(browser: browser))
        hosting.sizingOptions = []
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.addSubview(hosting)
        window.contentView = glass
        super.init(window: window)
        window.delegate = self
        browser.window = window
        installMonitors(window)
        watchTrafficLights(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        browser.selectedTab?.ensureWebView()
        browser.splitPartner?.ensureWebView()
    }

    /// Its pages go with it: text typed in them is asked about first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let typing = browser.allTabs.filter(\.hasUserInput)
        guard !typing.isEmpty else { return true }
        Task {
            if await BrowserWindows.shared.mayLoseTypedText(in: typing, leaving: L("Fermer quand même", "Close Anyway")) { sender.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        buttonObservers.forEach(NotificationCenter.default.removeObserver)
        buttonObservers = []
        if browser === BrowserModel.shared, let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: "mainWindowFrame")
        }
        BrowserWindows.shared.windowWillClose(self)
    }

    func windowDidResize(_ notification: Notification) { scheduleTrafficLights() }

    func windowDidBecomeKey(_ notification: Notification) {
        becameKeyAt = ProcessInfo.processInfo.systemUptime
        // The new tab page's field is there to be typed in, at launch and when coming back.
        if browser.selectedTab == nil { browser.newTabFieldFocus += 1 }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { browser.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        browser.isFullScreen = false
        scheduleTrafficLights()
    }

    // MARK: - Pointer and keys the chrome needs from the whole window

    private func installMonitors(_ window: NSWindow) {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self, weak window] event in
            if event.window === window { MainActor.assumeIsolated { self?.pointerMoved(event) } }
            return event
        }) { monitors.append(monitor) }
        // The click that brings the window forward must count, on a tab too.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { [weak self, weak window] event in
            if event.window === window { MainActor.assumeIsolated { self?.firstClickEvent(event) } }
            return event
        }) { monitors.append(monitor) }
        // A middle click on a tab closes it.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp, handler: { [weak self, weak window] event in
            guard event.window === window, event.buttonNumber == 2 else { return event }
            let handled = MainActor.assumeIsolated { self?.middleClick(event) ?? false }
            return handled ? nil : event
        }) { monitors.append(monitor) }
        // A shortcut an extension declared.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak window] event in
            guard event.window === window, !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            return MainActor.assumeIsolated { Extensions.performCommand(for: event) } ? nil : event
        }) { monitors.append(monitor) }
        // Esc lets a Porthole go, wherever the focus is.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self, weak window] event in
            guard event.window === window, event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated {
                guard let browser = self?.browser, browser.porthole != nil, browser.commandBar == nil else { return false }
                browser.closePorthole()
                return true
            }
            return handled ? nil : event
        }) { monitors.append(monitor) }
    }

    private func topLeftLocation(_ event: NSEvent) -> CGPoint {
        let height = window?.contentView?.bounds.height ?? 0
        return CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
    }

    private func pointerMoved(_ event: NSEvent) {
        let point = topLeftLocation(event)
        if AppSettings.shared.autoHideTopBar, !browser.isFullScreen {
            if point.y <= 5, !browser.topBarRevealed {
                withAnimation(Theme.quick) { browser.topBarRevealed = true }
            } else if browser.topBarRevealed, point.y > Metrics.topBarHeight + 24, browser.carry == nil, !browser.showingDownloads, !browser.showingTabList, !browser.showingBookmarks, !browser.editingBookmark {
                withAnimation(Theme.quick) { browser.topBarRevealed = false }
            }
        }
        updateSplitHandle(at: point)
    }

    /// The small handle of a split page: near the top of that page.
    private func updateSplitHandle(at point: CGPoint) {
        var side: SplitSide?
        if browser.shownSplit != nil, browser.pageFrame != .zero {
            let page = browser.pageFrame
            if point.y >= page.minY, point.y <= page.minY + 44, point.x >= page.minX, point.x <= page.maxX {
                let sides = SplitGeometry.sides(in: page.size, ratio: browser.currentSpace.splitRatio)
                side = point.x - page.minX < sides.left.maxX ? .left : .right
            }
        }
        if browser.splitHandleSide != side, !browser.isDraggingSplitHandle {
            withAnimation(Theme.quick) { browser.splitHandleSide = side }
        }
    }

    /// AppKit gives the click that activates a window only to views that ask for it, and SwiftUI's
    /// inside the tabs' scroll view don't: that click would do nothing but bring the window forward.
    /// So it is noted here, and acted on after its release if it stayed in place and nothing answered:
    /// the tab or the button, should it have received the click after all, comes first.
    private func firstClickEvent(_ event: NSEvent) {
        let point = topLeftLocation(event)
        browser.traceClick("fenêtre \(event.type == .leftMouseDown ? "appui" : "relâche") \(point), clé \(window?.isKeyWindow == true)")
        if event.type == .leftMouseDown {
            let isFirst = window?.isKeyWindow != true || event.timestamp - becameKeyAt < 0.3
            guard isFirst, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                firstClick = nil
                return
            }
            firstClick = (point, browser.currentSpace.allTabs.first { browser.tabFrames[$0.id]?.contains(point) == true },
                          browser.newTabButtonFrame.contains(point))
            return
        }
        guard let click = firstClick else { return }
        firstClick = nil
        guard hypot(point.x - click.point.x, point.y - click.point.y) < 4, browser.carry == nil else { return }
        DispatchQueue.main.async { [browser] in
            browser.traceClick("après relâche : visé \(click.tab?.title ?? "rien"), ouvert \(browser.selectedTab?.title ?? "aucun"), barre \(browser.commandBar != nil)")
            if let tab = click.tab, !tab.isClosed {
                if browser.selectedTab !== tab, browser.commandBar == nil {
                    // Before, not after: opening a tab can let the click's own release in (seen on a slow Mac).
                    browser.openedByFirstClick = (tab.id, Date())
                    browser.select(tab)
                    browser.traceClick("premier clic ouvre \(tab.title)")
                }
            } else if click.onNewTab, browser.commandBar == nil {
                browser.showCommandBar(.newTab)
            }
        }
    }

    private func middleClick(_ event: NSEvent) -> Bool {
        let point = topLeftLocation(event)
        guard let tab = browser.currentSpace.tabs.first(where: { browser.tabFrames[$0.id]?.contains(point) == true }) else { return false }
        browser.requestClose(tab)
        return true
    }

    // MARK: - Traffic lights

    private func watchTrafficLights(_ window: NSWindow) {
        buttonObservers = trafficLights(window).map { button in
            button.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleTrafficLights() }
            }
        }
        scheduleTrafficLights()
    }

    private func trafficLights(_ window: NSWindow) -> [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }

    /// AppKit puts the buttons back one after the other during its title bar layout: moving them
    /// from inside that pass loses to the next reset. Waiting for the pass to end moves all three.
    private func scheduleTrafficLights() {
        guard !applyPending else { return }
        applyPending = true
        DispatchQueue.main.async { [weak self] in
            self?.applyPending = false
            self?.applyTrafficLights()
        }
    }

    private func applyTrafficLights() {
        // Full screen: the buttons live in the menu-bar reveal, leave them where macOS puts them.
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let centerY = Metrics.topBarHeight / 2
        for button in trafficLights(window) {
            guard let titleBar = button.superview else { continue }
            let fromTop = centerY - button.frame.height / 2
            let y = titleBar.isFlipped ? fromTop : titleBar.bounds.height - fromTop - button.frame.height
            // Setting the same origin posts no notification, so this doesn't loop.
            if button.frame.origin.y != y { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
        }
    }
}

/// As a Mac toolbar: in a window behind others, a click on the chrome acts at once, tabs included.
private final class ChromeHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The bar's empty places: they move the window as a title bar would, and a double-click does what
/// the title bar's does. The window itself can't be moved by the system (see above).
struct TitleBarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        /// As a title bar: an inactive window is moved by its first click.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.zoom(nil)
                }
                return
            }
            // macOS moves the window itself: only its own drag knows the screen's edges and corners
            // (the window tiled on a half or a quarter of the screen), Spaces and Mission Control.
            // A window moved by hand with setFrameOrigin got none of that. It is movable for the
            // time of this drag only: at rest, tabs must still never move it.
            window.isMovable = true
            window.performDrag(with: event)
            Self.lockWhenReleased(window)
        }

        /// `performDrag` may come back before the button is up: the window stays movable until then.
        private static func lockWhenReleased(_ window: NSWindow) {
            guard NSEvent.pressedMouseButtons & 1 != 0 else { window.isMovable = false; return }
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak window] timer in
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                MainActor.assumeIsolated { window?.isMovable = false }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
