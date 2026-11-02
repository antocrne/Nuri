import AppKit
import SwiftUI
import WebKit

/// The bar's one place for extensions: they stay out of the way until asked for, and their popups
/// hang from here.
@available(macOS 15.4, *)
struct ExtensionsButton: View {
    @Environment(BrowserModel.self) private var browser
    @State private var showing = false

    var body: some View {
        ChromeButton(symbol: "puzzlepiece.extension", help: L("Extensions", "Extensions"), isOn: showing) { showing.toggle() }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WindowSpace.name)) } action: { browser.extensionsButtonFrame = $0 }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ExtensionsPanel(close: { showing = false }).environment(browser)
            }
    }
}

@available(macOS 15.4, *)
struct ExtensionsPanel: View {
    let close: () -> Void
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let host = ExtensionHost.shared
        let running = host.running
        VStack(alignment: .leading, spacing: 2) {
            PanelHeader(title: L("Extensions", "Extensions"))
            if running.isEmpty {
                Text(L("Celles du Chrome Web Store fonctionnent ici, la plupart du temps.", "Those from the Chrome Web Store work here, most of the time."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            ForEach(running, id: \.record.id) { item in
                ExtensionRow(id: item.record.id, title: item.record.name,
                             badge: host.action(of: item.context, in: browser)?.badgeText ?? "") {
                    close()
                    // A popover can't open another one while it is still going.
                    DispatchQueue.main.async { host.performAction(item.record.id, in: browser) }
                }
            }
            if let id = offeredFromStore {
                Divider().padding(.vertical, 4)
                PanelRow(symbol: "plus", title: L("Ajouter cette extension à Nuri", "Add This Extension to Nuri")) {
                    close()
                    Task { await host.addFromStore(id: id, in: browser) }
                }
            }
            Divider().padding(.vertical, 4)
            PanelRow(symbol: "gearshape", title: L("Gérer et ajouter…", "Manage and Add…")) {
                close()
                DispatchQueue.main.async { SettingsWindow.show(.extensions) }
            }
        }
        .panelStyle()
    }

    /// The page shown is an extension of the Chrome Web Store that isn't here yet.
    private var offeredFromStore: String? {
        guard let address = browser.selectedTab?.url?.absoluteString, let id = ExtensionFiles.webStoreID(from: address),
              !ExtensionHost.shared.installed.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

@available(macOS 15.4, *)
private struct ExtensionRow: View {
    let id: String
    let title: String
    let badge: String
    let action: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ExtensionIcon(id: id, browser: browser)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Capsule().fill(Theme.accent))
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.control : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

@available(macOS 15.4, *)
private struct ExtensionIcon: View {
    let id: String
    var browser: BrowserModel?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = ExtensionHost.shared.icon(of: id, in: browser, size: size) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.75)).foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Settings

struct ExtensionsPane: View {
    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionsSettings()
        } else {
            SettingsGroup(title: L("Extensions", "Extensions")) {
                Note(L("Les extensions demandent macOS 15.4 ou plus récent.", "Extensions need macOS 15.4 or later."))
            }
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionsSettings: View {
    @State private var address = ""
    @State private var message: String?
    @State private var working = false
    @State private var found: [FoundExtension]?
    @State private var unreadable: [String] = []

    /// A copy in another browser, with what WebKit reads of it.
    struct FoundExtension: Identifiable {
        let copy: BrowserExtensionCopy
        let name: String
        var id: String { copy.id }
    }

    private var host: ExtensionHost { ExtensionHost.shared }
    private var browser: BrowserModel { BrowserWindows.shared.normalTarget }

    var body: some View {
        SettingsGroup(title: L("Installées", "Installed")) {
            if host.installed.isEmpty {
                Note(L("Aucune pour l'instant.", "None yet."))
            }
            ForEach(host.installed) { record in
                row(record)
                if record != host.installed.last { Divider() }
            }
            if !host.installed.isEmpty {
                @Bindable var settings = AppSettings.shared
                Toggle(L("Mettre à jour automatiquement", "Update automatically"), isOn: $settings.extensionsAutoUpdate)
                Note(L("Une fois par jour, Nuri demande au Chrome Web Store la version de chacune : seuls leurs identifiants sont envoyés.",
                       "Once a day, Nuri asks the Chrome Web Store for each one's version: only their identifiers are sent."))
                Button(working ? L("Recherche…", "Checking…") : L("Chercher les mises à jour", "Check for Updates")) {
                    run { message = await host.checkForUpdates() }
                }
                .disabled(working)
            }
        }
        SettingsGroup(title: L("Depuis le Chrome Web Store", "From the Chrome Web Store")) {
            HStack {
                TextField(L("Adresse de l'extension sur le store", "The extension's address on the store"), text: $address)
                    .onSubmit(addAddress)
                Button(L("Ajouter", "Add"), action: addAddress)
                    .disabled(working || ExtensionFiles.webStoreID(from: address) == nil)
            }
            Button(L("Ouvrir le Chrome Web Store", "Open the Chrome Web Store")) {
                if let url = URL(string: "https://chromewebstore.google.com/") {
                    browser.openTab(url: url)
                    browser.window?.makeKeyAndOrderFront(nil)
                }
            }
            Note(L("Sur la page d'une extension, le bouton Extensions de la barre propose de l'ajouter. Le bouton « Ajouter à Chrome » du site, lui, ne fonctionne que dans Chrome.",
                   "On an extension's page, the bar's Extensions button offers to add it. The site's own “Add to Chrome” button only works in Chrome."))
        }
        SettingsGroup(title: L("Déjà dans Chrome", "Already in Chrome")) {
            Button(L("Chercher dans Chrome…", "Look in Chrome…")) { look() }
                .disabled(working)
            Note(L("Regarde les dossiers d'extensions de Chrome, Brave, Edge, Arc et Vivaldi, et rien d'autre. Leurs réglages et leurs comptes restent dans Chrome.",
                   "Looks in the extension folders of Chrome, Brave, Edge, Arc and Vivaldi, and nowhere else. Their settings and accounts stay in Chrome."))
            if let found {
                if found.isEmpty, unreadable.isEmpty {
                    Note(L("Rien à reprendre : aucune extension trouvée.", "Nothing to bring over: no extension found."))
                }
                if !unreadable.isEmpty {
                    let names = unreadable.joined(separator: ", ")
                    Note(L("macOS n'a pas donné accès au dossier de : \(names). Réglages Système → Confidentialité et sécurité → Gestion des apps ou Accès complet au disque.",
                           "macOS didn't give access to the folder of: \(names). System Settings → Privacy & Security → App Management or Full Disk Access."))
                }
                ForEach(found) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.system(size: 12.5)).lineLimit(1)
                            Text("\(item.copy.browser) · \(item.copy.profile)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        if host.installed.contains(where: { $0.id == item.id }) {
                            Text(L("Ajoutée", "Added")).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        } else {
                            Button(L("Ajouter", "Add")) { add(item) }.controlSize(.small).disabled(working)
                        }
                    }
                }
            }
        }
        if let message {
            Note(message).padding(.bottom, 10)
        }
        Note(L("Elles tournent sur le moteur de WebKit, jamais dans les fenêtres privées. Celles qui demandent des fonctions propres à Chrome ne suivent pas toujours : le lien avec une app du Mac (déverrouillage de 1Password ou Bitwarden par leur app) n'existe pas ici.",
               "They run on WebKit's engine, never in private windows. Those that need features specific to Chrome don't always follow: the link with a Mac app (unlocking 1Password or Bitwarden through their app) doesn't exist here."))
    }

    private func row(_ record: InstalledExtension) -> some View {
        HStack(spacing: 9) {
            ExtensionIcon(id: record.id, browser: nil, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if let problem = host.problems[record.id] {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(2)
                } else {
                    Text(record.version).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            if host.webExtension(record.id)?.hasOptionsPage == true {
                Button(L("Options", "Options")) {
                    host.openOptions(record.id, in: browser)
                }
                .controlSize(.small)
            }
            Button(L("Retirer", "Remove")) { confirmRemoval(record) }.controlSize(.small)
            Toggle("", isOn: Binding(get: { record.enabled }, set: { host.setEnabled($0, for: record.id) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func confirmRemoval(_ record: InstalledExtension) {
        let alert = NSAlert()
        alert.messageText = L("Retirer « \(record.name) » ?", "Remove “\(record.name)”?")
        alert.informativeText = L("Ce qu'elle a gardé (réglages, listes) sera effacé.", "What it kept (settings, lists) will be erased.")
        alert.addButton(withTitle: L("Retirer", "Remove"))
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { host.remove(record.id) }
    }

    private func addAddress() {
        guard let id = ExtensionFiles.webStoreID(from: address) else { return }
        run {
            message = nil
            await host.addFromStore(id: id, in: browser)
            if host.installed.contains(where: { $0.id == id }) { address = "" }
        }
    }

    private func look() {
        run {
            var list: [FoundExtension] = []
            let copies = await Task.detached { ExtensionFiles.findInBrowsers() }.value
            unreadable = await Task.detached { ExtensionFiles.unreadableBrowsers() }.value
            for copy in copies {
                let name = (try? await WKWebExtension(resourceBaseURL: copy.folder))?.displayName ?? copy.id
                list.append(FoundExtension(copy: copy, name: name))
            }
            found = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func add(_ item: FoundExtension) {
        run {
            do {
                try await host.add(from: item.copy.folder, id: item.id, source: .browser)
                message = nil
            } catch {
                message = ExtensionHost.describe(error)
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        working = true
        Task {
            await work()
            working = false
        }
    }
}
