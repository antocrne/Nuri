import AppKit
import SwiftUI

/// The tabs, in the bar. A tab opens when the click is released, so it can be picked up without
/// switching to it; carried along the bar it moves among the others, carried over the page it goes
/// to split view, carried over a folder it goes in. Back on the bar, nothing happens. The active tab
/// is the address bar: stretched, and a click on it edits the address. The two tabs of a split
/// view make one block, which moves along the bar as one.
struct TabStrip: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.chromeForeground) private var foreground

    private static let spacing: CGFloat = 3
    private static let maxWidth: CGFloat = 190
    private static let minWidth: CGFloat = 34
    private static let maxActive: CGFloat = 560
    private static let minActive: CGFloat = 300
    private static let newTabRoom: CGFloat = 32
    /// Around and between the two tabs of a split.
    private static let blockInset: CGFloat = 2
    /// What the list's button takes at the end of a crowded bar.
    private static let listRoom: CGFloat = 48

    private struct Entry: Identifiable {
        let tab: Tab
        /// Tabs of the bar move among themselves; a folder's tab shown next to its folder doesn't.
        let reorderable: Bool
        var id: UUID { tab.id }
    }

    var body: some View {
        let space = browser.currentSpace
        GeometryReader { geometry in
            // A tab of a folder shows here while it is on screen.
            let extras = space.folders.flatMap(\.tabs).filter { tab in browser.visibleTabs.contains { $0 === tab } }
            let entries = extras.map { Entry(tab: $0, reorderable: false) } + space.tabs.map { Entry(tab: $0, reorderable: true) }
            // The pair's block goes where the first of its tabs is (they are side by side in the bar).
            let pair = space.split.flatMap { pair -> (left: Entry, right: Entry, first: UUID)? in
                guard let left = entries.first(where: { $0.id == pair.left }), let right = entries.first(where: { $0.id == pair.right }),
                      let first = entries.first(where: { pair.contains($0.id) }) else { return nil }
                return (left, right, first.id)
            }
            let inset = pair == nil ? 0 : Self.blockInset * 2
            // Down to their icons, the tabs no longer say what they are: the list of them all comes
            // at the end of the bar. Decided on the whole width, so its own room can't undo it.
            let crowded = Self.tabWidths(available: geometry.size.width - inset, count: entries.count, hasActive: browser.selectedTab != nil).normal < TabChip.titleFrom
            let listed = crowded || browser.showingTabList
            let room = geometry.size.width - (listed ? Self.listRoom : 0)
            let widths = Self.tabWidths(available: room - inset, count: entries.count, hasActive: browser.selectedTab != nil)
            let width = { (tab: Tab) in tab === browser.selectedTab ? widths.active : widths.normal }
            HStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(entries) { entry in
                            if let pair, space.split?.contains(entry.id) == true {
                                if entry.id == pair.first {
                                    HStack(spacing: Self.blockInset) {
                                        TabChip(tab: pair.left.tab, width: width(pair.left.tab), reorderable: pair.left.reorderable)
                                            .id(pair.left.id)
                                        TabChip(tab: pair.right.tab, width: width(pair.right.tab), reorderable: pair.right.reorderable)
                                            .id(pair.right.id)
                                    }
                                    .padding(Self.blockInset)
                                    .background(RoundedRectangle(cornerRadius: Metrics.controlRadius + Self.blockInset, style: .continuous).fill(Theme.control))
                                    .accessibilityElement(children: .contain)
                                    .accessibilityLabel(L("Vue partagée", "Split View"))
                                }
                            } else {
                                TabChip(tab: entry.tab, width: width(entry.tab), reorderable: entry.reorderable)
                                    .id(entry.id)
                            }
                        }
                        newTabButton
                    }
                    .animation(Theme.spring, value: browser.selectedTab?.id)
                    // The whole width, past the last tab: all of it moves the window.
                    .frame(minWidth: room, alignment: .leading)
                    .frame(height: Metrics.topBarHeight)
                    .background(TitleBarDragArea())
                }
                .scrollDisabled(browser.carry != nil)
                // A link dragged from a page, a file or another app: a new tab for it.
                .dropDestination(for: URL.self) { urls, _ in browser.openDroppedLinks(urls) }
                .onChange(of: browser.selectedTab?.id) { _, id in
                    if let id { withAnimation(Theme.quick) { reader.scrollTo(id) } }
                }
            }
            // Always there, so its panel has where to open from when the shortcut asks for it.
            TabListButton(tabs: entries.map(\.tab))
                .frame(width: listed ? Self.listRoom : 0, alignment: .trailing)
                .opacity(listed ? 1 : 0)
                .allowsHitTesting(listed)
                .accessibilityHidden(!listed)
            }
        }
        .frame(height: Metrics.topBarHeight)
    }

    private var newTabButton: some View {
        ChromeButton(symbol: "plus", help: L("Nouvel onglet (⌘T)", "New tab (⌘T)")) { browser.showCommandBar(.newTab) }
            .padding(.leading, 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WindowSpace.name)) } action: { browser.newTabButtonFrame = $0 }
    }

    /// The active tab carries the address, so it comes first: the others share what it leaves, down
    /// to their icon, and past that the row scrolls. When they all fit it takes the rest.
    static func tabWidths(available: CGFloat, count: Int, hasActive: Bool) -> (normal: CGFloat, active: CGFloat) {
        let room = max(0, available - newTabRoom - CGFloat(max(0, count - 1)) * spacing)
        let others = CGFloat(max(0, count - (hasActive ? 1 : 0)))
        guard hasActive else { return (max(minWidth, min(room / max(1, others), maxWidth)), 0) }
        let least = min(minActive, room * 0.6)
        let normal = others > 0 ? max(minWidth, min((room - least) / others, maxWidth)) : maxWidth
        return (normal, max(least, min(maxActive, room - normal * others)))
    }
}

/// One tab. All its gestures are here: release to open, carry to move.
struct TabChip: View {
    let tab: Tab
    let width: CGFloat
    /// Tabs of the bar move among themselves; a folder's tab shown next to its folder doesn't.
    let reorderable: Bool
    @Environment(BrowserModel.self) private var browser
    @State private var pointerInside = false

    /// While a tab is carried the others pass under the pointer: none of them lights up.
    private var hovering: Bool { pointerInside && browser.carry == nil }

    var body: some View {
        let selected = browser.selectedTab === tab
        let carried = browser.carry?.tabID == tab.id
        chip(selected: selected)
            .frame(width: width)
            .opacity(carried ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WindowSpace.name)) } action: { browser.tabFrames[tab.id] = $0 }
            .onHover { pointerMoved(inside: $0) }
            .animation(Theme.quick, value: hovering)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(WindowSpace.name))
                    .onChanged { browser.tabDragChanged(tab, location: $0.location, translation: $0.translation) }
                    .onEnded { browser.tabDragEnded(tab, translation: $0.translation) }
            )
            .contextMenu { TabMenu(tab: tab) }
            // The others have their card (TabPreviewCard) when their title is cut.
            .help(selected ? L("\(tab.displayTitle) : rechercher ou saisir une adresse (⌘L)", "\(tab.displayTitle): search or enter an address (⌘L)") : "")
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Its card under the pointer

    /// Narrower than this, a tab is its icon alone.
    static let titleFrom: CGFloat = 62
    private static let titleFont = NSFont.systemFont(ofSize: 12)
    /// The card waits for the pointer to rest on a first tab; from one tab to the next it follows at once.
    private static let previewDelay: Duration = .milliseconds(350)
    /// Between two tabs the pointer is over none: the card stays this long, so it doesn't blink.
    private static let leaveDelay: Duration = .milliseconds(140)

    /// What its whole title needs: margins, icon, title, its buttons (close, sound, call).
    static func fittingWidth(_ tab: Tab) -> CGFloat {
        let title = ceil((tab.displayTitle as NSString).size(withAttributes: [.font: titleFont]).width)
        let buttons = 18 * CGFloat(1 + (tab.isAudible || tab.isMuted ? 1 : 0) + (tab.isInCall ? 1 : 0))
        return 8 + 15 + 6 + title + 6 + 6 + buttons + 8
    }

    private func pointerMoved(inside: Bool) {
        pointerInside = inside
        let id = tab.id
        if inside {
            guard browser.carry == nil else { return }
            if browser.previewTabID != nil {
                browser.previewTabID = id
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: Self.previewDelay)
                    if pointerInside, browser.carry == nil { browser.previewTabID = id }
                }
            }
        } else if browser.previewTabID == id {
            Task { @MainActor in
                try? await Task.sleep(for: Self.leaveDelay)
                if browser.previewTabID == id, !pointerInside { browser.previewTabID = nil }
            }
        }
    }

    @ViewBuilder
    private func chip(selected: Bool) -> some View {
        let compact = width < Self.titleFrom && !selected
        HStack(spacing: 6) {
            TabIcon(tab: tab)
            if selected {
                TabAddress(tab: tab, showsTools: width >= 260 || hovering)
            } else if !compact {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(titleColor(selected: selected))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if !compact || !hovering { accessories(selected: selected, compact: compact) }
        }
        .padding(.leading, compact ? 0 : 8)
        .padding(.trailing, compact ? 0 : (selected ? 4 : 8))
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.tabHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
            .fill(selected ? Theme.selected : (hovering ? Theme.controlHover : .clear)))
        .overlay(alignment: .bottom) {
            if selected, tab.isLoading, tab.progress < 1 { loadingLine }
        }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.controlRadius))
    }

    private var loadingLine: some View {
        GeometryReader { geometry in
            Capsule().fill(Theme.accent)
                .frame(width: max(8, (geometry.size.width - 16) * tab.progress), height: 2)
                .animation(.easeOut(duration: 0.2), value: tab.progress)
                .offset(x: 8, y: geometry.size.height - 2)
        }
        .allowsHitTesting(false)
    }

    private func titleColor(selected: Bool) -> Color {
        if browser.isPrivate { return Theme.privateText.opacity(selected ? 1 : 0.8) }
        if selected { return Theme.text }
        return tab.isAsleep ? Theme.faintText : Theme.secondaryText
    }

    @ViewBuilder
    private func accessories(selected: Bool, compact: Bool) -> some View {
        HStack(spacing: 0) {
            if tab.isInCall {
                TabMiniButton(symbol: "video.fill", help: L("Réunion en fenêtre flottante", "Meeting in floating window"), tint: Theme.accent) {
                    Task { await PiPController.shared.toggle(tab) }
                }
            }
            if tab.isAudible || tab.isMuted {
                TabMiniButton(symbol: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                              help: tab.isMuted ? L("Remettre le son de l'onglet", "Unmute tab") : L("Couper le son de l'onglet", "Mute tab"),
                              tint: tab.isMuted ? Theme.secondaryText : Theme.accent) {
                    tab.setMuted(!tab.isMuted)
                }
            }
            if !compact, hovering || selected {
                TabMiniButton(symbol: "xmark", help: L("Fermer l'onglet (⌘W)", "Close tab (⌘W)"), tint: Theme.secondaryText) {
                    browser.requestClose(tab)
                }
            }
        }
    }
}

/// The favicon, or the site's first letter; a dotted ring around it while it loads.
struct TabIcon: View {
    let tab: Tab

    var body: some View {
        Group {
            if let favicon = tab.favicon {
                Image(nsImage: favicon).resizable().interpolation(.high)
            } else {
                let letter = tab.displayTitle.first.map { String($0).uppercased() } ?? "•"
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.accent.opacity(0.55))
                    .overlay(Text(letter).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onAccent))
            }
        }
        .frame(width: 15, height: 15)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .opacity(tab.isAsleep ? 0.55 : 1)
    }
}

private struct TabMiniButton: View {
    let symbol: String
    let help: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.control : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// A tab's right-click menu.
struct TabMenu: View {
    let tab: Tab
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        IconMenuItem(tab.isMuted ? L("Remettre le son de l'onglet", "Unmute Tab") : L("Couper le son de l'onglet", "Mute Tab"),
                     tab.isMuted ? "speaker.wave.2" : "speaker.slash") { tab.setMuted(!tab.isMuted) }
        Divider()
        if browser.selectedTab !== tab, browser.splitPartner !== tab {
            IconMenuItem(L("Afficher en vue partagée", "Show in Split View"), "rectangle.split.2x1") { browser.showInSplit(tab) }
        } else if browser.shownSplit != nil {
            IconMenuItem(L("Retirer de la vue partagée", "Take Out of Split View"), "rectangle") { browser.takeOutOfSplit(tab) }
        }
        if !browser.isPrivate {
            if tab.url != nil, tab.space.map({ BookmarkStore.shared.bookmark(for: tab.url, space: $0.id) == nil }) == true {
                IconMenuItem(L("Ajouter aux signets", "Add to Bookmarks"), "bookmark") { browser.bookmark(tab) }
            }
            let space = tab.space
            Menu {
                ForEach(space?.folders ?? []) { folder in
                    if space?.folder(of: tab) !== folder { IconMenuItem(folder.name, folder.icon) { browser.put(tab, in: folder) } }
                }
                if space?.folders.isEmpty == false { Divider() }
                IconMenuItem(L("Nouveau dossier…", "New Folder…"), "folder.badge.plus") { browser.addFolder(with: tab) }
            } label: {
                Label(L("Ranger dans un dossier", "Put in Folder"), systemImage: "folder").labelStyle(.titleAndIcon)
            }
            if space?.folder(of: tab) != nil {
                IconMenuItem(L("Retirer du dossier", "Take Out of Folder"), "folder.badge.minus") { browser.removeFromFolder(tab) }
                if !tab.isAsleep { IconMenuItem(L("Mettre en veille", "Put to Sleep"), "moon") { browser.sleepTab(tab) } }
            }
        }
        if !tab.isAsleep, browser.selectedTab !== tab, browser.splitPartner !== tab {
            IconMenuItem(L("Mettre en veille", "Put to Sleep"), "moon") { browser.sleepTab(tab) }
        }
        Divider()
        IconMenuItem(L("Fermer l'onglet", "Close Tab"), "xmark") { browser.requestClose(tab) }
        IconMenuItem(L("Fermer tous les onglets sauf celui-ci", "Close All Other Tabs"), "xmark.square") { browser.closeAllTabs(keeping: tab) }
        IconMenuItem(L("Fermer tous les onglets", "Close All Tabs"), "xmark.rectangle") { browser.closeAllTabs() }
    }
}

/// A folder in the bar, next to the space's dot: a chip that opens the list of its tabs, and a place
/// to drop a tab. `compact`: its icon alone, when there are many.
struct FolderChip: View {
    @Bindable var folder: TabFolder
    var compact = false
    @Environment(BrowserModel.self) private var browser
    @State private var showingList = false
    @State private var hovering = false

    var body: some View {
        let isTarget = browser.carry?.dropFolder == folder.id
        let containsShown = folder.tabs.contains { tab in browser.visibleTabs.contains { $0 === tab } }
        let colored = folder.color != nil
        Button { showingList.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isTarget ? "folder.fill.badge.plus" : folder.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(colored ? Theme.onAccent : (isTarget ? Theme.text : Theme.accent))
                    .frame(minWidth: 14)
                if !compact {
                    Text(folder.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colored ? Theme.onAccent : Theme.text)
                        .lineLimit(1)
                }
                Text("\(folder.tabs.count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(colored ? Theme.onAccent.opacity(0.75) : Theme.secondaryText)
            }
            .padding(.horizontal, compact ? 7 : 9)
            .frame(height: 30)
            .frame(maxWidth: 130)
            .fixedSize()
            .background { background(isTarget: isTarget, lit: containsShown || hovering) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WindowSpace.name)) } action: { browser.folderFrames[folder.id] = $0 }
        .help(folder.name)
        .contextMenu {
            IconMenuItem(L("Nom, icône et couleur…", "Name, Icon and Color…"), "pencil") { browser.renamingFolderID = folder.id }
            IconMenuItem(L("Mettre ses onglets en veille", "Put Its Tabs to Sleep"), "moon") { folder.tabs.forEach { browser.sleepTab($0) } }
            Divider()
            IconMenuItem(L("Supprimer le dossier, garder ses onglets", "Delete Folder, Keep Its Tabs"), "folder.badge.minus") { browser.deleteFolder(folder, keepingTabs: true) }
            IconMenuItem(L("Supprimer le dossier et ses onglets", "Delete Folder and Its Tabs"), "trash", role: .destructive) { browser.deleteFolder(folder, keepingTabs: false) }
        }
        .popover(isPresented: $showingList, arrowEdge: .bottom) { list }
        .popover(isPresented: Binding(get: { browser.renamingFolderID == folder.id },
                                      set: { if !$0 { browser.renamingFolderID = nil; browser.setNeedsSave() } }), arrowEdge: .bottom) {
            FolderEditor(folder: folder) {
                browser.renamingFolderID = nil
                browser.setNeedsSave()
            }
        }
    }

    /// Its color is solid, so nothing behind the window can weaken the icon on it, and lit by getting
    /// lighter, which only helps: the pastels all carry dark text.
    @ViewBuilder
    private func background(isTarget: Bool, lit: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        if let color = folder.color {
            shape.fill(color.color)
                .overlay(shape.fill(.white.opacity(lit ? 0.2 : 0)))
                .overlay(shape.strokeBorder(Theme.onAccent.opacity(isTarget ? 0.6 : 0), lineWidth: 1.5))
        } else {
            shape.fill(isTarget ? Theme.accent.opacity(0.35) : (lit ? Theme.control : Theme.controlHover.opacity(0.5)))
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 1) {
            if folder.tabs.isEmpty {
                Text(L("Glissez un onglet ici pour le garder pour plus tard.", "Drag a tab here to keep it for later."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
            ForEach(folder.tabs) { tab in
                TabRow(tab: tab) {
                    showingList = false
                    browser.select(tab)
                }
            }
        }
        .padding(6)
        .frame(width: 270)
    }
}

/// A folder's name, icon and color.
struct FolderEditor: View {
    @Bindable var folder: TabFolder
    let done: () -> Void
    @Environment(BrowserModel.self) private var browser
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Nom du dossier", "Folder name"), text: $folder.name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onAppear { nameFocused = true }
                .onSubmit(done)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 7), spacing: 2) {
                ForEach(TabFolder.icons, id: \.self) { icon in
                    Button {
                        folder.icon = icon
                        browser.setNeedsSave()
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundStyle(folder.icon == icon ? Theme.onAccent : Theme.secondaryText)
                            .frame(width: 28, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(folder.icon == icon ? (folder.color?.color ?? Theme.accent) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorChoices(selection: Binding(get: { folder.color }, set: {
                folder.color = $0
                browser.setNeedsSave()
            }), allowsNone: true, noneIsPlain: true, cell: 23, spacing: 0)
        }
        .frame(width: 208)
        .padding(10)
    }
}

/// A tab in a list (a folder's, the bar's): its title has the room the bar doesn't give it.
struct TabRow: View {
    let tab: Tab
    /// The one the keyboard is on, or the one on screen.
    var lit = false
    let open: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            TabIcon(tab: tab)
            Text(tab.displayTitle).font(.system(size: 12.5)).lineLimit(1).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            if hovering {
                Button { browser.requestClose(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering || lit ? Theme.control : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(tab: tab) }
    }
}

// MARK: - The card of the tab under the pointer

extension BrowserModel {
    /// The tab whose card is out: under the pointer, not the one on screen, and its title cut in the bar.
    var previewedTab: Tab? {
        guard carry == nil, commandBar == nil, let id = previewTabID, let frame = tabFrames[id],
              let tab = currentSpace.allTabs.first(where: { $0.id == id }), tab !== selectedTab,
              frame.width < TabChip.fittingWidth(tab) - 1 else { return nil }
        return tab
    }
}

/// With many tabs, their titles are cut or gone. The one under the pointer says its title and its
/// site on a card under the bar: nothing moves in the bar itself.
struct TabPreviewCard: View {
    @Environment(BrowserModel.self) private var browser

    static let width: CGFloat = 250
    private static let margin: CGFloat = 8

    /// Under its tab and centered on it, kept inside the window.
    static func origin(under tab: CGRect, windowWidth: CGFloat) -> CGPoint {
        CGPoint(x: max(margin, min(tab.midX - width / 2, windowWidth - width - margin)), y: tab.maxY + 5)
    }

    var body: some View {
        GeometryReader { geometry in
            if let tab = browser.previewedTab, let frame = browser.tabFrames[tab.id] {
                let origin = Self.origin(under: frame, windowWidth: geometry.size.width)
                card(tab)
                    .offset(x: origin.x, y: origin.y)
                    .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: browser.previewedTab?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func card(_ tab: Tab) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            Text(tab.displayTitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = Self.detail(tab) {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Self.width, alignment: .leading)
        .background(shape.fill(Theme.card))
        .overlay(shape.stroke(Theme.hairline))
        .shadow(color: Theme.shadow, radius: 8, y: 3)
    }

    /// Its site, unless the title is already that, and whether it sleeps.
    static func detail(_ tab: Tab) -> String? {
        var parts: [String] = []
        if !tab.addressText.isEmpty, tab.addressText != tab.displayTitle { parts.append(tab.addressText) }
        if tab.isAsleep, tab.url != nil { parts.append(L("en veille", "asleep")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - The list of the bar's tabs

/// At the end of a crowded bar: how many tabs it holds, and the way to the list of them.
struct TabListButton: View {
    let tabs: [Tab]
    @Environment(BrowserModel.self) private var browser
    @Environment(\.chromeForeground) private var foreground
    @State private var hovering = false

    var body: some View {
        @Bindable var browser = browser
        let help = L("Tous les onglets", "All tabs") + (Shortcuts.shortcut(for: .tabList).map { " (\($0.display))" } ?? "")
        Button { browser.showingTabList.toggle() } label: {
            HStack(spacing: 3) {
                Text("\(tabs.count)").font(.system(size: 11.5, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .fixedSize()
            .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(hovering || browser.showingTabList ? Theme.control : Theme.controlHover.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .popover(isPresented: $browser.showingTabList, arrowEdge: .bottom) {
            TabListPanel(tabs: tabs, close: { browser.showingTabList = false }).environment(browser)
        }
    }
}

/// Every tab of the bar with its title, and a field to narrow them down. Arrows and Return work
/// from the field.
struct TabListPanel: View {
    let tabs: [Tab]
    let close: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var query = ""
    @State private var highlighted: UUID?
    @FocusState private var fieldFocused: Bool

    private static let rowHeight: CGFloat = 29
    private static let tallest: CGFloat = 420

    /// The tabs whose title or address holds every word typed, whatever the case or the accents.
    static func matches(_ tabs: [Tab], _ query: String) -> [Tab] {
        let fold = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let words = fold(query).split(separator: " ")
        guard !words.isEmpty else { return tabs }
        return tabs.filter { tab in
            let text = fold(tab.displayTitle + " " + (tab.url?.absoluteString ?? ""))
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        let shown = Self.matches(tabs.filter { !$0.isClosed }, query)
        let current = shown.first { $0.id == highlighted } ?? shown.first
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("Filtrer les onglets", "Filter tabs"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { if let current { open(current) } }
                .onKeyPress(.upArrow) { move(-1, in: shown, from: current); return .handled }
                .onKeyPress(.downArrow) { move(1, in: shown, from: current); return .handled }
            if shown.isEmpty {
                Text(L("Aucun onglet ne correspond.", "No tab matches."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(8)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(shown) { tab in
                                TabRow(tab: tab, lit: tab === current) { open(tab) }.id(tab.id)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(shown.count) * Self.rowHeight, Self.tallest))
                    .onChange(of: highlighted) { _, id in if let id { reader.scrollTo(id) } }
                    .onAppear { if let id = highlighted { reader.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .padding(8)
        .frame(width: 320)
        .onAppear {
            highlighted = browser.selectedTab?.id
            fieldFocused = true
        }
        .onChange(of: query) { highlighted = Self.matches(tabs, query).first?.id }
    }

    private func move(_ step: Int, in shown: [Tab], from current: Tab?) {
        guard !shown.isEmpty else { return }
        let index = current.flatMap { tab in shown.firstIndex { $0 === tab } } ?? 0
        highlighted = shown[(index + step + shown.count) % shown.count].id
    }

    private func open(_ tab: Tab) {
        close()
        browser.select(tab)
    }
}

// MARK: - Carrying a tab

extension BrowserModel {
    private static let dragThreshold: CGFloat = 4
    /// Above this, a carried tab is still on the bar.
    fileprivate static let barBottom = Metrics.topBarHeight + 10

    /// Pointer moved with a tab pressed. Nothing happens under the threshold: it's still a click.
    func tabDragChanged(_ tab: Tab, location: CGPoint, translation: CGSize) {
        if previewTabID != nil { previewTabID = nil }
        if carry == nil {
            guard hypot(translation.width, translation.height) >= Self.dragThreshold else { return }
            let frame = tabFrames[tab.id]
            let grabbedAt = location.x - translation.width
            carry = TabCarry(tabID: tab.id, grabX: frame.map { grabbedAt - $0.midX } ?? 0, width: frame?.width ?? 170)
        }
        guard var next = carry, next.tabID == tab.id else { return }
        carryPointer.location = location
        next.settling = false
        next.dropFolder = nil
        next.dropSide = nil
        if location.y <= Self.barBottom {
            // Along the bar: over a folder it goes in; otherwise it moves among the others.
            if let folder = currentSpace.folders.first(where: { folderFrames[$0.id]?.contains(location) == true }),
               tab.space?.folder(of: tab) !== folder {
                next.dropFolder = folder.id
            } else {
                reorder(tab, center: location.x - next.grabX)
            }
        } else if canCarryToSplit(tab), pageFrame.contains(location) {
            let page = pageFrame
            next.dropSide = location.x < page.midX ? .left : .right
        }
        if next != carry { carry = next }
    }

    /// Released. No move past the threshold: this is the click, and the tab opens now; on the tab
    /// already open, its address is what's being asked for.
    func tabDragEnded(_ tab: Tab, translation: CGSize) {
        guard let carried = carry, carried.tabID == tab.id else {
            if hypot(translation.width, translation.height) < Self.dragThreshold {
                // The same click may have opened it a moment ago (a window's first click, acted on
                // before this release on a slow Mac): it asked for the tab, not for its address.
                traceClick("relâché sur \(tab.title), ouvert \(selectedTab === tab), premier clic \(openedByFirstClick != nil)")
                let justOpened = openedByFirstClick.map { $0.id == tab.id && $0.at.timeIntervalSinceNow > -0.5 } ?? false
                openedByFirstClick = nil
                if selectedTab !== tab { select(tab) } else if !justOpened { showCommandBar(.currentTab) }
            }
            return
        }
        if let id = carried.dropFolder, let folder = currentSpace.folders.first(where: { $0.id == id }) {
            carry = nil
            put(tab, in: folder)
        } else if let side = carried.dropSide {
            carry = nil
            carryToSplit(tab, side: side)
        } else {
            settle(tab, grabX: carried.grabX)
        }
        setNeedsSave()
    }

    /// Back on the bar: its picture glides to its place, and the tab takes over from it there.
    private func settle(_ tab: Tab, grabX: CGFloat) {
        guard let frame = tabFrames[tab.id] else {
            carry = nil
            return
        }
        carry?.settling = true
        withAnimation(Theme.slide) { carryPointer.location = CGPoint(x: frame.midX + grabX, y: frame.midY) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if self?.carry?.tabID == tab.id, self?.carry?.settling == true { self?.carry = nil }
        }
    }

    /// The carried tab takes the place of every tab whose middle it has passed, however fast the
    /// pointer went. After a swap the other tab's middle is further behind: it can't swap back.
    /// A tab of a split carries its partner: the block moves when its own middle has passed.
    private func reorder(_ tab: Tab, center x: CGFloat) {
        let tabs = currentSpace.tabs
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        if let pair = currentSpace.split, let partnerID = pair.other(than: tab.id),
           let partner = tabs.firstIndex(where: { $0.id == partnerID }), abs(partner - from) == 1,
           let own = tabFrames[tab.id], let other = tabFrames[partnerID] {
            let block = (min(own.minX, other.minX) + max(own.maxX, other.maxX)) / 2 + x - own.midX
            if let target = passed(in: tabs, from: min(from, partner), to: max(from, partner), center: block) {
                moveSplitPair(pair, to: target)
            }
            return
        }
        if let target = passed(in: tabs, from: from, to: from, center: x) { moveTab(tab, to: target) }
    }

    /// The furthest tab, outside `low...high`, whose middle `x` has passed.
    private func passed(in tabs: [Tab], from low: Int, to high: Int, center x: CGFloat) -> Int? {
        var target: Int?
        for index in tabs.indices where index > high {
            guard let frame = tabFrames[tabs[index].id], x > frame.midX else { break }
            target = index
        }
        if target == nil {
            for index in tabs.indices.reversed() where index < low {
                guard let frame = tabFrames[tabs[index].id], x < frame.midX else { break }
                target = index
            }
        }
        return target
    }

    /// Something else must be there to share the page with.
    func canCarryToSplit(_ tab: Tab) -> Bool {
        tab.space === currentSpace && currentSpace.allTabs.count > 1
    }

    /// Let go on the page: it opens on that half. The focused page dragged onto itself pairs up
    /// with the tab used last.
    func carryToSplit(_ tab: Tab, side: SplitSide) {
        if tab === selectedTab, shownSplit == nil {
            let others = currentSpace.allTabs.filter { $0 !== tab && !$0.isClosed }
            guard let partner = others.max(by: { $0.lastAccess < $1.lastAccess }) else { return }
            select(partner)
        }
        if selectedTab == nil { select(tab); return }
        showInSplit(tab, on: side)
    }
}

/// The tab under the pointer while it's carried: the same size as in the bar and held where it was
/// grabbed, so nothing jumps when it's picked up. On the bar it only moves along it.
struct TabCarryGhost: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        if let carry = browser.carry, let tab = browser.currentSpace.allTabs.first(where: { $0.id == carry.tabID }) {
            let pointer = browser.carryPointer.location
            let onBar = pointer.y <= BrowserModel.barBottom
            HStack(spacing: 6) {
                TabIcon(tab: tab)
                if carry.width >= TabChip.titleFrom {
                    Text(tab.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, carry.width >= TabChip.titleFrom ? 8 : 0)
            .frame(width: carry.width, height: Metrics.tabHeight, alignment: carry.width >= TabChip.titleFrom ? .leading : .center)
            .background(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous).stroke(Theme.hairline))
            .shadow(color: Theme.shadow, radius: onBar ? 5 : 12, y: onBar ? 2 : 5)
            .position(x: pointer.x - carry.grabX, y: onBar ? Metrics.topBarHeight / 2 : pointer.y)
            .animation(Theme.quick, value: onBar)
            .allowsHitTesting(false)
        }
    }
}
