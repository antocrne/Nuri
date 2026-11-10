import AppKit
import ObjectiveC
import WebKit

/// Links of the Web Inspector. Its « Ouvrir dans une nouvelle fenêtre » (on a resource's address)
/// and its ⌘-clicks hand the address to the inspector's delegate (`_WKInspectorDelegate`): with none,
/// WebKit drops it and nothing happens. They open in a tab of Nuri, next to the inspected page's, and
/// the menu item says so.
@MainActor
final class InspectorLinks: NSObject {
    private static let shared = InspectorLinks()

    static func attach(to webView: WKWebView) {
        _ = renamesMenuItem
        let setter = NSSelectorFromString("setDelegate:")
        guard let inspector = WebKitSPI.inspector(of: webView), inspector.responds(to: setter) else { return }
        inspector.perform(setter, with: shared)
    }

    @objc(inspector:openURLExternally:)
    func inspector(_ inspector: NSObject, openURLExternally url: URL) {
        let getter = NSSelectorFromString("webView")
        let inspected = inspector.responds(to: getter) ? inspector.perform(getter)?.takeUnretainedValue() as? NuriWebView : nil
        let tab = inspected?.tab
        let browser = tab?.browser ?? BrowserWindows.shared.active
        _ = browser.openTab(url: url, background: false, after: tab)
    }

    /// The inspector's own menu goes through WebKit's controller of its web view
    /// (`WKInspectorViewController`, `_webView:contextMenu:forElement:`): the item is renamed on its
    /// way out. Nothing changes if WebKit has neither.
    private static let renamesMenuItem: Void = {
        guard let controller = NSClassFromString("WKInspectorViewController") else { return }
        let selector = NSSelectorFromString("_webView:contextMenu:forElement:")
        guard let method = class_getInstanceMethod(controller, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject?, NSMenu, AnyObject?) -> NSMenu
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, AnyObject?, NSMenu, AnyObject?) -> NSMenu = { object, webView, menu, element in
            let result = original(object, selector, webView, menu, element)
            MainActor.assumeIsolated { renameNewWindowItems(in: result) }
            return result
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }()

    /// WebInspectorUI's own words for it, in the languages Nuri speaks.
    private static let newWindowTitles: Set<String> = ["Ouvrir dans une nouvelle fenêtre", "Open in New Window"]

    static func renameNewWindowItems(in menu: NSMenu) {
        for item in menu.items {
            if newWindowTitles.contains(item.title) { item.title = L("Ouvrir dans un nouvel onglet", "Open in New Tab") }
            if let submenu = item.submenu { renameNewWindowItems(in: submenu) }
        }
    }
}
