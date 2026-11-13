import AppKit

/// A key combination, as saved and as shown.
struct Shortcut: Equatable, Codable {
    /// The key: a character, or "\t", "←", "→".
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    var modifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    /// What NSMenuItem wants for this key.
    var keyEquivalent: String {
        switch key {
        case "←": String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "→": String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default: key
        }
    }

    var display: String {
        guard !key.isEmpty else { return "—" }
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        switch key {
        case "\t": text += "⇥"
        case " ": text += "␣"
        default: text += key.uppercased()
        }
        return text
    }

    /// From a key pressed in Settings. nil for a key that can't be a shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        switch event.keyCode {
        case 123: key = "←"
        case 124: key = "→"
        case 48: key = "\t"
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return nil }
            key = characters
        }
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
    }

    init(_ key: String, _ modifiers: String = "") {
        self.key = key
        command = modifiers.contains("c")
        shift = modifiers.contains("s")
        option = modifiers.contains("o")
        control = modifiers.contains("k")
    }
}

/// Everything shortcuts can do. Menus and Settings → Shortcuts are both built from this list.
enum NuriCommand: String, CaseIterable, Identifiable {
    case newTab, newWindow, newPrivateWindow, address, closeTab, closeWindow, closeAllTabs, reopenTab
    case nextTab, previousTab, tabList, newFolder, muteTab
    case back, forward, reload, reloadHard, stop, copyAddress, printPage, savePage, openFile
    case find, findNext, findPrevious, zoomIn, zoomOut, zoomReset
    case reader, pip, split, swapSides, focusOtherSide, toggleBar, fullScreen
    case nextSpace, previousSpace
    case bookmark, bookmarks, history, downloads, blockerForSite, viewSource, inspector, console
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9

    var id: String { rawValue }

    /// The key it has unless the user chose another. nil: none by default.
    var defaultShortcut: Shortcut? {
        switch self {
        case .newTab: Shortcut("t", "c")
        case .newWindow: Shortcut("n", "c")
        case .newPrivateWindow: Shortcut("n", "cs")
        case .address: Shortcut("l", "c")
        case .closeTab: Shortcut("w", "c")
        case .closeWindow: Shortcut("w", "cs")
        case .closeAllTabs: Shortcut("w", "co")
        case .reopenTab: Shortcut("t", "cs")
        case .nextTab: Shortcut("\t", "k")
        case .previousTab: Shortcut("\t", "ks")
        case .tabList: Shortcut("a", "cs")
        case .newFolder: Shortcut("n", "ck")
        case .muteTab: Shortcut("m", "k")
        case .back: Shortcut("[", "c")
        case .forward: Shortcut("]", "c")
        case .reload: Shortcut("r", "c")
        case .reloadHard: Shortcut("r", "co")
        case .stop: Shortcut(".", "c")
        case .copyAddress: Shortcut("c", "cs")
        case .printPage: Shortcut("p", "c")
        case .savePage: Shortcut("s", "c")
        case .openFile: Shortcut("o", "c")
        case .find: Shortcut("f", "c")
        case .findNext: Shortcut("g", "c")
        case .findPrevious: Shortcut("g", "cs")
        case .zoomIn: Shortcut("+", "c")
        case .zoomOut: Shortcut("-", "c")
        case .zoomReset: Shortcut("0", "c")
        case .reader: Shortcut("r", "cs")
        case .pip: Shortcut("p", "cs")
        case .split: Shortcut("s", "co")
        case .swapSides: Shortcut("s", "cos")
        case .focusOtherSide: Shortcut("\t", "o")
        case .toggleBar: Shortcut("b", "ck")
        case .fullScreen: Shortcut("f", "ck")
        case .nextSpace: Shortcut("→", "ck")
        case .previousSpace: Shortcut("←", "ck")
        case .bookmark: Shortcut("d", "c")
        case .bookmarks: Shortcut("b", "co")
        case .history: Shortcut("y", "c")
        case .downloads: Shortcut("l", "co")
        case .blockerForSite: nil
        case .viewSource: Shortcut("u", "co")
        case .inspector: Shortcut("i", "co")
        case .console: Shortcut("j", "co")
        case .tab1: Shortcut("1", "c")
        case .tab2: Shortcut("2", "c")
        case .tab3: Shortcut("3", "c")
        case .tab4: Shortcut("4", "c")
        case .tab5: Shortcut("5", "c")
        case .tab6: Shortcut("6", "c")
        case .tab7: Shortcut("7", "c")
        case .tab8: Shortcut("8", "c")
        case .tab9: Shortcut("9", "c")
        }
    }

    @MainActor var title: String {
        switch self {
        case .newTab: L("Nouvel onglet", "New Tab")
        case .newWindow: L("Nouvelle fenêtre", "New Window")
        case .newPrivateWindow: L("Nouvelle fenêtre privée", "New Private Window")
        case .address: L("Barre d'adresse", "Address Bar")
        case .closeTab: L("Fermer l'onglet", "Close Tab")
        case .closeWindow: L("Fermer la fenêtre", "Close Window")
        case .closeAllTabs: L("Fermer tous les onglets", "Close All Tabs")
        case .reopenTab: L("Rouvrir l'onglet fermé", "Reopen Closed Tab")
        case .nextTab: L("Onglet suivant", "Next Tab")
        case .previousTab: L("Onglet précédent", "Previous Tab")
        case .tabList: L("Tous les onglets", "All Tabs")
        case .newFolder: L("Nouveau dossier", "New Folder")
        case .muteTab: L("Couper ou remettre le son de l'onglet", "Mute or Unmute Tab")
        case .back: L("Précédent", "Back")
        case .forward: L("Suivant", "Forward")
        case .reload: L("Recharger", "Reload")
        case .reloadHard: L("Recharger sans le cache", "Reload Without Cache")
        case .stop: L("Arrêter", "Stop")
        case .copyAddress: L("Copier l'adresse", "Copy Address")
        case .printPage: L("Imprimer…", "Print…")
        case .savePage: L("Enregistrer la page…", "Save Page As…")
        case .openFile: L("Ouvrir un fichier…", "Open File…")
        case .find: L("Rechercher dans la page", "Find on Page")
        case .findNext: L("Résultat suivant", "Find Next")
        case .findPrevious: L("Résultat précédent", "Find Previous")
        case .zoomIn: L("Zoom avant", "Zoom In")
        case .zoomOut: L("Zoom arrière", "Zoom Out")
        case .zoomReset: L("Taille réelle", "Actual Size")
        case .reader: L("Mode lecture", "Reader Mode")
        case .pip: L("Picture in Picture / réunion flottante", "Picture in Picture / Floating Meeting")
        case .split: L("Vue partagée", "Split View")
        case .swapSides: L("Échanger les côtés", "Swap Sides")
        case .focusOtherSide: L("Passer à l'autre côté", "Focus Other Side")
        case .toggleBar: L("Masquer la barre (révélée en haut)", "Hide the Bar (Revealed at the Top)")
        case .fullScreen: L("Plein écran", "Full Screen")
        case .nextSpace: L("Espace suivant", "Next Space")
        case .previousSpace: L("Espace précédent", "Previous Space")
        case .bookmark: L("Ajouter aux signets", "Add to Bookmarks")
        case .bookmarks: L("Favoris et signets", "Favorites and Bookmarks")
        case .history: L("Historique", "History")
        case .downloads: L("Téléchargements", "Downloads")
        case .blockerForSite: L("Bloqueur sur ce site", "Blocker on This Site")
        case .viewSource: L("Afficher la source de la page", "Show Page Source")
        case .inspector: L("Inspecteur web", "Web Inspector")
        case .console: L("Console JavaScript", "JavaScript Console")
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8:
            L("Onglet \(rawValue.suffix(1))", "Tab \(rawValue.suffix(1))")
        case .tab9: L("Dernier onglet", "Last Tab")
        }
    }

    @MainActor func perform() {
        let browser = BrowserWindows.shared.active
        // A window that isn't a browser's (Settings, History) closes with ⌘W, like any other.
        if [.closeTab, .closeWindow].contains(self), let key = NSApp.keyWindow, !BrowserWindows.shared.all.contains(where: { $0.window === key }) {
            key.performClose(nil)
            return
        }
        if browser.window?.isVisible != true, ![.newWindow, .newPrivateWindow, .history].contains(self) {
            BrowserWindows.shared.showMainWindow()
        }
        switch self {
        case .newTab: browser.showCommandBar(.newTab)
        case .newWindow: BrowserWindows.shared.openNormalWindow()
        case .newPrivateWindow: BrowserWindows.shared.openPrivateWindow()
        case .address: browser.showCommandBar(.currentTab)
        case .closeTab:
            if browser.porthole != nil { browser.closePorthole() } else { browser.closeCurrentTab() }
        case .closeWindow: browser.window?.performClose(nil)
        case .closeAllTabs: browser.closeAllTabs()
        case .reopenTab: browser.reopenClosedTab()
        case .nextTab: browser.selectAdjacentTab(1)
        case .previousTab: browser.selectAdjacentTab(-1)
        case .tabList: browser.showingTabList.toggle()
        case .newFolder: browser.addFolder()
        case .muteTab: browser.toggleMute()
        case .back: browser.goBack()
        case .forward: browser.goForward()
        case .reload: browser.reload()
        case .reloadHard: browser.reload(ignoringCache: true)
        case .stop: browser.stopLoading()
        case .copyAddress: browser.copyAddress()
        case .printPage: browser.printPage()
        case .savePage: browser.savePage()
        case .openFile: browser.openFile()
        case .find: browser.showFindBar()
        case .findNext: browser.findAgain(backwards: false)
        case .findPrevious: browser.findAgain(backwards: true)
        case .zoomIn: browser.zoom(0.1)
        case .zoomOut: browser.zoom(-0.1)
        case .zoomReset: browser.zoom(0)
        case .reader: browser.toggleReader()
        case .pip: browser.togglePiP()
        case .split: browser.toggleSplit()
        case .swapSides: browser.swapSides()
        case .focusOtherSide: browser.focusOtherSide()
        case .toggleBar: browser.toggleTopBarAutoHide()
        case .fullScreen: browser.window?.toggleFullScreen(nil)
        case .nextSpace: browser.switchSpace(by: 1)
        case .previousSpace: browser.switchSpace(by: -1)
        case .bookmark: browser.bookmarkCurrentPage()
        case .bookmarks: if !browser.isPrivate { browser.showingBookmarks.toggle() }
        case .history: HistoryWindow.show(for: browser)
        case .downloads: browser.showingDownloads.toggle()
        case .blockerForSite: browser.toggleAdBlockForCurrentSite()
        case .viewSource: browser.showSource()
        case .inspector: browser.toggleInspector(console: false)
        case .console: browser.toggleInspector(console: true)
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            browser.selectTab(number: Int(rawValue.suffix(1)) ?? 1)
        }
    }
}

/// The user's own keys, saved by command. Everything else keeps its default.
@MainActor
enum Shortcuts {
    private static let key = "shortcuts"

    private static var overrides: [String: Shortcut] = {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Shortcut].self, from: data)) ?? [:]
    }()

    static func shortcut(for command: NuriCommand) -> Shortcut? {
        overrides[command.rawValue] ?? command.defaultShortcut
    }

    static func isCustom(_ command: NuriCommand) -> Bool { overrides[command.rawValue] != nil }

    /// The command already holding this key, other than `command`.
    static func conflict(_ shortcut: Shortcut, with command: NuriCommand) -> NuriCommand? {
        NuriCommand.allCases.first { $0 != command && self.shortcut(for: $0) == shortcut }
    }

    static func set(_ shortcut: Shortcut?, for command: NuriCommand) {
        overrides[command.rawValue] = shortcut
        if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: key) }
        NuriMenu.rebuild()
    }

    static func resetAll() {
        overrides = [:]
        UserDefaults.standard.removeObject(forKey: key)
        NuriMenu.rebuild()
    }
}

/// The menu bar, rebuilt when the language or a shortcut changes.
@MainActor
final class NuriMenu: NSObject {
    static let shared = NuriMenu()

    static func rebuild() {
        NSApp.mainMenu = shared.build()
    }

    private func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Nuri", appMenu()))
        let file = items([.newTab, .newWindow, .newPrivateWindow, .openFile, nil, .address, nil, .closeTab, .closeWindow, .closeAllTabs, .reopenTab, nil, .savePage, .printPage])
        file.addItem(.separator())
        add(file, L("Importer depuis un autre navigateur…", "Import from Another Browser…"), #selector(importFromBrowser))
        add(file, L("Exporter les signets…", "Export Bookmarks…"), #selector(exportBookmarks))
        main.addItem(submenu(L("Fichier", "File"), file))
        main.addItem(submenu(L("Édition", "Edit"), editMenu()))
        main.addItem(submenu(L("Présentation", "View"), items([.reload, .reloadHard, .stop, nil, .find, .findNext, .findPrevious, nil, .zoomIn, .zoomOut, .zoomReset, nil, .reader, .pip, nil, .toggleBar, .fullScreen, nil, .viewSource, .inspector, .console])))
        main.addItem(submenu(L("Navigation", "Go"), items([.back, .forward, nil, .copyAddress, nil, .history, .downloads, nil, .blockerForSite])))
        main.addItem(submenu(L("Signets", "Bookmarks"), items([.bookmark, .bookmarks])))
        main.addItem(submenu(L("Onglets", "Tabs"), items([.nextTab, .previousTab, .tabList, nil, .split, .swapSides, .focusOtherSide, nil, .muteTab, .newFolder, nil, .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9])))
        main.addItem(submenu(L("Espaces", "Spaces"), spacesMenu()))
        let window = NSMenu(title: L("Fenêtre", "Window"))
        window.addItem(withTitle: L("Réduire", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("Agrandir", "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let item = NSMenuItem(title: L("Fenêtre", "Window"), action: nil, keyEquivalent: "")
        item.submenu = window
        main.addItem(item)
        NSApp.windowsMenu = window
        main.addItem(submenu(L("Aide", "Help"), helpMenu()))
        return main
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func items(_ commands: [NuriCommand?]) -> NSMenu {
        let menu = NSMenu()
        for command in commands {
            guard let command else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: command.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            if let shortcut = Shortcuts.shortcut(for: command) {
                item.keyEquivalent = shortcut.keyEquivalent
                item.keyEquivalentModifierMask = shortcut.modifiers
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func run(_ sender: NSMenuItem) {
        (sender.representedObject as? String).flatMap(NuriCommand.init(rawValue:))?.perform()
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, L("À propos de Nuri", "About Nuri"), #selector(about))
        add(menu, L("Rechercher les mises à jour…", "Check for Updates…"), #selector(checkForUpdates))
        menu.addItem(.separator())
        add(menu, L("Réglages…", "Settings…"), #selector(settings), key: ",")
        add(menu, L("Raccourcis clavier", "Keyboard Shortcuts"), #selector(shortcuts))
        menu.addItem(.separator())
        // Filled by macOS with the services of the installed apps.
        let services = NSMenu(title: L("Services", "Services"))
        let servicesItem = NSMenuItem(title: L("Services", "Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        let hide = NSMenuItem(title: L("Masquer Nuri", "Hide Nuri"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(hide)
        let others = NSMenuItem(title: L("Masquer les autres", "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(others)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quitter Nuri", "Quit Nuri"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Annuler", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: L("Rétablir", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Couper", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L("Copier", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L("Coller", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // The text alone, without its fonts and colors (WebKit's pages and AppKit's fields both answer it).
        let plain = NSMenuItem(title: L("Coller sans mise en forme", "Paste and Match Style"), action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(plain)
        menu.addItem(withTitle: L("Supprimer", "Delete"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Tout sélectionner", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    /// macOS adds its search field at the top of a menu named as NSApp.helpMenu.
    private func helpMenu() -> NSMenu {
        let menu = NSMenu()
        add(menu, L("Raccourcis clavier", "Keyboard Shortcuts"), #selector(shortcuts))
        add(menu, L("Nuri sur GitHub", "Nuri on GitHub"), #selector(openRepository))
        add(menu, L("Signaler un problème…", "Report a Problem…"), #selector(reportProblem))
        NSApp.helpMenu = menu
        return menu
    }

    @objc private func openRepository() {
        if let url = URL(string: "https://github.com/\(Updater.repository)") { BrowserWindows.shared.normalTarget.openExternal(url) }
    }

    @objc private func reportProblem() {
        if let url = URL(string: "https://github.com/\(Updater.repository)/issues") { BrowserWindows.shared.normalTarget.openExternal(url) }
    }

    private func spacesMenu() -> NSMenu {
        items([.nextSpace, .previousSpace])
    }

    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Nuri",
            .credits: NSAttributedString(string: L("Nuri : le monde, en coréen. Un navigateur léger, sans compte, sans pisteur.", "Nuri: the world, in Korean. A light browser, no account, no trackers.")),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        Task { await Updater.shared.check(userInitiated: true) }
    }

    @objc private func importFromBrowser() { SettingsWindow.show(.general) }
    @objc private func exportBookmarks() { BrowserImport.exportWithPanel(space: BrowserWindows.shared.normalTarget.currentSpace) }

    @objc private func settings() { SettingsWindow.show() }
    @objc private func shortcuts() { SettingsWindow.show(.shortcuts) }
}
