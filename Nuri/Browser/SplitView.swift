import SwiftUI

/// Split view: two tabs of a space shown together, each in one part of the page area. The selected
/// tab is one of them (the focused side: address, shortcuts, find); clicking into the other side
/// selects it. Selecting a tab outside the pair hides the pair, which comes back when one of its
/// tabs is selected again. Closing either tab ends it. In the bar the two make one block, left then
/// right, as long as the pair lasts.
struct SplitPair: Equatable {
    var left: UUID
    var right: UUID

    func contains(_ id: UUID) -> Bool { left == id || right == id }
    func other(than id: UUID) -> UUID? { left == id ? right : (right == id ? left : nil) }
}

enum SplitSide { case left, right }

extension BrowserModel {
    /// The two tabs on screen side by side, or nil.
    var shownSplit: (left: Tab, right: Tab)? {
        let space = currentSpace
        guard let pair = space.split, let selected = selectedTab, pair.contains(selected.id),
              let left = space.allTabs.first(where: { $0.id == pair.left }),
              let right = space.allTabs.first(where: { $0.id == pair.right }) else { return nil }
        return (left, right)
    }

    /// The tab shown next to the selected one.
    var splitPartner: Tab? {
        guard let split = shownSplit else { return nil }
        return split.left === selectedTab ? split.right : split.left
    }

    /// Tabs whose page is on screen: the selected one, and its partner in split view.
    var visibleTabs: [Tab] {
        if let split = shownSplit { return [split.left, split.right] }
        return selectedTab.map { [$0] } ?? []
    }

    /// Shows `tab` next to the selected tab, on `side` (the other side when nothing says).
    /// Already in the pair on the wanted side: nothing moves. The replaced page goes back to the bar.
    func showInSplit(_ tab: Tab, on side: SplitSide = .right) {
        guard !tab.isClosed, let selected = selectedTab, let space = selected.space, tab.space === space else { return }
        let before = visibleTabs
        guard tab !== selected else {
            // The focused page dragged to the other half: the two swap if a pair is shown.
            if let pair = space.split, pair.contains(tab.id), (pair.left == tab.id) != (side == .left) { swapSides() }
            return
        }
        if var pair = space.split, pair.contains(selected.id) {
            if pair.contains(tab.id) {
                // Both already on screen: only its side may change.
                if (pair.left == tab.id) != (side == .left) { swapSides() }
                return
            }
            // It takes the half it was dropped on; the page there leaves the split.
            if side == .left { pair.left = tab.id } else { pair.right = tab.id }
            if !pair.contains(selected.id) {
                // The focused page was the one replaced: the focus goes to the page dropped.
                space.split = pair
                select(tab)
            } else {
                space.split = pair
            }
        } else {
            space.split = side == .left ? SplitPair(left: tab.id, right: selected.id) : SplitPair(left: selected.id, right: tab.id)
            space.splitRatio = 0.5
        }
        keepSplitTogether(in: space)
        tab.lastAccess = Date()
        tab.ensureWebView()
        PiPController.shared.visibleTabsChanged(from: before, to: visibleTabs)
    }

    /// ⌥⌘S: split view with the tab used last, or back to a single page.
    func toggleSplit() {
        if shownSplit != nil { endSplit(); return }
        guard let selected = selectedTab else { return }
        let candidates = currentSpace.allTabs.filter { $0 !== selected && !$0.isClosed }
        guard let partner = candidates.max(by: { $0.lastAccess < $1.lastAccess }) else {
            showToast("rectangle.split.2x1", L("Ouvrez un autre onglet pour le mettre à côté", "Open another tab to put it alongside"))
            return
        }
        showInSplit(partner)
    }

    /// Back to a single page: the selected tab stays, its partner goes back to the bar.
    func endSplit() {
        guard shownSplit != nil else { return }
        let before = visibleTabs
        currentSpace.split = nil
        PiPController.shared.visibleTabsChanged(from: before, to: visibleTabs)
    }

    /// The handle's ×: this page leaves the split, its tab stays in the bar, the other takes the page.
    func takeOutOfSplit(_ tab: Tab) {
        guard let split = shownSplit, split.left === tab || split.right === tab else { return }
        let other = split.left === tab ? split.right : split.left
        let before = visibleTabs
        currentSpace.split = nil
        if selectedTab !== other { select(other) }
        PiPController.shared.visibleTabsChanged(from: before, to: visibleTabs)
    }

    func swapSides() {
        guard shownSplit != nil, let pair = currentSpace.split else { return }
        currentSpace.split = SplitPair(left: pair.right, right: pair.left)
        currentSpace.splitRatio = 1 - currentSpace.splitRatio
        keepSplitTogether(in: currentSpace)
    }

    /// The pair's two tabs side by side in the bar, in the order of the page, where the first of
    /// them was. A tab of a folder stays in its folder.
    func keepSplitTogether(in space: Space) {
        guard let pair = space.split, let left = space.tabs.firstIndex(where: { $0.id == pair.left }),
              let right = space.tabs.firstIndex(where: { $0.id == pair.right }) else { return }
        let start = min(left, right)
        moveTab(space.tabs[left], to: start)
        if let right = space.tabs.firstIndex(where: { $0.id == pair.right }) { moveTab(space.tabs[right], to: start + 1) }
    }

    /// The pair carried along the bar: it moves as one block, to `index` of the bar as it is now
    /// (past the tab there, on whichever side the block comes from).
    func moveSplitPair(_ pair: SplitPair, to index: Int) {
        let space = currentSpace
        guard let left = space.tabs.first(where: { $0.id == pair.left }), let right = space.tabs.first(where: { $0.id == pair.right }),
              let start = space.tabs.firstIndex(where: { $0 === left || $0 === right }), space.tabs.indices.contains(index),
              index < start || index > start + 1 else { return }
        let before: [(Tab, Int)] = [left, right].map { tab in (tab, allTabs.firstIndex(where: { $0 === tab }) ?? 0) }
        var rest = space.tabs.filter { $0 !== left && $0 !== right }
        rest.insert(contentsOf: [left, right], at: index < start ? index : index - 1)
        withAnimation(Theme.slide) { space.tabs = rest }
        for (tab, from) in before { Extensions.tabMoved(tab, from: from) }
        setNeedsSave()
    }

    /// Focus goes to the other side.
    func focusOtherSide() {
        if let partner = splitPartner { select(partner) }
    }

    /// A link opened from `tab`'s page next to it (the context menu): it takes the other side.
    func openInSplit(_ url: URL, beside tab: Tab) {
        let opened = openTab(url: url, background: true, after: tab)
        if selectedTab !== tab { select(tab) }
        showInSplit(opened)
    }

    /// `tab` is going (closed, put to sleep, moved): its pair ends. Returns the partner.
    @discardableResult
    func leaveSplit(_ tab: Tab) -> Tab? {
        guard let space = tab.space, let pair = space.split, let otherID = pair.other(than: tab.id) else { return nil }
        space.split = nil
        return space.allTabs.first { $0.id == otherID && !$0.isClosed }
    }
}

/// Where the two sides of a split go, shared by the web views' host and the overlays above them.
enum SplitGeometry {
    static let divider: CGFloat = 7
    static let minSide: CGFloat = 280

    /// Width of the left side for a page area `width` wide.
    static func leftWidth(_ width: CGFloat, ratio: Double) -> CGFloat {
        let available = max(0, width - divider)
        let low = min(minSide, available / 2)
        return min(max(available * ratio, low), available - low).rounded()
    }

    static func sides(in size: CGSize, ratio: Double) -> (left: CGRect, right: CGRect) {
        let left = leftWidth(size.width, ratio: ratio)
        return (CGRect(x: 0, y: 0, width: left, height: size.height),
                CGRect(x: left + divider, y: 0, width: max(0, size.width - left - divider), height: size.height))
    }

    /// The ratio that puts the divider at `leftWidth`.
    static func ratio(leftWidth: CGFloat, in width: CGFloat) -> Double {
        let available = max(1, width - divider)
        return min(0.85, max(0.15, Double(leftWidth / available)))
    }
}
