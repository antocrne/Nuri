import AppKit
import SwiftUI

/// The only bar: navigation, the space and its folders, the tabs (the active one carries the
/// address), and a few tools. There is no sidebar.
struct TopBar: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        HStack(spacing: 6) {
            lead
            TabStrip()
            tools
        }
        .padding(.trailing, 8)
        .frame(height: Metrics.topBarHeight)
        .background(TitleBarDragArea())
    }

    private var lead: some View {
        HStack(spacing: 6) {
            if !browser.isFullScreen { Color.clear.frame(width: 72, height: 1) }
            navigation
            if browser.isPrivate {
                PrivateBadge()
            } else {
                SpaceChip()
                let folders = browser.currentSpace.folders
                ForEach(folders) { FolderChip(folder: $0, compact: folders.count > 3) }
            }
        }
        .padding(.leading, browser.isFullScreen ? 10 : 0)
    }

    private var navigation: some View {
        let tab = browser.selectedTab
        return HStack(spacing: 0) {
            ChromeButton(symbol: "chevron.left", help: L("Précédent (⌘[)", "Back (⌘[)"), isEnabled: tab?.canGoBack == true) { browser.goBack() }
            ChromeButton(symbol: "chevron.right", help: L("Suivant (⌘])", "Forward (⌘])"), isEnabled: tab?.canGoForward == true) { browser.goForward() }
            ChromeButton(symbol: tab?.isLoading == true ? "xmark" : "arrow.clockwise",
                         help: tab?.isLoading == true ? L("Arrêter", "Stop") : L("Recharger (⌘R)", "Reload (⌘R)"),
                         isEnabled: tab != nil) {
                if tab?.isLoading == true { browser.stopLoading() } else { browser.reload() }
            }
        }
    }

    private var tools: some View {
        HStack(spacing: 2) {
            DownloadsButton()
            if !browser.isPrivate { BookmarksButton() }
            if !browser.isPrivate, #available(macOS 15.4, *) { ExtensionsButton() }
            MoreMenu()
        }
    }
}

private struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.slash.fill").font(.system(size: 11))
            Text(L("Privé", "Private")).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Theme.privateText)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(.white.opacity(0.12)))
        .help(L("Rien de cette fenêtre n'est conservé après sa fermeture.", "Nothing from this window is kept once it closes."))
    }
}

/// What the active tab shows: the address of its page, its title if there's room, and what can be
/// done with the page. A click on the tab (or ⌘L) stretches it into the command bar, in place.
struct TabAddress: View {
    let tab: Tab
    /// Too narrow for the address and the tools at once: they wait for the pointer.
    let showsTools: Bool
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @Environment(\.chromeForeground) private var foreground

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon(tab))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(foreground.opacity(0.75))
            Text(text(tab))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(browser.isPrivate ? Theme.privateText : (tab.url == nil ? Theme.faintText : Theme.text))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if tab.url != nil, tab.displayTitle != tab.addressText {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(browser.isPrivate ? Theme.privateText.opacity(0.7) : Theme.faintText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if tab.url != nil, showsTools {
                pageActions(tab)
            }
        }
    }

    private func icon(_ tab: Tab) -> String {
        guard let url = tab.url else { return "magnifyingglass" }
        if url.scheme == "https", tab.hasOnlySecureContent, !CertificateExceptions.isExcepted(url.host()) { return "lock.fill" }
        return url.scheme == "https" || url.scheme == "http" ? "lock.open" : "globe"
    }

    private func text(_ tab: Tab) -> String {
        guard tab.url != nil else { return L("Rechercher ou saisir une adresse", "Search or enter an address") }
        return tab.addressText
    }

    @ViewBuilder
    private func pageActions(_ tab: Tab) -> some View {
        HStack(spacing: 0) {
            if tab.hasVideo || tab.isInCall {
                ChromeButton(symbol: tab.isInCall ? "video" : "pip", help: tab.isInCall ? L("Réunion en fenêtre flottante (⌘⇧P)", "Meeting in floating window (⌘⇧P)") : "Picture in Picture (⌘⇧P)",
                             size: 24, iconSize: 11, isOn: tab.isInPiP || tab.isInFloatingPlayer) { browser.togglePiP() }
            }
            ChromeButton(symbol: tab.reader == nil ? "doc.plaintext" : "doc.plaintext.fill", help: L("Mode lecture (⌘⇧R)", "Reader mode (⌘⇧R)"),
                         size: 24, iconSize: 11, isOn: tab.reader != nil) { browser.toggleReader() }
            let host = tab.url?.host()
            ChromeButton(symbol: settings.isAdBlockActive(on: host) ? "shield.lefthalf.filled" : "shield.slash",
                         help: settings.adBlockEnabled
                            ? (settings.isAdBlockActive(on: host) ? L("Publicités et pisteurs bloqués : couper pour ce site", "Ads and trackers blocked: turn off for this site")
                                                                  : L("Bloqueur coupé sur ce site : le remettre", "Blocker off for this site: turn back on"))
                            : L("Bloqueur désactivé dans les Réglages", "Blocker turned off in Settings"),
                         size: 24, iconSize: 11, isEnabled: settings.adBlockEnabled) { browser.toggleAdBlockForCurrentSite() }
            if !browser.isPrivate { BookmarkStar(tab: tab) }
        }
    }
}

/// The current space and the way to the others.
struct SpaceChip: View {
    @Environment(BrowserModel.self) private var browser
    @State private var showingList = false
    @State private var hovering = false

    var body: some View {
        let space = browser.currentSpace
        Button { showingList.toggle() } label: {
            Circle()
                .fill(space.tint.color)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Theme.hairline))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(hovering ? Theme.controlHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Espace : \(space.name)", "Space: \(space.name)"))
        .popover(isPresented: $showingList, arrowEdge: .bottom) {
            SpacesPanel(close: { showingList = false }).environment(browser)
        }
    }
}

struct SpacesPanel: View {
    let close: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var editing: Space?
    @State private var newName = ""
    @State private var addingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelHeader(title: L("Espaces", "Spaces"))
            ForEach(browser.spaces) { space in
                row(space)
            }
            Divider().padding(.vertical, 4)
            if addingNew {
                TextField(L("Nom de l'espace", "Space name"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        browser.addSpace(name: name, color: Pastel.allCases.first { color in !browser.spaces.contains { $0.color == color } })
                        newName = ""
                        addingNew = false
                        close()
                    }
            } else if browser.managesSpaces {
                PanelRow(symbol: "plus", title: L("Nouvel espace", "New Space")) { addingNew = true }
            }
            if let editing {
                SpaceEditor(space: editing, onDelete: { self.editing = nil }).padding(.top, 6)
            }
        }
        .panelStyle()
    }

    private func row(_ space: Space) -> some View {
        HStack(spacing: 8) {
            Circle().fill(space.tint.color).frame(width: 10, height: 10)
            Text(space.name).lineLimit(1)
            Spacer()
            if space.id == browser.currentSpaceID {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondaryText)
            }
            if browser.managesSpaces {
                Button {
                    editing = editing === space ? nil : space
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(L("Modifier", "Edit"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(space.id == browser.currentSpaceID ? Theme.control : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            browser.switchSpace(to: space)
            close()
        }
    }
}

/// A space's name and color. Its data (sign-ins, history) goes with it when it is deleted.
struct SpaceEditor: View {
    @Bindable var space: Space
    var onDelete: () -> Void = {}
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Nom", "Name"), text: $space.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { browser.setNeedsSave() }
            ColorChoices(selection: Binding(get: { space.color }, set: {
                space.color = $0
                browser.setNeedsSave()
            }), allowsNone: true)
            if browser.spaces.count > 1 {
                Button(role: .destructive) { confirmDeletion() } label: {
                    Label(L("Supprimer cet espace…", "Delete This Space…"), systemImage: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger)
            }
        }
    }

    private func confirmDeletion() {
        let alert = NSAlert()
        alert.messageText = L("Supprimer « \(space.name) » ?", "Delete “\(space.name)”?")
        alert.informativeText = L("Ses onglets, ses connexions, ses cookies et son historique seront effacés.",
                                  "Its tabs, sign-ins, cookies and history will be erased.")
        alert.addButton(withTitle: L("Supprimer", "Delete"))
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            browser.deleteSpace(space)
            onDelete()
        }
    }
}

/// Pastel dots, going to the next row when the width runs out. `allowsNone`: the first one means
/// "the app's accent", or no color at all with `noneIsPlain`.
struct ColorChoices: View {
    @Binding var selection: Pastel?
    var allowsNone = false
    var noneIsPlain = false
    var cell: CGFloat = 24
    var spacing: CGFloat = 5

    var body: some View {
        WrappingRow(spacing: spacing) {
            if allowsNone {
                dot(nil)
            }
            ForEach(Pastel.allCases) { dot($0) }
        }
    }

    private func dot(_ pastel: Pastel?) -> some View {
        Button { selection = pastel } label: {
            ZStack {
                if pastel == nil, noneIsPlain {
                    Image(systemName: "slash.circle").font(.system(size: 17)).foregroundStyle(Theme.secondaryText)
                } else {
                    Circle().fill(pastel?.color ?? AppSettings.shared.accent.color).frame(width: 18, height: 18)
                    if pastel == nil {
                        Image(systemName: "sparkle").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.onAccent)
                    }
                }
                if selection == pastel {
                    Circle().stroke(Theme.text.opacity(0.7), lineWidth: 1.5).frame(width: 23, height: 23)
                }
            }
            .frame(width: cell, height: cell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pastel?.label ?? (noneIsPlain ? L("Sans couleur", "No color") : L("Couleur d'accent", "Accent color")))
    }
}

/// Everything else, in one panel like the spaces'.
private struct MoreMenu: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.chromeForeground) private var foreground
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(hovering || showing ? Theme.controlHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Plus", "More"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            MorePanel(close: { showing = false }).environment(browser)
        }
    }
}

struct MorePanel: View {
    let close: () -> Void
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelHeader(title: "Nuri")
            item("eye.slash", L("Nouvelle fenêtre privée", "New Private Window"), .newPrivateWindow) { BrowserWindows.shared.openPrivateWindow() }
            if !browser.isPrivate {
                item("folder", L("Nouveau dossier", "New Folder"), .newFolder) { browser.addFolder() }
            }
            Divider().padding(.vertical, 4)
            if !browser.isPrivate {
                item("bookmark", L("Favoris et signets", "Favorites and Bookmarks"), .bookmarks) { browser.showingBookmarks = true }
            }
            item("clock", L("Historique", "History"), .history) { HistoryWindow.show(for: browser) }
            item("arrow.down.circle", L("Téléchargements", "Downloads"), .downloads) { browser.showingDownloads = true }
            if !browser.isPrivate, Extensions.isSupported {
                item("puzzlepiece.extension", L("Extensions", "Extensions"), nil) { SettingsWindow.show(.extensions) }
            }
            Divider().padding(.vertical, 4)
            item("xmark.square", L("Fermer tous les onglets", "Close All Tabs"), .closeAllTabs) { browser.closeAllTabs() }
            Divider().padding(.vertical, 4)
            item("command", L("Raccourcis clavier", "Keyboard Shortcuts"), nil) { SettingsWindow.show(.shortcuts) }
            item("gearshape", L("Réglages…", "Settings…"), nil) { SettingsWindow.show() }
        }
        .panelStyle()
    }

    /// This panel leaves first: a popover can't open another one while it is still going.
    private func item(_ symbol: String, _ title: String, _ command: NuriCommand?, action: @escaping @MainActor () -> Void) -> some View {
        PanelRow(symbol: symbol, title: title, trailing: command.flatMap { Shortcuts.shortcut(for: $0)?.display }) {
            close()
            DispatchQueue.main.async { action() }
        }
    }
}

/// The small title at the top of a panel.
struct PanelHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }
}

/// One choice in a panel.
struct PanelRow: View {
    let symbol: String
    let title: String
    var trailing: String? = nil
    var tint: Color = Theme.text
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 11.5)).foregroundStyle(Theme.faintText)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.control : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// What all the bar's panels have in common.
    func panelStyle() -> some View {
        font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(10)
            .frame(width: 280)
            .fixedSize(horizontal: false, vertical: true)
    }
}
