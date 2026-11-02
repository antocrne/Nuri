import AppKit
import Observation

/// All browser windows. Each has its own model; the main one (`BrowserModel.shared`) outlives its
/// window and is the one saved. Closing a private window destroys its model and its storage.
@MainActor @Observable
final class BrowserWindows {
    static let shared = BrowserWindows()

    /// The browser of the frontmost browser window: menus and shortcuts act on it.
    private(set) var active: BrowserModel = .shared

    @ObservationIgnored private var controllers: [BrowserWindowController] = []
    @ObservationIgnored private var mainController: BrowserWindowController?
    @ObservationIgnored private weak var lastNormal: BrowserModel?
    @ObservationIgnored private var sleepTimer: Timer?
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var started = false

    private init() {}

    var all: [BrowserModel] { [.shared] + controllers.map(\.browser) }

    /// Where links opened from other apps go: the frontmost normal window.
    var normalTarget: BrowserModel {
        if !active.isPrivate { return active }
        return lastNormal ?? .shared
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { BrowserWindows.shared.windowBecameKey(note.object as? NSWindow) }
        }
        // One timer for all tabs, once a minute: nothing else in Nuri ticks in the background.
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                BrowserWindows.shared.all.forEach { $0.sleepInactiveTabs() }
                Extensions.updateIfDue()
            }
        }
        timer.tolerance = 15
        sleepTimer = timer
        // ⌘= zooms in like ⌘+ (which needs ⇧ on most keyboards), as in Safari.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "=" else { return event }
            let handled = MainActor.assumeIsolated {
                let windows = BrowserWindows.shared
                guard let key = NSApp.keyWindow, windows.all.contains(where: { $0.window === key }) else { return false }
                windows.active.zoom(0.1)
                return true
            }
            return handled ? nil : event
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak pressure] in
            guard let event = pressure?.data else { return }
            MainActor.assumeIsolated { BrowserWindows.shared.memoryPressure(critical: event.contains(.critical)) }
        }
        pressure.resume()
        memoryPressureSource = pressure
    }

    /// macOS runs low on memory: idle tabs go to sleep without waiting for the usual delay
    /// (five minutes of inactivity, none when it's critical), before WebKit has to kill pages.
    func memoryPressure(critical: Bool) {
        let idle: TimeInterval = critical ? 0 : 5 * 60
        all.forEach { $0.sleepInactiveTabs(idleFor: idle) }
    }

    private func windowBecameKey(_ window: NSWindow?) {
        guard let window, let model = all.first(where: { $0.window === window }) else { return }
        if active !== model { active = model }
        if !model.isPrivate { lastNormal = model }
        Extensions.windowFocused(model)
    }

    // MARK: - Opening windows

    /// The main window, at launch or after it was closed.
    func showMainWindow() {
        show(.shared)
    }

    /// Quitting or closing a window takes the pages with it. Those holding text typed and not sent
    /// are named first; true when the user goes ahead (or nothing would be lost). `leaving`: the
    /// button's words.
    func mayLoseTypedText(in tabs: [Tab], leaving: String) async -> Bool {
        #if DEBUG
        if SelfTestRunner.isRequested { return true }
        #endif
        var holding: [Tab] = []
        for tab in tabs {
            if await tab.holdsTypedText() { holding.append(tab) }
        }
        guard let first = holding.first else { return true }
        let alert = NSAlert()
        alert.messageText = holding.count == 1 ? L("Du texte saisi n'a pas été envoyé", "Some text you typed hasn't been sent")
                                               : L("Du texte saisi n'a pas été envoyé dans \(holding.count) onglets", "Some text you typed hasn't been sent in \(holding.count) tabs")
        let names = holding.prefix(3).map(\.displayTitle).joined(separator: "\n")
        alert.informativeText = names + "\n\n" + L("Il sera perdu.", "It will be lost.")
        alert.addButton(withTitle: L("Rester", "Stay"))
        alert.addButton(withTitle: leaving)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { return true }
        if let browser = first.browser {
            browser.select(first)
            browser.window?.makeKeyAndOrderFront(nil)
        }
        return false
    }

    /// At launch: the ⌘N windows that were open, the main window staying in front.
    func reopenSavedWindows() {
        guard let saved = BrowserModel.shared.stateToReopen else { return }
        BrowserModel.shared.stateToReopen = nil
        guard let windows = saved.windows, !windows.isEmpty else { return }
        for window in windows {
            let model = BrowserModel(kind: .secondary, mirroring: .shared)
            model.restore(window, in: saved)
            show(model)
        }
        BrowserModel.shared.window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘N. Reopens the main window if it was closed, otherwise opens another normal window
    /// showing the same spaces (same storage, so the same logins).
    @discardableResult
    func openNormalWindow() -> BrowserModel {
        if BrowserModel.shared.window?.isVisible != true {
            showMainWindow()
            return .shared
        }
        let model = BrowserModel(kind: .secondary, mirroring: normalTarget)
        show(model)
        return model
    }

    /// ⌘⇧N. Every tab of the window is private and shares one in-memory store.
    @discardableResult
    func openPrivateWindow(url: URL? = nil) -> BrowserModel {
        let model = BrowserModel(kind: .privateWindow)
        show(model)
        if let url { model.openTab(url: url) }
        return model
    }

    func show(_ model: BrowserModel) {
        if model.window?.isVisible == true {
            model.window?.makeKeyAndOrderFront(nil)
            return
        }
        let reference = NSApp.keyWindow.flatMap { key in all.contains { $0.window === key } ? key : nil } ?? active.window
        let controller = BrowserWindowController(browser: model, cascadingFrom: model === BrowserModel.shared ? nil : reference)
        if model === BrowserModel.shared { mainController = controller } else { controllers.append(controller) }
        controller.present()
        Extensions.windowOpened(model)
        active = model
        if !model.isPrivate { lastNormal = model }
    }

    func windowWillClose(_ controller: BrowserWindowController) {
        let model = controller.browser
        Extensions.windowClosed(model)
        if model === BrowserModel.shared {
            model.windowClosed()
            model.window = nil
            mainController = nil
        } else {
            model.tearDown()
            controllers.removeAll { $0 === controller }
            BrowserModel.shared.setNeedsSave()
        }
        if active === model {
            let front = NSApp.orderedWindows.lazy.compactMap { w in self.all.first { $0.window === w } }.first
            active = front ?? .shared
        }
    }
}
