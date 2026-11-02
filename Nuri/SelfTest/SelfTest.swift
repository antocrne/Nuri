#if DEBUG
import AppKit
import Network
import SwiftUI
import WebKit

/// Automated checks run against the real app code paths, in the real window. Debug builds only.
///
///   Nuri.app/Contents/MacOS/Nuri -NuriSelfTest features -NuriSelfTestOut /path/report.md [-NuriSelfTestOnly split,hublot]
///
/// Never touches the user's session, history or downloads (see StateStore.directory). Mouse events
/// are given to Nuri's own window: the real pointer doesn't move. Pages come from HTML strings and
/// a small local server; `pip` and `bloqueur` also need the network.
@MainActor
enum SelfTestRunner {
    nonisolated static var isRequested: Bool { UserDefaults.standard.string(forKey: "NuriSelfTest") != nil }
    /// `-NuriSelfTestDir`: the same folder from one launch to the next (section `lancement`).
    nonisolated static var keptDirectory: String? { UserDefaults.standard.string(forKey: "NuriSelfTestDir") }

    static func startIfRequested() {
        guard isRequested else { return }
        let out = UserDefaults.standard.string(forKey: "NuriSelfTestOut") ?? (NSTemporaryDirectory() + "nuri-selftest.md")
        let only = UserDefaults.standard.string(forKey: "NuriSelfTestOnly")?.split(separator: ",").map(String.init)
        Task {
            try? await Task.sleep(for: .seconds(1))
            await FeatureSelfTest(outputPath: out, only: only).run()
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class FeatureSelfTest {
    private let outputPath: String
    private let only: [String]?
    private let browser = BrowserModel.shared
    private var lines: [String] = []
    private var passed = 0
    private var failed = 0

    init(outputPath: String, only: [String]?) {
        self.outputPath = outputPath
        self.only = only
    }

    private var sections: [(String, (FeatureSelfTest) async -> Void)] {
        [
            ("session", { await $0.testSession() }),
            ("onglets", { await $0.testTabs() }),
            ("porter", { await $0.testCarrying() }),
            ("glisser", { await $0.testTabGestures() }),
            ("liens", { await $0.testLinks() }),
            ("split", { await $0.testSplit() }),
            ("hublot", { await $0.testPorthole() }),
            ("espaces", { await $0.testSpaces() }),
            ("dossiers", { await $0.testFolders() }),
            ("adresse", { await $0.testActiveTab() }),
            ("menus", { await $0.testPageMenu() }),
            ("fermer", { await $0.testCloseAll() }),
            ("son", { await $0.testMute() }),
            ("veille", { await $0.testSleep() }),
            ("prive", { await $0.testPrivate() }),
            ("calcul", { await $0.testCalculations() }),
            ("commandes", { await $0.testCommandBar() }),
            ("focus", { await $0.testNewTabFocus() }),
            ("attente", { await $0.testHold() }),
            ("extensions", { await $0.testExtensions() }),
            ("lancement", { await $0.testExtensionsAtLaunch() }),
            ("lecture", { await $0.testReader() }),
            ("historique", { await $0.testHistory() }),
            ("signets", { await $0.testBookmarks() }),
            ("telechargements", { await $0.testDownloads() }),
            ("pistage", { await $0.testTrackingParameters() }),
            ("permissions", { await $0.testSitePermissions() }),
            ("http", { await $0.testPlainHTTP() }),
            ("bloqueur", { await $0.testBlocker() }),
            ("langue", { await $0.testLanguage() }),
            ("raccourcis", { await $0.testShortcuts() }),
            ("barre", { await $0.testHiddenBar() }),
            ("mise-a-jour", { await $0.testUpdater() }),
            ("reunion", { await $0.testMeetingWindow() }),
            ("partage-son", { await $0.testShareAudio() }),
            ("pip", { await $0.testPiP() }),
            ("apercu", { await $0.testPreview() }),
        ]
    }

    func run() async {
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? FileManager.default.createDirectory(at: Self.downloads, withIntermediateDirectories: true)
        AppSettings.shared.downloadFolderPath = Self.downloads.path
        for (name, section) in sections where only == nil || only!.contains(name) {
            lines.append("\n## \(name)")
            NSLog("[Nuri self-test] ▶ %@", name)
            eventsWereInFront = true
            browser.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            await section(self)
            cleanUp()
        }
        AppSettings.shared.downloadFolderPath = nil
        let summary = "# Nuri \(Updater.currentVersion) : \(passed) réussis, \(failed) échoués, \(unverified) non vérifiés\n"
        try? (summary + lines.joined(separator: "\n") + "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: outputPath + ".partial")
        NSLog("[Nuri self-test] %@", summary)
    }

    private static let downloads = StateStore.directory.appendingPathComponent("downloads", isDirectory: true)

    /// Each section starts from one empty space.
    private func cleanUp() {
        browser.closePorthole()
        for space in browser.spaces.dropFirst() { browser.deleteSpace(space) }
        browser.currentSpace.split = nil
        for tab in browser.allTabs { browser.close(tab) }
        for folder in browser.currentSpace.folders { browser.deleteFolder(folder, keepingTabs: false) }
        browser.forgetClosedTabs()
        browser.commandBar = nil
        browser.carry = nil
    }

    // MARK: Helpers

    private func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        // Events made by hand get lost when another app is in front: that says nothing of Nuri.
        if !condition, !eventsWereInFront {
            unverified += 1
            lines.append("- ⚪️ NON VÉRIFIÉ (Nuri pas au premier plan) : \(name)")
            return
        }
        if condition { passed += 1 } else { failed += 1 }
        lines.append("- \(condition ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        // As it goes: a test stuck for good still says how far it went.
        try? (lines.joined(separator: "\n") + "\n").write(toFile: outputPath + ".partial", atomically: true, encoding: .utf8)
    }

    private var unverified = 0

    private var eventsWereInFront = true

    private func note(_ text: String) { lines.append("- ⚪️ \(text)") }

    private func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    private func until(_ timeout: Double = 4, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<Int(timeout * 10) {
            if condition() { return true }
            await sleep(0.1)
        }
        return condition()
    }

    private func waitForLoad(_ tab: Tab, timeout: Double = 20) async {
        let start = Date()
        await sleep(0.5)
        while tab.isLoading && Date().timeIntervalSince(start) < timeout { await sleep(0.1) }
        await sleep(0.2)
    }

    private func htmlTab(_ html: String, base: String = "https://nuri-selftest.example/", in model: BrowserModel? = nil, title: String? = nil) async -> Tab {
        let tab = (model ?? browser).openTab(url: nil)
        tab.ensureWebView().loadHTMLString(html, baseURL: URL(string: base))
        await waitForLoad(tab)
        if let title { tab.title = title }
        return tab
    }

    private func js(_ tab: Tab, _ body: String) async -> Any? { await tab.webView?.nuriCall(body) }

    private func windowPoint(_ topLeft: CGPoint) -> NSPoint {
        NSPoint(x: topLeft.x, y: (browser.window?.contentView?.bounds.height ?? 0) - topLeft.y)
    }

    private func mouse(_ type: NSEvent.EventType, at topLeft: CGPoint, flags: NSEvent.ModifierFlags = [], post: Bool = false, button: Int64? = nil) async {
        if !NSApp.isActive || browser.window?.isKeyWindow != true || NSEvent.pressedMouseButtons != 0 {
            eventsWereInFront = false
        }
        guard let window = browser.window,
              let event = NSEvent.mouseEvent(with: type, location: windowPoint(topLeft), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        // The bar's empty place moves the window: it would wait here for a release that never comes.
        if type == .leftMouseDown, !post, let hit = window.contentView?.hitTest(windowPoint(topLeft)), String(describing: Swift.type(of: hit)).contains("DragView") {
            check("Pointeur : un clic simulé tombe sur la barre vide", false,
                  "\(topLeft) · onglets \(browser.currentSpace.tabs.map { "\($0.title) \(browser.tabFrames[$0.id] ?? .zero)" }) · porté \(String(describing: browser.carry))")
            return
        }
        var final = event
        if let button, let quartz = event.cgEvent {
            quartz.setIntegerValueField(.mouseEventButtonNumber, value: button)
            final = NSEvent(cgEvent: quartz) ?? event
        }
        if post { NSApp.postEvent(final, atStart: false) } else { window.sendEvent(final) }
        await sleep(0.07)
    }

    private func center(of tab: Tab) -> CGPoint? {
        browser.tabFrames[tab.id].map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// Renders the window by itself, next to the report. The app draws its own views: nothing else
    /// on the screen is read, so the desktop behind the glass and web views may be missing.
    private func snapshot(_ name: String, window: NSWindow? = nil) async {
        await sleep(0.4)
        guard let view = (window ?? browser.window)?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let path = (outputPath as NSString).deletingPathExtension + "-\(name).png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// A panel of the bar, by itself: a popover has its own window.
    private func snapshot(panel: some View, _ name: String) {
        let view = NSHostingView(rootView: panel.environment(browser).environment(AppSettings.shared)
            .background(Color(nsColor: Theme.frameNS)))
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let path = (outputPath as NSString).deletingPathExtension + "-\(name).png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Session

    private func testSession() async {
        let space = SavedSpace(id: UUID(), name: "Travail", color: Pastel.sage.rawValue,
                               tabs: [SavedTab(id: UUID(), url: URL(string: "https://a.example"), title: "A", isMuted: true)],
                               selectedTabID: nil,
                               folders: [SavedFolder(id: UUID(), name: "Plus tard", tabs: [SavedTab(id: UUID(), url: URL(string: "https://b.example"), title: "B")])])
        let state = SavedState(currentSpaceID: space.id, spaces: [space])
        let decoded = (try? JSONEncoder().encode(state)).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        check("Session : espace, couleur, dossier et son coupé relus", decoded?.spaces.first?.color == "sage"
              && decoded?.spaces.first?.tabs.first?.isMuted == true && decoded?.spaces.first?.folders.first?.tabs.first?.title == "B")
        let damaged = #"{"currentSpaceID":"x","spaces":[{"id":"\#(space.id.uuidString)","tabs":[{"url":12},{"title":"ok"}]}]}"#
        let tolerant = try? JSONDecoder().decode(SavedState.self, from: Data(damaged.utf8))
        check("Session : un fichier abîmé garde l'espace (ses connexions en dépendent)", tolerant?.spaces.first?.id == space.id)
        check("Session : le test écrit hors des données de l'utilisateur", StateStore.directory.path.contains("nuri-selftest"), StateStore.directory.path)

        // ⌘N windows.
        guard let server = LocalServer() else { check("Session : serveur local", false); return }
        _ = await until(2) { server.port != 0 }
        let other = BrowserModel(kind: .secondary, mirroring: browser)
        BrowserWindows.shared.show(other)
        let there = other.openTab(url: URL(string: "http://127.0.0.1:\(server.port)/long"))
        await waitForLoad(there)
        let written = (try? JSONEncoder().encode(browser.sessionState())).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        check("Session : les onglets d'une fenêtre ⌘N sont enregistrés",
              written?.windows?.first?.spaces.flatMap(\.tabs).first?.id == there.id && written?.windows?.first?.frame != nil)
        if let written, let window = written.windows?.first {
            let back = BrowserModel(kind: .secondary, mirroring: browser)
            back.restore(window, in: written)
            check("Session : et reviennent dans leur fenêtre, à sa place",
                  back.allTabs.first?.id == there.id && back.currentSpaceID == other.currentSpaceID && back.frameToReopen == other.window?.frame)
        }
        let opened = browser.closedTabs.count
        other.window?.performClose(nil)
        await sleep(0.3)
        check("Session : ⌘⇧T rouvre les onglets d'une fenêtre ⌘N fermée", browser.closedTabs.count == opened + 1)
        browser.forgetClosedTabs()

        // Back/forward lists.
        let tab = browser.openTab(url: URL(string: "http://127.0.0.1:\(server.port)/long"))
        await waitForLoad(tab)
        tab.load(URL(string: "http://127.0.0.1:\(server.port)/long?suite")!)
        await waitForLoad(tab)
        check("Session : la liste Précédent/Suivant s'écrit", tab.stateToSave != nil && tab.canGoBack)
        let saved = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nuri-state-\(UUID().uuidString)", isDirectory: true)
        let previous = StateStore.sessionDirectory
        try? FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        StateStore.sessionDirectory = saved
        TabStates.save([tab], keeping: [tab.id])
        let (savedID, savedURL) = (tab.id, tab.url)
        browser.close(tab)
        let restored = Tab(id: savedID, url: savedURL, title: "")
        restored.space = browser.currentSpace
        restored.isFromSession = true
        browser.currentSpace.tabs.append(restored)
        browser.select(restored)
        await waitForLoad(restored)
        check("Session : un onglet relancé retrouve sa liste", restored.canGoBack, "\(restored.url?.absoluteString ?? "?")")
        // A list that can't be read: its page all the same.
        let unreadable = UUID()
        try? Data("n'importe quoi".utf8).write(to: saved.appendingPathComponent("TabStates/\(unreadable.uuidString)"))
        let broken = Tab(id: unreadable, url: URL(string: "http://127.0.0.1:\(server.port)/long"), title: "")
        broken.space = browser.currentSpace
        broken.isFromSession = true
        browser.currentSpace.tabs.append(broken)
        browser.select(broken)
        await waitForLoad(broken)
        check("Session : une liste illisible laisse sa page s'ouvrir", broken.title == "Long", broken.title)
        browser.close(broken)
        restored.forgetHistory()
        TabStates.save([restored], keeping: [restored.id])
        check("Session : effacer l'historique efface la liste enregistrée", TabStates.read(restored.id) == nil)
        browser.close(restored)
        TabStates.save([], keeping: [])
        StateStore.sessionDirectory = previous
        try? FileManager.default.removeItem(at: saved)

        // ⌘R on a load that failed.
        let failing = browser.openTab(url: URL(string: "http://127.0.0.1:9/"))
        await waitForLoad(failing)
        let failedFirst = failing.loadError != nil
        browser.select(failing)
        browser.reload()
        await waitForLoad(failing)
        check("Session : ⌘R après un échec redemande la page", failedFirst && failing.loadError != nil && failing.url != nil, failing.loadError ?? "aucune erreur")

        // Text typed and not sent.
        let typed = await htmlTab("<title>T</title><form><input id=f name=f><input type=search id=s><input type=password id=p></form>")
        typed.hasUserInput = true
        _ = await js(typed, "document.getElementById('s').value = 'x'; document.getElementById('p').value = 'x'; return 1;")
        let notMuch = await typed.holdsTypedText()
        _ = await js(typed, "document.getElementById('f').value = 'bonjour'; return 1;")
        let holding = await typed.holdsTypedText()
        typed.hasUserInput = false
        let done = await typed.holdsTypedText()
        check("Session : un texte saisi est repéré, pas une recherche ni un mot de passe", !notMuch && holding && !done)
    }

    // MARK: Tabs

    private func testTabs() async {
        let a = await htmlTab("<title>A</title>a")
        let b = await htmlTab("<title>B</title>b")
        let c = await htmlTab("<title>C</title>c")
        check("Onglets : le dernier ouvert est affiché", browser.selectedTab === c)
        browser.moveTab(c, to: 0)
        check("Onglets : déplacer change l'ordre", browser.currentSpace.tabs.map(\.title) == ["C", "A", "B"], browser.currentSpace.tabs.map(\.title).joined())
        browser.selectTab(number: 2)
        check("Onglets : ⌘2", browser.selectedTab === a)
        browser.selectTab(number: 9)
        check("Onglets : ⌘9 va au dernier", browser.selectedTab === b)
        browser.selectAdjacentTab(1)
        check("Onglets : ⌃⇥ boucle", browser.selectedTab === c)
        browser.close(c)
        check("Onglets : fermer montre le suivant", browser.selectedTab === a && c.isClosed && c.webView == nil)
        browser.reopenClosedTab()
        check("Onglets : ⌘⇧T rouvre", browser.currentSpace.tabs.count == 3 && browser.selectedTab !== a && browser.selectedTab !== b)
    }

    /// What a carried tab does, whichever app is in front: the same calls as the gesture's.
    private func testCarrying() async {
        let a = await htmlTab("<title>A</title>a")
        let b = await htmlTab("<title>B</title>b")
        let c = await htmlTab("<title>C</title>c")
        browser.select(a)
        await sleep(0.4)
        guard let pointB = center(of: b), let pointC = center(of: c) else { check("Porter : onglets mesurés", false); return }
        func drag(_ tab: Tab, from start: CGPoint, to end: CGPoint) {
            browser.tabDragChanged(tab, location: end, translation: CGSize(width: end.x - start.x, height: end.y - start.y))
        }
        browser.tabDragChanged(b, location: pointB, translation: .zero)
        check("Porter : presser n'ouvre rien", browser.selectedTab === a && browser.carry == nil)
        browser.tabDragEnded(b, translation: .zero)
        check("Porter : relâcher sans bouger ouvre l'onglet", browser.selectedTab === b)
        browser.select(a)

        drag(b, from: pointB, to: CGPoint(x: pointC.x + 40, y: pointC.y))
        await sleep(0.3)
        check("Porter : l'onglet est sous le pointeur, les autres s'écartent", browser.carry?.tabID == b.id && browser.currentSpace.tabs.map(\.title) == ["A", "C", "B"], browser.currentSpace.tabs.map(\.title).joined())
        browser.tabDragEnded(b, translation: CGSize(width: 100, height: 0))
        let settled = await until(1) { browser.carry == nil }
        check("Porter : lâché sur la barre, il ne s'ouvre pas", browser.selectedTab === a && settled)

        let page = browser.pageFrame
        let right = CGPoint(x: page.maxX - 60, y: page.midY)
        drag(b, from: pointB, to: right)
        check("Porter : la moitié droite se montre", browser.carry?.dropSide == .right)
        drag(b, from: pointB, to: CGPoint(x: pointB.x, y: Metrics.topBarHeight / 2))
        check("Porter : retour sur la barre, plus de zone", browser.carry?.dropSide == nil)
        browser.tabDragEnded(b, translation: CGSize(width: 0, height: 10))
        check("Porter : changer d'avis ne crée pas de vue partagée", browser.shownSplit == nil)

        drag(b, from: pointB, to: CGPoint(x: page.minX + 60, y: page.midY))
        browser.tabDragEnded(b, translation: CGSize(width: 300, height: 300))
        check("Porter : lâché à gauche, il s'ouvre à gauche", browser.shownSplit?.left === b && browser.shownSplit?.right === a)
        browser.endSplit()

        // The focused page itself: it pairs with the tab used last.
        browser.select(a)
        drag(a, from: pointB, to: right)
        browser.tabDragEnded(a, translation: CGSize(width: 300, height: 300))
        check("Porter : la page affichée va à droite, l'onglet d'avant à gauche", browser.shownSplit?.right === a && browser.shownSplit?.left != nil)
        browser.endSplit()

        // With the bar hidden: it stays out as long as a tab is carried.
        let settings = AppSettings.shared
        DispatchQueue.main.async { settings.autoHideTopBar = true }
        await sleep(0.5)
        browser.topBarRevealed = true
        await sleep(0.4)
        drag(b, from: pointB, to: right)
        await mouse(.mouseMoved, at: CGPoint(x: 300, y: 400), post: true)
        await sleep(0.4)
        check("Porter : barre masquée, elle reste tant qu'un onglet est porté", browser.topBarRevealed && browser.carry?.dropSide == .right)
        browser.tabDragEnded(b, translation: CGSize(width: 300, height: 300))
        check("Porter : barre masquée, il s'ouvre en vue partagée", browser.shownSplit?.right === b)
        browser.topBarRevealed = false
        DispatchQueue.main.async { settings.autoHideTopBar = false }
        await sleep(0.5)
    }

    /// The real gestures, through mouse events given to the window.
    private func testTabGestures() async {
        let a = await htmlTab("<title>A</title>a")
        let b = await htmlTab("<title>B</title>b")
        let c = await htmlTab("<title>C</title>c")
        browser.select(a)
        await sleep(0.4)
        guard let pointB = center(of: b), let pointC = center(of: c), let window = browser.window else {
            check("Glisser : onglets mesurés", false)
            return
        }
        let origin = window.frame.origin

        await mouse(.leftMouseDown, at: pointB)
        check("Glisser : presser un onglet ne l'ouvre pas encore", browser.selectedTab === a)
        await mouse(.leftMouseUp, at: pointB)
        check("Glisser : il s'ouvre au relâchement", browser.selectedTab === b)

        browser.select(a)
        await sleep(0.6)
        // Picked up without switching to it, carried past C.
        let past = CGPoint(x: pointC.x + 40, y: pointC.y)
        await mouse(.leftMouseDown, at: pointB)
        await mouse(.leftMouseDragged, at: CGPoint(x: pointB.x + 20, y: pointB.y))
        check("Glisser : l'onglet attrapé suit le pointeur, sans s'ouvrir", browser.carry?.tabID == b.id && browser.selectedTab === a)
        await mouse(.leftMouseDragged, at: past)
        await sleep(0.3)
        await mouse(.leftMouseUp, at: past)
        check("Glisser : déplacé parmi les autres", browser.currentSpace.tabs.map(\.title) == ["A", "C", "B"], browser.currentSpace.tabs.map(\.title).joined())
        let settled = await until(1) { browser.carry == nil }
        check("Glisser : ni ouvert ni fenêtre déplacée", browser.selectedTab === a && window.frame.origin == origin && settled)

        // In a window that isn't in front, the first click on a tab opens it.
        let other = BrowserWindows.shared.openNormalWindow()
        await sleep(0.4)
        await mouse(.leftMouseDown, at: pointB, post: true)
        await mouse(.leftMouseUp, at: pointB, post: true)
        let firstClick = await until(1) { browser.selectedTab?.title == "C" }
        eventsWereInFront = true
        check("Glisser : le premier clic dans une fenêtre inactive ouvre l'onglet", firstClick, browser.selectedTab?.title ?? "nil")
        other.window?.close()
        window.makeKeyAndOrderFront(nil)
        browser.select(a)
        await sleep(0.5)

        // Over the page: its right half shows where it will open.
        await sleep(0.3)
        guard let start = center(of: b) else { return }
        let page = browser.pageFrame
        await mouse(.leftMouseDown, at: start)
        await mouse(.leftMouseDragged, at: CGPoint(x: page.maxX - 60, y: page.midY))
        check("Glisser : au-dessus de la moitié droite, la page le montre", browser.carry?.dropSide == .right)
        // Back to the bar: nothing happens.
        await mouse(.leftMouseDragged, at: CGPoint(x: start.x, y: Metrics.topBarHeight / 2))
        check("Glisser : revenu sur la barre, plus de zone", browser.carry?.dropSide == nil)
        await mouse(.leftMouseUp, at: CGPoint(x: start.x, y: Metrics.topBarHeight / 2))
        check("Glisser : changer d'avis ne crée pas de vue partagée", browser.shownSplit == nil)

        // Let go on the left half. A tab being settled isn't there to be grabbed yet.
        let landed = await until(2) { browser.carry == nil }
        check("Glisser : l'onglet reposé est de nouveau là", landed, String(describing: browser.carry))
        await sleep(0.3)
        guard let again = center(of: b) else { return }
        await mouse(.leftMouseDown, at: again)
        await mouse(.leftMouseDragged, at: CGPoint(x: page.minX + 60, y: page.midY))
        await mouse(.leftMouseUp, at: CGPoint(x: page.minX + 60, y: page.midY))
        await sleep(0.2)
        check("Glisser : lâché à gauche, il s'ouvre à gauche", browser.shownSplit?.left === b && browser.shownSplit?.right === a)
        browser.endSplit()

        // Bar's empty place: it moves the window, a tab doesn't.
        check("Glisser : la fenêtre ne se déplace pas toute seule", !window.isMovable)
    }

    private func testLinks() async {
        let target = "https://nuri-selftest.example/autre"
        let page = await htmlTab("""
            <!doctype html><title>Liens</title><body style="margin:0">
            <a id="plain" href="\(target)" style="display:block;height:40px">lien</a>
            <a id="blank" href="\(target)" target="_blank" style="display:block;height:40px">blank</a>
            <button id="forged" style="display:block;height:40px" onclick="const w = window.open('https://banque.example/compte'); w.document.write('<title>Banque</title><h1>Fausse page</h1>'); w.document.close();">forged</button>
            """)
        browser.window?.makeFirstResponder(page.webView)
        func point(_ id: String) async -> CGPoint? {
            guard let webView = page.webView,
                  let p = await webView.nuriCall("const r = document.getElementById(s).getBoundingClientRect(); return {x: r.left + r.width/2, y: r.top + r.height/2};", arguments: ["s": id]) as? [String: Double] else { return nil }
            return CGPoint(x: browser.pageFrame.minX + p["x"]!, y: browser.pageFrame.minY + p["y"]!)
        }
        func click(_ id: String, flags: NSEvent.ModifierFlags = []) async {
            guard let p = await point(id) else { return }
            await mouse(.leftMouseDown, at: p, flags: flags)
            await mouse(.leftMouseUp, at: p, flags: flags)
        }
        let start = browser.currentSpace.tabs.count
        await click("plain", flags: .command)
        let opened = await until(3) { browser.currentSpace.tabs.count == start + 1 }
        check("Liens : ⌘-clic ouvre un seul onglet, derrière, avec sa page",
              opened && browser.selectedTab === page && browser.currentSpace.tabs.last?.url?.absoluteString == target,
              "\(browser.currentSpace.tabs.count) onglets")
        await click("blank")
        let blank = await until(3) { browser.currentSpace.tabs.count == start + 2 }
        check("Liens : target=_blank ouvre un seul onglet, avec sa page", blank && browser.selectedTab !== page && browser.selectedTab?.requestedURL?.absoluteString == target,
              "\(browser.currentSpace.tabs.count) onglets")
        browser.select(page)
        await sleep(0.2)

        await click("plain", flags: .option)
        let glance = await until(3) { browser.porthole != nil }
        check("Liens : ⌥-clic ouvre le hublot, sans quitter la page", glance && browser.selectedTab === page && browser.currentSpace.tabs.count == start + 2)
        browser.closePorthole()

        // A page writing in the tab it opens: the tab shows where that page really comes from.
        await click("forged")
        _ = await until(3) { browser.selectedTab !== page }
        await sleep(1)
        let forged = browser.selectedTab
        check("Liens : une page qui écrit dans l'onglet qu'elle ouvre n'obtient pas l'adresse demandée",
              forged !== page && forged?.requestedURL?.host() == "banque.example" && forged?.url?.host() != "banque.example",
              "adresse : \(forged?.url?.absoluteString ?? "aucune")")
        if let forged, forged !== page { browser.close(forged) }
        browser.select(page)
        await sleep(0.2)

        // The context menu.
        if let webView = page.webView {
            webView.contextLinkURL = URL(string: target)
            let menu = NSMenu()
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                webView.willOpenMenu(menu, with: event)
            }
            // An icon sits in the title, as an attachment.
            func plain(_ item: NSMenuItem) -> String { item.title.replacingOccurrences(of: "\u{FFFC}", with: "") }
            let titles = menu.items.map(plain)
            check("Liens : menu contextuel complet",
                  titles.contains(L("Ouvrir le lien dans un nouvel onglet", "Open Link in New Tab")) && !titles.contains(L("Ouvrir en arrière-plan", "Open in Background"))
                  && titles.contains(L("Ouvrir dans une fenêtre privée", "Open in Private Window")) && titles.contains(L("Ouvrir dans un hublot", "Open in Porthole")),
                  titles.joined(separator: " · "))
            let count = browser.currentSpace.tabs.count
            let icons = [L("Ouvrir dans un hublot", "Open in Porthole"), L("Ouvrir en vue partagée", "Open in Split View")]
            check("Liens : hublot et vue partagée ont leur icône", icons.allSatisfy { title in menu.items.first { plain($0) == title }?.attributedTitle?.containsAttachments(in: NSRange(location: 0, length: 1)) == true })
            menu.items.first { plain($0) == L("Ouvrir le lien dans un nouvel onglet", "Open Link in New Tab") }.map { menu.performActionForItem(at: menu.index(of: $0)) }
            let behind = await until(2) { browser.currentSpace.tabs.count == count + 1 }
            check("Liens : « Ouvrir dans un nouvel onglet » reste sur la page", behind && browser.selectedTab === page)
        }
    }

    // MARK: Split view

    private func testSplit() async {
        let a = await htmlTab("<title>A</title>a")
        let b = await htmlTab("<title>B</title>b")
        let c = await htmlTab("<title>C</title>c")
        func index(_ tab: Tab) -> Int { browser.currentSpace.tabs.firstIndex { $0 === tab } ?? -1 }

        // In the bar the pair makes one block, in the order of the page, and moves as one.
        browser.select(a)
        browser.showInSplit(c)
        await sleep(0.5)
        let gap = (browser.tabFrames[c.id]?.minX ?? 0) - (browser.tabFrames[a.id]?.maxX ?? 0)
        check("Vue partagée : les deux onglets côte à côte dans la barre, un seul bloc", index(c) == index(a) + 1 && abs(gap - 2) < 0.5,
              "a \(index(a)) · b \(index(b)) · c \(index(c)) · écart \(gap)")
        await snapshot("split-bloc")
        if let pair = browser.currentSpace.split { browser.moveSplitPair(pair, to: index(b)) }
        check("Vue partagée : le bloc se déplace d'un seul tenant", index(b) + 1 == index(a) && index(a) + 1 == index(c),
              "a \(index(a)) · b \(index(b)) · c \(index(c))")

        browser.showInSplit(b)
        await sleep(0.4)
        check("Vue partagée : la page remplacée quitte le bloc", index(a) + 1 == index(b), "a \(index(a)) · b \(index(b)) · c \(index(c))")
        check("Vue partagée : deux pages à l'écran", browser.shownSplit?.left === a && browser.shownSplit?.right === b && a.webView?.window != nil && b.webView?.window != nil)
        let sizeA = a.webView?.frame.width ?? 0
        let sizeB = b.webView?.frame.width ?? 0
        check("Vue partagée : moitié-moitié", abs(sizeA - sizeB) <= 2 && sizeA > 200, "\(sizeA) / \(sizeB)")

        // The divider, with the pointer.
        let page = browser.pageFrame
        let x = page.minX + sizeA + SplitGeometry.divider / 2
        let hit = browser.window?.contentView?.hitTest(windowPoint(CGPoint(x: x, y: page.midY))).map { String(describing: type(of: $0)) } ?? "nil"
        await mouse(.leftMouseDown, at: CGPoint(x: x, y: page.midY))
        await mouse(.leftMouseDragged, at: CGPoint(x: x + 120, y: page.midY))
        await mouse(.leftMouseUp, at: CGPoint(x: x + 120, y: page.midY))
        await sleep(0.3)
        let widened = a.webView?.frame.width ?? 0
        check("Vue partagée : le séparateur se tire", abs(widened - sizeA - 120) <= 3, "\(sizeA) → \(widened) · sous le pointeur \(hit) · ratio \(browser.currentSpace.splitRatio)")

        browser.select(b)
        check("Vue partagée : passer d'un côté à l'autre garde la paire", browser.shownSplit != nil)
        browser.swapSides()
        check("Vue partagée : échanger les côtés", browser.shownSplit?.left === b && browser.shownSplit?.right === a && index(b) + 1 == index(a))

        // The handle appears near the top of a page.
        await mouse(.mouseMoved, at: CGPoint(x: page.minX + 100, y: page.minY + 12), post: true)
        let shown = await until(2) { browser.splitHandleSide == .left }
        check("Vue partagée : la poignée apparaît en haut de la page", shown)
        await snapshot("split-poignee")
        await mouse(.mouseMoved, at: CGPoint(x: page.minX + 100, y: page.midY), post: true)
        let hidden = await until(2) { browser.splitHandleSide == nil }
        check("Vue partagée : elle repart au milieu de la page", hidden)

        // A third tab: selecting it hides the pair, which comes back.
        browser.select(c)
        check("Vue partagée : un autre onglet cache la paire", browser.shownSplit == nil)
        browser.select(a)
        check("Vue partagée : elle revient avec l'un des deux", browser.shownSplit != nil)

        browser.takeOutOfSplit(b)
        check("Vue partagée : le × retire la page, l'onglet reste", browser.shownSplit == nil && browser.currentSpace.tabs.contains { $0 === b } && browser.selectedTab === a)

        browser.showInSplit(b)
        browser.close(b)
        check("Vue partagée : fermer un côté rend la page à l'autre", browser.shownSplit == nil && browser.selectedTab === a)

        browser.showInSplit(c, on: .left)
        check("Vue partagée : déposer à gauche", browser.shownSplit?.left === c && browser.shownSplit?.right === a)
        browser.carryToSplit(a, side: .right)
        check("Vue partagée : la page déjà du bon côté ne bouge pas", browser.shownSplit?.right === a)
    }

    // MARK: Porthole

    private func testPorthole() async {
        let page = await htmlTab("<title>Page</title>page")
        let space = browser.currentSpace
        browser.openPorthole(URL(string: "about:blank")!, from: page)
        guard let glance = browser.porthole else { check("Hublot : s'ouvre", false); return }
        await sleep(0.5)
        check("Hublot : la page reste affichée, rien dans la barre", browser.selectedTab === page && space.tabs.count == 1)
        check("Hublot : même espace, donc mêmes connexions", glance.webView?.configuration.websiteDataStore === space.dataStore)
        check("Hublot : sa page est à l'écran", glance.webView?.window === browser.window)
        await snapshot("hublot")
        browser.closePorthole()
        check("Hublot : Échap le ferme et libère sa page", browser.porthole == nil && glance.webView == nil)

        browser.openPorthole(URL(string: "about:blank")!, from: page)
        let kept = browser.porthole
        let view = kept?.webView
        browser.keepPorthole()
        check("Hublot : le garder en fait un onglet, même page", browser.selectedTab === kept && space.tabs.count == 2 && kept?.webView === view && view != nil)
        await sleep(0.3)
        check("Hublot : la page passe dans la zone des onglets", view?.superview is WebHostView)

        browser.select(page)
        browser.openPorthole(URL(string: "about:blank")!, from: page)
        let side = browser.porthole
        browser.portholeToSplit()
        check("Hublot : en vue partagée", browser.shownSplit?.right === side && browser.shownSplit?.left === page)
    }

    // MARK: Spaces

    private func testSpaces() async {
        let first = browser.currentSpace
        let second = browser.addSpace(name: "Travail", color: .sage)
        check("Espaces : le nouveau est affiché, avec sa couleur", browser.currentSpace === second && second.tint == .sage)
        check("Espaces : stockage séparé", first.dataStore !== second.dataStore && first.dataStore.isPersistent && second.dataStore.isPersistent)
        let cookie = HTTPCookie(properties: [.domain: "nuri-selftest.example", .path: "/", .name: "c", .value: "travail", .secure: "TRUE"])!
        await second.dataStore.httpCookieStore.setCookie(cookie)
        let inSecond = await second.dataStore.httpCookieStore.allCookies().contains { $0.name == "c" }
        let inFirst = await first.dataStore.httpCookieStore.allCookies().contains { $0.name == "c" }
        check("Espaces : une connexion dans l'un n'existe pas dans l'autre", inSecond && !inFirst)
        let id = UUID()
        HistoryStore.shared.record(url: URL(string: "https://secret-travail.example/")!, title: "t", space: second.id)
        check("Espaces : historique séparé", !HistoryStore.shared.search("secret-travail", space: first.id).contains { _ in true }
              && HistoryStore.shared.search("secret-travail", space: second.id).count == 1)
        _ = id
        browser.switchSpace(by: -1)
        check("Espaces : ⌃⌘← revient", browser.currentSpace === first)
        browser.deleteSpace(second)
        check("Espaces : supprimer retire son historique", HistoryStore.shared.search("secret-travail", space: nil).isEmpty && browser.spaces.count == 1)
    }

    // MARK: Folders

    /// WCAG's contrast ratio between two opaque colors.
    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB) ?? color
            let linear = [c.redComponent, c.greenComponent, c.blueComponent].map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func testFolders() async {
        let a = await htmlTab("<title>A</title>a")
        let b = await htmlTab("<title>B</title>b")
        guard let folder = browser.addFolder(with: b) else { check("Dossiers : créer", false); return }
        browser.renamingFolderID = nil
        await sleep(0.3)
        check("Dossiers : un onglet rangé s'endort et sort de la barre", b.isAsleep && folder.tabs.first === b && browser.currentSpace.tabs.count == 1 && browser.selectedTab === a)
        await snapshot("dossier")
        browser.select(b)
        check("Dossiers : l'ouvrir le réveille sans l'en sortir", !b.isAsleep && browser.selectedTab === b && folder.tabs.first === b)
        browser.select(a)
        browser.sleepTab(b)
        check("Dossiers : « Mettre en veille » l'y rendort", b.isAsleep)
        browser.removeFromFolder(b)
        check("Dossiers : retirer le remet dans la barre", folder.tabs.isEmpty && browser.currentSpace.tabs.last === b)

        // Dropped on its chip, with the pointer.
        await sleep(0.4)
        if let start = center(of: b), let chip = browser.folderFrames[folder.id] {
            let target = CGPoint(x: chip.midX, y: chip.midY)
            await mouse(.leftMouseDown, at: start)
            await mouse(.leftMouseDragged, at: CGPoint(x: start.x - 10, y: start.y))
            await mouse(.leftMouseDragged, at: target)
            check("Dossiers : le dossier se montre comme cible", browser.carry?.dropFolder == folder.id, "départ \(start) · cible \(target) · porté \(String(describing: browser.carry))")
            await mouse(.leftMouseUp, at: target)
            check("Dossiers : glisser un onglet sur le dossier l'y range", folder.tabs.first === b)
        } else {
            check("Dossiers : mesurés", false)
        }
        folder.icon = "leaf.fill"
        let saved = SavedFolder(id: folder.id, name: folder.name, icon: folder.icon, tabs: [])
        let reread = (try? JSONEncoder().encode(saved)).flatMap { try? JSONDecoder().decode(SavedFolder.self, from: $0) }
        check("Dossiers : son icône est gardée", TabFolder(id: folder.id, name: "x", icon: reread?.icon).icon == "leaf.fill")
        check("Dossiers : une icône inconnue redevient le dossier", TabFolder(name: "x", icon: "nope").icon == TabFolder.icons[0])
        let missing = TabFolder.icons.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check("Dossiers : toutes les icônes proposées existent", missing.isEmpty, missing.joined(separator: " "))
        await snapshot("dossier-icone")
        snapshot(panel: FolderEditor(folder: folder, done: {}), "panneau-dossier")

        folder.color = .sage
        // The test's session doesn't save by itself; this one goes to its temporary folder.
        browser.isEphemeralSession = false
        browser.saveNow()
        browser.isEphemeralSession = true
        let restored = BrowserModel(kind: .main)
        if let session = StateStore.load() { restored.restore(session) }
        let restoredColor = restored.spaces.flatMap(\.folders).first { $0.id == folder.id }?.color
        check("Dossiers : sa couleur est gardée", restoredColor == .sage, restoredColor?.rawValue ?? "aucune")
        let old = #"{"id":"\#(UUID().uuidString)","name":"x","tabs":[]}"#
        check("Dossiers : sans couleur dans une ancienne session", (try? JSONDecoder().decode(SavedFolder.self, from: Data(old.utf8)))?.color == nil)
        // The chip's icon on each color, in both appearances: 4.5 is what small text asks for.
        var faint: [String] = []
        for pastel in Pastel.allCases {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                    let ratio = contrast(Theme.onAccentNS, pastel.nsColor)
                    if ratio < 4.5 { faint.append("\(pastel.rawValue) \(name.rawValue) \(ratio)") }
                }
            }
        }
        check("Dossiers : l'icône reste lisible sur chaque couleur", faint.isEmpty, faint.joined(separator: " · "))
        await snapshot("dossier-couleur")
        browser.select(b)
        await snapshot("dossier-couleur-affiche")
        browser.carryPointer.location = CGPoint(x: 900, y: 23)
        browser.carry = TabCarry(tabID: a.id, grabX: 0, width: 170, dropFolder: folder.id)
        await snapshot("dossier-couleur-cible")
        browser.carry = nil
        browser.select(a)
        browser.renamingFolderID = folder.id
        await sleep(0.5)
        let popover = NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") }
        check("Dossiers : le panneau s'ouvre sur le dossier", popover != nil)
        if let popover { await snapshot("panneau-dossier-vrai", window: popover) }
        browser.renamingFolderID = nil
        await sleep(0.3)
        let others = Pastel.allCases.filter { $0 != .sage }.prefix(3).compactMap { pastel in
            browser.addFolder().map { other in
                other.color = pastel
                other.name = pastel.label
                return other
            }
        }
        browser.renamingFolderID = nil
        await snapshot("dossier-couleurs")
        browser.window?.appearance = NSAppearance(named: .darkAqua)
        await snapshot("dossier-couleurs-sombre")
        browser.window?.appearance = nil
        others.forEach { browser.deleteFolder($0, keepingTabs: true) }

        browser.deleteFolder(folder, keepingTabs: true)
        check("Dossiers : supprimer en gardant ses onglets", browser.currentSpace.tabs.contains { $0 === b } && browser.currentSpace.folders.isEmpty)
    }

    /// The active tab is the address bar.
    private func testActiveTab() async {
        let a = await htmlTab("<title>Page claire</title><body style='background:#fff'>a", title: "Page claire")
        let b = await htmlTab("<title>Page sombre</title><body style='background:#101014;color:#eee'>b", title: "Page sombre")
        browser.select(a)
        await sleep(0.5)
        guard let frameA = browser.tabFrames[a.id], let frameB = browser.tabFrames[b.id] else {
            check("Adresse : onglets mesurés", false)
            return
        }
        check("Adresse : l'onglet actif est plus large que les autres", frameA.width > frameB.width, "\(frameA.width) · \(frameB.width)")
        check("Adresse : la barre de commande part de l'onglet actif", browser.addressFrame == frameA)
        await snapshot("onglet-actif")

        // In the middle of the tab: its text.
        await mouse(.leftMouseDown, at: CGPoint(x: frameA.minX + 60, y: frameA.midY))
        await mouse(.leftMouseUp, at: CGPoint(x: frameA.minX + 60, y: frameA.midY))
        check("Adresse : un clic sur l'onglet actif édite son adresse", browser.commandBar?.mode == .currentTab)
        await snapshot("onglet-actif-edition")
        browser.commandBar = nil
        await sleep(0.2)

        // One of the tools it carries: its own action, not the address.
        let reader = CGPoint(x: frameA.maxX - 4 - 18 - 24 - 24 - 12, y: frameA.midY)
        await mouse(.leftMouseDown, at: reader)
        await mouse(.leftMouseUp, at: reader)
        check("Adresse : un outil de l'onglet n'ouvre pas la barre de commande", browser.commandBar == nil)
        if a.reader != nil { browser.toggleReader() }
        await sleep(0.2)

        await mouse(.leftMouseDown, at: CGPoint(x: frameB.midX, y: frameB.midY))
        await mouse(.leftMouseUp, at: CGPoint(x: frameB.midX, y: frameB.midY))
        check("Adresse : un clic sur un autre onglet l'ouvre, sans éditer", browser.selectedTab === b && browser.commandBar == nil)
        await sleep(0.5)
        check("Adresse : il prend la largeur", (browser.tabFrames[b.id]?.width ?? 0) > (browser.tabFrames[a.id]?.width ?? 0))
        await snapshot("onglet-actif-autre")
    }

    /// A real right-click on a link: the menu as it opens, with a picture for each choice.
    private func testPageMenu() async {
        let page = await htmlTab("<!doctype html><title>Menu</title><body style='margin:0'><a href='https://nuri-selftest.example/autre' style='display:block;height:200px'>lien</a>", title: "Menu")
        browser.window?.makeFirstResponder(page.webView)
        await sleep(0.3)
        let point = CGPoint(x: browser.pageFrame.minX + 60, y: browser.pageFrame.minY + 60)
        var seen: [NSMenuItem] = []
        NuriWebView.menuTestHook = { menu in
            seen = menu.items
            // Long enough to be looked at, with -NuriSelfTestHoldMenu.
            let hold = UserDefaults.standard.double(forKey: "NuriSelfTestHoldMenu")
            let timer = Timer(timeInterval: max(0.3, hold), repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(timer, forMode: .common)
        }
        await mouse(.rightMouseDown, at: point, post: true)
        await mouse(.rightMouseUp, at: point, post: true)
        let opened = await until(4) { !seen.isEmpty }
        NuriWebView.menuTestHook = nil
        guard opened else {
            eventsWereInFront = false
            check("Menus : le clic droit ouvre le menu", false)
            return
        }
        await sleep(max(0.3, UserDefaults.standard.double(forKey: "NuriSelfTestHoldMenu")) + 0.2)
        let titled = seen.filter { !$0.isSeparatorItem }
        let hasIcon = { (item: NSMenuItem) in item.image != nil || item.attributedTitle?.containsAttachments(in: NSRange(location: 0, length: item.attributedTitle?.length ?? 0)) == true }
        let bare = titled.filter { !hasIcon($0) }
        check("Menus : le hublot a son icône", titled.contains { $0.action == NSSelectorFromString("openLinkInPorthole:") && hasIcon($0) })
        check("Menus : chaque choix a une icône", bare.isEmpty,
              bare.map { "\($0.title) [\($0.identifier?.rawValue ?? "?")]" }.joined(separator: " · "))

        // Its choices still act, with WebKit's own delegate behind ours: this one opens a tab, behind.
        let before = browser.currentSpace.tabs.count
        seen = []
        NuriWebView.menuTestHook = { menu in
            seen = menu.items
            let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
                menu.cancelTracking()
                if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) { menu.performActionForItem(at: index) }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        await mouse(.rightMouseDown, at: point, post: true)
        await mouse(.rightMouseUp, at: point, post: true)
        let again = await until(4) { !seen.isEmpty }
        NuriWebView.menuTestHook = nil
        let opensTab = await until(4) { browser.currentSpace.tabs.count == before + 1 }
        check("Menus : il rouvre, et un choix de WebKit ouvre son onglet derrière", again && opensTab && browser.selectedTab === page, "\(browser.currentSpace.tabs.count) onglets")
    }

    private func testCloseAll() async {
        let a = await htmlTab("<title>A</title>a")
        let b = await htmlTab("<title>B</title>b")
        let c = await htmlTab("<title>C</title>c")
        guard let folder = browser.addFolder(with: c) else { return }
        browser.renamingFolderID = nil
        browser.select(a)
        browser.closeAllTabs()
        let kept = await until(3) { browser.currentSpace.tabs.isEmpty }
        check("Fermer : tous, jamais ceux des dossiers", kept && folder.tabs.first === c && !c.isClosed)
        let d = await htmlTab("<title>D</title>d")
        let e = await htmlTab("<title>E</title>e")
        _ = b
        browser.closeAllTabs(keeping: d)
        let others = await until(3) { browser.currentSpace.tabs.count == 1 }
        check("Fermer : tous sauf celui-ci, dossiers intacts", others && browser.selectedTab === d && e.isClosed && folder.tabs.first === c)
        browser.closeAllTabs()
        let none = await until(3) { browser.currentSpace.tabs.isEmpty }
        check("Fermer : seule la page vide reste, avec le dossier", none && browser.selectedTab == nil && folder.tabs.first === c)
        browser.close(c)
        check("Fermer : un onglet de dossier se ferme quand on le demande", folder.tabs.isEmpty && c.isClosed)
        await snapshot("page-vide")
    }

    // MARK: Sound

    private static let toneHTML = """
        <!doctype html><title>Musique</title><body><audio id="a"></audio><script>
        const rate = 48000, n = rate * 30, b = new ArrayBuffer(44 + n * 2), v = new DataView(b);
        const w = (o, s) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
        w(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); w(8, 'WAVEfmt '); v.setUint32(16, 16, true);
        v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true);
        v.setUint16(32, 2, true); v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, n * 2, true);
        for (let i = 0; i < n; i++) v.setInt16(44 + i * 2, Math.sin(2 * Math.PI * 440 * i / rate) * 12000, true);
        a.src = URL.createObjectURL(new Blob([b], { type: 'audio/wav' }));
        </script>
        """

    private func play(_ tab: Tab) async -> Bool {
        let playing = try? await tab.webView?.callAsyncJavaScript("const a = document.getElementById('a'); a.volume = 0.02; await a.play(); return !a.paused;", contentWorld: .page) as? Bool
        return playing == true
    }

    private func testMute() async {
        let music = await htmlTab(Self.toneHTML, base: "https://nuri-musique.example/")
        let playing = await play(music)
        let audible = await until(3) { music.isAudible }
        check("Son : un onglet qui joue le dit", playing && audible, "lecture \(playing) · audible \(audible)")
        await snapshot("son-onglet")
        music.setMuted(true)
        check("Son : l'enceinte le coupe", music.isMuted && music.webView.map(WebKitSPI.isPageMuted) == true)
        music.setMuted(false)
        check("Son : et le remet", !music.isMuted && music.webView.map(WebKitSPI.isPageMuted) == false)
        browser.toggleMute()
        check("Son : ⌃M coupe l'onglet affiché", music.isMuted)
        music.sleepKeepingHistory()
        music.ensureWebView()
        check("Son : reste coupé après une veille", music.webView.map(WebKitSPI.isPageMuted) == true)
    }

    // MARK: Sleep

    private func testSleep() async {
        check("Veille : 30 minutes par défaut", BrowserModel.tabSleepDelay == 30 * 60)
        // A real address: a page made from a string has nothing to reload from when it wakes up.
        guard let server = LocalServer() else { check("Veille : serveur local", false); return }
        _ = await until(2) { server.port != 0 }
        let idle = browser.openTab(url: URL(string: "http://127.0.0.1:\(server.port)/long"))
        await waitForLoad(idle)
        _ = await js(idle, "window.scrollTo(0, 1200); return 1;")
        let busy = await htmlTab("<title>Saisie</title>saisie")
        busy.hasUserInput = true
        let recent = await htmlTab("<title>Récent</title>r")
        let shown = await htmlTab("<title>Affiché</title>s")
        let old = Date().addingTimeInterval(-31 * 60)
        idle.lastAccess = old
        busy.lastAccess = old
        shown.lastAccess = old
        recent.lastAccess = Date()
        browser.sleepInactiveTabs()
        let slept = await until(3) { idle.isAsleep }
        check("Veille : un onglet inactif depuis 31 min s'endort", slept)
        check("Veille : pas celui avec du texte saisi, ni le récent, ni l'affiché", !busy.isAsleep && !recent.isAsleep && !shown.isAsleep)
        check("Veille : il garde son titre et son adresse", idle.title == "Long")
        browser.select(idle)
        await waitForLoad(idle)
        let scroll = await js(idle, "return window.scrollY;") as? Double
        check("Veille : réveillé à la même place", !idle.isAsleep && abs((scroll ?? 0) - 1200) < 80, "\(scroll ?? -1)")
        recent.lastAccess = Date().addingTimeInterval(-6 * 60)
        BrowserWindows.shared.memoryPressure(critical: false)
        let pressed = await until(3) { recent.isAsleep }
        check("Veille : mémoire basse, après 5 min seulement", pressed)
    }

    // MARK: Private

    private func testPrivate() async {
        let model = BrowserWindows.shared.openPrivateWindow()
        await sleep(0.4)
        let tab = await htmlTab("<title>Secret</title>s", base: "https://nuri-prive.example/", in: model)
        check("Privé : stockage en mémoire", tab.isPrivate && tab.webView?.configuration.websiteDataStore.isPersistent == false)
        await model.currentSpace.dataStore.httpCookieStore.setCookie(HTTPCookie(properties: [.domain: "nuri-prive.example", .path: "/", .name: "p", .value: "1", .secure: "TRUE"])!)
        await sleep(0.2)
        let leak = await browser.currentSpace.dataStore.httpCookieStore.allCookies().contains { $0.name == "p" }
        check("Privé : rien ne passe dans un espace", !leak)
        tab.load(URL(string: "about:blank")!)
        HistoryStore.shared.erase(.all)
        if let url = URL(string: "https://nuri-prive.example/") {
            let delegate = tab.keepsHistory
            check("Privé : ses visites ne sont pas écrites", !delegate && HistoryStore.shared.search("nuri-prive", space: nil).isEmpty, url.absoluteString)
        }
        check("Privé : pas de dossier", model.addFolder() == nil)
        await snapshot("prive", window: model.window)
        weak var weakModel = model
        model.window?.close()
        await sleep(0.5)
        check("Privé : la fenêtre fermée détruit ses onglets", tab.isClosed && tab.webView == nil && !BrowserWindows.shared.all.contains { $0.isPrivate })
        _ = weakModel
        browser.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Address bar

    private func testCalculations() async {
        check("Calcul : 12*4+3", Calculator.answer(for: "12*4+3")?.value == "51", Calculator.answer(for: "12*4+3")?.text ?? "nil")
        check("Calcul : pourcentage", Calculator.answer(for: "20 % de 150")?.value == "30")
        check("Calcul : un nombre seul reste une recherche", Calculator.answer(for: "2026") == nil)
        func text(_ input: String) -> String? {
            if case .result(let result) = QuickConverter.answer(for: input) { return result.text }
            return nil
        }
        check("Conversion : 10 km en miles", text("10 km en miles")?.contains("mi") == true, text("10 km en miles") ?? "nil")
        check("Conversion : 72 °F en °C", text("72 °F en °C")?.contains("22") == true, text("72 °F en °C") ?? "nil")
        check("Conversion : en anglais aussi", text("10 km in miles") != nil)
        let rows = SuggestionEngine.suggestions(for: "12*4+3", browser: browser)
        check("Conversion : le résultat est dans la barre, sous la recherche", rows.contains { if case .copy("51") = $0.kind { return true } else { return false } })
    }

    private var responderName: String {
        browser.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "aucun"
    }

    /// Typing would land in a text field: AppKit's field editor has the keyboard.
    private func fieldHasFocus() async -> Bool {
        await until(1) {
            guard let editor = self.browser.window?.firstResponder as? NSTextView else { return false }
            return editor.isFieldEditor
        }
    }

    private func clickNewTabButton(post: Bool = false) async {
        let plus = CGPoint(x: browser.newTabButtonFrame.midX, y: browser.newTabButtonFrame.midY)
        await mouse(.leftMouseDown, at: plus, post: post)
        await mouse(.leftMouseUp, at: plus, post: post)
    }

    /// After the + , in every state it can be pressed in, what is typed goes in the field.
    private func testNewTabFocus() async {
        await sleep(0.5)
        check("Focus : page vide, le champ a le clavier au départ", await fieldHasFocus(), responderName)

        // As at launch, nothing else having touched the focus yet.
        await clickNewTabButton(post: true)
        await sleep(0.2)
        check("Focus : au lancement, le + donne le champ", await fieldHasFocus(), responderName)

        // The focus is elsewhere, the state saying it hasn't moved.
        browser.window?.makeFirstResponder(nil)
        await sleep(0.2)
        await clickNewTabButton()
        check("Focus : page vide, le + donne le champ", await fieldHasFocus(), responderName)

        browser.window?.makeFirstResponder(nil)
        await sleep(0.2)
        await clickNewTabButton(post: true)
        await sleep(0.2)
        check("Focus : page vide, le + (événement réel) donne le champ", await fieldHasFocus(), responderName)

        // A page closed: its web view had the keyboard.
        let page = await htmlTab("<title>Une page</title><input autofocus>", title: "Une page")
        browser.window?.makeFirstResponder(page.webView)
        await sleep(0.3)
        browser.close(page)
        await sleep(0.4)
        check("Focus : dernier onglet fermé, le champ a le clavier", await fieldHasFocus(), responderName)
        await clickNewTabButton(post: true)
        await sleep(0.2)
        check("Focus : dernier onglet fermé, le + donne le champ", await fieldHasFocus(), responderName)

        // A page whose own field is focused.
        let other = await htmlTab("<title>Autre</title><input autofocus id=i><script>i.focus()</script>", title: "Autre")
        browser.window?.makeFirstResponder(other.webView)
        await sleep(0.4)
        await clickNewTabButton(post: true)
        await sleep(0.2)
        check("Focus : page chargée, le + (événement réel) ouvre la barre", browser.commandBar?.mode == .newTab)
        check("Focus : page chargée, le + donne le champ", await fieldHasFocus(), responderName)
        let requested = browser.commandBar?.id
        await sleep(0.8)
        check("Focus : le champ le garde ensuite", await fieldHasFocus(), responderName)
        check("Focus : une seule barre", browser.commandBar?.id == requested)
        browser.commandBar = nil
        await sleep(0.2)

        // The click that brings the window forward: both the first-click path and the button answer.
        for attempt in 1...3 {
            browser.window?.makeFirstResponder(other.webView)
            await sleep(0.3)
            browser.window?.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: browser.window))
            await clickNewTabButton(post: true)
            await sleep(0.1)
            let opened = browser.commandBar?.id
            await sleep(0.4)
            check("Focus : premier clic n° \(attempt), le + ouvre une seule barre", opened != nil && browser.commandBar?.id == opened)
            check("Focus : premier clic n° \(attempt), le + donne le champ", await fieldHasFocus(), responderName)
            browser.commandBar = nil
            await sleep(0.2)
        }

        // The same click on another tab: it opens, and its address isn't being edited.
        let third = await htmlTab("<title>Troisième</title>c", title: "Troisième")
        browser.select(other)
        await sleep(0.4)
        if let center = center(of: third) {
            browser.window?.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: browser.window))
            await mouse(.leftMouseDown, at: center, post: true)
            await mouse(.leftMouseUp, at: center, post: true)
            await sleep(0.3)
            check("Focus : premier clic sur un autre onglet, il s'ouvre", browser.selectedTab === third)
            check("Focus : premier clic sur un autre onglet, sans éditer l'adresse", browser.commandBar == nil)
            browser.commandBar = nil
        }

        // The bar is up when the last tab goes: only the page's own field stays.
        browser.close(third)
        browser.showCommandBar(.newTab)
        await sleep(0.3)
        browser.close(other)
        await sleep(0.4)
        check("Focus : dernier onglet fermé, la barre s'en va", browser.commandBar == nil)
        check("Focus : dernier onglet fermé, le champ de la page a le clavier", await fieldHasFocus(), responderName)
    }

    // MARK: Extensions

    private func testExtensions() async {
        // What can be told without running anything.
        let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
        check("Extensions : l'adresse du store donne l'identifiant", ExtensionFiles.webStoreID(from: "https://chromewebstore.google.com/detail/dark-reader/\(id)?hl=fr") == id)
        check("Extensions : l'ancienne adresse aussi", ExtensionFiles.webStoreID(from: "https://chrome.google.com/webstore/detail/x/\(id)") == id)
        check("Extensions : l'identifiant seul aussi", ExtensionFiles.webStoreID(from: " \(id)\n") == id)
        check("Extensions : un autre site non", ExtensionFiles.webStoreID(from: "https://exemple.fr/detail/x/\(id)") == nil)
        check("Extensions : les versions se comparent en nombres", ExtensionFiles.isOlder("1.9.0_0", than: "1.10.0_0"))
        check("Extensions : un fichier quelconque n'est pas un paquet", ExtensionFiles.zipPayload(ofPackage: Data("PK pas un crx du tout".utf8)) == nil)
        var crx = Data("Cr24".utf8)
        crx.append(contentsOf: [3, 0, 0, 0, 2, 0, 0, 0, 0xAA, 0xBB])
        crx.append(Data("zip".utf8))
        check("Extensions : un paquet donne son zip", ExtensionFiles.zipPayload(ofPackage: crx).map { Data($0) } == Data("zip".utf8))

        guard #available(macOS 15.4, *) else {
            note("Extensions : macOS trop ancien pour la suite")
            return
        }
        let host = ExtensionHost.shared
        check("Extensions : rien d'installé, pas de contrôleur", host.controller == nil)
        let before = browser.openTab(url: nil)
        before.ensureWebView().loadHTMLString("<title>Avant</title>avant", baseURL: URL(string: "https://nuri-selftest.example/"))
        await waitForLoad(before)
        check("Extensions : sans extension, la page reste sans contrôleur", before.webView?.configuration.webExtensionController == nil)

        // A small one of our own, in a folder laid out like Chrome's.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nuri-ext-\(UUID().uuidString)", isDirectory: true)
        let fakeID = "abcdefghijklmnopabcdefghijklmnop"
        let copy = root.appendingPathComponent("Google/Chrome/Default/Extensions/\(fakeID)/1.2.0_0", isDirectory: true)
        try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let older = root.appendingPathComponent("Google/Chrome/Default/Extensions/\(fakeID)/1.1.0_0", isDirectory: true)
        try? FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"Essai Nuri","version":"1.2.0","description":"Essai",
         "permissions":["storage","tabs","webNavigation","scripting"],"host_permissions":["<all_urls>"],
         "background":{"service_worker":"background.js"},
         "action":{"default_title":"Essai","default_popup":"popup.html"},
         "options_page":"options.html",
         "content_scripts":[{"matches":["<all_urls>"],"js":["content.js"],"run_at":"document_start"}]}
        """
        let files = ["manifest.json": manifest,
                     "content.js": "document.documentElement.dataset.nuriExtension = 'oui'; document.documentElement.dataset.nuriIdle = typeof requestIdleCallback;",
                     "injected.js": "window.nuriInjected = true;",
                     "background.js": """
                     // Like Proton Pass: an API WebKit lacks, used right away, and the API globals
                     // hidden once started (extension-shim.js must keep both working).
                     chrome.runtime.onUpdateAvailable.addListener(() => {});
                     // What Bitwarden and 1Password read as they start: one missing stops them.
                     chrome.webNavigation.onCreatedNavigationTarget.addListener(() => {});
                     chrome.storage.managed.onChanged.addListener(() => {});
                     chrome.idle.onStateChanged.addListener(() => {});
                     const managers = { agent: navigator.userAgent, world: chrome.scripting.ExecutionWorld.ISOLATED, privacy: typeof chrome.privacy.services.autofillAddressEnabled.get };
                     const later = { files: ["injected.js"] };
                     setTimeout(() => { for (const name of ["chrome", "browser"]) globalThis[name] = new Proxy({}, {}); }, 0);
                     let pinged = false;
                     chrome.runtime.onMessage.addListener((message, sender, reply) => {
                       if (message && message.nuriPing) pinged = true;
                       if (message && message.kind === "pinged") { reply({ pinged }); return; }
                       if (message && message.kind === "managers") { reply(managers); return; }
                       chrome.tabs.query({}).then(tabs => reply({tabs: tabs.length, id: chrome.runtime.id}));
                       return true;
                     });
                     """,
                     // A popup isn't in a tab: Chrome's answer, which extensions rely on to size it.
                     "popup.html": "<!doctype html><title>Essai</title><body style='width:220px;height:120px'>Essai<script src=popup.js></script></body>",
                     "popup.js": "chrome.tabs.getCurrent().then((tab) => { document.title = 'popup:' + (tab ? 'onglet' : 'aucun'); });",
                     "options.html": "<!doctype html><title>Options essai</title><a id=out href='https://nuri-selftest.example/'>out</a>"]
        for (name, text) in files { try? text.write(to: copy.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try? manifest.write(to: older.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let found = ExtensionFiles.findInBrowsers(root: root)
        check("Extensions : retrouvée dans le dossier de Chrome", found.first?.id == fakeID && found.count == 1, "\(found.map(\.id))")
        check("Extensions : sa dernière version", found.first?.version == "1.2.0_0", found.first?.version ?? "")
        check("Extensions : sait de quel navigateur elle vient", found.first?.browser == "Google Chrome" && found.first?.profile == "Default")

        guard let source = found.first?.folder else { return }
        do {
            let added = try await host.add(from: source, id: fakeID, source: .browser, asks: false)
            check("Extensions : ajoutée", added && host.installed.contains { $0.id == fakeID && $0.name == "Essai Nuri" && $0.version == "1.2.0" })
        } catch {
            check("Extensions : ajoutée", false, "\(error)")
            return
        }
        check("Extensions : copiée chez Nuri", FileManager.default.fileExists(atPath: ExtensionFiles.folder(of: fakeID).appendingPathComponent("manifest.json").path))
        check("Extensions : gardée pour le prochain lancement", ExtensionFiles.loadRecords().contains { $0.id == fakeID })
        let copied = ExtensionFiles.folder(of: fakeID)
        let readCopy = { (name: String) in (try? String(contentsOf: copied.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        check("Extensions : le shim d'abord dans l'arrière-plan", readCopy("nuri-background.js").contains("importScripts(\"/nuri-shim.js\", \"/background.js\")"), readCopy("nuri-background.js"))
        check("Extensions : le shim d'abord dans ses pages", readCopy("popup.html").contains("<script src=\"/nuri-shim.js\"></script>"))
        check("Extensions : le shim d'abord dans un script qu'elle injecte", readCopy("injected.js").hasPrefix("/*nuri-shim:start*/"))
        check("Extensions : l'original n'est pas touché", (try? String(contentsOf: copy.appendingPathComponent("popup.html"), encoding: .utf8))?.contains("nuri-shim") == false)
        let stampedManifest = readCopy("manifest.json")
        ExtensionFiles.addShims(to: copied)
        check("Extensions : le shim une seule fois", readCopy("manifest.json") == stampedManifest && readCopy("injected.js").components(separatedBy: "/*nuri-shim:start*/").count == 2)
        if let context = host.running.first(where: { $0.record.id == fakeID })?.context {
            check("Extensions : son service worker répond, malgré ses globales masquées", await host.backgroundAnswers(context))
            host.remember(permissions: ["bookmarks"], sites: ["https://exemple.fr/*"], for: context)
            let kept = ExtensionFiles.loadRecords().first { $0.id == fakeID }
            check("Extensions : ce qu'elle obtient plus tard est gardé", kept?.laterPermissions == ["bookmarks"] && kept?.laterSites == ["https://exemple.fr/*"])
        }
        check("Extensions : tourne", host.running.contains { $0.record.id == fakeID }, host.problems[fakeID] ?? "")
        check("Extensions : l'onglet ouvert avant la reçoit", before.webView?.configuration.webExtensionController != nil)
        await waitForLoad(before)

        // Its script in a page.
        let page = browser.openTab(url: URL(string: "https://example.com/"))
        await waitForLoad(page)
        let mark = try? await page.webView?.evaluateJavaScript("document.documentElement.dataset.nuriExtension")
        check("Extensions : son script entre dans les pages", (mark as? String) == "oui", "\(String(describing: mark))")
        let idle = try? await page.webView?.evaluateJavaScript("document.documentElement.dataset.nuriIdle")
        check("Extensions : requestIdleCallback dans ses scripts", (idle as? String) == "function", "\(String(describing: idle))")
        await snapshot("extensions-page")

        // Private windows stay out of it.
        let privateWindow = BrowserWindows.shared.openPrivateWindow()
        let hidden = privateWindow.openTab(url: URL(string: "https://example.com/"))
        await waitForLoad(hidden)
        let privateMark = try? await hidden.webView?.evaluateJavaScript("document.documentElement.dataset.nuriExtension")
        check("Extensions : jamais dans une fenêtre privée", hidden.webView?.configuration.webExtensionController == nil && (privateMark as? String) != "oui")
        privateWindow.window?.close()
        await sleep(0.3)
        browser.window?.makeKeyAndOrderFront(nil)

        // Its background and its idea of the tabs, asked from one of its own pages.
        host.openOptions(fakeID, in: browser)
        guard let options = browser.selectedTab else { return }
        await waitForLoad(options)
        check("Extensions : ses options s'ouvrent dans un onglet", Extensions.isExtensionPage(options.url) && options.webView?.url?.host() == fakeID, options.webView?.url?.absoluteString ?? "nil")
        check("Extensions : son nom dans la barre", options.addressText == "Essai Nuri", options.addressText)
        let answer = try? await options.webView?.callAsyncJavaScript("return await chrome.runtime.sendMessage({})", contentWorld: .page) as? [String: Any]
        check("Extensions : son arrière-plan répond, et voit les onglets", (answer?["tabs"] as? Int ?? 0) >= 2 && answer?["id"] as? String == fakeID, "\(String(describing: answer))")

        let seen = try? await options.webView?.callAsyncJavaScript("return await chrome.runtime.sendMessage({kind: 'pinged'})", contentWorld: .page) as? [String: Any]
        check("Extensions : ses écouteurs ne voient pas le contrôle de Nuri", seen?["pinged"] as? Bool == false, "\(String(describing: seen))")

        let managers = try? await options.webView?.callAsyncJavaScript("return await chrome.runtime.sendMessage({kind: 'managers'})", contentWorld: .page) as? [String: Any]
        check("Extensions : ce que lisent les gestionnaires de mots de passe au démarrage est là",
              (managers?["agent"] as? String)?.contains(" Chrome/") == true && managers?["world"] as? String == "ISOLATED" && managers?["privacy"] as? String == "function",
              "\(String(describing: managers))")
        let unknown = try? await options.webView?.callAsyncJavaScript("return await chrome.permissions.contains({permissions: ['privacy']})", contentWorld: .page) as? Bool
        check("Extensions : une permission inconnue de WebKit ne lève pas d'erreur", unknown == true, "\(String(describing: unknown))")

        // From its page back to the web: the tab changes web view.
        options.load(URL(string: "https://example.com/")!)
        await waitForLoad(options)
        check("Extensions : retour au web dans le même onglet", options.webView?.url?.host() == "example.com", options.webView?.url?.absoluteString ?? "nil")
        check("Extensions : ses pages n'entrent pas dans l'historique", !HistoryStore.shared.search("Options essai", space: browser.currentSpaceID, limit: 5).contains { Extensions.isExtensionPage($0.url) })

        // Its button: the popup, under the bar's button.
        browser.select(page)
        await sleep(0.4)
        host.performAction(fakeID, in: browser)
        check("Extensions : son bouton ouvre sa fenêtre", await until(12) { host.shownPopover?.isShown == true }, "\(host.revivals) relance(s), \(NSStringFromSize(host.shownPopover?.contentSize ?? .zero))")
        check("Extensions : sa fenêtre sait qu'elle n'est pas un onglet", await until(3) { host.shownPopupWebView?.title == "popup:aucun" }, host.shownPopupWebView?.title ?? "nil")
        check("Extensions : pas de relance sans raison", host.revivals == 0, "\(host.revivals)")
        if let popover = host.shownPopover {
            let before = popover.contentSize
            await sleep(0.2)
            check("Extensions : sa page remplit la fenêtre", host.shownPopupWebView?.frame.size == before, "\(NSStringFromSize(host.shownPopupWebView?.frame.size ?? .zero)) · \(NSStringFromSize(before))")
        }
        snapshot(panel: ExtensionsPanel(close: {}), "extensions-panneau")
        await sleep(0.4)
        host.shownPopover?.performClose(nil)
        await sleep(0.3)

        // Pinned: its own button in the bar, kept in extensions.json, and its popup hangs from it.
        host.setPinned(true, for: fakeID)
        check("Extensions : épinglée, gardée", ExtensionFiles.loadRecords().first { $0.id == fakeID }?.pinned == true)
        let pinnedFrame = await until(3) { !(browser.pinnedExtensionFrames[fakeID] ?? .zero).isEmpty } ? browser.pinnedExtensionFrames[fakeID]! : .zero
        check("Extensions : épinglée, son bouton avant celui des extensions", !pinnedFrame.isEmpty && pinnedFrame.maxX <= browser.extensionsButtonFrame.minX,
              "\(NSStringFromRect(pinnedFrame)) · \(NSStringFromRect(browser.extensionsButtonFrame))")
        await snapshot("extensions-epinglee")
        snapshot(panel: ExtensionsPanel(close: {}), "extensions-panneau-epinglee")
        host.performAction(fakeID, in: browser)
        let hung = await until(12) { host.shownPopover?.isShown == true }
        let from = host.shownPopover?.positioningRect ?? .zero
        check("Extensions : épinglée, sa fenêtre part de son bouton", hung && abs(from.midX - pinnedFrame.midX) < 1, "\(NSStringFromRect(from)) · \(NSStringFromRect(pinnedFrame))")
        host.shownPopover?.performClose(nil)
        await sleep(0.3)
        host.setPinned(false, for: fakeID)
        check("Extensions : désépinglée, plus de bouton", await until(3) { browser.pinnedExtensionFrames[fakeID] == nil } && ExtensionFiles.loadRecords().first { $0.id == fakeID }?.pinned == nil)

        // Turned off, it stops.
        host.setEnabled(false, for: fakeID)
        check("Extensions : désactivée, ne tourne plus", !host.running.contains { $0.record.id == fakeID })
        page.load(URL(string: "https://example.com/?2")!)
        await waitForLoad(page)
        let off = try? await page.webView?.evaluateJavaScript("document.documentElement.dataset.nuriExtension")
        check("Extensions : désactivée, plus de script", (off as? String) != "oui")
        host.setEnabled(true, for: fakeID)
        check("Extensions : réactivée", await until(4) { host.running.contains { $0.record.id == fakeID } })

        host.remove(fakeID)
        check("Extensions : retirée, plus rien", !host.installed.contains { $0.id == fakeID } && !FileManager.default.fileExists(atPath: ExtensionFiles.folder(of: fakeID).path))
        try? FileManager.default.removeItem(at: root)

        // Real ones, from the store. Which of them run says what can be promised.
        let real = UserDefaults.standard.string(forKey: "NuriSelfTestStore")?.split(separator: ",").map(String.init) ?? []
        for storeID in real {
            await host.addFromStore(id: storeID, in: nil, asks: false)
            let record = host.installed.first { $0.id == storeID }
            let running = host.running.contains { $0.record.id == storeID }
            let webExtension = host.webExtension(storeID)
            let errors = webExtension?.errors.map(\.localizedDescription).joined(separator: " | ") ?? ""
            check("Store : \(record?.name ?? storeID) \(record?.version ?? "")", running,
                  "manifeste \(webExtension?.manifestVersion ?? 0) · \(errors.isEmpty ? "sans erreur" : errors) · \(host.problems[storeID] ?? "")")
            if running {
                let tab = browser.openTab(url: URL(string: "https://example.com/?\(storeID)"))
                await waitForLoad(tab)
                check("Store : \(record?.name ?? storeID), la page charge", tab.loadError == nil && tab.webView?.url?.host() == "example.com")
                browser.close(tab)
                await sleep(0.8)
                let context = host.running.first { $0.record.id == storeID }?.context
                // Past the moment WebKit loses service workers.
                await sleep(12)
                // Its popup, looked at.
                let shown = browser.openTab(url: URL(string: "https://example.com/"))
                await waitForLoad(shown)
                host.performAction(storeID, in: browser)
                let opened = await until(12) { host.shownPopover?.isShown == true }
                await sleep(2.5)
                savePopupPicture(host.shownPopupWebView, storeID)
                let popupText = await host.shownPopupWebView?.nuriCall("return document.body.innerText;", world: .page, timeout: 3) as? String
                note("Store : \(record?.name ?? storeID) — fenêtre \(opened ? "ouverte" : "non"), \(NSStringFromSize(host.shownPopover?.contentSize ?? .zero)), \(host.revivals) relance(s) — \(popupText?.prefix(160).replacingOccurrences(of: "\n", with: " / ") ?? "nil")")
                note("Store : \(record?.name ?? storeID) — erreurs : \(context?.errors.map(\.localizedDescription).joined(separator: " | ").prefix(260) ?? "")")
                host.shownPopover?.performClose(nil)
                await sleep(0.5)
                // Pinned, its icon as a glyph in the bar.
                host.setPinned(true, for: storeID)
                await sleep(0.5)
                await snapshot("store-epinglee-\(storeID.prefix(6))")
                let monochrome = AppSettings.shared.monochromeExtensions
                AppSettings.shared.monochromeExtensions.toggle()
                await sleep(0.3)
                await snapshot("store-epinglee-\(monochrome ? "couleur" : "mono")-\(storeID.prefix(6))")
                AppSettings.shared.monochromeExtensions = monochrome
                host.setPinned(false, for: storeID)
                browser.close(shown)
            }
            host.remove(storeID)
        }
    }

    private func savePopupPicture(_ popup: WKWebView?, _ id: String) {
        let path = (outputPath as NSString).deletingPathExtension + "-popup-\(id.prefix(6)).png"
        popup?.takeSnapshot(with: nil) { image, _ in
            guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Over two launches, with `-NuriSelfTestDir`: the first adds what `-NuriSelfTestStore` names,
    /// the second finds it loaded at launch, which is when WebKit loses service workers.
    private func testExtensionsAtLaunch() async {
        guard #available(macOS 15.4, *), SelfTestRunner.keptDirectory != nil else { return }
        let host = ExtensionHost.shared
        if host.installed.isEmpty {
            for id in UserDefaults.standard.string(forKey: "NuriSelfTestStore")?.split(separator: ",").map(String.init) ?? [] {
                await host.addFromStore(id: id, in: nil, asks: false)
            }
            await sleep(3)
            note("Lancement : \(host.installed.map(\.name)) ajoutées, à relancer")
            return
        }
        _ = browser.openTab(url: URL(string: "https://example.com/"))
        await sleep(16)
        note("Lancement : \(host.revivals) relance(s) après 16 s")
        for item in host.running {
            let name = item.record.name
            for round in 1...2 {
                host.performAction(item.record.id, in: browser)
                check("Lancement : \(name), fenêtre ouverte (\(round))", await until(14) { host.shownPopover?.isShown == true }, "\(host.revivals) relance(s)")
                await sleep(2.5)
                let text = await host.shownPopupWebView?.nuriCall("return document.body.innerText;", world: .page, timeout: 3) as? String
                check("Lancement : \(name), toujours ouverte, avec du contenu (\(round))", host.shownPopover?.isShown == true && text?.isEmpty == false,
                      "\(text?.prefix(120).replacingOccurrences(of: "\n", with: " / ") ?? "nil") · \(host.revivals) relance(s) · \(item.context.errors.map(\.localizedDescription).joined(separator: " | ").prefix(200))")
                savePopupPicture(host.shownPopupWebView, item.record.id)
                await sleep(0.5)
                host.shownPopover?.performClose(nil)
                await sleep(1)
            }
            host.remove(item.record.id)
        }
        ExtensionFiles.save([])
    }

    /// A page in the window for a while, for a look with the real pointer and keyboard (which no
    /// simulated event replaces): every change of first responder is written in the report.
    private func testHold() async {
        let seconds = UserDefaults.standard.double(forKey: "NuriSelfTestHold")
        guard seconds > 0 else { return }
        if #available(macOS 15.4, *), let id = UserDefaults.standard.string(forKey: "NuriSelfTestHoldExtension") {
            await ExtensionHost.shared.addFromStore(id: id, in: nil, asks: false)
        }
        _ = await htmlTab("<!doctype html><title>Essai</title><body style='background:#fff'><h1>Essai</h1>", title: "Essai")
        var last = ""
        var shown: String?
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            let now = "\(responderName) · barre \(browser.commandBar != nil) · clé \(browser.window?.isKeyWindow == true)"
            if now != last {
                last = now
                note(String(format: "%.2f s : %@", Date().timeIntervalSince(start), now))
            }
            if let editor = browser.window?.firstResponder as? NSTextView, editor.string != shown {
                shown = editor.string
                note("texte : \(editor.string)")
            }
            await sleep(0.02)
        }
    }

    private func testCommandBar() async {
        let titles = { (text: String) in SuggestionEngine.suggestions(for: text, browser: self.browser).map(\.title) }
        let shortcuts = L("Raccourcis clavier", "Keyboard Shortcuts")
        check("Commandes : « shortcuts » propose les raccourcis", titles("shortcuts").contains(shortcuts))
        check("Commandes : « raccourcis » aussi", titles("raccourcis").contains(shortcuts))
        check("Commandes : « histo » propose l'historique", titles("histo").contains(L("Afficher l'historique", "Show History")))
        let tab = await htmlTab("<title>Planète Mars</title>m")
        _ = await htmlTab("<title>Autre</title>o")
        let rows = SuggestionEngine.suggestions(for: "planète", browser: browser)
        check("Commandes : retrouve un onglet ouvert", rows.contains { if case .switchTo(let t) = $0.kind { return t === tab } else { return false } })
        browser.showCommandBar(.newTab)
        await sleep(0.3)
        check("Commandes : ⌘T ouvre la barre", browser.commandBar?.mode == .newTab)
        check("Commandes : ⌘T donne le champ, prêt à taper", await fieldHasFocus(), responderName)
        await snapshot("barre-commande")
        browser.commandBar = nil
        browser.showCommandBar(.currentTab)
        await sleep(0.3)
        check("Commandes : ⌘L donne le champ, prêt à taper", await fieldHasFocus(), responderName)
        await snapshot("barre-adresse-etendue")
        browser.commandBar = nil
        await sleep(0.2)

        // A real click on the +, from a page that holds the focus.
        browser.window?.makeFirstResponder(browser.selectedTab?.webView)
        await sleep(0.3)
        let plus = CGPoint(x: browser.newTabButtonFrame.midX, y: browser.newTabButtonFrame.midY)
        await mouse(.leftMouseDown, at: plus)
        await mouse(.leftMouseUp, at: plus)
        check("Commandes : le + ouvre la barre", await until { self.browser.commandBar?.mode == .newTab })
        check("Commandes : le + donne le champ, prêt à taper", await fieldHasFocus(), responderName)
        browser.commandBar = nil
        await sleep(0.2)

        // The same click on the active tab.
        if let frame = browser.selectedTab.flatMap({ browser.tabFrames[$0.id] }) {
            browser.window?.makeFirstResponder(browser.selectedTab?.webView)
            await sleep(0.3)
            let point = CGPoint(x: frame.minX + 60, y: frame.midY)
            await mouse(.leftMouseDown, at: point)
            await mouse(.leftMouseUp, at: point)
            check("Commandes : un clic sur l'onglet actif donne le champ", await fieldHasFocus(), responderName)
            browser.commandBar = nil
            await sleep(0.2)
        }
        browser.navigate("trou noir", mode: .currentTab)
        check("Commandes : du texte devient une recherche", browser.selectedTab?.url?.absoluteString.contains("trou%20noir") == true, browser.selectedTab?.url?.absoluteString ?? "nil")
        browser.selectedTab?.webView?.stopLoading()
        await testCommandBarVeil()
    }

    /// The window's brightness at a place of the bar with nothing on it: the veil is all that changes it.
    private func chromeBrightness() -> CGFloat? {
        guard let view = browser.window?.contentView else { return nil }
        let y = view.isFlipped ? Metrics.topBarHeight / 2 : view.bounds.height - Metrics.topBarHeight / 2
        // Two points only: rendering the whole window takes longer than the fade it is timing.
        let spot = NSRect(x: browser.newTabButtonFrame.maxX + 60, y: y, width: 2, height: 2)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: spot) else { return nil }
        view.cacheDisplay(in: spot, to: rep)
        return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)?.brightnessComponent
    }

    /// What it is at each moment, for `seconds`.
    private func brightnessOverTime(_ seconds: Double) async -> [CGFloat] {
        var values: [CGFloat] = []
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if let value = chromeBrightness() { values.append(value) }
            await sleep(0.02)
        }
        return values
    }

    private func testCommandBarVeil() async {
        // Fading, and how much it darkens, in each appearance.
        for (name, appearance, range) in [("clair", NSAppearance.Name.aqua, 0.07...0.17), ("sombre", .darkAqua, 0.19...0.31)] {
            browser.window?.appearance = NSAppearance(named: appearance)
            await sleep(0.3)
            guard let clear = chromeBrightness() else { check("Voile : lecture de la fenêtre", false); continue }
            browser.showCommandBar(.newTab)
            let coming = await brightnessOverTime(0.3)
            let dimmed = coming.last ?? clear
            check("Voile (\(name)) : assombrit la fenêtre", range.contains(Double(1 - dimmed / clear)),
                  String(format: "%.3f → %.3f", clear, dimmed))
            check("Voile (\(name)) : arrive en douceur", coming.contains { $0 < clear - 0.005 && $0 > dimmed + 0.005 },
                  coming.map { String(format: "%.3f", $0) }.joined(separator: " "))
            await snapshot("barre-voile-\(name)")
            browser.commandBar = nil
            let leaving = await brightnessOverTime(0.3)
            check("Voile (\(name)) : s'en va en douceur", leaving.contains { $0 < clear - 0.005 && $0 > dimmed + 0.005 },
                  leaving.map { String(format: "%.3f", $0) }.joined(separator: " "))
            check("Voile (\(name)) : ne laisse aucune trace", abs((leaving.last ?? 0) - clear) < 0.005,
                  String(format: "%.3f → %.3f", clear, leaving.last ?? 0))
            var alpha: CGFloat = 0
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                alpha = NSColor(Theme.commandBarCard).usingColorSpace(.sRGB)?.alphaComponent ?? 0
            }
            check("Voile (\(name)) : la carte de la barre est opaque", alpha == 1, "\(alpha)")
        }
        browser.window?.appearance = nil
        await sleep(0.3)

        let other = await htmlTab("<title>Autre</title>o")
        let tab = await htmlTab("""
            <!doctype html><title>Voile</title><body style="height:100vh;margin:0" onclick="window.nuriClicks = (window.nuriClicks || 0) + 1">
            """)
        // In the page's world, where its onclick counts: `js` runs in Nuri's own.
        let clicks = { () async -> Int in
            let value = try? await tab.webView?.callAsyncJavaScript("return window.nuriClicks || 0", contentWorld: .page)
            return (value as? NSNumber)?.intValue ?? -1
        }
        // A page gets its events a moment later.
        let clicksReach = { (expected: Int) async -> Int in
            for _ in 0..<10 {
                let count = await clicks()
                if count == expected { return count }
                await self.sleep(0.1)
            }
            return await clicks()
        }
        let click = { (point: CGPoint) in
            await self.mouse(.leftMouseDown, at: point)
            await self.mouse(.leftMouseUp, at: point)
        }
        let page = browser.pageFrame
        let outside = CGPoint(x: page.midX, y: page.maxY - 60)
        browser.window?.makeFirstResponder(tab.webView)
        await click(outside)
        var count = await clicksReach(1)
        check("Voile : sans la barre, un clic va à la page", count == 1, "\(count)")

        browser.showCommandBar(.newTab)
        await sleep(0.3)
        await click(outside)
        check("Voile : un clic hors de la barre la ferme", await until(1) { self.browser.commandBar == nil })
        await sleep(0.5)
        count = await clicks()
        check("Voile : ce clic n'atteint pas la page", count == 1, "\(count)")

        // Right away, the veil still fading out.
        browser.showCommandBar(.newTab)
        await sleep(0.3)
        await click(outside)
        _ = await until(1) { self.browser.commandBar == nil }
        await click(outside)
        count = await clicksReach(2)
        check("Voile : pendant qu'il s'efface, un clic va à la page", count == 2, "\(count)")

        browser.showCommandBar(.currentTab)
        await sleep(0.3)
        await click(outside)
        check("Voile : ⌘L, un clic hors de la barre la ferme", await until(1) { self.browser.commandBar == nil })
        await sleep(0.3)

        // On a tab: the bar goes, and that is all that click does.
        if let frame = browser.tabFrames[other.id] {
            browser.showCommandBar(.newTab)
            await sleep(0.3)
            await click(CGPoint(x: frame.midX, y: frame.midY))
            check("Voile : un clic sur un autre onglet ferme la barre", await until(1) { self.browser.commandBar == nil })
            check("Voile : sans changer d'onglet", browser.selectedTab === tab)
            await sleep(0.3)
        }

        // In the card: the bar stays, with its field.
        browser.showCommandBar(.newTab)
        await sleep(0.3)
        let field = CGPoint(x: page.midX, y: ((browser.window?.contentView?.bounds.height ?? 0)) / 2)
        await click(field)
        await sleep(0.2)
        check("Voile : un clic dans la barre la laisse ouverte", browser.commandBar != nil)
        check("Voile : la barre garde le clavier", await fieldHasFocus(), responderName)

        // Esc.
        if let window = browser.window, let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                   windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            window.sendEvent(esc)
        }
        check("Voile : Échap ferme la barre", await until(1) { self.browser.commandBar == nil })
        check("Voile : la page reprend le clavier", browser.window?.firstResponder === tab.webView, responderName)
        await sleep(0.3)
        await click(outside)
        count = await clicksReach(3)
        check("Voile : ensuite, un clic va à la page", count == 3, "\(count)")
    }

    // MARK: Reader

    private func testReader() async {
        let paragraphs = (0..<30).map { "<p>Paragraphe \($0) de cet article assez long pour que le mode lecture le reconnaisse comme un vrai texte à lire, avec des phrases entières et de la ponctuation.</p>" }.joined()
        let tab = await htmlTab("""
            <!doctype html><html><head><title>Un article</title></head><body>
            <nav>menu menu menu</nav><article><h1>Un article</h1>
            <img data-src="https://nuri-selftest.example/tardive.jpg" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" width="600" height="400" alt="image">
            \(paragraphs)</article><footer>pied de page</footer></body></html>
            """)
        ReaderMode.toggle(tab)
        let opened = await until(4) { tab.reader != nil }
        check("Lecture : l'article est extrait", opened && tab.reader?.html.contains("Paragraphe 12") == true)
        check("Lecture : sans le menu ni le pied de page", tab.reader?.html.contains("menu menu") == false && tab.reader?.html.contains("pied de page") == false)
        check("Lecture : image chargée tardivement comprise", tab.reader?.html.contains("tardive.jpg") == true)
        if let article = tab.reader {
            let small = ReaderMode.document(for: article, fontScale: 1)
            let large = ReaderMode.document(for: article, fontScale: 1.3)
            check("Lecture : affichage sans JavaScript, taille réglable", small.contains("default-src 'none'") && !small.contains("<script") && large.contains("font: 24px"), "")
        }
        await snapshot("lecture")
        tab.reader = nil
        check("Lecture : on en sort", tab.reader == nil)
    }

    // MARK: Bookmarks

    private func testBookmarks() async {
        let store = BookmarkStore.shared
        let tab = await htmlTab("<title>Mars</title>m", base: "https://nuri-selftest.example/mars")
        browser.bookmarkCurrentPage()
        guard let bookmark = store.bookmark(for: tab.url, space: browser.currentSpaceID) else {
            check("Signets : ⌘D garde la page", false, tab.url?.absoluteString ?? "nil")
            return
        }
        browser.editingBookmark = false
        check("Signets : ⌘D garde la page, avec son titre", bookmark.title == "Mars")
        browser.bookmarkCurrentPage()
        browser.editingBookmark = false
        check("Signets : une seule fois", store.items.filter { $0.url == bookmark.url }.count == 1)
        let rows = SuggestionEngine.suggestions(for: "mars", browser: browser)
        check("Signets : retrouvé dans la barre de commande", rows.contains { $0.title == "Mars" }, rows.map(\.title).joined(separator: " · "))
        store.setFavorite(bookmark.id, true)
        check("Signets : un favori se montre à part", store.favorites(space: browser.currentSpaceID).count == 1 && store.bookmarks(space: browser.currentSpaceID).isEmpty)
        check("Signets : la barre vide propose les favoris", SuggestionEngine.suggestions(for: "", browser: browser).map(\.title) == ["Mars"])
        store.rename(bookmark.id, to: "Planète")
        browser.open(store.favorites(space: browser.currentSpaceID)[0])
        check("Signets : ouvrir retrouve l'onglet déjà ouvert", browser.currentSpace.tabs.count == 1 && browser.selectedTab === tab)
        browser.close(tab)
        await sleep(0.3)
        await snapshot("page-vide-favoris")
        browser.open(store.favorites(space: browser.currentSpaceID)[0])
        check("Signets : sinon un nouvel onglet", browser.currentSpace.tabs.count == 1 && browser.selectedTab?.url == bookmark.url)
        let raw = try? JSONDecoder().decode([Lossy<Bookmark>].self, from: Data(contentsOf: StateStore.directory.appendingPathComponent("bookmarks.json")))
        check("Signets : gardés sur le disque", raw?.compactMap(\.value).first?.title == "Planète")
        let space = browser.addSpace(name: "Autre")
        store.add(url: bookmark.url, title: "Ailleurs", favicon: nil, space: space.id)
        check("Signets : chaque espace a les siens", store.items.filter { $0.url == bookmark.url }.count == 2)
        browser.deleteSpace(space)
        check("Signets : supprimer un espace emporte les siens", store.items.filter { $0.url == bookmark.url }.count == 1)
        store.remove(bookmark.id)
        check("Signets : supprimer", store.items.isEmpty)
    }

    // MARK: History

    private func testHistory() async {
        let store = HistoryStore.shared
        let space = browser.currentSpaceID
        store.erase(.all)
        let now = Date()
        for (name, age) in [("h", 1800.0), ("j", 7200), ("m", 2 * 86_400), ("a", 40 * 86_400), ("v", 366 * 86_400)] {
            store.record(url: URL(string: "https://\(name).nuri-selftest.example/")!, title: name, space: space, at: now.addingTimeInterval(-age))
        }
        let count = { store.search("nuri-selftest", space: nil, limit: 50).count }
        check("Historique : les visites sont là", count() == 5, "\(count())")
        store.erase(.hour, now: now)
        check("Historique : effacer la dernière heure", count() == 4 && store.search("h.nuri", space: nil).isEmpty)
        store.erase(.day, now: now)
        check("Historique : le dernier jour", count() == 3)
        store.erase(.month, now: now)
        check("Historique : les 30 derniers jours", count() == 2)
        store.erase(.year, now: now)
        check("Historique : la dernière année", count() == 1)
        store.erase(.all)
        check("Historique : tout", count() == 0)
        let tab = await htmlTab("<title>Visite</title>v")
        tab.url = URL(string: "https://nuri-selftest.example/")
        store.record(url: tab.url!, title: "Visite", space: space)
        store.delete(store.search("nuri-selftest", space: space)[0])
        check("Historique : retirer une page", count() == 0)
        HistoryWindow.show(for: browser)
        await sleep(0.5)
        let window = NSApp.windows.first { $0.title == L("Historique", "History") }
        check("Historique : sa fenêtre s'ouvre", window != nil)
        if let window { await snapshot("historique", window: window) }
        window?.close()
        browser.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Downloads

    /// A small local server: /file.bin (attachment) slowly enough to see it go.
    private final class LocalServer {
        let listener: NWListener
        var port: UInt16 { listener.port?.rawValue ?? 0 }
        /// The Referer of the last /echo.
        private(set) var lastReferer: String?
        init?() {
            guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    if request.hasPrefix("GET /echo") {
                        self?.lastReferer = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("referer:") }?.dropFirst(8).trimmingCharacters(in: .whitespaces)
                    }
                    if request.hasPrefix("GET /long") || request.hasPrefix("GET /echo") {
                        let html = Data("<!doctype html><title>Long</title><body style='height:5000px'>long".utf8)
                        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.count)\r\nConnection: close\r\n\r\n"
                        connection.send(content: Data(head.utf8) + html, completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    let body = Data(repeating: 0x2A, count: 200_000)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"nuri ../test.bin\"\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: .global())
        }
        deinit { listener.cancel() }
    }

    private func testDownloads() async {
        guard let server = LocalServer() else { check("Téléchargements : serveur local", false); return }
        _ = await until(2) { server.port != 0 }
        let page = await htmlTab("<title>Page</title>p")
        let manager = DownloadManager.shared
        let before = manager.items.count
        let tab = browser.openTab(url: URL(string: "http://127.0.0.1:\(server.port)/file.bin"), background: true, after: page)
        let started = await until(5) { manager.items.count == before + 1 }
        check("Téléchargements : un fichier joint devient un téléchargement", started)
        guard started, let item = manager.items.first else { return }
        let finished = await until(10) { item.state == .finished }
        check("Téléchargements : il se termine", finished, "\(item.state)")
        let file = item.destination
        check("Téléchargements : dans le dossier choisi, nom nettoyé", file?.deletingLastPathComponent().standardizedFileURL == Self.downloads.standardizedFileURL
              && file.map { !$0.lastPathComponent.contains("/") } == true && file.map { FileManager.default.fileExists(atPath: $0.path) } == true, file?.path ?? "nil")
        check("Téléchargements : taille exacte", item.receivedBytes == 200_000 || (file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) == 200_000, "\(item.receivedBytes)")
        var url = file
        let quarantine = (try? url?.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        check("Téléchargements : mis en quarantaine (Gatekeeper le vérifiera)", quarantine != nil)
        url = nil
        check("Téléchargements : l'onglet ouvert pour le fichier se referme", tab.isClosed)
        browser.showingDownloads = true
        await snapshot("telechargements")
        browser.showingDownloads = false
        check("Téléchargements : plus d'anneau ni de vitesse une fois terminé", manager.progress(for: browser) == nil && manager.speedLabel(for: browser) == nil)
        let measured = DownloadItem(filename: "vitesse", sourceURL: nil, browser: browser)
        measured.update(received: 0, total: 1_000)
        await sleep(0.6)
        measured.update(received: 500, total: 1_000)
        let speed = measured.bytesPerSecond
        measured.noteStall()
        let keptWhileMoving = measured.bytesPerSecond == speed
        measured.noteStall(now: Date().addingTimeInterval(10))
        check("Téléchargements : la vitesse retombe à zéro si plus rien n'arrive", speed > 0 && keptWhileMoving && measured.bytesPerSecond == 0, "\(speed)")
        manager.clearFinished()
        check("Téléchargements : « Effacer » vide la liste", !manager.items.contains { $0 === item })
        if let file { try? FileManager.default.removeItem(at: file) }
        check("Téléchargements : nom piégé désamorcé", DownloadManager.sanitizedFilename("facture\u{202E}fdp.app") == "facturefdp.app"
              && !DownloadManager.sanitizedFilename(".cache").hasPrefix(".") && !DownloadManager.sanitizedFilename("a/b").contains("/"))
    }

    private func testPlainHTTP() async {
        let security = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]
        check("HTTP : permis aux pages web, pas aux requêtes de Nuri",
              security?["NSAllowsArbitraryLoadsInWebContent"] as? Bool == true && security?["NSAllowsArbitraryLoads"] == nil)
        let site = "http://info.cern.ch/"
        check("HTTP : l'avertissement vaut pour Internet, pas pour le réseau local ni HTTPS",
              PlainHTTP.needsWarning(URL(string: site), in: browser)
              && !PlainHTTP.needsWarning(URL(string: "https://info.cern.ch/"), in: browser)
              && !PlainHTTP.needsWarning(URL(string: "http://192.168.1.1/"), in: browser)
              && !PlainHTTP.needsWarning(URL(string: "http://localhost:3000/"), in: browser))
        check("Réseau local : un nom public qui commence par une adresse privée reste sur Internet",
              !LocalNetwork.isLocal("10.0.0.1.evil.com") && !LocalNetwork.isLocal("127.0.0.1.attacker.net") && !LocalNetwork.isLocal("192.168.1.1.nip.io")
              && !LocalNetwork.isLocal("8.8.8.8") && LocalNetwork.isLocal("10.0.0.1") && LocalNetwork.isLocal("192.168.1.1") && LocalNetwork.isLocal("172.16.0.1"))
        // The question WebKit asks for a local device: answered from the main thread, it stopped Nuri.
        var anchors: CFArray?
        if SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess, let certificate = (anchors as? [SecCertificate])?.first {
            var trust: SecTrust?
            SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "localhost" as CFString), &trust)
            if let trust {
                _ = await CertificateExceptions.decide(host: "localhost", trust: trust, tab: nil)
                check("Réseau local : vérifier le certificat d'un appareil ne plante pas", true)
            }
        }
        func text(_ tab: Tab) async -> String { await js(tab, "return document.body ? document.body.innerText : ''") as? String ?? "" }
        func go(_ tab: Tab, _ url: String) async { _ = await js(tab, "location.replace(\"\(url)\"); return true;") }

        // Nothing behind the warning: « Retour » closes the tab.
        let direct = browser.openTab(url: URL(string: site)!)
        let warned = await until(10) { direct.insecurePage != nil }
        await snapshot("avertissement-http")
        check("HTTP : une page sans HTTPS attend une réponse", warned && direct.webView?.backForwardList.currentItem == nil && direct.loadError == nil, direct.loadError ?? "")
        await direct.leaveInsecurePage()
        check("HTTP : Retour ferme un onglet qui n'a rien d'autre", direct.isClosed)

        // A page behind it: it stays, untouched.
        let page = browser.openTab(url: URL(string: "https://example.com/")!)
        await waitForLoad(page)
        await go(page, site)
        let overPage = await until(10) { page.insecurePage != nil }
        await page.leaveInsecurePage()
        let kept = await text(page)
        check("HTTP : Retour rend la page d'où venait le lien", overPage && page.insecurePage == nil && !page.isClosed && kept.contains("documentation"), String(kept.prefix(40)))

        // A page that only forwards (a link shim): nothing to come back to, so the one before it…
        let shim = URL(string: "data:text/html,<script>location.replace('\(site)')</script>".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!
        page.webView?.load(URLRequest(url: shim))
        let overShim = await until(10) { page.insecurePage != nil }
        await page.leaveInsecurePage()
        _ = await until(5) { page.webView?.url?.host() == "example.com" }
        await sleep(0.3)
        let before = await text(page)
        check("HTTP : Retour saute une page vide qui ne faisait que renvoyer", overShim && before.contains("documentation"), String(before.prefix(40)))
        // … or the tab goes, when the link had opened it.
        let shimTab = browser.openTab(url: shim)
        let overShimTab = await until(10) { shimTab.insecurePage != nil }
        await shimTab.leaveInsecurePage()
        check("HTTP : … et ferme l'onglet qu'elle avait ouvert", overShimTab && shimTab.isClosed)

        // « Continuer »: the page shows, and the site isn't asked about again.
        await go(page, site)
        _ = await until(10) { page.insecurePage != nil }
        page.continueToInsecurePage()
        var shown = ""
        for _ in 0..<40 where !shown.contains("CERN") && !shown.contains("cern") {
            await sleep(0.25)
            shown = await text(page)
        }
        check("HTTP : Continuer ouvre la page", page.loadError == nil && page.insecurePage == nil && page.url?.scheme == "http" && !shown.isEmpty, page.loadError ?? String(shown.prefix(40)))
        let again = browser.openTab(url: URL(string: site + "hypertext/")!)
        await waitForLoad(again)
        check("HTTP : le site accepté n'est plus demandé", again.insecurePage == nil && !PlainHTTP.needsWarning(URL(string: site), in: browser))

        // The first step of many links: Threads, for one, sends to the address as it was posted.
        let upgraded = browser.openTab(url: URL(string: "http://github.com/")!)
        await waitForLoad(upgraded)
        check("HTTP : une adresse qui redirige vers HTTPS y arrive sans question", upgraded.insecurePage == nil && upgraded.loadError == nil && upgraded.url?.scheme == "https", upgraded.loadError ?? upgraded.url?.absoluteString ?? "")
        // The whole chain of a Threads link, for as long as Threads honours it.
        let threads = browser.openTab(url: URL(string: "https://l.threads.com/?u=http%3A%2F%2Ffirnbrowser.com%2Fmac&e=AUAw_g1IQvAUMeM3HWcxVWqa_NymaPy8W3WTqYTxiOFvAFaTffpUQtOQ8M_5jBR-Z_KIyBELBZVZShkT_5rBi3zWQ7NLfAOaAhkM97rvv70YQkWnumUeEcqKERek6quoMyHmcRVPBGsSCush2WARqspLYdEg")!)
        _ = await until(12) { threads.url?.host() == "firnbrowser.com" || threads.insecurePage != nil }
        note("Threads : \(threads.url?.absoluteString ?? "?") · avertissement \(threads.insecurePage?.absoluteString ?? "aucun")")
        for tab in [page, again, upgraded, threads] { browser.close(tab) }
    }

    private func testTrackingParameters() async {
        let dirty = URL(string: "https://a.example/p?id=3&utm_source=x&fbclid=y&gclid=z#f")!
        check("Pistage : les paramètres de suivi partent, le reste reste", TrackingParameters.cleaned(dirty).absoluteString == "https://a.example/p?id=3#f", TrackingParameters.cleaned(dirty).absoluteString)
        let clean = URL(string: "https://a.example/p?id=3")!
        check("Pistage : une adresse propre ne bouge pas", TrackingParameters.cleaned(clean) == clean)
        for (given, wanted) in [("https://a.fr/s?q=a%2Bb&utm_source=x", "https://a.fr/s?q=a%2Bb"),
                                ("https://a.fr/s?sig=abc%2F%2B%3D&utm_medium=m&exp=1", "https://a.fr/s?sig=abc%2F%2B%3D&exp=1"),
                                ("https://a.fr/s?a=1;b=2&gclid=z", "https://a.fr/s?a=1;b=2"),
                                ("https://a.fr/s?redirect=https%3A%2F%2Fb.fr%2F%3Fx%3D1&UTM_Source=x", "https://a.fr/s?redirect=https%3A%2F%2Fb.fr%2F%3Fx%3D1"),
                                ("https://a.fr/s?utm_source=x", "https://a.fr/s"),
                                ("https://a.fr/s?%75tm_source=x&k=1#h?utm_source=y", "https://a.fr/s?k=1#h?utm_source=y"),
                                ("https://a.fr/#h?utm_source=y", "https://a.fr/#h?utm_source=y")] {
            let got = TrackingParameters.cleaned(URL(string: given)!).absoluteString
            check("Pistage : le reste de l'adresse ne change pas d'un caractère", got == wanted, "\(given) → \(got)")
        }
        // A click: only the address changes, the Referer stays.
        if let server = LocalServer() {
            _ = await until(2) { server.port != 0 }
            let base = "http://127.0.0.1:\(server.port)"
            let tab = browser.openTab(url: URL(string: "\(base)/long"))
            await waitForLoad(tab)
            browser.window?.makeFirstResponder(tab.webView)
            _ = await js(tab, "document.body.insertAdjacentHTML('afterbegin', '<a id=t style=\"position:fixed;left:0;top:0;width:200px;height:60px;background:red\" href=\"/echo?k=a%2Bb&utm_source=x\">t</a>'); return 1;")
            await sleep(0.2)
            let point = CGPoint(x: browser.pageFrame.minX + 50, y: browser.pageFrame.minY + 30)
            await mouse(.leftMouseDown, at: point)
            await mouse(.leftMouseUp, at: point)
            await sleep(0.5)
            await waitForLoad(tab)
            check("Pistage : un lien cliqué garde son Referer et ses autres paramètres",
                  tab.url?.absoluteString == "\(base)/echo?k=a%2Bb" && server.lastReferer == "\(base)/long",
                  "\(tab.url?.absoluteString ?? "?") · Referer \(server.lastReferer ?? "aucun")")
        }
        let saved = AppSettings.shared.stripTrackingParameters
        AppSettings.shared.stripTrackingParameters = false
        check("Pistage : désactivable", TrackingParameters.cleaned(dirty) == dirty)
        AppSettings.shared.stripTrackingParameters = saved
    }

    // MARK: Windows, printing, notifications

    private func testSitePermissions() async {
        guard let server = LocalServer() else { check("Permissions : serveur local", false); return }
        _ = await until(2) { server.port != 0 }
        let base = "http://localhost:\(server.port)"
        let page = browser.openTab(url: URL(string: "\(base)/long"))
        await waitForLoad(page)
        func inPage(_ code: String) async -> Any? { try? await page.webView?.callAsyncJavaScript(code, contentWorld: .page) }
        browser.select(page)

        // Windows. A script called by Nuri counts as a click, as long as it runs at once.
        let host = URL(string: base)?.host()?.nuriNormalizedHost ?? ""
        PopupPermission.allowedSites.remove(host)
        let count = browser.currentSpace.tabs.count
        _ = await inPage("window.open('/long?a'); return 1;")
        let opened = await until(3) { browser.currentSpace.tabs.count == count + 1 }
        check("Permissions : window.open après un clic ouvre un onglet, sans question", opened && page.request == nil, "\(browser.currentSpace.tabs.count) onglets pour \(count)")
        browser.currentSpace.tabs.last.map { browser.close($0) }
        browser.select(page)
        // A click, an answer from the server, then the window: payments and sign-ins do this.
        _ = await inPage("await fetch('/long?requete'); await new Promise((done) => setTimeout(done, 300)); window.nuriAfterFetch = !!window.open('/long?apres'); return 1;")
        let afterFetch = await until(3) { browser.currentSpace.tabs.count == count + 1 }
        check("Permissions : une fenêtre juste après une requête reste permise", afterFetch && page.request == nil, "\(browser.currentSpace.tabs.count) onglets pour \(count), \(String(describing: page.request))")
        if afterFetch { browser.currentSpace.tabs.last.map { browser.close($0) } }
        page.request = nil
        browser.select(page)
        _ = await inPage("setTimeout(() => { window.open('/long?b') }, 3000); return 1;")
        _ = await until(5) { page.request != nil }
        if case .popup(let url, let site)? = page.request {
            check("Permissions : une fenêtre sans clic est bloquée, et c'est dit", url?.absoluteString == "\(base)/long?b" && site == host && browser.currentSpace.tabs.count == count, "\(String(describing: url))")
            await snapshot("fenetre-bloquee")
        } else {
            check("Permissions : une fenêtre sans clic est bloquée, et c'est dit", false, "aucune question")
        }
        page.request = nil
        PopupPermission.allow(host, in: browser)
        _ = await inPage("setTimeout(() => { window.open('/long?c') }, 3000); return 1;")
        let allowed = await until(5) { browser.currentSpace.tabs.count == count + 1 }
        check("Permissions : un site autorisé ouvre ses fenêtres", allowed && page.request == nil, "\(browser.currentSpace.tabs.count) onglets pour \(count)")
        browser.currentSpace.tabs.last.map { browser.close($0) }
        browser.select(page)
        PopupPermission.allowedSites.remove(host)

        // window.print().
        _ = await inPage("setTimeout(() => { window.print(); window.nuriPrinted = true; }, 0); return 1;")
        _ = await until(3) { browser.window?.attachedSheet != nil }
        let sheet = browser.window?.attachedSheet
        // macOS closes a print panel at once in an app that isn't in front: that says nothing of Nuri.
        if !NSApp.isActive { eventsWereInFront = false }
        check("Permissions : window.print() ouvre le panneau d'impression", sheet != nil)
        eventsWereInFront = true
        // Its Cancel button: ending the sheet from outside leaves the print operation waiting.
        func cancel(_ view: NSView) -> Bool {
            if let button = view as? NSButton, button.keyEquivalent == "\u{1b}" {
                button.performClick(nil)
                return true
            }
            return view.subviews.contains(where: cancel)
        }
        if let content = sheet?.contentView { _ = cancel(content) }
        await sleep(0.8)
        check("Permissions : la page reprend une fois le panneau fermé", await inPage("return window.nuriPrinted === true") as? Bool == true)

        // Notifications: the question.
        WebNotifications.allowedSites.remove(host)
        WebNotifications.refusedSites.remove(host)
        let asking = Task { @MainActor in await inPage("return await Notification.requestPermission()") }
        let asked = await until(2) { if case .notifications? = page.request { return true } else { return false } }
        check("Permissions : une demande de notifications passe par la pastille", asked)
        await snapshot("notifications-question")
        if case .notifications(_, let answer)? = page.request {
            page.request = nil
            answer(true)
        }
        check("Permissions : acceptée, la page reçoit « granted »", await asking.value as? String == "granted")
        check("Permissions : et le site reste autorisé", WebNotifications.allowedSites.contains(host))
        // What it shows goes to macOS, and a click on it comes back.
        _ = await inPage("window.nuriClicks = 0; window.nuriN = new Notification('Bonjour', { body: 'Un message' }); window.nuriN.onclick = () => { window.nuriClicks++ }; return 1;")
        let delivered = await until(2) { WebNotifications.shared.lastShown?.title == "Bonjour" }
        check("Permissions : une notification de la page arrive à macOS", delivered && WebNotifications.shared.lastShown?.body == "Un message" && WebNotifications.shared.lastShown?.host == host)
        WebNotifications.shared.opened(tabID: page.id.uuidString, id: "1", url: "")
        await sleep(0.3)
        check("Permissions : un clic dessus revient à la page", await inPage("return window.nuriClicks") as? Int == 1)
        // Next page of the site: its notifications still go through.
        page.load(URL(string: "\(base)/long?suite")!)
        await waitForLoad(page)
        await sleep(0.3)
        _ = await inPage("new Notification('Encore'); return 1;")
        let again = await until(2) { WebNotifications.shared.lastShown?.title == "Encore" }
        check("Permissions : après un changement de page aussi", again)
        // Taken off the list: nothing more; refused: not asked again.
        WebNotifications.allowedSites.remove(host)
        _ = await inPage("new Notification('Plus rien'); return 1;")
        await sleep(0.4)
        check("Permissions : retiré de la liste, plus rien ne part", WebNotifications.shared.lastShown?.title == "Encore")
        WebNotifications.refusedSites.add(host)
        page.load(URL(string: "\(base)/long?refus")!)
        await waitForLoad(page)
        WebNotifications.refusedSites.remove(host)
        WebNotifications.refusedSites.add(host)
        _ = await inPage("Notification.requestPermission().then(() => {}); return 1;")
        await sleep(0.3)
        check("Permissions : un site refusé n'est plus sollicité", page.request == nil)
        WebNotifications.refusedSites.remove(host)
        // A site never asked gets nothing added to its page.
        let source = await inPage("return Notification.toString().includes('native')") as? Bool
        check("Permissions : sur un site non autorisé, rien n'est ajouté à la page", source == true)
    }

    // MARK: Blocker

    private func testBlocker() async {
        let settings = AppSettings.shared
        let installed = await until(5) { ContentRules.shared.installedAdBlockList != nil }
        check("Bloqueur : liste compilée et installée", installed)
        func fetchWorks(_ url: String, in tab: Tab) async -> Bool? {
            let result = try? await tab.webView?.callAsyncJavaScript("try { await fetch(u, {mode: 'no-cors', cache: 'no-store'}); return true; } catch (_) { return false; }", arguments: ["u": url], contentWorld: .page) as? Bool
            return result
        }
        let tab = await htmlTab("<title>Page</title>p", base: "https://nuri-bloqueur.example/")
        let tracker = "https://www.googletagmanager.com/gtm.js"
        let control = await fetchWorks("https://www.apple.com/favicon.ico", in: tab)
        let blocked = await fetchWorks(tracker, in: tab)
        if control == true {
            check("Bloqueur : un pisteur connu est bloqué (une autre adresse passe)", blocked == false, "pisteur \(String(describing: blocked))")
            settings.adBlockEnabled = false
            await ContentRules.shared.reloadNow()
            tab.webView?.reload()
            await waitForLoad(tab)
            let off = await fetchWorks(tracker, in: tab)
            check("Bloqueur : désactivable dans les Réglages", off == true && ContentRules.shared.installedAdBlockList == nil, "\(String(describing: off))")
            settings.adBlockEnabled = true
            await ContentRules.shared.reloadNow()
        } else {
            note("Bloqueur : pas de réseau, blocage réel non vérifié")
            settings.adBlockEnabled = false
            await ContentRules.shared.reloadNow()
            check("Bloqueur : désactivable dans les Réglages", ContentRules.shared.installedAdBlockList == nil)
            settings.adBlockEnabled = true
            await ContentRules.shared.reloadNow()
        }
        settings.toggleAdBlock(for: "www.nuri-site.example")
        check("Bloqueur : coupé pour un site seulement", !settings.isAdBlockActive(on: "nuri-site.example") && settings.isAdBlockActive(on: "autre.example"))
        settings.toggleAdBlock(for: "nuri-site.example")
        await ContentRules.shared.reloadNow()
    }

    // MARK: Language

    private func testLanguage() async {
        let store = LanguageStore.shared
        let saved = store.choice
        store.choice = .en
        check("Langue : anglais", L("Nouvel onglet", "New tab") == "New tab")
        check("Langue : le menu suit", NSApp.mainMenu?.items.contains { $0.title == "File" } == true, NSApp.mainMenu?.items.map(\.title).joined(separator: " ") ?? "")
        await snapshot("anglais")
        store.choice = .fr
        check("Langue : français", L("Nouvel onglet", "New tab") == "Nouvel onglet" && NSApp.mainMenu?.items.contains { $0.title == "Fichier" } == true)
        store.choice = saved
        check("Langue : suit le système par défaut", saved != .system || UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] == nil)
    }

    private func testShortcuts() async {
        // The user's own keys are in the same preferences: they come back at the end.
        let savedKeys = UserDefaults.standard.data(forKey: "shortcuts")
        defer { UserDefaults.standard.set(savedKeys, forKey: "shortcuts") }
        func item(_ command: NuriCommand) -> NSMenuItem? {
            NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.representedObject as? String == command.rawValue }
        }
        check("Raccourcis : ⌘T dans le menu", item(.newTab)?.keyEquivalent == "t" && item(.newTab)?.keyEquivalentModifierMask == .command)
        check("Raccourcis : aucun doublon par défaut", {
            let list = NuriCommand.allCases.compactMap(\.defaultShortcut).map(\.display)
            return Set(list).count == list.count
        }())
        let custom = Shortcut("k", "co")
        Shortcuts.set(custom, for: .reader)
        check("Raccourcis : changer un raccourci change le menu", item(.reader)?.keyEquivalent == "k" && item(.reader)?.keyEquivalentModifierMask == [.command, .option])
        check("Raccourcis : un conflit est repéré", Shortcuts.conflict(Shortcut("t", "c"), with: .reader) == .newTab)
        Shortcuts.resetAll()
        check("Raccourcis : tout rétablir", item(.reader)?.keyEquivalent == "r")
        SettingsWindow.show(.shortcuts)
        await sleep(0.5)
        if let window = NSApp.keyWindow, window !== browser.window { await snapshot("reglages-raccourcis", window: window); window.close() }
        browser.window?.makeKeyAndOrderFront(nil)
    }

    private func testHiddenBar() async {
        let a = await htmlTab("<title>A</title>a")
        let b = await htmlTab("<title>B</title>b")
        browser.select(a)
        let settings = AppSettings.shared
        await sleep(0.5)
        // As a menu or a switch does it: from the run loop, not from this test's task.
        DispatchQueue.main.async { settings.autoHideTopBar = true }
        await sleep(0.3)
        let close = browser.window?.standardWindowButton(.closeButton)
        await snapshot("barre-masquee")
        check("Barre masquée : la page prend la place, feux cachés", browser.pageFrame.minY < Metrics.topBarHeight && close?.isHidden == true, "page \(browser.pageFrame.minY) · feux cachés \(close?.isHidden == true)")
        await mouse(.mouseMoved, at: CGPoint(x: 300, y: 2), post: true)
        let out = await until(2) { browser.topBarRevealed }
        check("Barre masquée : elle revient au bord haut", out)
        await sleep(0.4)
        // Dragged from there into split view: the bar stays while the tab is carried.
        if let start = center(of: b) {
            let page = browser.pageFrame
            await snapshot("barre-revelee")
            await mouse(.leftMouseDown, at: start)
            await mouse(.leftMouseDragged, at: CGPoint(x: page.maxX - 50, y: page.midY))
            check("Barre masquée : on peut en glisser un onglet vers la page", browser.carry?.dropSide == .right)
            await mouse(.leftMouseUp, at: CGPoint(x: page.maxX - 50, y: page.midY))
            await sleep(0.2)
            check("Barre masquée : il s'ouvre en vue partagée", browser.shownSplit?.right === b, "porté \(String(describing: browser.carry)) · départ \(start)")
        } else {
            check("Barre masquée : onglets mesurés", false)
        }
        await mouse(.mouseMoved, at: CGPoint(x: 300, y: 300), post: true)
        let gone = await until(2) { !browser.topBarRevealed }
        check("Barre masquée : elle repart", gone)
        DispatchQueue.main.async { settings.autoHideTopBar = false }
        await sleep(0.5)
        check("Barre : réaffichée, feux compris", browser.pageFrame.minY >= Metrics.topBarHeight && close?.isHidden == false)
    }

    private func testUpdater() async {
        check("Mises à jour : comparaison de versions", Updater.isNewer("0.1.1", than: "0.1.0") && !Updater.isNewer("0.1.0", than: "0.1") && Updater.isNewer("1.0", than: "0.9.9"))
        check("Mises à jour : on vérifie les archives par la signature", Updater.teamIdentifier() != nil, Updater.teamIdentifier() ?? "nil")
        do {
            _ = try await Updater.newestRelease()
            note("Mises à jour : le dépôt \(Updater.repository) répond")
        } catch {
            note("Mises à jour : le dépôt \(Updater.repository) ne répond pas encore (\(error.localizedDescription)) : aucune version à trouver tant qu'il n'est pas publié")
        }
    }

    // MARK: Meeting

    private func testMeetingWindow() async {
        browser.window?.makeKeyAndOrderFront(nil)
        let meeting = await htmlTab("<!doctype html><body>appel</body>", base: "https://nuri-visio.example/")
        let other = await htmlTab("<!doctype html><body>ailleurs</body>")
        let zoom = meeting.webView?.pageZoom ?? 1
        browser.select(meeting)
        meeting.isInCall = true
        browser.select(other)
        await sleep(0.5)
        let floating = meeting.webView?.window
        check("Réunion : quitter l'onglet l'envoie en fenêtre flottante, page entière dézoomée à 75 %",
              FloatingPlayer.shared.isOpen && FloatingPlayer.shared.tab === meeting && meeting.isInFloatingPlayer
                && floating != nil && floating !== browser.window && floating?.level == .floating
                && abs((meeting.webView?.pageZoom ?? 0) - zoom * FloatingPlayer.meetingZoom) < 0.01,
              "zoom \(meeting.webView?.pageZoom ?? 0)")

        browser.select(meeting)
        await sleep(0.8)
        check("Réunion : revenir à l'onglet la ramène, zoom rendu",
              !FloatingPlayer.shared.isOpen && !meeting.isInFloatingPlayer && meeting.webView?.window === browser.window && meeting.webView?.pageZoom == zoom)

        browser.togglePiP()
        await sleep(0.4)
        let manual = FloatingPlayer.shared.isOpen && meeting.isInFloatingPlayer && FloatingPlayer.shared.mode == .meeting
        await snapshot("reunion-onglet")
        let panel = meeting.webView?.window
        panel?.setFrameOrigin(NSPoint(x: 40, y: 40))
        let moved = panel?.frame
        meeting.isInCall = false
        PiPController.shared.callStateChanged(meeting)
        await sleep(3.6)
        check("Réunion : ⌘⇧P l'envoie en fenêtre flottante, raccrocher l'en ramène", manual && !FloatingPlayer.shared.isOpen && meeting.webView?.window === browser.window)
        check("Réunion : la fenêtre retient sa place", moved != nil && UserDefaults.standard.string(forKey: "meetingWindowFrame").map(NSRectFromString) == moved)

        meeting.isInCall = true
        let saved = AppSettings.shared.autoMeetingPiP
        AppSettings.shared.autoMeetingPiP = false
        browser.select(other)
        await sleep(0.4)
        check("Réunion : réglage désactivé, l'appel reste dans son onglet (page gardée en vie)", !FloatingPlayer.shared.isOpen && meeting.webView?.window === browser.window)
        AppSettings.shared.autoMeetingPiP = saved
        meeting.isInCall = false
    }

    // MARK: Sound in screen sharing

    private func testShareAudio() async {
        let share = ShareAudio.shared
        let saved = (AppSettings.shared.shareScreenAudio, share.includesOtherApps)
        share.includesOtherApps = false
        defer {
            share.stop()
            (AppSettings.shared.shareScreenAudio, share.includesOtherApps) = saved
        }
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let music = await htmlTab(Self.toneHTML, base: "https://nuri-musique.example/")
        let playing = await play(music)
        let eligible = await js(music, """
            const other = document.createElement('audio'); other.src = 'https://ailleurs.example/son.mp3';
            const loop = document.createElement('audio'); loop.src = document.getElementById('a').src; loop.loop = true;
            return [document.getElementById('a'), other, loop].map(__nuriShareAudio.eligible).join();
            """) as? String
        check("Partage du son : seuls les sons lisibles par la page sont pris", playing && eligible == "true,false,false", "lecture \(playing) · éligibles \(eligible ?? "nil")")

        let call = await htmlTab("<!doctype html><body>réunion</body>", base: "https://nuri-partage.example/")
        browser.select(call)
        guard let webView = call.webView else { check("Partage du son : onglet de réunion", false); return }
        WebKitSPI.setPreference(webView.configuration.preferences, "mockCaptureDevicesEnabled", true)
        browser.window?.makeFirstResponder(webView)
        await sleep(0.5)

        let wholeScreen = L("Partager l'écran entier…", "Share Entire Screen…")
        func shareScreen(sound: Bool, choice: String = wholeScreen) async -> String {
            // WebKit refuses to share from a page without focus.
            for _ in 0..<25 where !(NSApp.isActive && browser.window?.isKeyWindow == true) {
                NSApp.activate(ignoringOtherApps: true)
                browser.window?.makeKeyAndOrderFront(nil)
                await sleep(0.2)
            }
            browser.window?.makeFirstResponder(webView)
            // WebKit's process learns of the focus a moment later.
            await sleep(0.6)
            let page = Task { @MainActor in
                try? await webView.callAsyncJavaScript("""
                    let s;
                    try { s = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true }); }
                    catch (e) { return e.name + ' ' + e.message; }
                    window.__shared = s;
                    window.__sharedLabel = s.getVideoTracks()[0]?.label;
                    const tracks = s.getAudioTracks();
                    if (tracks.length) {
                      const ctx = new AudioContext(), analyser = ctx.createAnalyser(), mute = ctx.createGain();
                      mute.gain.value = 0;
                      ctx.createMediaStreamSource(new MediaStream([tracks[0]])).connect(analyser);
                      analyser.connect(mute); mute.connect(ctx.destination);
                      window.__listen = { ctx, analyser };
                    }
                    return 'son ' + tracks.length;
                    """, contentWorld: .page) as? String
            }
            var sheet: NSWindow?
            for _ in 0..<50 where sheet == nil { await sleep(0.1); sheet = browser.window?.attachedSheet }
            guard let sheet else { return "pas de question (\(await page.value ?? "nil"))" }
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let buttons = (sheet.contentView.map(views) ?? []).compactMap { $0 as? NSButton }
            let question = (sheet.contentView.map(views) ?? []).compactMap { ($0 as? NSTextField)?.stringValue }
            if !sound {
                check("Partage du son : la question est bien « Partager votre écran ? », case décochée au départ possible",
                      question.contains(L("Partager votre écran ?", "Share your screen?")), question.joined(separator: " / "))
            }
            buttons.first { $0.title == L("Partager aussi le son (vidéos, autres apps)", "Share sound too (videos, other apps)") }?.state = sound ? .on : .off
            buttons.first { $0.title == choice }?.performClick(nil)
            return await page.value ?? "aucune réponse"
        }

        let shared = await shareScreen(sound: true)
        browser.select(music)
        await sleep(3.5)
        let peak = try? await webView.callAsyncJavaScript("""
            const { analyser } = window.__listen, data = new Float32Array(analyser.fftSize);
            let peak = 0;
            for (let i = 0; i < 20; i++) {
              await new Promise((r) => setTimeout(r, 100));
              analyser.getFloatTimeDomainData(data);
              for (const x of data) peak = Math.max(peak, Math.abs(x));
            }
            return peak;
            """, contentWorld: .page) as? Double
        check("Partage du son : case cochée → piste audio qui porte le son de l'autre onglet", shared == "son 1" && (peak ?? 0) > 0.002,
              "\(shared) · crête \(peak.map { String(format: "%.3f", $0) } ?? "nil")")
        browser.select(call)
        await sleep(0.5)
        let ended = try? await webView.callAsyncJavaScript(
            "window.__listen.ctx.close(); window.__shared.getVideoTracks()[0].stop(); await new Promise((r) => setTimeout(r, 2500)); return window.__shared.getAudioTracks()[0].readyState;",
            contentWorld: .page) as? String
        check("Partage du son : arrêter l'écran arrête le son", ended == "ended" && !share.isSharing, "piste \(ended ?? "nil") · relais \(share.isSharing)")

        let silent = await shareScreen(sound: false)
        let screenLabel = try? await webView.callAsyncJavaScript("return window.__sharedLabel;", contentWorld: .page) as? String
        check("Partage du son : case décochée → l'image seule", silent == "son 0", silent)
        _ = try? await webView.callAsyncJavaScript("window.__shared.getTracks().forEach((t) => t.stop());", contentWorld: .page)

        // A single window rather than the whole screen (WebKit's mock devices are named after their kind).
        let windowOnly = await shareScreen(sound: false, choice: L("Partager une fenêtre…", "Share a Window…"))
        let windowLabel = try? await webView.callAsyncJavaScript("return window.__sharedLabel;", contentWorld: .page) as? String
        check("Partage d'écran : « une fenêtre » partage une fenêtre, « l'écran entier » un écran",
              windowOnly == "son 0" && windowLabel != screenLabel && windowLabel?.localizedCaseInsensitiveContains("window") == true
                && screenLabel?.localizedCaseInsensitiveContains("screen") == true,
              "\(windowOnly) · fenêtre « \(windowLabel ?? "nil") » · écran « \(screenLabel ?? "nil") »")
        _ = try? await webView.callAsyncJavaScript("window.__shared.getTracks().forEach((t) => t.stop());", contentWorld: .page)

        let faked = try? await webView.callAsyncJavaScript("""
            const canvas = document.createElement('canvas');
            const holder = document.createElement('audio');
            holder.srcObject = canvas.captureStream().getVideoTracks().length ? canvas.captureStream() : null;
            document.body.append(holder);
            return await new Promise((resolve) => {
              holder.addEventListener('nurishareaudioready', () => resolve('son ' + holder.srcObject.getAudioTracks().length), { once: true });
              holder.dispatchEvent(new Event('nurishareaudio', { bubbles: true }));
              setTimeout(() => resolve('pas de réponse'), 3000);
            });
            """, contentWorld: .page) as? String
        check("Partage du son : une page qui imite la demande n'obtient rien", faked == "son 0" && !share.isSharing, faked ?? "nil")
    }

    // MARK: Picture in Picture

    private func testPiP() async {
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let tab = await htmlTab("""
            <!doctype html><title>Vidéo</title><body style="margin:0;background:#111">
            <video id="v" src="https://media.w3.org/2010/05/sintel/trailer.mp4" width="640" height="360" controls playsinline loop></video>
            """)
        let other = await htmlTab("<title>Ailleurs</title>a")
        browser.select(tab)
        await sleep(0.3)
        let playing = try? await tab.webView?.callAsyncJavaScript("const v = document.getElementById('v'); v.volume = 0.02; await v.play(); return !v.paused;", contentWorld: .page) as? Bool
        let audible = await until(12) { tab.isPlayingVideo && tab.isAudible }
        guard playing == true, audible else {
            note("PiP : la vidéo de test ne joue pas (réseau ?), non vérifié : lecture \(String(describing: playing))")
            return
        }
        let outcome = await PiPController.shared.enter(tab, allowFloatingFallback: false)
        let manual: Bool
        if case .entered = outcome { manual = true } else { manual = false }
        check("PiP : manuel", manual, "\(outcome)")
        await PiPController.shared.exit(tab)
        await sleep(0.8)
        browser.select(other)
        let auto = await until(5) { tab.isInPiP }
        check("PiP : automatique en quittant l'onglet", auto && tab.webView?.window === browser.window)
        browser.select(tab)
        let back = await until(5) { !tab.isInPiP }
        check("PiP : revenir à l'onglet le referme", back)
        let saved = AppSettings.shared.autoPiP
        AppSettings.shared.autoPiP = false
        browser.select(other)
        await sleep(1.5)
        check("PiP : automatique désactivable", !tab.isInPiP)
        AppSettings.shared.autoPiP = saved
        _ = try? await tab.webView?.callAsyncJavaScript("document.getElementById('v').pause();", contentWorld: .page)
    }

    // MARK: Pictures of the interface

    private func testPreview() async {
        browser.onboardingStep = 1
        await snapshot("premier-lancement")
        browser.onboardingStep = nil
        await snapshot("page-vide")
        browser.showCommandBar(.newTab)
        check("Aperçu : sur la page vide, ⌘T donne son champ, pas une seconde barre", browser.commandBar == nil)
        snapshot(panel: VStack(alignment: .leading) {
            SpacesPanel(close: {})
            SpaceEditor(space: browser.currentSpace).panelStyle()
        }, "panneau-espaces")
        snapshot(panel: MorePanel(close: {}), "panneau-plus")
        snapshot(panel: HStack(spacing: 14) {
            ForEach([16, 32, 64] as [CGFloat], id: \.self) { side in
                Image(nsImage: .porthole).resizable().renderingMode(.template).frame(width: side, height: side).foregroundStyle(Theme.text)
            }
            NuriWordmark(height: 46)
            NuriWordmark(height: 26)
        }.padding(14), "marque")
        _ = await htmlTab("<title>Planète Mars</title><body style='font:15px -apple-system;padding:32px'><h1>Planète Mars</h1><p>La quatrième planète.</p>")
        _ = await htmlTab("<title>Recettes de saison</title>r")
        _ = await htmlTab("<title>Carnet de voyage</title>c")
        await snapshot("barre")
    }
}
#endif
