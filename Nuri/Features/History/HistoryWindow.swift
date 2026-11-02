import AppKit
import SwiftUI

/// The history: searched, by space, by day. Erasing is by range: the last hour, day, 30 days, year,
/// or everything.
@MainActor
enum HistoryWindow {
    private static var window: NSWindow?

    static func show(for browser: BrowserModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = HistoryView(spaces: browser.isPrivate ? BrowserModel.shared.spaces : browser.spaces, browser: browser.isPrivate ? .shared : browser)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L("Historique", "History")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            // Its list isn't kept in memory once it is closed.
            MainActor.assumeIsolated { HistoryWindow.window = nil }
        }
    }
}

private struct HistoryView: View {
    let spaces: [Space]
    let browser: BrowserModel
    @State private var query = ""
    /// nil: every space.
    @State private var spaceID: UUID?

    var body: some View {
        let store = HistoryStore.shared
        let _ = store.revision
        let entries = store.search(query, space: spaceID, limit: 500)
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.lastVisit) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    TextField(L("Rechercher dans l'historique", "Search history"), text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
                if spaces.count > 1 {
                    Picker("", selection: $spaceID) {
                        Text(L("Tous les espaces", "All spaces")).tag(UUID?.none)
                        ForEach(spaces) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Menu(L("Effacer…", "Erase…")) {
                    ForEach(HistoryStore.Range.allCases) { range in
                        Button(range.label) { confirmErase(range) }
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 10)
            Divider()
            if entries.isEmpty {
                Text(query.isEmpty ? L("L'historique est vide.", "History is empty.") : L("Aucun résultat.", "No results."))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(days.keys.sorted(by: >), id: \.self) { day in
                            Section {
                                ForEach(days[day] ?? []) { HistoryRow(entry: $0, browser: browser, spaces: spaces, showsSpace: spaceID == nil) }
                            } header: {
                                Text(day.formatted(date: .complete, time: .omitted))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                    .background(Color(nsColor: Theme.frameNS))
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: Theme.frameNS))
        .ignoresSafeArea()
    }

    private func confirmErase(_ range: HistoryStore.Range) {
        let alert = NSAlert()
        alert.messageText = L("Effacer l'historique ?", "Erase history?")
        alert.informativeText = L("\(range.label) : ces pages seront retirées, dans tous les espaces. Vos connexions et vos cookies restent.",
                                  "\(range.label): these pages will be removed, in every space. Your sign-ins and cookies stay.")
        alert.addButton(withTitle: L("Effacer", "Erase"))
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HistoryStore.shared.erase(range)
        BrowserWindows.shared.all.forEach { $0.forgetClosedTabs() }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let browser: BrowserModel
    let spaces: [Space]
    let showsSpace: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.lastVisit.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.faintText)
                .frame(width: 44, alignment: .leading)
            if showsSpace, let space = spaces.first(where: { $0.id == entry.space }) {
                Circle().fill(space.tint.color).frame(width: 7, height: 7).help(space.name)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(entry.url.absoluteString)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faintText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if hovering {
                Button { HistoryStore.shared.delete(entry) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Retirer de l'historique", "Remove from history"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(hovering ? Theme.controlHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            let target = browser.spaces.first { $0.id == entry.space }
            browser.openTab(url: entry.url, in: target)
            if let target, target.id != browser.currentSpaceID { browser.switchSpace(to: target) }
            if browser.window?.isVisible != true { BrowserWindows.shared.show(browser) }
            browser.window?.makeKeyAndOrderFront(nil)
        }
    }
}
