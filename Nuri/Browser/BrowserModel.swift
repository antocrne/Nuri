import SwiftUI
import WebKit
import Observation

/// The command bar's two ways: the address of this tab, or a new tab.
enum CommandBarMode { case currentTab, newTab }

struct CommandBarRequest: Identifiable, Equatable {
    let id = UUID()
    var mode: CommandBarMode
    var text: String
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var message: String
}

/// A tab closed in this window, which ⌘⇧T brings back.
struct ClosedTab {
    let url: URL
    let title: String
    let spaceID: UUID
    /// Its back/forward list and place in the page: it comes back as it was.
    var interactionState: Any? = nil
}

/// A tab being carried by the pointer. The window draws it under the pointer, and the page area
/// shows where it would open. The pointer itself is in `CarryPointer`: what changes at each move
/// must not make everything that looks at this redraw.
struct TabCarry: Equatable {
    var tabID: UUID
    /// Where the tab was grabbed, from its middle: it stays under the pointer at that same place.
    var grabX: CGFloat
    /// Its width in the bar.
    var width: CGFloat
    /// Below the bar: it would open in split view on this side when released.
    var dropSide: SplitSide?
    /// Over a folder's chip: it would go in this folder.
    var dropFolder: UUID?
    /// Released on the bar: on its way to its place.
    var settling = false
}

/// The pointer while a tab is carried, in the window's content (top-left origin). Only the carried
/// tab's picture reads it.
@MainActor @Observable
final class CarryPointer {
    var location: CGPoint = .zero
}

/// The state of one browser window: spaces, tabs, selection and transient UI.
/// `shared` is the main window, whose session is saved; ⌘N and ⌘⇧N windows get their own model.
@MainActor @Observable
final class BrowserModel {
    enum Kind {
        /// The main window: saved session.
        case main
        /// Another normal window (⌘N): same spaces and storage, its own tabs, saved with the main one.
        case secondary
        /// Private window (⌘⇧N): one ephemeral store for all its tabs, nothing saved.
        case privateWindow
    }

    static let shared = BrowserModel(kind: .main)

    let kind: Kind
    var isPrivate: Bool { kind == .privateWindow }
    /// Plain HTTP sites accepted in this private window, gone with it (PlainHTTP).
    @ObservationIgnored var acceptedHTTPHosts: Set<String> = []
    /// Expired certificates accepted in this private window, gone with it (CertificateExceptions).
    @ObservationIgnored var acceptedCertificates: [String: String] = [:]
    /// Sites that said in this private window that they require HTTPS (StrictTransport).
    @ObservationIgnored var strictTransportHosts: Set<String> = []
    @ObservationIgnored var strictTransportSubdomains: Set<String> = []
    var managesSpaces: Bool { kind == .main }

    var spaces: [Space] = [] {
        didSet { spaces.forEach { $0.browser = self } }
    }
    var currentSpaceID: UUID

    var commandBar: CommandBarRequest?
    @ObservationIgnored private var commandBarOpenedAt = Date.distantPast
    var findBarVisible = false {
        didSet { if !findBarVisible { findResult = nil } }
    }
    @ObservationIgnored var lastFindText = ""
    /// What the last search in the page found.
    var findResult: FindResult?
    /// Bumped to put the keyboard in the find bar's field (⌘F, even with the bar already out).
    var findFieldFocus = 0
    var toast: Toast?
    /// The downloads panel, next to its button (⌥⌘L).
    var showingDownloads = false
    /// The space's editing popover (its name, its color).
    var editingSpaceID: UUID?
    /// The folder whose name is being typed.
    var renamingFolderID: UUID?
    /// First-launch personalization step shown over the window (nil = hidden).
    var onboardingStep: Int?
    /// A link glanced at, in its Porthole over the page (see Porthole.swift).
    var porthole: Tab?
    /// The tab under the pointer while being dragged.
    var carry: TabCarry?
    @ObservationIgnored let carryPointer = CarryPointer()
    /// Bumped to give the new tab page's field the focus.
    var newTabFieldFocus = 0
    /// The panel of favorites and bookmarks, next to its button (⌥⌘B).
    var showingBookmarks = false
    /// The current page's bookmark card, under the address bar's star (⌘D).
    var editingBookmark = false
    /// The bar is out while `autoHideTopBar` hides it (the pointer reached the top edge).
    var topBarRevealed = false
    /// An extension's side panel, beside the page (chrome.sidePanel).
    var sidePanel: ExtensionSidePanel?
    /// The split page whose small handle is out (the pointer rests near its top). While the
    /// handle is dragged: the page it would swap with, nil until it has crossed over.
    var splitHandleSide: SplitSide?
    var isDraggingSplitHandle = false
    /// Where things are in the window, for the pointer's sake (top-left origin).
    @ObservationIgnored var tabFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var folderFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var pageFrame: CGRect = .zero
    /// The active tab carries the address.
    var addressFrame: CGRect { selectedTab.flatMap { tabFrames[$0.id] } ?? .zero }
    @ObservationIgnored var newTabButtonFrame: CGRect = .zero
    @ObservationIgnored var extensionsButtonFrame: CGRect = .zero
    /// Pinned extensions' buttons, by identifier: their popups hang from them.
    @ObservationIgnored var pinnedExtensionFrames: [String: CGRect] = [:]
    /// What this window looks like to extensions (see ExtensionHost).
    @ObservationIgnored var extensionAdapter: AnyObject?

    @ObservationIgnored weak var window: NSWindow?
    var isFullScreen = false
    /// Oldest first.
    private(set) var closedTabs: [ClosedTab] = []
    /// Private windows: sites allowed to download, forgotten with the window (DownloadPermission).
    @ObservationIgnored var allowedDownloadHosts: Set<String> = []
    /// Private windows: sites allowed to open windows without a click, forgotten with the window.
    @ObservationIgnored var allowedPopupHosts: Set<String> = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    /// Disables persistence and history (used by the self-test).
    @ObservationIgnored var isEphemeralSession = false
    /// The session read at launch, until its ⌘N windows are open again (BrowserWindows.reopenSavedWindows).
    @ObservationIgnored var stateToReopen: SavedState?
    /// Where this window was, for its controller.
    @ObservationIgnored var frameToReopen: NSRect?

    /// Inactivity after which a tab is put to sleep.
    static var tabSleepDelay: TimeInterval = 30 * 60

    /// A window other than the main one. `mirroring`: the spaces to show (same identifiers,
    /// hence the same cookies and logins) in a new normal window.
    init(kind: Kind, mirroring source: BrowserModel? = nil) {
        self.kind = kind
        switch kind {
        case .privateWindow:
            let space = Space(name: L("Navigation privée", "Private browsing"), isEphemeral: true)
            currentSpaceID = space.id
            spaces = [space]
            isEphemeralSession = true
            space.browser = self
            return
        case .secondary:
            let source = source ?? .shared
            let mirrored = source.spaces.map { Space(id: $0.id, name: $0.name, color: $0.color) }
            currentSpaceID = source.currentSpaceID
            spaces = mirrored
            isEphemeralSession = source.isEphemeralSession   // true only during the self-test
            mirrored.forEach { $0.browser = self }
            return
        case .main:
            break
        }
        let fallback = Space(name: L("Personnel", "Personal"), color: nil)
        currentSpaceID = fallback.id
        if SingleInstance.isDuplicate {
            // Quits as soon as its links are passed on: never reads or writes the session.
            isEphemeralSession = true
            spaces = [fallback]
            fallback.browser = self
            return
        }
        #if DEBUG
        if SelfTestRunner.isRequested {
            // The self-test never reads or writes the user's session.
            isEphemeralSession = true
            spaces = [fallback]
            fallback.browser = self
            return
        }
        #endif
        if let saved = StateStore.load(), !saved.spaces.isEmpty {
            restore(saved)
        } else {
            spaces = [fallback]
            currentSpaceID = fallback.id
        }
        // Property observers don't run during init.
        spaces.forEach { $0.browser = self }
    }

    // MARK: - Derived state

    var currentSpace: Space { spaces.first { $0.id == currentSpaceID } ?? spaces[0] }
    var selectedTab: Tab? { currentSpace.selectedTab }
    var allTabs: [Tab] { spaces.flatMap(\.allTabs) }

    /// Tabs whose web view must stay attached to the window even when not selected,
    /// so that video keeps playing and PiP keeps working (see WebHost).
    var keepAliveTabs: [Tab] {
        allTabs.filter { $0.webView != nil && !$0.isInFloatingPlayer && ($0.isPlayingVideo || $0.isInPiP || $0.isAudible || $0.isInCall) }
    }

    // MARK: - Tabs

    /// Every tab of a private window is private (⌘T, links, pop-ups alike).
    @discardableResult
    func openTab(url: URL?, in space: Space? = nil, background: Bool = false,
                 after anchor: Tab? = nil, popupConfiguration: WKWebViewConfiguration? = nil, restoring state: Any? = nil) -> Tab {
        let space = space ?? anchor?.space ?? currentSpace
        let tab = Tab(url: url, isPrivate: isPrivate, popupConfiguration: popupConfiguration, interactionState: state)
        tab.space = space
        withAnimation(Theme.spring) {
            if let anchor, let i = space.tabs.firstIndex(where: { $0 === anchor }) {
                space.tabs.insert(tab, at: i + 1)
            } else {
                space.tabs.append(tab)
            }
        }
        Extensions.tabOpened(tab)
        if background {
            // Background tabs still start loading so they're ready when selected.
            if popupConfiguration == nil, url != nil { tab.ensureWebView() }
        } else {
            select(tab)
        }
        setNeedsSave()
        return tab
    }

    func select(_ tab: Tab) {
        // A tab closed meanwhile (a stale suggestion, a late callback) is never brought back: its
        // web view would load and play with no row to show or close it.
        guard !tab.isClosed, let space = tab.space, space.allTabs.contains(where: { $0 === tab }) else { return }
        let previous = selectedTab
        let shownBefore = visibleTabs
        if let glance = porthole, glance !== tab { closePorthole() }
        if space.id != currentSpaceID { currentSpaceID = space.id }
        withAnimation(Theme.quick) { space.selectedTabID = tab.id }
        // Inactivity counts from the moment a tab stops being shown.
        previous?.lastAccess = Date()
        tab.lastAccess = Date()
        tab.ensureWebView()
        findBarVisible = false
        // Moving between the two sides of a split keeps both on screen: no PiP either way.
        if previous !== tab {
            PiPController.shared.visibleTabsChanged(from: shownBefore, to: visibleTabs)
            Extensions.tabActivated(tab, previous: previous)
        }
        setNeedsSave()
    }

    /// `reselect`: false when the whole space is going: no neighbour is selected, hence none woken up.
    func close(_ tab: Tab, reselect: Bool = true) {
        // Already closed: a second ⌘W answered by the page after the first one, a late callback.
        guard !tab.isClosed, let space = tab.space else { return }
        if porthole === tab { porthole = nil }
        // Split view: the other side takes the whole page.
        let partner = leaveSplit(tab)
        if tab.isInFloatingPlayer { FloatingPlayer.shared.close() }
        if tab.isInPiP, let wv = tab.webView { PiPController.shared.forceExit(wv) }
        if let url = tab.url {
            closedTabs.append(ClosedTab(url: url, title: tab.displayTitle, spaceID: space.id,
                                        interactionState: tab.currentInteractionState))
        }
        if closedTabs.count > 30 { closedTabs.removeFirst() }
        if reselect, space.selectedTabID == tab.id { selectNeighbor(of: tab, in: space, preferring: partner) }
        withAnimation(Theme.spring) { space.detach(tab) }
        tab.isClosed = true
        Extensions.tabClosed(tab)
        tab.sleep(force: true)
        setNeedsSave()
    }

    /// Releases a tab's web view where it stays (a tab of a folder): its neighbour is shown instead
    /// if it was shown.
    private func sleepInPlace(_ tab: Tab, in space: Space, preferring partner: Tab? = nil) {
        if space.selectedTabID == tab.id { selectNeighbor(of: tab, in: space, preferring: partner) }
        if tab.isInPiP || tab.isInFloatingPlayer {
            // Sleep once PiP (or the floating player) has actually been left — unless the tab
            // was shown again meanwhile (it would be left without its page).
            Task {
                await PiPController.shared.exit(tab)
                if tab.browser?.selectedTab !== tab { tab.sleep(force: true) }
            }
        } else {
            tab.sleep()
        }
    }

    /// The tab that takes the place of `tab` when it goes: the next one, else the previous one.
    private func neighbor(of tab: Tab, in space: Space) -> Tab? {
        let list = space.tabs
        if let i = list.firstIndex(where: { $0 === tab }) {
            let candidates = list.enumerated().filter { $0.element !== tab }
            return (candidates.first(where: { $0.offset > i }) ?? candidates.last)?.element
        }
        return list.first { $0 !== tab }
    }

    private func selectNeighbor(of tab: Tab, in space: Space, preferring partner: Tab? = nil) {
        let next = partner ?? neighbor(of: tab, in: space)
        guard space.id == currentSpaceID else {
            // A space in the background: only its remembered selection changes. It isn't shown,
            // and its tab isn't woken up, until the user goes there.
            space.selectedTabID = next?.id
            return
        }
        if let next {
            select(next)
            return
        }
        let shownBefore = visibleTabs
        withAnimation(Theme.quick) { space.selectedTabID = nil }
        PiPController.shared.visibleTabsChanged(from: shownBefore, to: [])
        // The new tab page comes up with its own field: no second one over it.
        commandBar = nil
        newTabFieldFocus += 1
    }

    func closeCurrentTab() {
        if let tab = selectedTab { requestClose(tab) }
    }

    /// Closing asked by the user (⌘W, a tab's cross or menu). The page is asked first, as when
    /// leaving it: one that says so (beforeunload: a message being written…) gets a "Quitter cette
    /// page ?" sheet (TabWebDelegate), and the tab stays if the user does.
    func requestClose(_ tab: Tab) {
        guard let webView = tab.webView, let closedAtOnce = WebKitSPI.tryClose(webView) else {
            close(tab)
            return
        }
        if closedAtOnce { close(tab); return }
        // The page answers through webViewDidClose (TabWebDelegate), which closes the tab. A page
        // whose process doesn't answer doesn't keep its tab: closed anyway, unless it is asking.
        tab.closeRequested = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak tab] in
            guard let self, let tab, !tab.isClosed, tab.closeRequested, !tab.isAskingToStay else { return }
            self.close(tab)
        }
    }

    /// Every tab of the bar. `keeping`: this one stays. A tab put away in a folder is only closed
    /// when asked for by name (its cross, its menu, or deleting the folder with its tabs).
    /// ⌘⇧T brings them back one by one.
    func closeAllTabs(keeping kept: Tab? = nil) {
        let space = currentSpace
        let targets = space.tabs.filter { $0 !== kept }
        guard !targets.isEmpty else { return }
        if let kept, selectedTab !== kept { select(kept) }
        for tab in targets { requestClose(tab) }
    }

    /// Settings → history erased: "reopen closed tab" no longer brings anything back, and no tab
    /// keeps its back/forward list for the next launch.
    func forgetClosedTabs() {
        closedTabs = []
        allTabs.forEach { $0.forgetHistory() }
    }

    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let space = spaces.first { $0.id == closed.spaceID } ?? currentSpace
        openTab(url: closed.url, in: space, restoring: closed.interactionState)
    }

    /// Moves a tab to `index` among the bar's tabs (drag and drop).
    func moveTab(_ tab: Tab, to index: Int) {
        guard let space = tab.space, let from = space.tabs.firstIndex(where: { $0 === tab }),
              space.tabs.indices.contains(index), from != index else { return }
        let fromInWindow = allTabs.firstIndex { $0 === tab } ?? from
        withAnimation(Theme.slide) {
            space.tabs.remove(at: from)
            space.tabs.insert(tab, at: index)
        }
        Extensions.tabMoved(tab, from: fromInWindow)
        setNeedsSave()
    }

    /// ⌘1…⌘8 select the nth tab, ⌘9 the last one.
    func selectTab(number: Int) {
        let list = currentSpace.navigableTabs
        guard !list.isEmpty else { return }
        let index = number == 9 ? list.count - 1 : number - 1
        if list.indices.contains(index) { select(list[index]) }
    }

    func selectAdjacentTab(_ delta: Int) {
        let list = currentSpace.navigableTabs
        guard !list.isEmpty else { return }
        guard let current = selectedTab, let i = list.firstIndex(where: { $0 === current }) else {
            select(list[0]); return
        }
        select(list[(i + delta + list.count) % list.count])
    }

    // MARK: - Folders

    /// A new folder next to the space's dot, its name asked for at once. `tab`: put in it right away.
    @discardableResult
    func addFolder(with tab: Tab? = nil) -> TabFolder? {
        guard !isPrivate else { return nil }
        let space = tab?.space ?? currentSpace
        let folder = TabFolder(name: L("Nouveau dossier", "New folder"))
        withAnimation(Theme.spring) { space.folders.append(folder) }
        if let tab { put(tab, in: folder) }
        renamingFolderID = folder.id
        setNeedsSave()
        return folder
    }

    /// Puts a tab away in a folder of its space, asleep: the next tab is shown if it was.
    func put(_ tab: Tab, in folder: TabFolder) {
        guard !tab.isPrivate, !tab.isClosed, let space = tab.space,
              space.folders.contains(where: { $0 === folder }), space.folder(of: tab) !== folder else { return }
        let partner = leaveSplit(tab)
        if space.selectedTabID == tab.id { selectNeighbor(of: tab, in: space, preferring: partner) }
        withAnimation(Theme.spring) {
            space.detach(tab)
            folder.tabs.append(tab)
        }
        sleepInPlace(tab, in: space)
        setNeedsSave()
    }

    /// Takes a tab out of its folder, to the end of the bar.
    func removeFromFolder(_ tab: Tab) {
        guard let space = tab.space, let folder = space.folder(of: tab) else { return }
        withAnimation(Theme.spring) {
            folder.tabs.removeAll { $0 === tab }
            space.tabs.append(tab)
        }
        setNeedsSave()
    }

    /// A tab of a folder shown earlier goes back to sleep, staying where it is.
    func sleepTab(_ tab: Tab) {
        guard let space = tab.space, !tab.isAsleep else { return }
        sleepInPlace(tab, in: space, preferring: leaveSplit(tab))
    }

    /// `keepingTabs`: its tabs go to the bar, asleep; otherwise they are closed (⌘⇧T reopens them).
    func deleteFolder(_ folder: TabFolder, keepingTabs: Bool) {
        guard let space = spaces.first(where: { $0.folders.contains { $0 === folder } }) else { return }
        if keepingTabs {
            withAnimation(Theme.spring) {
                space.tabs.append(contentsOf: folder.tabs)
                folder.tabs = []
                space.folders.removeAll { $0 === folder }
            }
        } else {
            for tab in folder.tabs { close(tab) }
            withAnimation(Theme.spring) { space.folders.removeAll { $0 === folder } }
        }
        setNeedsSave()
    }

    // MARK: - Navigation

    func showCommandBar(_ mode: CommandBarMode) {
        // The new tab page has its own field: no second one over it.
        guard selectedTab != nil else {
            commandBar = nil
            newTabFieldFocus += 1
            return
        }
        // One click answered twice (see firstClickEvent) keeps the bar it opened, and its field's focus.
        if commandBar?.mode == mode, Date().timeIntervalSince(commandBarOpenedAt) < 0.5 { return }
        commandBarOpenedAt = Date()
        let text = mode == .currentTab ? (selectedTab?.url?.absoluteString ?? "") : ""
        commandBar = CommandBarRequest(mode: mode, text: text)
    }

    func navigate(_ input: String, mode: CommandBarMode) {
        // "view-source:…": the page opens in a new tab, which then shows its source.
        if let page = URLResolver.viewSourceTarget(input) {
            showSource(of: page)
            return
        }
        // "mailto:…", "tel:…": the Mac's app for it, and the tab stays where it is.
        if let url = URLResolver.url(from: input), URLResolver.externalSchemes.contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = URLResolver.url(from: input) {
            open(url, mode: mode)
            if URLResolver.isTypedWithoutScheme(input) {
                selectedTab?.typedAddress = TypedAddressFallback.Typed(text: input.trimmingCharacters(in: .whitespacesAndNewlines), url: url)
            }
            return
        }
        guard let url = AppSettings.shared.searchURL(for: input) else { return }
        open(url, mode: mode)
    }

    func open(_ url: URL, mode: CommandBarMode) {
        switch mode {
        case .currentTab:
            if let tab = selectedTab { tab.load(url) } else { openTab(url: url) }
        case .newTab:
            openTab(url: url)
        }
    }

    /// URLs opened from other apps (Nuri as default browser).
    func openExternal(_ url: URL) {
        openTab(url: url)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { BrowserWindows.shared.show(self) }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Spaces

    func switchSpace(to space: Space) {
        guard space.id != currentSpaceID else { return }
        let shownBefore = visibleTabs
        porthole = nil
        withAnimation(Theme.spring) { currentSpaceID = space.id }
        space.selectedTab?.ensureWebView()
        splitPartner?.ensureWebView()
        PiPController.shared.visibleTabsChanged(from: shownBefore, to: visibleTabs)
        setNeedsSave()
    }

    func switchSpace(by delta: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let j = i + delta
        guard spaces.indices.contains(j) else { return }
        switchSpace(to: spaces[j])
    }

    @discardableResult
    func addSpace(name: String, color: Pastel? = nil) -> Space {
        let space = Space(name: name.isEmpty ? L("Espace \(spaces.count + 1)", "Space \(spaces.count + 1)") : name, color: color)
        spaces.append(space)
        switchSpace(to: space)
        setNeedsSave()
        return space
    }

    func moveSpace(from source: IndexSet, to destination: Int) {
        spaces.move(fromOffsets: source, toOffset: destination)
        setNeedsSave()
    }

    func deleteSpace(_ space: Space) {
        guard spaces.count > 1 else { return }
        // Other normal windows showing this space lose it too (its storage is about to go).
        for other in BrowserWindows.shared.all where other !== self {
            guard let mirror = other.spaces.first(where: { $0.id == space.id }) else { continue }
            if other.spaces.count == 1, let replacement = spaces.first(where: { $0.id != space.id }) {
                other.spaces.append(Space(id: replacement.id, name: replacement.name, color: replacement.color))
            }
            if mirror.id == other.currentSpaceID, let next = other.spaces.first(where: { $0.id != mirror.id }) { other.switchSpace(to: next) }
            for tab in mirror.allTabs { other.close(tab, reselect: false) }
            other.spaces.removeAll { $0.id == mirror.id }
        }
        // Leave the space first, then close its tabs without selecting their neighbours: none of
        // them is woken up (with the space's cookies) just before going.
        if space.id == currentSpaceID, let other = spaces.first(where: { $0.id != space.id }) { switchSpace(to: other) }
        for tab in space.allTabs { close(tab, reselect: false) }
        spaces.removeAll { $0.id == space.id }
        closedTabs.removeAll { $0.spaceID == space.id }
        HistoryStore.shared.deleteAll(ofSpace: space.id)
        BookmarkStore.shared.removeAll(space: space.id)
        // Its data goes now (this works while the store is still referenced)…
        space.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        // …and its folder as soon as WebKit lets go of it: at the latest, at the next launch.
        Space.releaseStore(for: space.id)
        Space.removeStoreFromDisk(space.id)
        setNeedsSave()
    }

    // MARK: - Toasts

    func showToast(_ symbol: String, _ message: String) {
        withAnimation(Theme.spring) { toast = Toast(symbol: symbol, message: message) }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(Theme.spring) { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    // MARK: - Automatic sleep

    /// Puts idle tabs to sleep (called every minute by BrowserWindows). The tabs on screen are
    /// never touched; see `Tab.canAutoSleep` for the other exceptions.
    /// `idle`: shorter when macOS runs low on memory (see BrowserWindows).
    func sleepInactiveTabs(idleFor delay: TimeInterval? = nil, now: Date = Date()) {
        guard AppSettings.shared.sleepInactiveTabs else { return }
        let idle = delay ?? Self.tabSleepDelay
        let visible = visibleTabs
        for tab in allTabs where !visible.contains(where: { $0 === tab }) && tab !== porthole && tab.canAutoSleep(idleFor: idle, now: now) {
            Task { await tab.sleepKeepingPlace(idleFor: idle) }
        }
    }

    /// The main window was closed (its model lives on, for when it reopens): its pages stop —
    /// no sound or video from a window that isn't there — and come back, same history, when shown again.
    func windowClosed() {
        for tab in allTabs {
            if tab.isInFloatingPlayer { FloatingPlayer.shared.close() }
            if tab.isInPiP, let wv = tab.webView { PiPController.shared.forceExit(wv) }
            tab.sleepKeepingHistory()
        }
        porthole = nil
        commandBar = nil
        findBarVisible = false
    }

    // MARK: - Window lifetime

    /// Called when a secondary or private window closes. For a private window this destroys
    /// everything it held: web views, the in-memory store's cookies, cache and sessions, the
    /// reopen-closed-tab list and its downloads list.
    func tearDown() {
        // A ⌘N window closed: ⌘⇧T brings its tabs back one by one, in the main window.
        if kind == .secondary { BrowserModel.shared.keepClosedTabs(of: self) }
        for tab in allTabs {
            tab.isClosed = true
            if tab.isInFloatingPlayer { FloatingPlayer.shared.close() }
            if tab.isInPiP, let wv = tab.webView { PiPController.shared.forceExit(wv) }
            tab.sleep(force: true)
        }
        porthole?.sleep(force: true)
        porthole = nil
        sidePanel = nil
        if isPrivate {
            for space in spaces {
                space.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            }
            DownloadManager.shared.forget(browser: self)
        }
        closedTabs = []
        allowedDownloadHosts = []
        commandBar = nil
        for space in spaces {
            space.tabs = []
            space.folders = []
            space.selectedTabID = nil
        }
        window = nil
    }

    private func keepClosedTabs(of other: BrowserModel) {
        for space in other.spaces {
            for tab in space.allTabs {
                guard let url = tab.url else { continue }
                closedTabs.append(ClosedTab(url: url, title: tab.displayTitle, spaceID: space.id, interactionState: tab.currentInteractionState))
            }
        }
        if closedTabs.count > 30 { closedTabs.removeFirst(closedTabs.count - 30) }
    }

    // MARK: - Persistence

    /// The main window saves the session, its ⌘N windows' tabs included (each writing its own would
    /// overwrite the others').
    private var savesSession: Bool { kind == .main && !isEphemeralSession }

    func setNeedsSave() {
        if kind == .main { syncMirroredSpaces() }
        if kind == .secondary { BrowserModel.shared.setNeedsSave() }
        guard savesSession else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        // Every page load asks: one write for a burst of them (quitting saves at once anyway).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func saveNow() {
        guard savesSession else { return }
        let saved = sessionState()
        StateStore.save(saved)
        let spaces = saved.spaces + (saved.windows ?? []).flatMap(\.spaces)
        let ids = Set(spaces.flatMap { $0.tabs + $0.folders.flatMap(\.tabs) }.map(\.id))
        TabStates.save(BrowserWindows.shared.all.filter { !$0.isPrivate }.flatMap(\.allTabs), keeping: ids)
    }

    /// What is written: this window's spaces, and those of the ⌘N windows.
    func sessionState() -> SavedState {
        let restoreTabs = AppSettings.shared.restoreTabs
        var favicons: [String: Data] = [:]
        let persistable: (Tab) -> SavedTab = { tab in
            // Each icon once: tabs of the same site share it.
            let key = tab.faviconData.map { data in
                let key = SavedState.faviconKey(data)
                favicons[key] = data
                return key
            }
            return SavedTab(id: tab.id, url: tab.url, title: tab.title, faviconKey: key, isMuted: tab.isMuted)
        }
        let saving = { (model: BrowserModel) -> [SavedSpace] in
            model.spaces.map { space in
                SavedSpace(id: space.id, name: space.name, color: space.color?.rawValue,
                           tabs: restoreTabs ? space.tabs.filter { $0.url != nil }.map(persistable) : [],
                           selectedTabID: space.selectedTabID,
                           // Put away on purpose: kept even when the other tabs aren't.
                           folders: space.folders.map { folder in
                               SavedFolder(id: folder.id, name: folder.name, icon: folder.icon, color: folder.color?.rawValue, tabs: folder.tabs.filter { $0.url != nil }.map(persistable))
                           })
            }
        }
        var saved = SavedState(currentSpaceID: currentSpaceID, spaces: saving(self))
        saved.windows = BrowserWindows.shared.all.filter { $0.kind == .secondary }.compactMap { other in
            let spaces = saving(other)
            guard spaces.contains(where: { !$0.tabs.isEmpty || $0.folders.contains { !$0.tabs.isEmpty } }) else { return nil }
            return SavedWindow(currentSpaceID: other.currentSpaceID, frame: other.window.map { NSStringFromRect($0.frame) }, spaces: spaces)
        }
        saved.favicons = favicons
        return saved
    }

    /// ⌘N windows show copies of the main window's spaces: renaming, a new color, a new space
    /// or a new order there follows here.
    private func syncMirroredSpaces() {
        for other in BrowserWindows.shared.all where other.kind == .secondary {
            let mirrored = spaces.map { space in
                let mirror = other.spaces.first { $0.id == space.id } ?? Space(id: space.id, name: space.name, color: space.color)
                if mirror.name != space.name { mirror.name = space.name }
                if mirror.color != space.color { mirror.color = space.color }
                return mirror
            }
            if mirrored.map(\.id) != other.spaces.map(\.id) { other.spaces = mirrored }
        }
    }

    func restore(_ saved: SavedState) {
        spaces = saved.spaces.map { s in
            let space = Space(id: s.id, name: s.name, color: s.color.flatMap(Pastel.init(rawValue:)))
            fill(space, from: s, in: saved)
            return space
        }
        currentSpaceID = spaces.contains { $0.id == saved.currentSpaceID } ? saved.currentSpaceID : spaces[0].id
        stateToReopen = saved
        // Only the visible tab gets a web view at launch; the rest stays asleep.
    }

    /// A ⌘N window of the saved session, in a model just made for it.
    func restore(_ window: SavedWindow, in saved: SavedState) {
        for s in window.spaces {
            if let space = spaces.first(where: { $0.id == s.id }) { fill(space, from: s, in: saved) }
        }
        if spaces.contains(where: { $0.id == window.currentSpaceID }) { currentSpaceID = window.currentSpaceID }
        frameToReopen = window.frame.map(NSRectFromString)
    }

    private func fill(_ space: Space, from s: SavedSpace, in saved: SavedState) {
        let makeTab = { (t: SavedTab) -> Tab in
            let tab = Tab(id: t.id, url: t.url, title: t.title, faviconData: saved.favicon(of: t))
            tab.isMuted = t.isMuted
            tab.space = space
            tab.isFromSession = true
            return tab
        }
        space.tabs = s.tabs.map(makeTab)
        space.folders = s.folders.map { f in
            let folder = TabFolder(id: f.id, name: f.name, icon: f.icon, color: f.color.flatMap(Pastel.init(rawValue:)))
            folder.tabs = f.tabs.map(makeTab)
            return folder
        }
        // After a launch that died young: the new tab page, the tabs asleep in the bar.
        space.selectedTabID = LaunchGuard.previousLaunchDied ? nil : s.selectedTabID
    }
}
