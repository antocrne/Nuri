import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, privacy, spaces, downloads, extensions, shortcuts, about
    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .general: L("Général", "General")
        case .appearance: L("Apparence", "Appearance")
        case .privacy: L("Confidentialité", "Privacy")
        case .spaces: L("Espaces", "Spaces")
        case .downloads: L("Téléchargements", "Downloads")
        case .extensions: L("Extensions", "Extensions")
        case .shortcuts: L("Raccourcis", "Shortcuts")
        case .about: L("À propos", "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .privacy: "hand.raised"
        case .spaces: "circle.grid.2x2"
        case .downloads: "arrow.down.circle"
        case .extensions: "puzzlepiece.extension"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }
}

/// Settings, in their own window. Its panes go along the top, as everything in Nuri.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let model = SettingsModel()

    static func show(_ pane: SettingsPane = .general) {
        model.pane = pane
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 420)
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: SettingsView(model: model).environment(AppSettings.shared))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { SettingsWindow.window = nil }
        }
    }
}

@MainActor @Observable
final class SettingsModel {
    var pane: SettingsPane = .general
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { pane in
                    Button { model.pane = pane } label: {
                        VStack(spacing: 3) {
                            Image(systemName: pane.symbol).font(.system(size: 14))
                            Text(pane.title).font(.system(size: 10.5))
                        }
                        .foregroundStyle(model.pane == pane ? Theme.text : Theme.secondaryText)
                        .frame(width: 80, height: 48)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(model.pane == pane ? Theme.selected : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 30)
            .padding(.bottom, 8)
            Divider()
            ScrollView {
                Group {
                    switch model.pane {
                    case .general: GeneralPane()
                    case .appearance: AppearancePane()
                    case .privacy: PrivacyPane()
                    case .spaces: SpacesPane()
                    case .downloads: DownloadsPane()
                    case .extensions: ExtensionsPane()
                    case .shortcuts: ShortcutsPane()
                    case .about: AboutPane()
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: Theme.frameNS))
        .ignoresSafeArea()
        .foregroundStyle(Theme.text)
        .tint(AppSettings.shared.accent.color)
    }
}

// MARK: - Building blocks

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 11) { content }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.control))
        }
        .padding(.bottom, 14)
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        @Bindable var language = LanguageStore.shared
        SettingsGroup(title: L("Langue", "Language")) {
            Picker(L("Langue de Nuri", "Nuri's language"), selection: $language.choice) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
        }
        SettingsGroup(title: L("Navigation", "Browsing")) {
            Picker(L("Moteur de recherche", "Search engine"), selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
            }
            .fixedSize()
            if settings.searchEngine == .custom {
                TextField(L("Adresse, avec %s à la place de la recherche", "Address, with %s in place of the query"), text: $settings.customSearchTemplate)
            }
            Toggle(L("Rouvrir mes onglets au lancement", "Reopen my tabs at launch"), isOn: $settings.restoreTabs)
            Button(L("Faire de Nuri mon navigateur par défaut", "Make Nuri My Default Browser")) { setDefaultBrowser() }
        }
        SettingsGroup(title: L("Légèreté", "Lightness")) {
            Toggle(L("Mettre en veille les onglets inactifs après 30 min", "Put inactive tabs to sleep after 30 min"), isOn: $settings.sleepInactiveTabs)
            Note(L("Ils gardent leur place, leur historique et leur défilement. Ceux qui jouent du son, sont en appel ou contiennent du texte saisi restent éveillés. La veille arrive plus tôt si le Mac manque de mémoire.",
                   "They keep their place, history and scroll position. Those playing sound, in a call or holding typed text stay awake. Sleep comes sooner when the Mac runs low on memory."))
        }
        SettingsGroup(title: L("Vidéo", "Video")) {
            Toggle(L("Picture in Picture automatique en quittant un onglet", "Automatic Picture in Picture when leaving a tab"), isOn: $settings.autoPiP)
            Toggle(L("Réunion en fenêtre flottante en quittant son onglet", "Meeting in a floating window when leaving its tab"), isOn: $settings.autoMeetingPiP)
            Toggle(L("Empêcher la lecture automatique avec le son", "Block autoplay with sound"), isOn: $settings.blockAutoplayWithSound)
        }
        ImportExportGroup()
        Button(L("Revoir la personnalisation du premier lancement…", "Replay First-Launch Personalization…")) {
            BrowserWindows.shared.showMainWindow()
            BrowserModel.shared.onboardingStep = 0
            BrowserModel.shared.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func setDefaultBrowser() {
        let app = Bundle.main.bundleURL
        Task {
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
        }
    }
}

/// Bookmarks and history from another browser, into the current space; its bookmarks out, as the
/// HTML file every browser reads.
private struct ImportExportGroup: View {
    @State private var sources = BrowserImport.sources()
    @State private var bookmarks = true
    @State private var history = true
    @State private var working = false
    @State private var result: String?

    var body: some View {
        let space = BrowserModel.shared.currentSpace
        SettingsGroup(title: L("Importer et exporter", "Import and export")) {
            HStack(spacing: 14) {
                Toggle(L("Favoris et signets", "Bookmarks"), isOn: $bookmarks)
                Toggle(L("Historique", "History"), isOn: $history)
            }
            ForEach(sources) { source in
                HStack {
                    Text(source.name).font(.system(size: 12.5))
                    Spacer()
                    Button(L("Importer", "Import")) { run(source) }
                        .controlSize(.small)
                        .disabled(working || !(bookmarks && source.bookmarks != nil || history && source.history != nil))
                }
            }
            HStack {
                Button(L("Importer un fichier de favoris (HTML)…", "Import a Bookmarks File (HTML)…")) { importFile() }.disabled(working)
                Button(L("Exporter les signets…", "Export Bookmarks…")) { BrowserImport.exportWithPanel(space: space) }
            }
            if let result { Note(result) }
            Note(L("Dans l'espace « \(space.name) ». Les dossiers des autres navigateurs ne sont pas gardés ; ni mots de passe ni cookies ne sont lus.",
                   "Into the space “\(space.name)”. Other browsers' folders aren't kept; no passwords or cookies are read."))
        }
        .onAppear { sources = BrowserImport.sources() }
    }

    private func run(_ source: ImportSource) {
        let space = BrowserModel.shared.currentSpace
        working = true
        result = nil
        Task {
            let outcome = await BrowserImport.run(source, bookmarks: bookmarks, history: history, into: space.id)
            working = false
            switch outcome {
            case .success(let added): result = BrowserImport.summary(added, space: space.name)
            case .failure(let failure): result = failure.message
            }
        }
    }

    private func importFile() {
        let space = BrowserModel.shared.currentSpace
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.prompt = L("Importer", "Import")
        guard panel.runModal() == .OK, let file = panel.url else { return }
        switch BrowserImport.runFile(file, into: space.id) {
        case .success(let added): result = BrowserImport.summary(added, space: space.name)
        case .failure(let failure): result = failure.message
        }
    }
}

private struct AppearancePane: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsGroup(title: L("Fenêtre", "Window")) {
            Picker(L("Thème", "Theme"), selection: $settings.theme) {
                ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Transparence", "Transparency"))
                Slider(value: $settings.transparency, in: 0...1).frame(maxWidth: 320)
            }
            Toggle(L("Halos de couleur doux", "Soft color glows"), isOn: $settings.softGlows)
            Note(L("Ils prennent la couleur de l'espace.", "They take the space's color."))
            Toggle(L("Masquer la barre (elle revient au bord haut de la fenêtre)", "Hide the bar (it comes back at the window's top edge)"), isOn: $settings.autoHideTopBar)
        }
        SettingsGroup(title: L("Couleur d'accent", "Accent color")) {
            ColorChoices(selection: Binding(get: { settings.accent }, set: { settings.accent = $0 ?? .peach }))
        }
    }
}

private struct PrivacyPane: View {
    @Environment(AppSettings.self) private var settings
    @State private var erasedSites = false
    /// Bumped when a site leaves a list below.
    @State private var revision = 0

    var body: some View {
        @Bindable var settings = settings
        SettingsGroup(title: L("Publicités et pisteurs", "Ads and trackers")) {
            Toggle(L("Bloquer les pisteurs et les principales régies publicitaires", "Block trackers and the main ad networks"), isOn: $settings.adBlockEnabled)
            Toggle(L("Retirer les paramètres de pistage des liens (utm, fbclid…)", "Strip tracking parameters from links (utm, fbclid…)"), isOn: $settings.stripTrackingParameters)
            Note(AdBlockList.scopeNote)
            if !settings.adBlockAllowlist.isEmpty {
                Text(L("Bloqueur coupé sur :", "Blocker off for:")).font(.system(size: 12, weight: .medium))
                ForEach(settings.adBlockAllowlist, id: \.self) { host in
                    HStack {
                        Text(host).font(.system(size: 12))
                        Spacer()
                        Button(L("Retirer", "Remove")) { settings.toggleAdBlock(for: host) }.controlSize(.small)
                    }
                }
            }
        }
        SettingsGroup(title: L("Historique", "History")) {
            Picker(L("Conserver l'historique", "Keep history for"), selection: $settings.historyRetention) {
                ForEach(HistoryRetention.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Button(L("Voir et effacer l'historique…", "See and Erase History…")) { HistoryWindow.show(for: BrowserWindows.shared.active) }
        }
        let _ = revision
        let lists = [(L("Notifications autorisées", "Notifications allowed"), WebNotifications.allowedSites),
                     (L("Notifications refusées", "Notifications denied"), WebNotifications.refusedSites),
                     (L("Fenêtres sans clic autorisées", "Windows without a click allowed"), PopupPermission.allowedSites)]
            + MediaPermission.lists.map { ($0.title, $0.list) }
        if lists.contains(where: { !$0.1.hosts.isEmpty }) {
            SettingsGroup(title: L("Autorisations des sites", "Site permissions")) {
                ForEach(lists.filter { !$0.1.hosts.isEmpty }, id: \.0) { title, list in
                    Text(title).font(.system(size: 12, weight: .medium))
                    ForEach(list.hosts, id: \.self) { host in
                        HStack {
                            Text(host).font(.system(size: 12))
                            Spacer()
                            Button(L("Retirer", "Remove")) {
                                list.remove(host)
                                revision += 1
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        SettingsGroup(title: L("Données des sites", "Site data")) {
            Note(L("Chaque espace garde ses cookies et ses connexions à part. Rien n'est envoyé nulle part : pas de compte, pas de statistiques.",
                   "Each space keeps its cookies and sign-ins apart. Nothing is sent anywhere: no account, no analytics."))
            Button(erasedSites ? L("Effacé", "Erased") : L("Effacer cookies et données de l'espace actuel…", "Erase Cookies and Data of the Current Space…")) { eraseSiteData() }
                .disabled(erasedSites)
            SiteDataList(space: BrowserModel.shared.currentSpace)
        }
    }

    private func eraseSiteData() {
        let space = BrowserModel.shared.currentSpace
        let alert = NSAlert()
        alert.messageText = L("Effacer les données de « \(space.name) » ?", "Erase the data of “\(space.name)”?")
        alert.informativeText = L("Vous serez déconnecté des sites de cet espace.", "You will be signed out of the sites in this space.")
        alert.addButton(withTitle: L("Effacer", "Erase"))
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        space.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        erasedSites = true
    }
}

/// The sites that keep something in a space (cookies, storage, cache…), each erased on its own.
private struct SiteDataList: View {
    let space: Space
    @State private var sites: [SiteData.Site]?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sites {
                let shown = filter.isEmpty ? sites : sites.filter { $0.name.localizedCaseInsensitiveContains(filter) }
                HStack {
                    Text(L("\(sites.count) sites ont des données dans « \(space.name) »", "\(sites.count) sites have data in “\(space.name)”"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if sites.count > 8 {
                        TextField(L("Filtrer", "Filter"), text: $filter).textFieldStyle(.roundedBorder).frame(width: 160).controlSize(.small)
                    }
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(shown) { site in
                            HStack {
                                Text(site.name).font(.system(size: 12))
                                Text(site.kinds).font(.system(size: 11)).foregroundStyle(Theme.faintText).lineLimit(1)
                                Spacer()
                                Button(L("Effacer", "Erase")) {
                                    Task {
                                        await SiteData.remove(site, from: space.dataStore)
                                        self.sites = await SiteData.sites(in: space.dataStore)
                                    }
                                }
                                .controlSize(.small)
                            }
                            .frame(height: 26)
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else {
                Text(L("Recherche des sites qui ont des données…", "Looking for sites with data…")).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
        }
        .task(id: space.id) { sites = await SiteData.sites(in: space.dataStore) }
    }
}

private struct SpacesPane: View {
    var body: some View {
        let browser = BrowserModel.shared
        SettingsGroup(title: L("Espaces", "Spaces")) {
            Note(L("Chacun a ses onglets, ses connexions, ses cookies et son historique. Une couleur si vous voulez.",
                   "Each has its own tabs, sign-ins, cookies and history. A color if you want one."))
            ForEach(browser.spaces) { space in
                SpaceEditor(space: space).environment(browser).padding(.vertical, 4)
                if space !== browser.spaces.last { Divider() }
            }
            Button(L("Nouvel espace", "New Space")) {
                browser.addSpace(name: "", color: Pastel.allCases.first { color in !browser.spaces.contains { $0.color == color } })
            }
        }
    }
}

private struct DownloadsPane: View {
    @Environment(AppSettings.self) private var settings
    @State private var hosts = DownloadPermission.allowedHosts

    var body: some View {
        @Bindable var settings = settings
        SettingsGroup(title: L("Fichiers", "Files")) {
            HStack {
                Text(L("Dossier", "Folder"))
                Text(settings.downloadFolder.path).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("Choisir…", "Choose…")) { chooseFolder() }
            }
            Toggle(L("Demander où enregistrer chaque fichier", "Ask where to save each file"), isOn: $settings.askDownloadLocation)
        }
        if !hosts.isEmpty {
            SettingsGroup(title: L("Sites autorisés à enregistrer plusieurs fichiers d'affilée", "Sites allowed to save several files in a row")) {
                ForEach(hosts, id: \.self) { host in
                    HStack {
                        Text(host).font(.system(size: 12))
                        Spacer()
                        Button(L("Retirer", "Remove")) {
                            DownloadPermission.revoke(host)
                            hosts = DownloadPermission.allowedHosts
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.downloadFolder
        if panel.runModal() == .OK, let url = panel.url { settings.downloadFolderPath = url.path }
    }
}

private struct ShortcutsPane: View {
    @State private var revision = 0

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Note(L("Cliquez sur un raccourci puis tapez le nouveau. Aussi depuis la barre de commande : tapez « raccourcis ».",
                       "Click a shortcut, then type the new one. Also from the command bar: type “shortcuts”."))
                Spacer()
                Button(L("Tout rétablir", "Reset All")) {
                    Shortcuts.resetAll()
                    revision += 1
                }
            }
            VStack(spacing: 0) {
                ForEach(NuriCommand.allCases) { command in
                    ShortcutRow(command: command) { revision += 1 }
                    if command != NuriCommand.allCases.last { Divider().opacity(0.5) }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.control))
        }
    }
}

private struct ShortcutRow: View {
    let command: NuriCommand
    let changed: () -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        HStack {
            Text(command.title).font(.system(size: 12.5))
            Spacer()
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(1)
            }
            Button { toggleRecording() } label: {
                Text(recording ? L("Tapez…", "Type…") : (Shortcuts.shortcut(for: command)?.display ?? "—"))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(recording ? Theme.onAccent : (Shortcuts.isCustom(command) ? Theme.accent : Theme.secondaryText))
                    .frame(minWidth: 62, minHeight: 22)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Theme.accent : Theme.selected))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 32)
        .onDisappear { stop() }
    }

    private func toggleRecording() {
        if recording { stop(); return }
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event -> NSEvent? in
            MainActor.assumeIsolated { () -> NSEvent? in
                if event.keyCode == 53 { stop(); return nil }   // Esc
                if event.keyCode == 51 {   // ⌫: no shortcut for this command
                    stop()
                    Shortcuts.set(Shortcut(""), for: command)
                    changed()
                    return nil
                }
                guard let shortcut = Shortcut(event: event) else {
                    message = L("Avec ⌘, ⌃ ou ⌥", "With ⌘, ⌃ or ⌥")
                    return nil
                }
                if let other = Shortcuts.conflict(shortcut, with: command) {
                    message = L("Déjà pris : \(other.title)", "Already used: \(other.title)")
                    return nil
                }
                stop()
                Shortcuts.set(shortcut, for: command)
                changed()
                return nil
            }
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct AboutPane: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 4) {
            NuriWordmark(height: 26)
            Text(L("Version \(Updater.currentVersion)", "Version \(Updater.currentVersion)")).foregroundStyle(Theme.secondaryText)
            Text(L("« Nuri » veut dire « le monde » en coréen.", "“Nuri” means “the world” in Korean."))
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).padding(.top, 4)
        }
        .padding(.bottom, 16)
        SettingsGroup(title: L("Mises à jour", "Updates")) {
            Toggle(L("Se tenir à jour tout seul", "Keep itself up to date"), isOn: $settings.checkForUpdates)
            Note(L("Nuri regarde les versions publiées au lancement puis toutes les 6 heures. Rien n'est téléchargé sans votre accord, et une version n'est installée que si sa signature est bien celle de Nuri.",
                   "Nuri looks at published versions at launch, then every 6 hours. Nothing is downloaded without your say, and a version is only installed if its signature is really Nuri's."))
            Button(L("Rechercher maintenant", "Check Now")) { Task { await Updater.shared.check(userInitiated: true) } }
        }
    }
}
