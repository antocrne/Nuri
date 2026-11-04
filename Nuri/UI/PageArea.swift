import AppKit
import SwiftUI
import WebKit

/// The page's card: the web views, and everything drawn above them.
struct PageArea: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if browser.selectedTab == nil {
                    NewTabPage()
                } else {
                    RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous).fill(Theme.pageBackdrop)
                }
                WebHost(browser: browser)
                    .allowsHitTesting(browser.selectedTab != nil)
                overlays(in: geometry.size)
                if browser.findBarVisible { FindBar().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
                if let glance = browser.porthole { PortholeOverlay(tab: glance).id(glance.id).transition(.opacity.combined(with: .scale(scale: 0.97))) }
                if let toast = browser.toast {
                    ToastView(toast: toast)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 18)
                        .allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WindowSpace.name)) } action: { browser.pageFrame = $0 }
        }
    }

    /// What covers one side of the page, and the split's divider, handle and drop zones.
    @ViewBuilder
    private func overlays(in size: CGSize) -> some View {
        let ratio = browser.currentSpace.splitRatio
        if let split = browser.shownSplit {
            let sides = SplitGeometry.sides(in: size, ratio: ratio)
            PageCover(tab: split.left, focused: browser.selectedTab === split.left, inSplit: true)
                .frame(width: sides.left.width, height: sides.left.height)
                .position(x: sides.left.midX, y: sides.left.midY)
            PageCover(tab: split.right, focused: browser.selectedTab === split.right, inSplit: true)
                .frame(width: sides.right.width, height: sides.right.height)
                .position(x: sides.right.midX, y: sides.right.midY)
            SplitDivider(width: size.width, leftWidth: sides.left.width)
                .frame(width: SplitGeometry.divider + 6, height: size.height)
                .position(x: sides.left.maxX + SplitGeometry.divider / 2, y: size.height / 2)
            SplitHandle(tab: split.left, side: .left, size: size)
                .position(x: sides.left.midX, y: 20)
            SplitHandle(tab: split.right, side: .right, size: size)
                .position(x: sides.right.midX, y: 20)
            if browser.isDraggingSplitHandle, let target = browser.splitHandleSide {
                DropZone(frame: target == .left ? sides.right : sides.left, title: L("Échanger les côtés", "Swap sides"))
            }
        } else if let tab = browser.selectedTab {
            PageCover(tab: tab, focused: true, inSplit: false)
        }
        if let side = browser.carry?.dropSide {
            let half = CGRect(x: side == .left ? 0 : size.width / 2, y: 0, width: size.width / 2, height: size.height)
            DropZone(frame: half, title: side == .left ? L("Ouvrir à gauche", "Open on the left") : L("Ouvrir à droite", "Open on the right"))
        }
    }
}

/// Where a carried tab would land.
private struct DropZone: View {
    let frame: CGRect
    let title: String

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous)
            .fill(Theme.accent.opacity(0.28))
            .overlay(RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous).stroke(Theme.accent, lineWidth: 1.5))
            .overlay(Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Theme.card)))
            .padding(4)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// What may cover a tab's page: an error, the reader, a meeting gone to its floating window.
private struct PageCover: View {
    let tab: Tab
    let focused: Bool
    let inSplit: Bool

    var body: some View {
        ZStack {
            if tab.isInFloatingPlayer {
                FloatingPlaceholder(tab: tab)
            } else if let article = tab.reader {
                ReaderView(article: article) { tab.reader = nil }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous))
            } else if let page = tab.insecurePage {
                InsecurePageView(tab: tab, page: page)
            } else if let error = tab.loadError {
                LoadErrorView(tab: tab, message: error)
            }
            if let request = tab.request {
                TabRequestBar(tab: tab, request: request)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
            if inSplit, focused {
                RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous)
                    .stroke(Theme.accent.opacity(0.7), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct FloatingPlaceholder: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: tab.isInCall ? "video" : "pip").font(.system(size: 26)).foregroundStyle(Theme.secondaryText)
            Text(tab.isInCall ? L("L'appel est dans sa fenêtre flottante", "The call is in its floating window")
                              : L("La vidéo est dans sa fenêtre flottante", "The video is in its floating window"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Button(L("Le ramener ici", "Bring It Back")) { FloatingPlayer.shared.close() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous).fill(Theme.pageBackdrop))
    }
}

/// What takes the place of a page: its reason, and what can be done about it.
private struct PageNotice<Buttons: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.secondaryText)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack { buttons }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous).fill(Theme.pageBackdrop))
    }
}

private struct LoadErrorView: View {
    let tab: Tab
    let message: String

    var body: some View {
        PageNotice(symbol: "cloud.drizzle", title: L("Cette page n'a pas pu s'ouvrir", "This page couldn't open"), message: message) {
            Button(L("Réessayer", "Try Again")) {
                tab.loadError = nil
                if let url = tab.url ?? tab.requestedURL { tab.load(url) }
            }
            if let pending = tab.untrustedCertificate {
                Button(L("Continuer vers \(pending.host)", "Continue to \(pending.host)")) {
                    CertificateExceptions.accept(pending, persist: !tab.isPrivate)
                    tab.loadError = nil
                    tab.untrustedCertificate = nil
                    if let url = tab.url ?? tab.requestedURL { tab.load(url) }
                }
            }
        }
    }
}

/// A page over plain HTTP, stopped before showing (PlainHTTP).
struct InsecurePageView: View {
    let tab: Tab
    let page: URL

    var body: some View {
        let host = page.host()?.nuriNormalizedHost ?? page.absoluteString
        PageNotice(symbol: "lock.open", title: L("Cette page n'est pas sécurisée", "This page isn't secure"),
                   message: L("La connexion à \(host) n'est pas chiffrée (HTTP) : ce que vous y lisez ou saisissez peut être vu ou modifié en chemin.",
                              "The connection to \(host) isn't encrypted (HTTP): what you read or type there can be seen or changed on the way.")) {
            Button(L("Retour", "Go Back")) { Task { await tab.leaveInsecurePage() } }
            Button(L("Continuer vers le site HTTP", "Continue to HTTP Site")) { tab.continueToInsecurePage() }
        }
    }
}

// MARK: - Split view controls

/// The bar between the two pages: pull to resize, double-click to go back to half and half.
private struct SplitDivider: NSViewRepresentable {
    let width: CGFloat
    let leftWidth: CGFloat
    @Environment(BrowserModel.self) private var browser

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.leftWidth = leftWidth
        let browser = browser
        let width = width
        view.onResize = { browser.currentSpace.splitRatio = SplitGeometry.ratio(leftWidth: $0, in: width) }
        view.onReset = { browser.currentSpace.splitRatio = 0.5 }
    }

    final class HandleView: NSView {
        var leftWidth: CGFloat = 0
        var onResize: ((CGFloat) -> Void)?
        var onReset: (() -> Void)?
        private var startX: CGFloat = 0
        private var startWidth: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onReset?(); return }
            startX = event.locationInWindow.x
            startWidth = leftWidth
        }

        override func mouseDragged(with event: NSEvent) {
            onResize?(startWidth + event.locationInWindow.x - startX)
        }
    }
}

/// Appears when the pointer rests near the top of a page in split view: drag it to the other side
/// to swap the two, or click its × to take this page out (the tab stays in the bar).
private struct SplitHandle: View {
    let tab: Tab
    let side: SplitSide
    let size: CGSize
    @Environment(BrowserModel.self) private var browser
    @State private var offset: CGSize = .zero

    var body: some View {
        let visible = browser.splitHandleSide == side || (browser.isDraggingSplitHandle && offset != .zero)
        HStack(spacing: 2) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named(WindowSpace.name))
                        .onChanged { value in
                            offset = value.translation
                            browser.isDraggingSplitHandle = true
                            let crossed = crossesOver(value.translation.width)
                            let target: SplitSide? = crossed ? side : nil
                            if browser.splitHandleSide != target { browser.splitHandleSide = target }
                        }
                        .onEnded { value in
                            let crossed = crossesOver(value.translation.width)
                            browser.isDraggingSplitHandle = false
                            browser.splitHandleSide = nil
                            withAnimation(Theme.spring) { offset = .zero }
                            if crossed { withAnimation(Theme.spring) { browser.swapSides() } }
                        }
                )
                .help(L("Glisser de l'autre côté pour échanger", "Drag to the other side to swap"))
            Button { browser.takeOutOfSplit(tab) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Retirer de la vue partagée", "Take out of split view"))
        }
        .padding(.horizontal, 2)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.hairline))
        .shadow(color: Theme.shadow, radius: 5, y: 2)
        .offset(offset)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    private func crossesOver(_ dx: CGFloat) -> Bool {
        let quarter = size.width / 4
        return side == .left ? dx > quarter : dx < -quarter
    }
}

// MARK: - Web views

/// Hosts the tabs' WKWebViews.
///
/// PiP / background playback: web views of tabs that are playing media (or are in PiP) are kept
/// attached to the window, stacked underneath the active one, instead of being removed. WebKit
/// considers a detached web view "not visible" and may pause its video or tear down the PiP
/// session. Every other tab not on screen is detached, so WebKit throttles it.
/// Those kept alive are transparent (WebKit doesn't look at the alpha): with no tab shown — a space
/// with no tab open — one of them would otherwise cover the new tab page, and take its clicks.
///
/// Element fullscreen (a video's fullscreen button): WebKit moves the web view into its own window
/// and puts a placeholder in its place, which it swaps back on exit. The host doesn't touch its
/// views until fullscreen ends: re-adding the web view would turn that window black.
struct WebHost: NSViewRepresentable {
    let browser: BrowserModel

    func makeNSView(context: Context) -> WebHostView { WebHostView(browser: browser) }
    func updateNSView(_ view: WebHostView, context: Context) { view.sync() }
}

final class WebHostView: NSView {
    private weak var browser: BrowserModel?
    private weak var currentActive: WKWebView?
    private var tracking = false
    private var split: (activeIsLeft: Bool, ratio: Double)?
    private weak var active: WKWebView?
    private weak var partner: WKWebView?
    private let dockedInspectors = NSHashTable<NSView>.weakObjects()

    init(browser: BrowserModel) {
        self.browser = browser
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Only the pages on screen take clicks: never one kept alive under them (between the two sides
    /// of a split, or over the new tab page when no tab is shown).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard MainActor.assumeIsolated({ browser?.selectedTab != nil }) else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        for view in subviews.reversed() where view.alphaValue > 0 && !view.isHidden {
            if let hit = view.hitTest(local) { return hit }
        }
        return nil
    }

    /// A page leaving (for the floating player, the Porthole, its sleep) is seen wherever it goes next.
    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        subview.alphaValue = 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        followMacAppearance()
        sync()
        track()
    }

    private var appearanceObservation: NSKeyValueObservation?

    /// A private window's chrome is always dark; its pages, as everywhere, follow the Mac's light or
    /// dark (a site's prefers-color-scheme says what the user chose, not what Nuri wears).
    private func followMacAppearance() {
        guard MainActor.assumeIsolated({ browser?.isPrivate == true }), appearanceObservation == nil else { return }
        appearance = NSApp.effectiveAppearance
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            DispatchQueue.main.async { self?.appearance = app.effectiveAppearance }
        }
    }

    /// Re-syncs whenever anything the host depends on changes.
    private func track() {
        guard !tracking else { return }
        tracking = true
        MainActor.assumeIsolated {
            withObservationTracking {
                _ = Self.desired(for: browser)
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.tracking = false
                    self.sync()
                    if self.window != nil { self.track() }
                }
            }
        }
    }

    private struct Desired {
        var active: WKWebView?
        var partner: WKWebView?
        var split: (activeIsLeft: Bool, ratio: Double)?
        var keepAlive: [WKWebView] = []
        var frozen = false
    }

    @MainActor
    private static func desired(for browser: BrowserModel?) -> Desired {
        guard let browser else { return Desired() }
        let tab = browser.selectedTab
        let active = (tab?.isInFloatingPlayer ?? true) ? nil : tab?.webView
        let frozen = browser.allTabs.contains(where: \.isInElementFullscreen)
        var result = Desired(active: active, keepAlive: browser.keepAliveTabs.compactMap(\.webView), frozen: frozen)
        if let shown = browser.shownSplit, let tab {
            let other = shown.left === tab ? shown.right : shown.left
            result.partner = other.isInFloatingPlayer ? nil : other.webView
            result.split = (shown.left === tab, browser.currentSpace.splitRatio)
        }
        return result
    }

    func sync() {
        guard window != nil else { return }
        let wanted = MainActor.assumeIsolated { Self.desired(for: browser) }
        guard !wanted.frozen else { return }
        let active = wanted.active
        split = wanted.split
        self.active = active
        partner = wanted.partner
        let shown = [wanted.partner, active].compactMap { $0 }
        let background = wanted.keepAlive.filter { view in !shown.contains { $0 === view } }
        let desired: [WKWebView] = background + shown
        // WebKit docks an inspector without telling: note those here before their pages leave.
        for case let webView as WKWebView in subviews { _ = dockedInspector(of: webView) }
        // Each page with its docked inspector just under it, as WebKit puts it.
        let withInspector = { (webView: WKWebView) in [self.dockedInspector(of: webView), webView].compactMap { $0 } }
        let views = desired.flatMap(withInspector)

        for sub in subviews where !views.contains(where: { $0 === sub }) {
            sub.removeFromSuperview()
        }
        for webView in desired {
            if webView.superview !== self {
                webView.removeFromSuperview()
                webView.frame = bounds
                webView.autoresizingMask = [.width, .height]
                // The page's card: rounded by its layer, since a web view ignores SwiftUI's clipping.
                webView.wantsLayer = true
                webView.layer?.cornerRadius = Metrics.pageRadius
                webView.layer?.cornerCurve = .continuous
                webView.layer?.masksToBounds = true
                addSubview(webView)
            }
            // After its page: WebKit sizes the inspector from the page's superview as it arrives.
            if let inspector = dockedInspector(of: webView), inspector.superview !== self {
                addSubview(inspector, positioned: .below, relativeTo: webView)
            }
        }
        // The shown views must be on top (the active one last); don't reorder otherwise.
        let top = shown.flatMap(withInspector)
        if !subviews.suffix(top.count).elementsEqual(top, by: ===) {
            for view in top { addSubview(view, positioned: .above, relativeTo: nil) }
        }
        // A page with a docked inspector: WebKit lays out both from the page's new frame.
        for webView in desired { webView.frame = frame(for: webView) }
        // Only what is shown is seen; the pages kept alive play on, out of sight.
        for webView in desired {
            let alpha: CGFloat = shown.contains { $0 === webView } ? 1 : 0
            for view in withInspector(webView) where view.alphaValue != alpha { view.alphaValue = alpha }
        }

        if active !== currentActive {
            currentActive = active
            if let active, let window, !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(active)
            }
        }
    }

    /// The selected tab's and its partner's sides; everything else (kept alive) lies underneath.
    private func frame(for view: NSView) -> NSRect {
        guard let split else { return bounds }
        let sides = SplitGeometry.sides(in: bounds.size, ratio: split.ratio)
        if view === active { return split.activeIsLeft ? sides.left : sides.right }
        if view === partner { return split.activeIsLeft ? sides.right : sides.left }
        return bounds
    }

    /// A docked Web Inspector's view: WebKit puts it beside the page's, in this view, and lays both
    /// out. It leaves and comes back with its page.
    private func dockedInspector(of webView: WKWebView) -> WKWebView? {
        guard let inspector = WebKitSPI.inspectorWebView(webView) else { return nil }
        if inspector.superview === self {
            dockedInspectors.add(inspector)
        } else if inspector.superview != nil {
            dockedInspectors.remove(inspector)  // In its own window.
        }
        return dockedInspectors.contains(inspector) ? inspector : nil
    }

    override func layout() {
        super.layout()
        subviews.forEach { if !dockedInspectors.contains($0) { $0.frame = frame(for: $0) } }
    }
}

// MARK: - Small overlays

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
            Text(toast.message).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.hairline))
        .shadow(color: Theme.shadow, radius: 8, y: 3)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .id(toast.id)
    }
}

/// Find in page (⌘F).
struct FindBar: View {
    @Environment(BrowserModel.self) private var browser
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            TextField(L("Rechercher dans la page", "Find on page"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(width: 180)
                .focused($focused)
                .onSubmit { browser.find(text) }
                .onChange(of: text) { _, value in browser.find(value) }
                .onExitCommand { close() }
            ChromeButton(symbol: "chevron.up", help: L("Précédent (⌘⇧G)", "Previous (⌘⇧G)"), size: 22, iconSize: 10) { browser.find(text, backwards: true) }
            ChromeButton(symbol: "chevron.down", help: L("Suivant (⌘G)", "Next (⌘G)"), size: 22, iconSize: 10) { browser.find(text) }
            ChromeButton(symbol: "xmark", help: L("Fermer (Échap)", "Close (Esc)"), size: 22, iconSize: 10) { close() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.hairline))
        .shadow(color: Theme.shadow, radius: 8, y: 3)
        .padding(12)
        .onAppear {
            text = browser.lastFindText
            focused = true
        }
    }

    private func close() {
        browser.findBarVisible = false
        browser.selectedTab?.webView?.window?.makeFirstResponder(browser.selectedTab?.webView)
    }
}

/// What the page's card shows when no tab is open: the frosted glass, the name, the address bar, and
/// the favorites if there are any. Nothing the user didn't choose to put there.
struct NewTabPage: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let favorites = browser.isPrivate ? [] : BookmarkStore.shared.favorites(space: browser.currentSpaceID)
        VStack(spacing: 22) {
            Spacer()
            NuriWordmark(height: 46, color: browser.isPrivate ? Theme.privateText : Theme.text, dot: browser.currentSpace.tint.color)
            NewTabField()
                .zIndex(1)
            if browser.isPrivate {
                Text(L("Rien de cette fenêtre n'est conservé après sa fermeture.", "Nothing from this window is kept once it closes."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.privateText.opacity(0.8))
            } else if !favorites.isEmpty {
                WrappingRow(spacing: 8, centered: true) {
                    ForEach(favorites) { FavoriteTile(bookmark: $0) }
                }
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous).fill(.white.opacity(0.05)))
    }
}
