import Foundation
import Observation

/// A folder of tabs kept for later: they sleep there, in order, and one wakes up when opened.
/// In the top bar it is a single chip that opens the list of its tabs. Always saved with the
/// session (main window), even when the other tabs aren't restored.
@MainActor @Observable
final class TabFolder: Identifiable {
    let id: UUID
    var name: String
    var icon: String
    /// The chip's background; nil: none, like the bar's other controls.
    var color: Pastel?
    var tabs: [Tab] = []

    /// The icons to choose from.
    static let icons = [
        "folder.fill", "star.fill", "heart.fill", "bookmark.fill", "flag.fill", "sparkles", "lightbulb.fill",
        "briefcase.fill", "house.fill", "book.fill", "graduationcap.fill", "newspaper.fill", "hammer.fill", "terminal.fill",
        "cart.fill", "creditcard.fill", "gift.fill", "airplane", "map.fill", "globe.europe.africa.fill", "fork.knife",
        "music.note", "film.fill", "gamecontroller.fill", "camera.fill", "paintpalette.fill", "leaf.fill", "dumbbell.fill",
    ]

    init(id: UUID = UUID(), name: String, icon: String? = nil, color: Pastel? = nil) {
        self.id = id
        self.name = name
        self.icon = icon.flatMap { Self.icons.contains($0) ? $0 : nil } ?? Self.icons[0]
        self.color = color
    }
}

extension Space {
    /// The folder holding `tab`, if any.
    func folder(of tab: Tab) -> TabFolder? {
        folders.first { $0.tabs.contains { $0 === tab } }
    }

    /// Takes `tab` out of whichever list holds it.
    func detach(_ tab: Tab) {
        tabs.removeAll { $0 === tab }
        for folder in folders { folder.tabs.removeAll { $0 === tab } }
    }

    /// What ⌘1…⌘9 and ⌃⇥ go through: the bar's tabs, plus a folder's tab while it is shown.
    var navigableTabs: [Tab] {
        let shownInFolder = folders.flatMap(\.tabs).filter { $0.id == selectedTabID }
        return shownInFolder + tabs
    }
}
