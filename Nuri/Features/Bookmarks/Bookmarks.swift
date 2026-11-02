import AppKit
import SwiftUI
import Observation

/// A page kept on purpose. A favorite is a bookmark that also shows on the new tab page.
/// Each space has its own, like its history and its sign-ins: a bookmark opens where it makes sense.
struct Bookmark: Identifiable, Codable, Equatable {
    var id = UUID()
    var spaceID: UUID
    var url: URL
    var title: String
    var isFavorite = false
    var favicon: Data?

    var displayTitle: String { title.isEmpty ? (url.host()?.nuriNormalizedHost ?? url.absoluteString) : title }
}

/// bookmarks.json, next to the session. Shared by every normal window; private windows don't use it.
@MainActor @Observable
final class BookmarkStore {
    static let shared = BookmarkStore()
    private(set) var items: [Bookmark] = []
    @ObservationIgnored private let fileURL = StateStore.directory.appendingPathComponent("bookmarks.json")

    private init() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Lossy<Bookmark>].self, from: data) else { return }
        items = saved.compactMap(\.value)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func favorites(space: UUID) -> [Bookmark] { items.filter { $0.spaceID == space && $0.isFavorite } }
    func bookmarks(space: UUID) -> [Bookmark] { items.filter { $0.spaceID == space && !$0.isFavorite } }

    func bookmark(for url: URL?, space: UUID) -> Bookmark? {
        guard let address = url?.absoluteString else { return nil }
        return items.first { $0.spaceID == space && $0.url.absoluteString == address }
    }

    func search(_ text: String, space: UUID, limit: Int) -> [Bookmark] {
        let lower = text.lowercased()
        let found = items.filter { $0.spaceID == space && ($0.title.lowercased().contains(lower) || $0.url.absoluteString.lowercased().contains(lower)) }
        return Array(found.prefix(limit))
    }

    @discardableResult
    func add(url: URL, title: String, favicon: Data?, space: UUID, isFavorite: Bool = false) -> Bookmark {
        if let existing = bookmark(for: url, space: space) { return existing }
        let bookmark = Bookmark(spaceID: space, url: url, title: title, isFavorite: isFavorite, favicon: favicon)
        items.append(bookmark)
        save()
        return bookmark
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].title != title else { return }
        items[i].title = title
        save()
    }

    func setFavorite(_ id: UUID, _ isFavorite: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].isFavorite != isFavorite else { return }
        items[i].isFavorite = isFavorite
        save()
    }

    /// A deleted space takes its bookmarks with it.
    func removeAll(space: UUID) {
        items.removeAll { $0.spaceID == space }
        save()
    }
}

extension BrowserModel {
    /// ⌘D and the star: the page is kept at once, and its small card lets it be named or made a favorite.
    func bookmarkCurrentPage() {
        guard !isPrivate, let tab = selectedTab, let url = tab.url else { return }
        BookmarkStore.shared.add(url: url, title: tab.displayTitle, favicon: tab.faviconData, space: currentSpaceID)
        if AppSettings.shared.autoHideTopBar, !topBarRevealed, !isFullScreen {
            // The star is out of sight with its bar: say it another way.
            showToast("star.fill", L("Ajouté aux signets", "Added to bookmarks"))
        } else {
            editingBookmark = true
        }
    }

    func bookmark(_ tab: Tab) {
        guard !isPrivate, let url = tab.url, let space = tab.space else { return }
        BookmarkStore.shared.add(url: url, title: tab.displayTitle, favicon: tab.faviconData, space: space.id)
        showToast("star.fill", L("Ajouté aux signets", "Added to bookmarks"))
    }

    /// Its tab if it is already open, otherwise a new one.
    func open(_ bookmark: Bookmark) {
        let address = bookmark.url.absoluteString
        if let tab = currentSpace.allTabs.first(where: { $0.url?.absoluteString == address }) {
            select(tab)
        } else {
            openTab(url: bookmark.url)
        }
    }
}

/// A bookmark's icon: its site's, or its first letter.
struct BookmarkIcon: View {
    let bookmark: Bookmark
    var side: CGFloat = 15

    var body: some View {
        Group {
            if let image = bookmark.favicon.flatMap(NSImage.init(data:)) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
                    .fill(Theme.accent.opacity(0.55))
                    .overlay(Text(bookmark.displayTitle.first.map { String($0).uppercased() } ?? "•")
                        .font(.system(size: side * 0.6, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.onAccent))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.27, style: .continuous))
    }
}

/// A favorite: on the new tab page and at the top of the bookmarks panel.
struct FavoriteTile: View {
    let bookmark: Bookmark
    var opened: () -> Void = {}
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        Button {
            opened()
            browser.open(bookmark)
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(hovering ? Theme.selected : Theme.control)
                    .frame(width: 52, height: 52)
                    .overlay(BookmarkIcon(bookmark: bookmark, side: 24))
                Text(bookmark.displayTitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .frame(width: 66)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help(bookmark.url.absoluteString)
        .contextMenu { BookmarkMenu(bookmark: bookmark) }
    }
}

struct BookmarkMenu: View {
    let bookmark: Bookmark
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        IconMenuItem(L("Ouvrir", "Open"), "arrow.up.right.square") { browser.open(bookmark) }
        IconMenuItem(L("Ouvrir dans un nouvel onglet", "Open in New Tab"), "plus.square.on.square") { browser.openTab(url: bookmark.url) }
        Divider()
        IconMenuItem(bookmark.isFavorite ? L("Retirer des favoris", "Remove from Favorites") : L("Ajouter aux favoris", "Add to Favorites"),
                     bookmark.isFavorite ? "star.slash" : "star") {
            BookmarkStore.shared.setFavorite(bookmark.id, !bookmark.isFavorite)
        }
        IconMenuItem(L("Supprimer", "Delete"), "trash", role: .destructive) { BookmarkStore.shared.remove(bookmark.id) }
    }
}

/// The star of the address bar, and the page's small card under it.
struct BookmarkStar: View {
    let tab: Tab
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        let bookmark = BookmarkStore.shared.bookmark(for: tab.url, space: browser.currentSpaceID)
        ChromeButton(symbol: bookmark == nil ? "star" : "star.fill",
                     help: bookmark == nil ? L("Ajouter aux signets (⌘D)", "Add to bookmarks (⌘D)") : L("Modifier le signet (⌘D)", "Edit bookmark (⌘D)"),
                     size: 24, iconSize: 11, isOn: bookmark != nil) { browser.bookmarkCurrentPage() }
            .popover(isPresented: $browser.editingBookmark, arrowEdge: .bottom) {
                if let bookmark {
                    BookmarkEditor(bookmark: bookmark, close: { browser.editingBookmark = false })
                }
            }
    }
}

private struct BookmarkEditor: View {
    let bookmark: Bookmark
    let close: () -> Void
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelHeader(title: L("Signet", "Bookmark"))
            TextField(L("Nom", "Name"), text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { close() }
                .padding(.bottom, 4)
            PanelRow(symbol: bookmark.isFavorite ? "star.fill" : "star",
                     title: bookmark.isFavorite ? L("Retirer des favoris", "Remove from Favorites") : L("Ajouter aux favoris", "Add to Favorites")) {
                BookmarkStore.shared.setFavorite(bookmark.id, !bookmark.isFavorite)
            }
            PanelRow(symbol: "trash", title: L("Supprimer le signet", "Delete Bookmark"), tint: Theme.danger) {
                BookmarkStore.shared.remove(bookmark.id)
                close()
            }
        }
        .panelStyle()
        .onAppear {
            title = bookmark.title
            focused = true
        }
        .onDisappear { BookmarkStore.shared.rename(bookmark.id, to: title) }
    }
}

/// Favorites and bookmarks of the current space, in the same kind of panel as the spaces'.
struct BookmarksButton: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        @Bindable var browser = browser
        ChromeButton(symbol: "bookmark", help: L("Favoris et signets (⌥⌘B)", "Favorites and bookmarks (⌥⌘B)"), isOn: browser.showingBookmarks) {
            browser.showingBookmarks.toggle()
        }
        .popover(isPresented: $browser.showingBookmarks, arrowEdge: .bottom) {
            BookmarksPanel(close: { browser.showingBookmarks = false }).environment(browser)
        }
    }
}

private struct BookmarksPanel: View {
    let close: () -> Void
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let store = BookmarkStore.shared
        let favorites = store.favorites(space: browser.currentSpaceID)
        let bookmarks = store.bookmarks(space: browser.currentSpaceID)
        VStack(alignment: .leading, spacing: 2) {
            if favorites.isEmpty, bookmarks.isEmpty {
                PanelHeader(title: L("Favoris et signets", "Favorites and bookmarks"))
                Text(L("L'étoile de la barre d'adresse (⌘D) garde la page. Chaque espace a les siens.",
                       "The star in the address bar (⌘D) keeps the page. Each space has its own."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            if !favorites.isEmpty {
                PanelHeader(title: L("Favoris", "Favorites"))
                WrappingRow(spacing: 6) {
                    ForEach(favorites) { FavoriteTile(bookmark: $0, opened: close) }
                }
                .padding(.horizontal, 4)
            }
            if !favorites.isEmpty, !bookmarks.isEmpty { Divider().padding(.vertical, 4) }
            if !bookmarks.isEmpty {
                PanelHeader(title: L("Signets", "Bookmarks"))
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(bookmarks) { BookmarkRow(bookmark: $0, opened: close) }
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle()
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark
    let opened: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            BookmarkIcon(bookmark: bookmark)
            Text(bookmark.displayTitle).lineLimit(1)
            Spacer(minLength: 0)
            if hovering {
                Button { BookmarkStore.shared.remove(bookmark.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Supprimer", "Delete"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.control : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            opened()
            browser.open(bookmark)
        }
        .onHover { hovering = $0 }
        .help(bookmark.url.absoluteString)
        .contextMenu { BookmarkMenu(bookmark: bookmark) }
    }
}
