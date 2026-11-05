import AppKit
import Observation
import SwiftUI
import WebKit

/// Runs the installed extensions, on WebKit's own support for them (the same format as Chrome's,
/// manifests 2 and 3). The controller only exists once there is an extension to run.
@available(macOS 15.4, *)
@MainActor @Observable
final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionHost()

    private(set) var installed: [InstalledExtension]
    /// Why an extension doesn't run, by identifier.
    private(set) var problems: [String: String] = [:]
    /// Bumped when an extension changes its icon, label or badge.
    private(set) var revision = 0
    @ObservationIgnored private var contexts: [String: WKWebExtensionContext] = [:]
    @ObservationIgnored private(set) var controller: WKWebExtensionController?
    @ObservationIgnored private var loaded = true
    @ObservationIgnored private var waiters: [() -> Void] = []
    @ObservationIgnored private var asksProxy: [String: Bool] = [:]

    /// The controller's storage (what extensions keep), the same at every launch.
    private static let storeID = UUID(uuidString: "6E757269-6578-7400-8000-6E7572696578")!

    override private init() {
        installed = ExtensionFiles.loadRecords()
        super.init()
    }

    // MARK: - Starting

    func start() {
        let enabled = installed.filter(\.enabled)
        guard !enabled.isEmpty else { return }
        makeController()
        loaded = false
        Task {
            for record in enabled { await load(record) }
            markLoaded()
        }
        // An extension that takes its time doesn't hold the first page for long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.markLoaded() }
    }

    func whenLoaded(_ block: @escaping () -> Void) {
        if loaded { block() } else { waiters.append(block) }
    }

    private func markLoaded() {
        guard !loaded else { return }
        loaded = true
        waiters.forEach { $0() }
        waiters = []
    }

    @discardableResult
    private func makeController() -> WKWebExtensionController {
        if let controller { return controller }
        var configuration = WKWebExtensionController.Configuration(identifier: Self.storeID)
        #if DEBUG
        // A self-test over two launches keeps what extensions store, apart from the user's.
        if SelfTestRunner.isRequested {
            configuration = SelfTestRunner.keptDirectory == nil ? .nonPersistent()
                : WKWebExtensionController.Configuration(identifier: UUID(uuidString: "6E757269-7465-7374-8000-6E7572696578")!)
        }
        #endif
        let made = WKWebExtensionController(configuration: configuration)
        made.delegate = self
        // Extension pages use the controller's store: they keep WebCrypto keys too.
        if let store = made.configuration.defaultWebsiteDataStore { WebCryptoMasterKey.shared.attach(to: store) }
        controller = made
        return made
    }

    /// Pages opened before the first extension have no way to it: they come back with one. Those in
    /// use (sound, a call, typed text, opened by another page) get it at their next wake-up.
    private func adoptOpenPages() {
        for browser in BrowserWindows.shared.all where !browser.isPrivate {
            let visible = browser.visibleTabs
            for tab in browser.allTabs {
                guard let webView = tab.webView, webView.configuration.webExtensionController == nil, !Extensions.isExtensionPage(tab.url),
                      !tab.isInCall, !tab.isAudible, !tab.isInPiP, !tab.isInFloatingPlayer, !tab.isInElementFullscreen,
                      !tab.hasUserInput, !tab.openedByPage else { continue }
                tab.sleepKeepingHistory()
                if visible.contains(where: { $0 === tab }) { tab.ensureWebView() }
            }
        }
    }

    private func load(_ record: InstalledExtension) async {
        do {
            let folder = ExtensionFiles.folder(of: record.id)
            // A new Nuri may bring a new shim.
            await Task.detached(priority: .userInitiated) { ExtensionFiles.addShims(to: folder) }.value
            let webExtension = try await WKWebExtension(resourceBaseURL: folder)
            try activate(webExtension, record: record)
            problems[record.id] = nil
        } catch {
            problems[record.id] = error.localizedDescription
        }
    }

    private func activate(_ webExtension: WKWebExtension, record: InstalledExtension) throws {
        let id = record.id
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = id
        // Stable: what it stores, and its pages in the saved tabs, are found again at the next launch.
        if let base = URL(string: "\(Extensions.pageScheme)://\(id)/") { context.baseURL = base }
        context.isInspectable = true
        // Granted when it was added, after asking.
        for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in Self.sitesAsked(by: webExtension) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        // And what it was allowed since.
        for permission in record.laterPermissions ?? [] { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission)) }
        for site in record.laterSites ?? [] {
            if let pattern = try? WKWebExtension.MatchPattern(string: site) { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        }
        // Its way to Nuri for what WebKit lacks (chrome.proxy, side panels, tab groups,
        // chrome.debugger…; ExtensionNative): runtime.sendNativeMessage, which only ever reaches
        // Nuri itself.
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        try makeController().load(context)
        contexts[id] = context
        if let saved = record.proxy, record.proxyAllowed == true { ExtensionProxy.shared.restore(saved, for: id) }
        watchBackground(context)
    }

    /// The sites it works on from the start, those it would ask for later aside.
    private static func sitesAsked(by webExtension: WKWebExtension) -> Set<WKWebExtension.MatchPattern> {
        webExtension.allRequestedMatchPatterns.subtracting(webExtension.optionalPermissionMatchPatterns)
    }

    // MARK: - Adding and removing

    /// `folder` is copied. `asks`: the user sees what it can do and may decline (false returned).
    @discardableResult
    func add(from folder: URL, id: String, source: InstalledExtension.Source, asks: Bool = true) async throws -> Bool {
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        if asks, !confirmAdding(webExtension) { return false }
        unload(id)
        let destination = ExtensionFiles.folder(of: id)
        try? FileManager.default.createDirectory(at: ExtensionFiles.directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: folder, to: destination)
        // Chrome's integrity data for its own copy: meaningless here.
        try? FileManager.default.removeItem(at: destination.appendingPathComponent("_metadata"))
        await Task.detached(priority: .userInitiated) { ExtensionFiles.addShims(to: destination) }.value
        let installedCopy = try await WKWebExtension(resourceBaseURL: destination)
        // A new version keeps what the previous one was allowed, and its being off.
        let previous = installed.first { $0.id == id }
        let record = InstalledExtension(id: id, name: installedCopy.displayName ?? id, version: installedCopy.version ?? "",
                                        source: source, enabled: previous?.enabled ?? true,
                                        laterPermissions: previous?.laterPermissions, laterSites: previous?.laterSites,
                                        proxyAllowed: previous?.proxyAllowed, proxy: previous?.proxy)
        installed.removeAll { $0.id == id }
        installed.append(record)
        installed.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        ExtensionFiles.save(installed)
        problems[id] = nil
        if record.enabled { try activate(installedCopy, record: record) }
        adoptOpenPages()
        return true
    }

    /// From the Chrome Web Store. A toast says what became of it. `browser`: where to say it.
    func addFromStore(id: String, in browser: BrowserModel?, asks: Bool = true) async {
        browser?.showToast("puzzlepiece.extension", L("Téléchargement de l'extension…", "Downloading the extension…"))
        do {
            let folder = try await ExtensionFiles.download(id: id)
            defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
            guard try await add(from: folder, id: id, source: .webStore, asks: asks) else { return }
            let name = installed.first { $0.id == id }?.name ?? id
            browser?.showToast("puzzlepiece.extension", L("« \(name) » ajoutée", "“\(name)” added"))
        } catch {
            browser?.showToast("exclamationmark.triangle", Self.describe(error))
        }
    }

    private static let lastUpdateCheckKey = "extensionsLastUpdateCheck"

    /// Asked by the window timer: at most one look a day. A password manager kept at the version
    /// it was added in misses its security fixes, then stops working with its servers.
    func updateIfDue() {
        #if DEBUG
        if SelfTestRunner.isRequested { return }
        #endif
        guard !installed.isEmpty, AppSettings.shared.extensionsAutoUpdate else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)
        Task {
            let updated = await updateAll().updated
            if let first = updated.first {
                BrowserWindows.shared.normalTarget.showToast("puzzlepiece.extension", updated.count == 1 ? L("« \(first) » mise à jour", "“\(first)” updated")
                                                                                                         : L("\(updated.count) extensions mises à jour", "\(updated.count) extensions updated"))
            }
        }
    }

    /// Each one with a newer version in the store is added again over itself: its data stays, and
    /// it asks again only if it wants more than it was allowed.
    private func updateAll() async -> (updated: [String], failed: Int) {
        var updated: [String] = []
        var failed = 0
        for record in installed {
            do {
                guard let version = await ExtensionFiles.latestVersion(id: record.id) else {
                    failed += 1
                    continue
                }
                guard ExtensionFiles.isOlder(record.version, than: version) else { continue }
                let folder = try await ExtensionFiles.download(id: record.id)
                defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
                let latest = try await WKWebExtension(resourceBaseURL: folder)
                let current = contexts[record.id]?.webExtension
                let wantsMore = current == nil || !latest.requestedPermissions.isSubset(of: current!.requestedPermissions)
                    || !Self.sitesAsked(by: latest).isSubset(of: Self.sitesAsked(by: current!))
                if try await add(from: folder, id: record.id, source: record.source, asks: wantsMore) { updated.append(record.name) }
            } catch {
                failed += 1
            }
        }
        return (updated, failed)
    }

    /// The button in the Settings: what it found, in words.
    func checkForUpdates() async -> String {
        let (updated, failed) = await updateAll()
        var parts = [updated.isEmpty ? L("Tout est à jour.", "Everything is up to date.")
                                     : L("Mises à jour : \(updated.joined(separator: ", ")).", "Updated: \(updated.joined(separator: ", ")).")]
        if failed > 0 { parts.append(L("\(failed) introuvable(s) sur le Chrome Web Store.", "\(failed) not found on the Chrome Web Store.")) }
        return parts.joined(separator: " ")
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].enabled != enabled else { return }
        installed[index].enabled = enabled
        ExtensionFiles.save(installed)
        if enabled {
            let record = installed[index]
            Task {
                await load(record)
                adoptOpenPages()
            }
        } else {
            unload(id)
            problems[id] = nil
            // As in Chrome: what it had set goes with it.
            rememberProxy(nil, for: id)
        }
    }

    /// What it stored goes with it.
    func remove(_ id: String) {
        guard let controller else { return forget(id) }
        if let context = contexts[id] {
            let types = WKWebExtensionController.allExtensionDataTypes
            controller.fetchDataRecord(ofTypes: types, for: context) { record in
                if let record { controller.removeData(ofTypes: types, from: [record]) {} }
            }
        }
        unload(id)
        forget(id)
    }

    private func forget(_ id: String) {
        installed.removeAll { $0.id == id }
        problems[id] = nil
        ExtensionFiles.save(installed)
        try? FileManager.default.removeItem(at: ExtensionFiles.folder(of: id))
    }

    /// `reloading`: it comes back at once (revive): what Nuri keeps for it stays.
    private func unload(_ id: String, reloading: Bool = false) {
        ExtensionProxy.shared.release(id, telling: false)
        closeSidePanels(of: id)
        ExtensionSockets.shared.closeAll(of: id)
        messengers[id] = nil
        if !reloading { ExtensionNative.forget(id) }
        guard let context = contexts[id] else { return }
        try? controller?.unload(context)
        contexts[id] = nil
    }

    private func confirmAdding(_ webExtension: WKWebExtension) -> Bool {
        let name = webExtension.displayName ?? L("cette extension", "this extension")
        let alert = NSAlert()
        alert.messageText = L("Ajouter « \(name) » à Nuri ?", "Add “\(name)” to Nuri?")
        alert.informativeText = Self.describeAccess(of: webExtension)
        alert.addButton(withTitle: L("Ajouter", "Add"))
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What it can do, in words, for the question asked before adding it.
    static func describeAccess(of webExtension: WKWebExtension) -> String {
        var lines: [String] = []
        let sites = sitesAsked(by: webExtension)
        if sites.contains(where: \.matchesAllHosts) {
            lines.append(L("Elle pourra lire et modifier toutes les pages que vous ouvrez.", "It will be able to read and change every page you open."))
        } else if !sites.isEmpty {
            let hosts = Set(sites.compactMap(\.host)).sorted()
            let shown = hosts.prefix(5).joined(separator: ", ") + (hosts.count > 5 ? "…" : "")
            lines.append(L("Elle pourra lire et modifier les pages de : \(shown).", "It will be able to read and change pages on: \(shown)."))
        }
        let granted = webExtension.requestedPermissions.map(\.rawValue)
        let words: [(String, String, String)] = [
            ("cookies", "ses cookies", "cookies"), ("history", "l'historique", "history"), ("tabs", "les onglets", "tabs"),
            ("downloads", "les téléchargements", "downloads"), ("bookmarks", "les signets", "bookmarks"),
            ("webNavigation", "les pages visitées", "visited pages"), ("clipboardRead", "le presse-papiers", "the clipboard"),
            ("clipboardWrite", "le presse-papiers", "the clipboard"), ("nativeMessaging", "les apps du Mac", "Mac apps"),
        ]
        var seen = Set<String>()
        let reached = words.filter { granted.contains($0.0) && seen.insert($0.1).inserted }.map { L($0.1, $0.2) }
        if !reached.isEmpty {
            lines.append(L("Accès à : \(reached.joined(separator: ", ")).", "Access to: \(reached.joined(separator: ", "))."))
        }
        if wantsProxy(webExtension) {
            lines.append(L("C'est un VPN : Nuri vous demandera avant de faire passer votre navigation par ses serveurs.",
                           "It's a VPN: Nuri will ask you before routing your browsing through its servers."))
        }
        lines.append(L("Jamais dans les fenêtres privées. Les extensions ne viennent pas de Nuri : n'ajoutez que celles en qui vous avez confiance.",
                       "Never in private windows. Extensions don't come from Nuri: only add those you trust."))
        return lines.joined(separator: "\n\n")
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? ExtensionFileError { return error.message }
        return error.localizedDescription
    }

    // MARK: - What the interface asks

    func webExtension(_ id: String) -> WKWebExtension? { contexts[id]?.webExtension }

    /// The installed extensions running now, in order.
    var running: [(record: InstalledExtension, context: WKWebExtensionContext)] {
        _ = revision
        return installed.compactMap { record in contexts[record.id].map { (record, $0) } }
    }

    /// The running extensions that have their own button in the bar.
    var pinned: [(record: InstalledExtension, context: WKWebExtensionContext)] {
        running.filter { $0.record.pinned == true }
    }

    func setPinned(_ pinned: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }), (installed[index].pinned == true) != pinned else { return }
        installed[index].pinned = pinned ? true : nil
        ExtensionFiles.save(installed)
    }

    func icon(of id: String, in browser: BrowserModel?, size: CGFloat) -> NSImage? {
        guard let context = contexts[id] else { return nil }
        let square = CGSize(width: size, height: size)
        return action(of: context, in: browser)?.icon(for: square) ?? context.webExtension.icon(for: square)
    }

    func action(of context: WKWebExtensionContext, in browser: BrowserModel?) -> WKWebExtension.Action? {
        context.action(for: browser?.selectedTab.map(adapter(for:)))
    }

    /// Its button: a popup, or its own answer to the click. Its background is asked first (see
    /// watchBackground), which also wakes it up if WebKit had unloaded it: a popup that finds no
    /// one to talk to closes itself.
    func performAction(_ id: String, in browser: BrowserModel) {
        guard let context = contexts[id] else { return }
        let tab = browser.selectedTab.map(adapter(for:))
        Task {
            if await backgroundWorkerIsLost(context) {
                await revive(context)
                if let revived = contexts[id] { _ = await backgroundAnswers(revived) }
            }
            // A context reloaded by Nuri is a new one.
            (contexts[id] ?? context).performAction(for: tab)
        }
    }

    // MARK: - The background's service worker

    #if DEBUG
    /// Self-test: extensions reloaded because their worker was lost.
    @ObservationIgnored private(set) var revivals = 0
    /// Self-test: the popup shown last. Asking an action for its popup before WebKit presents it
    /// loads it early, and WebKit then never presents it.
    @ObservationIgnored private(set) weak var shownPopover: NSPopover?
    @ObservationIgnored private(set) weak var shownPopupWebView: WKWebView?
    #endif
    @ObservationIgnored private var reviving: Set<ObjectIdentifier> = []

    /// WebKit can lose the service worker of an extension loaded at launch a few seconds after
    /// starting it (it turns redundant), while still taking the background for loaded: messages
    /// from the extension's popup and content scripts then reach no one. The extension's own
    /// `runtime.reload()` brings the worker back for good, so it is called when the worker is lost.
    /// Only then: reloading cuts its content scripts off in every open page until they reload.
    private func watchBackground(_ context: WKWebExtensionContext) {
        guard Self.hasServiceWorker(context) else { return }
        Task {
            // The worker is lost about 5 s after it starts: asked a few times after that.
            for delay in [6, 8, 10] {
                try? await Task.sleep(for: .seconds(delay))
                guard contexts[context.uniqueIdentifier] === context else { return }
                if await backgroundWorkerIsLost(context) { return await revive(context) }
            }
        }
    }

    private static func hasServiceWorker(_ context: WKWebExtensionContext) -> Bool {
        (context.webExtension.manifest["background"] as? [String: Any])?["service_worker"] is String
    }

    /// It no longer answers, asked twice. What its page says of its registration is no proof: after
    /// WebKit unloads an idle background (30 s) and wakes it again, none is listed while it runs.
    private func backgroundWorkerIsLost(_ context: WKWebExtensionContext) async -> Bool {
        guard Self.hasServiceWorker(context) else { return false }
        if await backgroundAnswers(context) { return false }
        try? await Task.sleep(for: .seconds(1))
        return !(await backgroundAnswers(context))
    }

    /// Asked from a blank page of the extension's own (ExtensionFiles.addShims): extension-shim.js
    /// answers in the worker, and a background WebKit had unloaded is woken up by the question.
    /// True when there is no way to ask. A page that doesn't even run is no answer: the extension's
    /// pages go through its service worker, and with the worker lost they never load (Claude's
    /// panel then spins forever).
    func backgroundAnswers(_ context: WKWebExtensionContext) async -> Bool {
        guard let page = await blankPage(of: context) else { return true }
        let answer = await page.nuriCall("""
            return await Promise.race([
              browser.runtime.sendMessage({ nuriPing: true }).then((reply) => !!(reply && reply.nuriPong), () => false),
              new Promise((done) => setTimeout(() => done(false), 3000))]);
            """, world: .page, timeout: 4) as? Bool
        if answer != true { ExtensionNative.note(context, "background check: \(answer == false ? "no answer" : "its page didn't run")") }
        return answer ?? false
    }

    /// `runtime.reload()`, as the extension would do itself, from one of its pages. When its pages
    /// no longer run (they wait for the lost worker), Nuri loads the extension again itself: a new
    /// context, with what it stored kept (only storage.session goes). At most three times a launch.
    private func revive(_ context: WKWebExtensionContext) async {
        guard reviving.insert(ObjectIdentifier(context)).inserted else { return }
        defer { reviving.remove(ObjectIdentifier(context)) }
        #if DEBUG
        revivals += 1
        #endif
        let id = context.uniqueIdentifier
        guard let page = await blankPage(of: context) else { return }
        if await page.nuriCall("return true;", world: .page, timeout: 2) as? Bool == true {
            ExtensionNative.note(context, "background lost: runtime.reload()")
            // No waiting for its answer: reloading takes this page away, and it may never come.
            page.evaluateJavaScript("browser.runtime.reload(); true", completionHandler: nil)
            try? await Task.sleep(for: .seconds(1))
            _ = page
            return
        }
        guard (nativeReloads[id] ?? 0) < 3, let record = installed.first(where: { $0.id == id && $0.enabled }), contexts[id] === context else { return }
        nativeReloads[id, default: 0] += 1
        ExtensionNative.note(context, "background lost and its pages don't run: loaded again by Nuri")
        unload(id, reloading: true)
        await load(record)
        // Its pages open in tabs get the new context at their next load.
        try? await Task.sleep(for: .seconds(1))
    }

    @ObservationIgnored private var nativeReloads: [String: Int] = [:]

    private func blankPage(of context: WKWebExtensionContext) async -> WKWebView? {
        guard let configuration = context.webViewConfiguration else { return nil }
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.load(URLRequest(url: context.baseURL.appendingPathComponent(ExtensionFiles.blankPageFile)))
        for _ in 0..<30 where page.isLoading || page.url == nil { try? await Task.sleep(for: .milliseconds(100)) }
        return page
    }

    // MARK: - VPN (chrome.proxy, see ExtensionProxy)

    static func wantsProxy(_ webExtension: WKWebExtension) -> Bool {
        (webExtension.manifest["permissions"] as? [String])?.contains("proxy") == true
    }

    /// Whether it asks for chrome.proxy, turned off or not.
    func asksForProxy(_ id: String) -> Bool {
        if let webExtension = contexts[id]?.webExtension { return Self.wantsProxy(webExtension) }
        if let known = asksProxy[id] { return known }
        let manifest = (try? Data(contentsOf: ExtensionFiles.folder(of: id).appendingPathComponent("manifest.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let asks = (manifest?["permissions"] as? [String])?.contains("proxy") == true
        asksProxy[id] = asks
        return asks
    }

    func proxyAllowed(_ id: String) -> Bool? { installed.first { $0.id == id }?.proxyAllowed }

    /// Whether the user lets it route pages through its servers: asked the first time it tries.
    func mayRoute(_ context: WKWebExtensionContext) -> Bool {
        let id = context.uniqueIdentifier
        if let allowed = proxyAllowed(id) { return allowed }
        guard installed.contains(where: { $0.id == id }) else { return false }
        let name = context.webExtension.displayName ?? ""
        let allowed = ask(context, title: L("« \(name) » veut servir de VPN", "“\(name)” wants to act as a VPN"),
                          more: L("Toutes vos pages passeraient par ses serveurs, celles des fenêtres privées comprises. Modifiable dans Réglages › Extensions.",
                                  "All your pages would go through its servers, private windows included. You can change this in Settings › Extensions."))
        setProxyAllowed(allowed, for: id)
        return allowed
    }

    func setProxyAllowed(_ allowed: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].proxyAllowed = allowed
        if !allowed { installed[index].proxy = nil }
        ExtensionFiles.save(installed)
        if !allowed { ExtensionProxy.shared.release(id, telling: true) }
    }

    func rememberProxy(_ saved: SavedProxy?, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].proxy != saved else { return }
        installed[index].proxy = saved
        ExtensionFiles.save(installed)
    }

    /// The password it gives for `server`, from its webRequest.onAuthRequired listeners.
    func proxyCredential(from id: String, for server: ExtensionProxy.Server) async -> ExtensionProxy.Credential? {
        guard let context = contexts[id] else { return nil }
        let reply = await askBackground(context, ["nuriProxyAuth": ["host": server.host, "port": server.port, "scheme": server.scheme]],
                                        timeout: 25) as? [String: Any]
        guard let user = reply?["username"] as? String, let password = reply?["password"] as? String else { return nil }
        return ExtensionProxy.Credential(user: user, password: password)
    }

    /// Its chrome.proxy.settings.onChange.
    func tellProxyChanged(_ id: String, _ details: [String: Any]) {
        guard let context = contexts[id] else { return }
        Task { _ = await askBackground(context, ["nuriProxyChanged": details], timeout: 5) }
    }

    // MARK: - Telling the background (ExtensionSockets)

    /// A page of each extension's own, kept to tell its background what Nuri receives for it.
    @ObservationIgnored private var messengers: [String: WKWebView] = [:]
    @ObservationIgnored private var tellings: [String: Task<Void, Never>] = [:]

    /// `message` to extension-shim.js in its background, after those before it. `done`: whether
    /// the background took it (true when the shim answered true).
    func tellBackground(_ id: String, _ message: [String: Any], done: @escaping (Bool) -> Void = { _ in }) {
        guard let context = contexts[id] else { return done(false) }
        let previous = tellings[id]
        tellings[id] = Task {
            await previous?.value
            done(await deliver(message, to: context))
        }
    }

    private func deliver(_ message: [String: Any], to context: WKWebExtensionContext) async -> Bool {
        let id = context.uniqueIdentifier
        guard contexts[id] === context else { return false }
        var page = messengers[id]
        if page?.url == nil {
            page = await blankPage(of: context)
            messengers[id] = page
        }
        let answer = await page?.nuriCall("""
            return await browser.runtime.sendMessage(message).then((reply) => reply === true, () => null);
            """, arguments: ["message": message], world: .page, timeout: 10) as? Bool
        // No answer at all: the page is made again next time.
        if answer == nil { messengers[id] = nil }
        return answer == true
    }

    /// A question for extension-shim.js in its background, from a blank page of its own (see
    /// backgroundAnswers). nil without an answer.
    private func askBackground(_ context: WKWebExtensionContext, _ message: [String: Any], timeout: Double) async -> Any? {
        guard let page = await blankPage(of: context) else { return nil }
        return await page.nuriCall("""
            return await Promise.race([
              browser.runtime.sendMessage(message).then((reply) => reply ?? null, () => null),
              new Promise((done) => setTimeout(() => done(null), \(Int(timeout * 1000))))]);
            """, arguments: ["message": message], world: .page, timeout: timeout + 1)
    }

    func openOptions(_ id: String, in browser: BrowserModel) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        browser.openTab(url: url)
        browser.window?.makeKeyAndOrderFront(nil)
    }

    func menuItems(for tab: Tab) -> [NSMenuItem] {
        guard controller != nil, tab.browser?.isPrivate != true else { return [] }
        return running.flatMap { $0.context.menuItems(for: adapter(for: tab)) }
    }

    func performCommand(for event: NSEvent) -> Bool {
        guard controller != nil else { return false }
        return contexts.values.contains { $0.performCommand(for: event) }
    }

    // MARK: - Telling extensions what happens

    private func adapter(for tab: Tab) -> ExtensionTab {
        if let existing = tab.extensionAdapter as? ExtensionTab { return existing }
        let made = ExtensionTab(tab)
        tab.extensionAdapter = made
        return made
    }

    private func adapter(for browser: BrowserModel) -> ExtensionWindow {
        if let existing = browser.extensionAdapter as? ExtensionWindow { return existing }
        let made = ExtensionWindow(browser)
        browser.extensionAdapter = made
        return made
    }

    fileprivate func tabs(of browser: BrowserModel) -> [ExtensionTab] { browser.allTabs.map(adapter(for:)) }
    fileprivate func activeTab(of browser: BrowserModel) -> ExtensionTab? { browser.selectedTab.map(adapter(for:)) }
    fileprivate func window(of tab: Tab) -> ExtensionWindow? { tab.browser.map(adapter(for:)) }
    fileprivate func tabAdapter(_ tab: Tab) -> ExtensionTab { adapter(for: tab) }

    private func controllerFor(_ tab: Tab) -> WKWebExtensionController? { tab.isPrivate ? nil : controller }

    func tabOpened(_ tab: Tab) { controllerFor(tab)?.didOpenTab(adapter(for: tab)) }
    func tabClosed(_ tab: Tab) { controllerFor(tab)?.didCloseTab(adapter(for: tab), windowIsClosing: false) }

    func tabActivated(_ tab: Tab, previous: Tab?) {
        controllerFor(tab)?.didActivateTab(adapter(for: tab), previousActiveTab: previous.map(adapter(for:)))
    }

    func tabMoved(_ tab: Tab, from index: Int) {
        controllerFor(tab)?.didMoveTab(adapter(for: tab), from: index, in: window(of: tab))
    }

    func tabChanged(_ tab: Tab, _ change: Extensions.TabChange) {
        guard !tab.isClosed else { return }
        let properties: WKWebExtension.TabChangedProperties
        switch change {
        case .title: properties = .title
        case .url: properties = .URL
        case .loading: properties = .loading
        }
        controllerFor(tab)?.didChangeTabProperties(properties, for: adapter(for: tab))
    }

    func windowOpened(_ browser: BrowserModel) {
        guard !browser.isPrivate else { return }
        controller?.didOpenWindow(adapter(for: browser))
    }

    func windowClosed(_ browser: BrowserModel) {
        guard !browser.isPrivate else { return }
        controller?.didCloseWindow(adapter(for: browser))
    }

    func windowFocused(_ browser: BrowserModel) {
        controller?.didFocusWindow(browser.isPrivate ? nil : adapter(for: browser))
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        let windows = BrowserWindows.shared
        let open = windows.all.filter { !$0.isPrivate && $0.window != nil }
        // The focused one first, as WebKit wants.
        return (open.filter { $0 === windows.active } + open.filter { $0 !== windows.active }).map(adapter(for:))
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        let active = BrowserWindows.shared.active
        return active.isPrivate || active.window == nil ? nil : adapter(for: active)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let browser = (configuration.window as? ExtensionWindow)?.browser ?? BrowserWindows.shared.normalTarget
        // chrome.sidePanel.open(): the extension's panel, not a tab.
        if let url = configuration.url, let panelURL = Self.sidePanelURL(url, of: extensionContext) {
            showSidePanel(panelURL, of: extensionContext, in: browser.isPrivate ? BrowserWindows.shared.normalTarget : browser)
            return completionHandler(nil, nil)
        }
        let tab = browser.openTab(url: configuration.url, background: !configuration.shouldBeActive,
                                  after: (configuration.parentTab as? ExtensionTab)?.tab)
        if configuration.shouldBeMuted { tab.setMuted(true) }
        completionHandler(adapter(for: tab), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // Extensions are kept out of private windows, even at their own request.
        let browser = BrowserWindows.shared.openNormalWindow()
        for url in configuration.tabURLs { browser.openTab(url: url) }
        completionHandler(adapter(for: browser), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let raw = permissions.map(\.rawValue)
        let allowed = ask(extensionContext, more: raw.sorted().joined(separator: ", "))
        if allowed { remember(permissions: raw, for: extensionContext) }
        completionHandler(allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap { $0.host() }).sorted()
        let allowed = ask(extensionContext, more: hosts.prefix(5).joined(separator: ", "))
        if allowed { remember(sites: hosts.map { "*://\($0)/*" }, for: extensionContext) }
        completionHandler(allowed ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let sites = matchPatterns.map(\.string).sorted()
        let allowed = ask(extensionContext, more: sites.prefix(5).joined(separator: ", "))
        if allowed { remember(sites: sites, for: extensionContext) }
        completionHandler(allowed ? matchPatterns : [], nil)
    }

    /// Given again at the next launch (see activate).
    func remember(permissions: [String] = [], sites: [String] = [], for context: WKWebExtensionContext) {
        guard let index = installed.firstIndex(where: { $0.id == context.uniqueIdentifier }) else { return }
        installed[index].laterPermissions = Set((installed[index].laterPermissions ?? []) + permissions).sorted()
        installed[index].laterSites = Set((installed[index].laterSites ?? []) + sites).sorted()
        ExtensionFiles.save(installed)
    }

    private func ask(_ context: WKWebExtensionContext, title: String? = nil, more what: String) -> Bool {
        #if DEBUG
        if SelfTestRunner.isRequested { return false }
        #endif
        let name = context.webExtension.displayName ?? ""
        let alert = NSAlert()
        alert.messageText = title ?? L("« \(name) » demande un accès en plus", "“\(name)” is asking for more access")
        alert.informativeText = what
        alert.addButton(withTitle: L("Autoriser", "Allow"))
        alert.addButton(withTitle: L("Refuser", "Deny"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// runtime.sendNativeMessage: only Nuri itself answers, for what extension-shim.js asks of it
    /// (ExtensionNative). No app of the Mac is ever reached.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        guard let identifier = applicationIdentifier, identifier.hasPrefix(ExtensionNative.prefix) else {
            replyHandler(nil, NSError(domain: "Nuri", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Nuri ne relie pas les extensions aux apps du Mac.", "Nuri doesn't connect extensions to Mac apps.")]))
            return
        }
        let app = String(identifier.dropFirst(ExtensionNative.prefix.count))
        Task { replyHandler(await ExtensionNative.handle(app, message, from: extensionContext), nil) }
    }

    // MARK: - Side panel (chrome.sidePanel, extension-shim.js)

    /// The mark extension-shim.js puts on a side panel's page, asked for as a new tab.
    nonisolated static let sidePanelMark = "nuri-side-panel"

    /// The page of a chrome.sidePanel.open(), without Nuri's mark: one of the extension's own pages.
    static func sidePanelURL(_ url: URL, of context: WKWebExtensionContext) -> URL? {
        guard url.scheme?.lowercased() == Extensions.pageScheme, url.host()?.lowercased() == context.baseURL.host()?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == sidePanelMark }) == true else { return nil }
        components.queryItems = components.queryItems?.filter { $0.name != sidePanelMark }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    /// Beside the window's page. The same extension's panel already open gets the new page; another
    /// extension's gives it its place.
    func showSidePanel(_ url: URL, of context: WKWebExtensionContext, in browser: BrowserModel) {
        guard !browser.isPrivate, let configuration = context.webViewConfiguration else { return }
        if let panel = browser.sidePanel, panel.extensionID == context.uniqueIdentifier {
            if panel.webView.url != url { panel.webView.load(URLRequest(url: url)) }
            return
        }
        ExtensionNative.note(context, "side panel shown: \(url.absoluteString)")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.underPageBackgroundColor = .clear
        webView.load(URLRequest(url: url))
        let name = context.webExtension.displayName ?? L("Extension", "Extension")
        let icon = context.webExtension.icon(for: CGSize(width: 32, height: 32))
        let panel = ExtensionSidePanel(extensionID: context.uniqueIdentifier, name: name, icon: icon, webView: webView, browser: browser)
        withAnimation(Theme.spring) { browser.sidePanel = panel }
    }

    /// The panels of an extension going away.
    func closeSidePanels(of id: String) {
        for browser in BrowserWindows.shared.all where browser.sidePanel?.extensionID == id {
            browser.sidePanel = nil
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        revision += 1
    }

    /// Its popup hangs from its own button when it is pinned, else from the extensions button.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let browser = (action.associatedTab as? ExtensionTab)?.tab?.browser ?? BrowserWindows.shared.normalTarget
        guard let popover = action.popupPopover, let view = browser.window?.contentView else {
            completionHandler(nil)
            return
        }
        #if DEBUG
        shownPopover = popover
        shownPopupWebView = action.popupWebView
        #endif
        popover.behavior = .transient
        if let webView = action.popupWebView {
            ExtensionPopupSizing.prepare(popover, webView: webView, extensionID: context.uniqueIdentifier, screen: browser.window?.screen)
        }
        let own = browser.pinnedExtensionFrames[context.uniqueIdentifier].flatMap { $0.isEmpty ? nil : $0 }
        let frame = own ?? browser.extensionsButtonFrame
        popover.show(relativeTo: NSRect(x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height),
                     of: view, preferredEdge: .minY)
        completionHandler(nil)
    }
}

/// A window as extensions see it: the tabs of its current space.
@available(macOS 15.4, *)
@MainActor
private final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var browser: BrowserModel?

    init(_ browser: BrowserModel) { self.browser = browser }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        browser.map(ExtensionHost.shared.tabs(of:)) ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        browser.flatMap(ExtensionHost.shared.activeTab(of:))
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let browser else { return .normal }
        if browser.isFullScreen { return .fullscreen }
        if browser.window?.isMiniaturized == true { return .minimized }
        return browser.window?.isZoomed == true ? .maximized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { browser?.isPrivate == true }
    func frame(for context: WKWebExtensionContext) -> CGRect { browser?.window.map { Self.flip($0.frame) } ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { browser?.window?.screen.map { Self.flip($0.frame) } ?? .null }

    /// Extensions use top-left screen coordinates, AppKit bottom-left ones.
    private static func flip(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    func adapter(of tab: Tab) -> (any WKWebExtensionTab)? { ExtensionHost.shared.tabAdapter(tab) }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.window?.performClose(nil)
        completionHandler(nil)
    }
}

/// A tab as extensions see it. A sleeping tab has no web view: it answers from what it remembers.
@available(macOS 15.4, *)
@MainActor
private final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?

    init(_ tab: Tab) { self.tab = tab }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        tab.flatMap(ExtensionHost.shared.window(of:))
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, !tab.isClosed else { return NSNotFound }
        return tab.browser?.allTabs.firstIndex { $0 === tab } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.webView }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { tab?.isLoading != true }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.isAudible == true }
    func isMuted(for context: WKWebExtensionContext) -> Bool { tab?.isMuted == true }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab.map { $0.browser?.selectedTab === $0 } ?? false }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        // One selected tab per window: selecting is activating, deselecting does nothing.
        guard selected else { return completionHandler(nil) }
        activate(for: context, completionHandler: completionHandler)
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let tab, let browser = tab.browser else { return completionHandler(nil, nil) }
        let copy = browser.openTab(url: tab.url, in: tab.space, background: !configuration.shouldBeActive, after: tab)
        completionHandler(ExtensionHost.shared.window(of: copy)?.adapter(of: copy), nil)
    }
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.webView?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.webView?.pageZoom ?? 1) }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { tab?.reader != nil }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.setMuted(muted)
        completionHandler(nil)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView?.pageZoom = zoomFactor
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { tab?.webView?.reloadFromOrigin() } else { tab?.webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { tab.browser?.select(tab) }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { tab.browser?.requestClose(tab) }
        completionHandler(nil)
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext,
                      completionHandler: @escaping (NSImage?, (any Error)?) -> Void) {
        guard let webView = tab?.webView else { return completionHandler(nil, nil) }
        webView.takeSnapshot(with: configuration) { image, error in
            MainActor.assumeIsolated { completionHandler(image, error) }
        }
    }
}
