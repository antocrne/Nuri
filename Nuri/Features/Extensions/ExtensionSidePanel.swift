import AppKit
import SwiftUI
import WebKit

/// An extension's side panel (chrome.sidePanel: Claude's conversation, for one), in a window: its
/// page in a card beside the page, on the side chosen in the Settings. One per window, kept while
/// the window's tabs change. `window.close()` in its page closes it; a link it opens goes to a tab.
@MainActor
final class ExtensionSidePanel: NSObject, Identifiable, WKUIDelegate, WKNavigationDelegate {
    let id = UUID()
    let extensionID: String
    let name: String
    let icon: NSImage?
    let webView: WKWebView
    private weak var browser: BrowserModel?

    init(extensionID: String, name: String, icon: NSImage?, webView: WKWebView, browser: BrowserModel) {
        self.extensionID = extensionID
        self.name = name
        self.icon = icon
        self.webView = webView
        self.browser = browser
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
    }

    /// What getContexts says of it (extension-shim.js): Claude's page checks it is a side panel.
    var context: [String: Any] {
        let address = webView.url?.absoluteString ?? ""
        return ["contextId": "nuri-side-panel-\(id.uuidString)", "contextType": "SIDE_PANEL", "documentId": id.uuidString,
                "documentOrigin": "\(Extensions.pageScheme)://\(extensionID)", "documentUrl": address,
                "frameId": 0, "incognito": false, "tabId": -1, "windowId": -1]
    }

    func close() {
        guard let browser, browser.sidePanel === self else { return }
        ExtensionLog.note(name, "side panel closed")
        withAnimation(Theme.spring) { browser.sidePanel = nil }
    }

    func webViewDidClose(_ webView: WKWebView) { close() }

    /// With the log on: what the panel shows a few seconds after each page it loads.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard ExtensionLog.isOn else { return }
        let name = self.name
        for delay in [3.0, 12.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                webView?.evaluateJavaScript("(document.body && document.body.innerText || '').slice(0, 300)") { value, _ in
                    let text = (value as? String ?? "nil").replacingOccurrences(of: "\n", with: " / ")
                    ExtensionLog.note(name, "side panel after \(Int(delay))s: \(text)")
                }
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ExtensionLog.note(name, "side panel process ended")
        webView.reload()
    }

    /// A page it opens goes to a tab of its window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased()) {
            browser?.openTab(url: url)
        }
        return nil
    }

    /// Its own pages stay in it; the web goes to a tab.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased()) {
            browser?.openTab(url: url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = name
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = name
        alert.informativeText = message
        alert.addButton(withTitle: L("OK", "OK"))
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    // MARK: - Width and side

    static let defaultWidth: Double = 400
    static let widthRange: ClosedRange<Double> = 320...680
}

/// The panel's card: the extension's icon and name, a button to move it to the other side and one
/// to close it, above its page. Its inner edge is pulled to resize it.
struct ExtensionSidePanelCard: View {
    let panel: ExtensionSidePanel
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var widthAtDragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            header
            ExtensionSidePanelHost(webView: panel.webView)
        }
        .frame(width: CGFloat(settings.sidePanelWidth))
        .background(RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous).fill(Theme.pageBackdrop))
        .overlay(alignment: settings.sidePanelOnLeft ? .trailing : .leading) { resizeHandle }
    }

    private var header: some View {
        HStack(spacing: 7) {
            if let icon = panel.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 15, height: 15)
            }
            Text(verbatim: panel.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            ChromeButton(symbol: settings.sidePanelOnLeft ? "rectangle.righthalf.inset.filled" : "rectangle.lefthalf.inset.filled",
                         help: settings.sidePanelOnLeft ? L("Mettre à droite", "Move to the Right") : L("Mettre à gauche", "Move to the Left"),
                         size: 24, iconSize: 11.5) {
                withAnimation(Theme.spring) { settings.sidePanelOnLeft.toggle() }
            }
            ChromeButton(symbol: "xmark", help: L("Fermer le panneau", "Close the Panel"), size: 24, iconSize: 11) { panel.close() }
        }
        .environment(\.chromeForeground, Theme.secondaryText)
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .frame(height: 32)
    }

    /// In the gap between the two cards: pulled, it moves the panel's inner edge; double-clicked,
    /// the width goes back to its default.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: Metrics.pageInset + 4)
            .contentShape(Rectangle())
            .offset(x: settings.sidePanelOnLeft ? Metrics.pageInset / 2 + 2 : -(Metrics.pageInset / 2 + 2))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(WindowSpace.name))
                .onChanged { drag in
                    let start = widthAtDragStart ?? settings.sidePanelWidth
                    widthAtDragStart = start
                    let moved = Double(drag.translation.width) * (settings.sidePanelOnLeft ? 1 : -1)
                    settings.sidePanelWidth = min(ExtensionSidePanel.widthRange.upperBound, max(ExtensionSidePanel.widthRange.lowerBound, start + moved))
                }
                .onEnded { _ in widthAtDragStart = nil })
            .onTapGesture(count: 2) {
                withAnimation(Theme.spring) { settings.sidePanelWidth = ExtensionSidePanel.defaultWidth }
            }
            .help(L("Tirer pour élargir · double-clic : largeur par défaut", "Drag to resize · double-click: default width"))
    }
}

/// The panel's page, kept by the panel: the same web view comes back after a redraw. Its bottom
/// corners are rounded by its layer, since a web view ignores SwiftUI's clipping.
private struct ExtensionSidePanelHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Metrics.pageRadius
        container.layer?.cornerCurve = .continuous
        // AppKit's layers have their origin at the bottom.
        container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        container.layer?.masksToBounds = true
        updateNSView(container, context: context)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
