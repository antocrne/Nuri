import AppKit
import SwiftUI

struct Suggestion: Identifiable {
    enum Kind {
        case go(URL)
        /// What was typed, read as an address (`navigate`: it may fall back on HTTP or a search).
        case typed(URL, String)
        case search(String)
        case switchTo(Tab)
        /// A result to copy (a calculation, a conversion).
        case copy(String)
        case action(@MainActor () -> Void)
    }
    let symbol: String
    let title: String
    let subtitle: String
    let kind: Kind

    /// Stable across recomputations (same target = same row), so SwiftUI keeps rows in place.
    var id: String {
        switch kind {
        case .go(let url), .typed(let url, _): "go:" + url.absoluteString
        case .search(let text): "search:" + text
        case .switchTo(let tab): "tab:" + tab.id.uuidString
        case .copy(let text): "copy:" + text
        case .action: "action:" + title
        }
    }
}

/// Builds the command bar's rows: address or search, calculations and conversions, open tabs, this
/// space's bookmarks and history, and Nuri's own commands ("shortcuts", "history", "private"…).
/// Private windows get no bookmarks or history. Nothing typed: only the favorites.
@MainActor
enum SuggestionEngine {
    static func suggestions(for raw: String, browser: BrowserModel) -> [Suggestion] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        var out: [Suggestion] = []
        var seen = Set<String>()
        let lower = text.lowercased()
        let useHistory = !browser.isPrivate
        let space = browser.currentSpaceID

        guard !text.isEmpty else {
            guard useHistory else { return [] }
            return BookmarkStore.shared.favorites(space: space).prefix(6).map {
                Suggestion(symbol: "star", title: $0.displayTitle, subtitle: $0.url.absoluteString, kind: .go($0.url))
            }
        }

        if let url = URLResolver.url(from: text) {
            out.append(Suggestion(symbol: "globe", title: url.absoluteString, subtitle: L("Ouvrir", "Open"), kind: .typed(url, text)))
            seen.insert(url.absoluteString)
        }
        let engine = AppSettings.shared.searchEngine.name
        out.append(Suggestion(symbol: "magnifyingglass", title: text, subtitle: L("Rechercher avec \(engine)", "Search with \(engine)"), kind: .search(text)))
        // « 12*4+3 », « 10 km en miles », « 100 usd en eur »: the answer, right under the search (↩ still searches).
        if let result = Calculator.answer(for: text) {
            out.append(Suggestion(symbol: "equal.circle", title: result.text, subtitle: L("Copier", "Copy"), kind: .copy(result.value)))
        } else {
            switch QuickConverter.answer(for: text) {
            case .result(let result):
                out.append(Suggestion(symbol: "equal.circle", title: result.text,
                                      subtitle: [result.note, L("Copier", "Copy")].compactMap { $0 }.joined(separator: " · "), kind: .copy(result.value)))
            case .loading:
                out.append(Suggestion(symbol: "equal.circle", title: L("Conversion…", "Converting…"),
                                      subtitle: L("Taux de change en cours de chargement", "Loading exchange rates"), kind: .action({})))
            case nil:
                break
            }
        }

        for command in commands(for: lower, browser: browser) { out.append(command) }

        var tabRows = 0
        for tab in browser.currentSpace.allTabs where tab !== browser.selectedTab {
            guard tabRows < 4 else { break }
            let hay = (tab.title + " " + (tab.url?.absoluteString ?? "")).lowercased()
            if hay.contains(lower) {
                tabRows += 1
                out.append(Suggestion(symbol: "square.on.square", title: tab.displayTitle, subtitle: L("Aller à l'onglet", "Go to tab"), kind: .switchTo(tab)))
            }
        }
        for bookmark in useHistory ? BookmarkStore.shared.search(text, space: space, limit: 4) : [] where !seen.contains(bookmark.url.absoluteString) {
            seen.insert(bookmark.url.absoluteString)
            out.append(Suggestion(symbol: "star", title: bookmark.displayTitle, subtitle: bookmark.url.absoluteString, kind: .go(bookmark.url)))
        }
        for entry in useHistory ? HistoryStore.shared.search(text, space: space, limit: 6) : [] where !seen.contains(entry.url.absoluteString) {
            seen.insert(entry.url.absoluteString)
            out.append(Suggestion(symbol: "clock", title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                  subtitle: entry.url.absoluteString, kind: .go(entry.url)))
        }
        var ids = Set<String>()
        return Array(out.filter { ids.insert($0.id).inserted }.prefix(11))
    }

    /// What the field completes as it is typed: the site of a bookmark or of a visited page whose
    /// name starts with it ("git" → "github.com"), or a longer address of one when it already has a
    /// path ("github.com/ap" → "github.com/apple"). Bookmarks first, then the pages visited most.
    /// Nothing in a private window, nor for a search (spaces), nor an address with its scheme.
    static func completion(for typed: String, browser: BrowserModel) -> String? {
        guard !browser.isPrivate, !typed.isEmpty, !typed.contains(" "), !typed.contains("://") else { return nil }
        let lower = typed.lowercased()
        let space = browser.currentSpaceID
        let candidates = BookmarkStore.shared.search(typed, space: space, limit: 20).map(\.url)
            + HistoryStore.shared.search(typed, space: space, limit: 30).map(\.url)
        for url in candidates {
            guard let host = url.host()?.nuriNormalizedHost else { continue }
            let full = host + (url.port.map { ":\($0)" } ?? "")
            if full.hasPrefix(lower), full.count > lower.count { return typed + full.dropFirst(typed.count) }
            guard lower.contains("/") else { continue }
            // Up to the end of the next part of the path.
            var address = full + url.path
            if address.hasSuffix("/") { address.removeLast() }
            guard address.lowercased().hasPrefix(lower), address.count > lower.count else { continue }
            let rest = address.dropFirst(lower.count)
            let next = rest.dropFirst().firstIndex(of: "/").map { rest[..<$0] } ?? rest[...]
            return typed + next
        }
        return nil
    }

    /// Nuri's own commands, found by a few letters of what they're called, in either language.
    private static func commands(for lower: String, browser: BrowserModel) -> [Suggestion] {
        guard lower.count >= 3 else { return [] }
        let list: [(keys: [String], symbol: String, title: String, run: @MainActor () -> Void)] = [
            (["shortcuts", "raccourcis", "keyboard", "clavier"], "command", L("Raccourcis clavier", "Keyboard Shortcuts"), { SettingsWindow.show(.shortcuts) }),
            (["settings", "réglages", "reglages", "preferences", "préférences"], "gearshape", L("Ouvrir les réglages", "Open Settings"), { SettingsWindow.show() }),
            (["bookmarks", "favorites", "signets", "favoris"], "bookmark", L("Afficher les favoris et signets", "Show Favorites and Bookmarks"), { browser.showingBookmarks = true }),
            (["history", "historique"], "clock", L("Afficher l'historique", "Show History"), { HistoryWindow.show(for: browser) }),
            (["downloads", "téléchargements", "telechargements"], "arrow.down.circle", L("Afficher les téléchargements", "Show Downloads"), { browser.showingDownloads = true }),
            (["extensions"], "puzzlepiece.extension", L("Gérer les extensions", "Manage Extensions"), { SettingsWindow.show(.extensions) }),
            (["private", "privée", "privee"], "eye.slash", L("Nouvelle fenêtre privée", "New Private Window"), { BrowserWindows.shared.openPrivateWindow() }),
            (["split", "partagée", "partagee", "côte"], "rectangle.split.2x1", L("Vue partagée", "Split View"), { browser.toggleSplit() }),
            (["reader", "lecture"], "doc.plaintext", L("Mode lecture", "Reader Mode"), { browser.toggleReader() }),
            (["folder", "dossier"], "folder", L("Nouveau dossier", "New Folder"), { browser.addFolder() }),
            (["close all", "fermer tous", "fermer tout"], "xmark.square", L("Fermer tous les onglets", "Close All Tabs"), { browser.closeAllTabs() }),
        ]
        return list.filter { $0.keys.contains { $0.hasPrefix(lower) } }
            .map { Suggestion(symbol: $0.symbol, title: $0.title, subtitle: "Nuri", kind: .action($0.run)) }
    }
}

extension Suggestion {
    /// Choosing it. `mode`: where an address or a search opens.
    @MainActor func perform(in browser: BrowserModel, mode: CommandBarMode) {
        switch kind {
        case .go(let url): browser.open(url, mode: mode)
        case .typed(_, let text): browser.navigate(text, mode: mode)
        case .search(let query):
            if let url = AppSettings.shared.searchURL(for: query) { browser.open(url, mode: mode) }
        case .switchTo(let tab): browser.select(tab)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            browser.showToast("doc.on.doc", L("« \(text) » copié", "“\(text)” copied"))
        case .action(let action): action()
        }
    }
}

/// Puts the keyboard in a field that has just appeared. While an accessibility client is looking at
/// the app (a window manager, a launcher, computer use), SwiftUI drops a focus asked for during the
/// view's installation, and its state goes on saying it is focused: what counts is where AppKit's
/// keyboard is, so it is asked again until the field really has it.
@MainActor
func giveFocus(_ focused: FocusState<Bool>.Binding, in browser: BrowserModel) async {
    for delay in [0, 30, 80, 150, 300] {
        try? await Task.sleep(for: .milliseconds(delay))
        guard !Task.isCancelled else { return }
        focused.wrappedValue = false
        await Task.yield()
        focused.wrappedValue = true
        await Task.yield()
        if let editor = browser.window?.firstResponder as? NSTextView, editor.isFieldEditor { return }
    }
}

/// Completes the address as it is typed, the added part selected: typing on replaces it, ⌫ takes it
/// away, ↩ opens it. Only when letters are added at the end: never while erasing or editing inside.
@MainActor
final class InlineCompleter {
    /// What the user typed, without the completion.
    var typed = ""
    /// The text this completer put in the field, while it's there.
    private var shown: String?

    /// The text the field should show instead of `value`, or nil to leave it.
    func complete(_ value: String, browser: BrowserModel) -> String? {
        if value == shown { return nil }   // The completion itself, coming back through the binding.
        shown = nil
        let grew = value.count > typed.count && value.hasPrefix(typed)
        typed = value
        guard grew, let editor = browser.window?.firstResponder as? NSTextView, editor.isFieldEditor,
              editor.selectedRange().location == (value as NSString).length,
              let completed = SuggestionEngine.completion(for: value, browser: browser) else { return nil }
        shown = completed
        // Once SwiftUI has put it in the field: the added part selected.
        let start = (value as NSString).length, length = (completed as NSString).length - start
        DispatchQueue.main.async {
            guard editor.string == completed else { return }
            editor.setSelectedRange(NSRange(location: start, length: length))
        }
        return completed
    }
}

/// Dims the window behind the command bar. Apart from the bar, which leaves at once: the veil outlives
/// it to fade out, and must never take a click meant for the page.
struct CommandBarVeil: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        ZStack {
            if browser.commandBar != nil { Theme.commandBarVeil.transition(.opacity) }
        }
        .animation(Theme.veil, value: browser.commandBar != nil)
        .allowsHitTesting(false)
    }
}

/// The command bar: one field for addresses, searches, calculations and Nuri's commands. ⌘T opens it
/// in the middle of the window; ⌘L, or a click on the address, stretches the address bar into it.
struct CommandBarOverlay: View {
    let request: CommandBarRequest
    @Environment(BrowserModel.self) private var browser
    @Environment(AppSettings.self) private var settings
    @State private var text = ""
    @State private var selection = 0
    @State private var rows: [Suggestion] = []
    @State private var opened = false
    @State private var cardHeight: CGFloat = Self.fieldHeight
    @State private var completer = InlineCompleter()
    @FocusState private var focused: Bool

    private static let fieldHeight: CGFloat = 46
    private static let margin: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let frame = cardFrame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                card
                    .frame(width: frame.width)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .scaleEffect(startsFromAddress || opened ? 1 : 0.97)
                    .opacity(startsFromAddress || opened ? 1 : 0)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .onAppear {
            text = request.text
            completer.typed = request.text
            rows = SuggestionEngine.suggestions(for: request.text, browser: browser)
            withAnimation(Theme.spring) { opened = true }
        }
        .task { await giveFocus($focused, in: browser) }
    }

    /// The address bar is on screen, and this is its address being edited.
    private var startsFromAddress: Bool {
        request.mode == .currentTab && browser.addressFrame != .zero && (!settings.autoHideTopBar || browser.topBarRevealed || browser.isFullScreen)
    }

    private func cardFrame(in size: CGSize) -> CGRect {
        let room = size.width - 2 * Self.margin
        if startsFromAddress {
            let address = browser.addressFrame
            let width = opened ? min(room, max(address.width, 680)) : address.width
            let x = max(Self.margin, min(address.minX, size.width - width - Self.margin))
            return CGRect(x: x, y: max(0, address.midY - Self.fieldHeight / 2), width: width, height: cardHeight)
        }
        let width = min(room, 620)
        // The field in the middle of the window; its list hangs below, and lifts it only if it must.
        let middle = (size.height - Self.fieldHeight) / 2
        let y = request.mode == .newTab ? max(Self.margin, min(middle, size.height - cardHeight - Self.margin)) : 8
        return CGRect(x: (size.width - width) / 2, y: y, width: width, height: cardHeight)
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: request.mode == .newTab ? "plus" : "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
                TextField(request.mode == .newTab ? L("Nouvel onglet : adresse, recherche, calcul…", "New tab: address, search, calculation…")
                                                  : L("Adresse, recherche, calcul, commande…", "Address, search, calculation, command…"),
                          text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onChange(of: text) { _, value in
                        if let completed = completer.complete(value, browser: browser) {
                            text = completed
                            return
                        }
                        rows = SuggestionEngine.suggestions(for: value, browser: browser)
                        selection = 0
                    }
                    .onSubmit(submit)
                    .onExitCommand { close() }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
            }
            .padding(.horizontal, 14)
            .frame(height: Self.fieldHeight)
            if !rows.isEmpty {
                Divider().opacity(0.6)
                SuggestionList(rows: rows, selection: $selection, choose: choose)
            }
        }
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.commandBarCard))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Theme.hairline))
        .shadow(color: Theme.shadow, radius: 24, y: 10)
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(rows.count - 1, max(0, selection + delta))
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { close(); return }
        // The first rows are what was typed: ↩ opens it, whatever comes next in the list.
        if rows.indices.contains(selection), selection > 0 {
            choose(rows[selection])
        } else {
            close()
            browser.navigate(trimmed, mode: request.mode)
        }
    }

    private func choose(_ row: Suggestion) {
        close()
        row.perform(in: browser, mode: request.mode)
    }

    private func close() {
        browser.commandBar = nil
        if let webView = browser.selectedTab?.webView { webView.window?.makeFirstResponder(webView) }
    }
}

/// The new tab page's address bar: a real field, not a way to another one. Its list floats below.
struct NewTabField: View {
    @Environment(BrowserModel.self) private var browser
    @State private var text = ""
    @State private var selection = 0
    @State private var rows: [Suggestion] = []
    @State private var completer = InlineCompleter()
    @FocusState private var focused: Bool

    private var tint: Color { browser.isPrivate ? Theme.privateText : Theme.secondaryText }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(tint)
            TextField(L("Rechercher ou saisir une adresse", "Search or enter an address"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(browser.isPrivate ? Theme.privateText : Theme.text)
                .focused($focused)
                .onChange(of: text) { _, value in
                    if let completed = completer.complete(value, browser: browser) {
                        text = completed
                        return
                    }
                    rows = value.isEmpty ? [] : SuggestionEngine.suggestions(for: value, browser: browser)
                    selection = 0
                }
                .onSubmit(submit)
                .onExitCommand { text = "" }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
        }
        .padding(.horizontal, 14)
        .frame(width: 480, height: 42)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(focused ? Theme.selected : Theme.control))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.hairline))
        .animation(Theme.quick, value: focused)
        .overlay(alignment: .top) {
            if !rows.isEmpty {
                SuggestionList(rows: rows, selection: $selection, choose: choose)
                    .frame(width: 480)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.hairline))
                    .shadow(color: Theme.shadow, radius: 16, y: 6)
                    .offset(y: 48)
            }
        }
        .task(id: browser.newTabFieldFocus) { await giveFocus($focused, in: browser) }
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(rows.count - 1, max(0, selection + delta))
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if rows.indices.contains(selection), selection > 0 {
            choose(rows[selection])
        } else {
            browser.navigate(trimmed, mode: .newTab)
        }
    }

    private func choose(_ row: Suggestion) {
        text = ""
        row.perform(in: browser, mode: .newTab)
    }
}

/// The rows under a command field.
private struct SuggestionList: View {
    let rows: [Suggestion]
    @Binding var selection: Int
    let choose: (Suggestion) -> Void
    /// A pointer resting where the list appears doesn't pick a row: the list changes under a still
    /// pointer at each key typed, and ↩ would then open that row instead of what was typed.
    @State private var restingPointer = NSEvent.mouseLocation

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                SuggestionRow(row: row, selected: index == selection)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active = phase, NSEvent.mouseLocation != restingPointer else { return }
                        restingPointer = NSEvent.mouseLocation
                        selection = index
                    }
                    .onTapGesture { choose(row) }
            }
        }
        .padding(6)
        .onChange(of: rows.map(\.id)) { restingPointer = NSEvent.mouseLocation }
    }
}

private struct SuggestionRow: View {
    let row: Suggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.onAccent : Theme.secondaryText)
                .frame(width: 18)
            Text(row.title)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(row.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? Theme.onAccent.opacity(0.75) : Theme.faintText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accent : .clear))
    }
}
