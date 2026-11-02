import AppKit
import WebKit

/// What the rest of Nuri knows of extensions. They need macOS 15.4, and Nuri runs from macOS 14: on
/// an older system all of this does nothing. With no extension installed nothing is created either,
/// and web views stay exactly as they would be without this feature.
@MainActor
enum Extensions {
    static let pageScheme = "webkit-extension"

    static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    static func start() {
        if #available(macOS 15.4, *) { ExtensionHost.shared.start() }
    }

    static func updateIfDue() {
        if #available(macOS 15.4, *) { ExtensionHost.shared.updateIfDue() }
    }

    /// `block` runs once the installed extensions are in, so that the first page gets their scripts.
    static func whenPagesMayLoad(_ block: @escaping () -> Void) {
        ContentRules.shared.whenReady {
            if #available(macOS 15.4, *) { ExtensionHost.shared.whenLoaded(block) } else { block() }
        }
    }

    static func attach(to configuration: WKWebViewConfiguration, isPrivate: Bool) {
        // Private windows stay out of reach of extensions, whatever they asked for.
        guard !isPrivate else { return }
        if #available(macOS 15.4, *) { configuration.webExtensionController = ExtensionHost.shared.controller }
    }

    // MARK: - An extension's own pages (options, new tabs it opens)

    static func isExtensionPage(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == pageScheme
    }

    /// WebKit only loads an extension's page in a web view made for it, and only that page there.
    static func configuration(forPage url: URL?) -> WKWebViewConfiguration? {
        guard isExtensionPage(url), let url else { return nil }
        if #available(macOS 15.4, *) { return ExtensionHost.shared.controller?.extensionContext(for: url)?.webViewConfiguration }
        return nil
    }

    /// The tab's web view can't show `url`: it goes, and another takes its place.
    static func needsOtherWebView(_ webView: WKWebView, for url: URL) -> Bool {
        let current = webView.url
        guard isExtensionPage(current) || isExtensionPage(url) else { return false }
        return current?.host()?.lowercased() != url.host()?.lowercased() || current?.scheme?.lowercased() != url.scheme?.lowercased()
    }

    static func name(ofPage url: URL?) -> String? {
        guard isExtensionPage(url), let id = url?.host() else { return nil }
        if #available(macOS 15.4, *) { return ExtensionHost.shared.installed.first { $0.id == id }?.name }
        return nil
    }

    // MARK: - What extensions are told

    static func tabOpened(_ tab: Tab) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabOpened(tab) }
    }

    static func tabClosed(_ tab: Tab) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabClosed(tab) }
    }

    static func tabActivated(_ tab: Tab, previous: Tab?) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabActivated(tab, previous: previous) }
    }

    static func tabMoved(_ tab: Tab, from index: Int) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabMoved(tab, from: index) }
    }

    enum TabChange { case title, url, loading }

    static func tabChanged(_ tab: Tab, _ change: TabChange) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.tabChanged(tab, change) }
    }

    static func windowOpened(_ browser: BrowserModel) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.windowOpened(browser) }
    }

    static func windowClosed(_ browser: BrowserModel) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.windowClosed(browser) }
    }

    static func windowFocused(_ browser: BrowserModel) {
        if #available(macOS 15.4, *) { ExtensionHost.shared.windowFocused(browser) }
    }

    // MARK: - What they add

    static func menuItems(for tab: Tab?) -> [NSMenuItem] {
        guard let tab, !tab.isPrivate else { return [] }
        if #available(macOS 15.4, *) { return ExtensionHost.shared.menuItems(for: tab) }
        return []
    }

    /// A keyboard shortcut an extension declared. True when one took it.
    static func performCommand(for event: NSEvent) -> Bool {
        if #available(macOS 15.4, *) { return ExtensionHost.shared.performCommand(for: event) }
        return false
    }
}
