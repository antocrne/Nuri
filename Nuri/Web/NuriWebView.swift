import AppKit
import WebKit

/// WKWebView with Nuri's context menu.
final class NuriWebView: WKWebView {
    weak var tab: Tab?
    /// Link under the last right-click, reported by core.js just before the menu opens.
    var contextLinkURL: URL?
    /// Set when one of WebKit's "Ouvrir … dans un nouvel onglet" items is chosen: the tab it
    /// creates (createWebViewWith, a moment later) opens behind, the page stays on screen.
    private var contextMenuOpenDate: Date?
    /// Key-downs given to WebKit: one of them coming back is WebKit re-sending an event the
    /// page didn't handle (see keyDown). The page answers late when it is busy, so several can be
    /// waiting at once.
    private let sentKeyDowns = NSHashTable<NSEvent>.weakObjects()

    /// A key the page leaves unhandled (an arrow in a video player, on a page that can't scroll, or
    /// in fullscreen) is re-sent by WebKit up the responder chain, where nothing takes it and macOS
    /// plays the "impossible action" sound. Menu shortcuts are matched before this point, so the
    /// re-sent event is simply dropped; ⌘ combinations nothing handles keep the system's answer.
    override func keyDown(with event: NSEvent) {
        if sentKeyDowns.contains(event) {
            sentKeyDowns.remove(event)
            if !event.modifierFlags.contains(.command) { return }
        } else {
            sentKeyDowns.add(event)
        }
        super.keyDown(with: event)
    }

    /// Split view: a click into the other side's page gives it the focus (address field, shortcuts).
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { MainActor.assumeIsolated { focusSplitSide() } }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { focusSplitSide() }
        super.mouseDown(with: event)
    }

    @MainActor
    private func focusSplitSide() {
        guard let tab, let browser = tab.browser, browser.selectedTab !== tab, browser.splitPartner === tab else { return }
        DispatchQueue.main.async { if browser.splitPartner === tab { browser.select(tab) } }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        MainActor.assumeIsolated { customize(menu) }
        #if DEBUG
        if let hook = Self.menuTestHook {
            Self.menuTestHook = nil
            hook(menu)
        }
        #endif
    }

    #if DEBUG
    /// Self-test: receives the next context menu as it opens (to pick an item and close it).
    static var menuTestHook: ((NSMenu) -> Void)?
    #endif

    /// A page that swallows the next right-click before core.js sees it must not get this link
    /// offered again.
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        contextLinkURL = nil
    }

    /// True once per context-menu "Ouvrir … dans un nouvel onglet": the new tab stays behind.
    /// A page that never asks for the window leaves the flag, so it expires.
    func consumeContextMenuOpen() -> Bool {
        defer { contextMenuOpenDate = nil }
        guard let date = contextMenuOpenDate else { return false }
        return Date().timeIntervalSince(date) < 2
    }

    @MainActor
    private func customize(_ menu: NSMenu) {
        forwardedActions.removeAll()
        menuIcons.removeAll()
        highlightedItem = nil
        menuWatcher = MenuHighlightWatcher(wrapping: menu.delegate) { [weak self] in self?.menuHighlighted($0) }
        menu.delegate = menuWatcher
        var linkItemIndex: Int?
        for (index, item) in menu.items.enumerated() {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow":
                // WebKit's action calls createWebViewWith → BrowserModel opens a tab.
                item.title = L("Ouvrir le lien dans un nouvel onglet", "Open Link in New Tab")
                linkItemIndex = index
                openBehind(item)
            case "WKMenuItemIdentifierOpenImageInNewWindow":
                item.title = L("Ouvrir l'image dans un nouvel onglet", "Open Image in New Tab")
                openBehind(item)
            case "WKMenuItemIdentifierOpenFrameInNewWindow":
                item.title = L("Ouvrir le cadre dans un nouvel onglet", "Open Frame in New Tab")
                openBehind(item)
            case "WKMenuItemIdentifierOpenMediaInNewWindow":
                item.title = L("Ouvrir la vidéo dans un nouvel onglet", "Open Video in New Tab")
                openBehind(item)
            default:
                break
            }
            if let id = item.identifier?.rawValue, let symbol = Self.menuSymbols[id] {
                setIcon(Self.symbol(symbol), of: item)
            }
        }

        if let link = contextLinkURL {
            var at = (linkItemIndex ?? -1) + 1
            func add(_ title: String, _ action: Selector, image: NSImage?) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.representedObject = link
                item.target = self
                setIcon(image, of: item)
                menu.insertItem(item, at: at)
                at += 1
            }
            if linkItemIndex == nil { add(L("Ouvrir le lien dans un nouvel onglet", "Open Link in New Tab"), #selector(openLinkBehind(_:)), image: Self.symbol("plus.square.on.square")) }
            add(L("Ouvrir dans un hublot", "Open in Porthole"), #selector(openLinkInPorthole(_:)), image: .porthole)
            add(L("Ouvrir en vue partagée", "Open in Split View"), #selector(openLinkInSplit(_:)), image: Self.symbol("rectangle.split.2x1"))
            if tab?.isPrivate == false { add(L("Ouvrir dans une fenêtre privée", "Open in Private Window"), #selector(openLinkPrivately(_:)), image: Self.symbol("eye.slash")) }
            if linkItemIndex == nil { menu.insertItem(.separator(), at: at) }
        }

        if tab?.isInCall == true {
            menu.addItem(.separator())
            let pip = NSMenuItem(title: L("Réunion en fenêtre flottante", "Meeting in Floating Window"), action: #selector(togglePiP), keyEquivalent: "")
            pip.target = self
            setIcon(Self.symbol("video"), of: pip)
            menu.addItem(pip)
        } else if tab?.hasVideo == true {
            menu.addItem(.separator())
            let pip = NSMenuItem(title: "Picture in Picture", action: #selector(togglePiP), keyEquivalent: "")
            pip.target = self
            setIcon(Self.symbol("pip"), of: pip)
            menu.addItem(pip)
        }

        let fromExtensions = Extensions.menuItems(for: tab)
        if !fromExtensions.isEmpty {
            menu.addItem(.separator())
            fromExtensions.forEach(menu.addItem)
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    /// WebKit's menu doesn't draw an item's `image`, except on its own Share and Services: the icon
    /// goes at the start of the title, in a box that lines the titles up with theirs.
    private func setIcon(_ icon: NSImage?, of item: NSMenuItem) {
        guard let icon else { return }
        item.image = nil
        menuIcons[ObjectIdentifier(item)] = (icon, item.title)
        drawIcon(of: item, color: .labelColor)
    }

    /// In a title an icon gets no tint from the menu: its color is given here, in step with the text.
    private func drawIcon(of item: NSMenuItem, color: NSColor) {
        guard let (icon, text) = menuIcons[ObjectIdentifier(item)] else { return }
        let side: CGFloat = 13, gap: CGFloat = 5
        let box = NSImage(size: NSSize(width: side + gap, height: side), flipped: false) { _ in
            let scale = min(1, side / max(icon.size.width, icon.size.height))
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let frame = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
            icon.draw(in: frame)
            color.set()
            frame.fill(using: .sourceIn)
            return true
        }
        let font = NSFont.menuFont(ofSize: 0)
        let attachment = NSTextAttachment()
        attachment.image = box
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side + gap, height: side)
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: text))
        title.addAttribute(.font, value: font, range: NSRange(location: 0, length: title.length))
        item.attributedTitle = title
        item.setAccessibilityLabel(text)
    }

    private func menuHighlighted(_ item: NSMenuItem?) {
        if let highlightedItem, highlightedItem !== item { drawIcon(of: highlightedItem, color: .labelColor) }
        highlightedItem = item
        if let item { drawIcon(of: item, color: .selectedMenuItemTextColor) }
    }

    /// WebKit's own items, by their identifier. One it adds later simply has no picture.
    private static let menuSymbols = [
        "WKMenuItemIdentifierOpenLink": "arrow.up.right.square",
        "WKMenuItemIdentifierOpenLinkInNewWindow": "plus.square.on.square",
        "WKMenuItemIdentifierOpenImageInNewWindow": "plus.square.on.square",
        "WKMenuItemIdentifierOpenFrameInNewWindow": "plus.square.on.square",
        "WKMenuItemIdentifierOpenMediaInNewWindow": "plus.square.on.square",
        "WKMenuItemIdentifierDownloadLinkedFile": "arrow.down.circle",
        "WKMenuItemIdentifierDownloadImage": "arrow.down.circle",
        "WKMenuItemIdentifierDownloadMedia": "arrow.down.circle",
        "WKMenuItemIdentifierCopyLink": "link",
        "WKMenuItemIdentifierCopyMediaLink": "link",
        "WKMenuItemIdentifierCopyImage": "photo.on.rectangle",
        "WKMenuItemIdentifierCopy": "doc.on.doc",
        "WKMenuItemIdentifierPaste": "doc.on.clipboard",
        "WKMenuItemIdentifierLookUp": "character.book.closed",
        "WKMenuItemIdentifierSearchWeb": "magnifyingglass",
        "WKMenuItemIdentifierTranslateMenu": "translate",
        "WKMenuItemIdentifierGoBack": "chevron.left",
        "WKMenuItemIdentifierGoForward": "chevron.right",
        "WKMenuItemIdentifierReload": "arrow.clockwise",
        "WKMenuItemIdentifierInspectElement": "hammer",
        "WKMenuItemIdentifierSpeechMenu": "waveform",
        "WKMenuItemIdentifierToggleFullScreen": "arrow.up.left.and.arrow.down.right",
        "WKMenuItemIdentifierShowHideMediaControls": "slider.horizontal.below.rectangle",
    ]

    /// WebKit's own items keep their action (it carries the opener and the referrer), routed
    /// through forwardOpenBehind so the tab it creates is marked to open behind.
    private func openBehind(_ item: NSMenuItem) {
        guard let action = item.action, action != #selector(forwardOpenBehind(_:)) else { return }
        forwardedActions[ObjectIdentifier(item)] = (item.target, action)
        item.target = self
        item.action = #selector(forwardOpenBehind(_:))
    }

    private var forwardedActions: [ObjectIdentifier: (target: AnyObject?, action: Selector)] = [:]
    private var menuIcons: [ObjectIdentifier: (icon: NSImage, title: String)] = [:]
    private weak var highlightedItem: NSMenuItem?
    private var menuWatcher: MenuHighlightWatcher?

    @objc private func forwardOpenBehind(_ sender: NSMenuItem) {
        guard let original = forwardedActions[ObjectIdentifier(sender)] else { return }
        forwardedActions.removeAll()
        contextMenuOpenDate = Date()
        NSApp.sendAction(original.action, to: original.target, from: sender)
    }

    @objc private func openLinkBehind(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated { _ = tab?.browser?.openTab(url: url, background: true, after: tab) }
    }

    @objc private func openLinkInPorthole(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated { tab?.browser?.openPorthole(url, from: tab) }
    }

    @objc private func openLinkInSplit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated {
            guard let tab, let browser = tab.browser else { return }
            browser.openInSplit(url, beside: tab)
        }
    }

    @objc private func openLinkPrivately(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated { _ = BrowserWindows.shared.openPrivateWindow(url: url) }
    }

    @objc private func togglePiP() {
        MainActor.assumeIsolated {
            guard let tab else { return }
            Task { await PiPController.shared.toggle(tab) }
        }
    }
}

/// Tells which item of WebKit's menu is highlighted, and leaves everything else to WebKit's delegate.
private final class MenuHighlightWatcher: NSObject, NSMenuDelegate {
    private weak var wrapped: NSMenuDelegate?
    private let highlighted: (NSMenuItem?) -> Void

    init(wrapping delegate: NSMenuDelegate?, highlighted: @escaping (NSMenuItem?) -> Void) {
        wrapped = delegate
        self.highlighted = highlighted
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlighted(item)
        wrapped?.menu?(menu, willHighlight: item)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || wrapped?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { wrapped }
}
