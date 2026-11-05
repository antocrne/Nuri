import AppKit
import Observation

enum HistoryRetention: Int, CaseIterable, Identifiable {
    case year = 365, sixMonths = 182, ninetyDays = 90, thirtyDays = 30
    var id: Int { rawValue }
    @MainActor var label: String {
        switch self {
        case .year: L("1 an", "1 year")
        case .sixMonths: L("6 mois", "6 months")
        case .ninetyDays: L("90 jours", "90 days")
        case .thirtyDays: L("30 jours", "30 days")
        }
    }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    @MainActor var label: String {
        switch self {
        case .system: L("Système", "System")
        case .light: L("Clair", "Light")
        case .dark: L("Sombre", "Dark")
        }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckduckgo, google, bing, ecosia, qwant, startpage, kagi, custom
    var id: String { rawValue }

    @MainActor var name: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        case .qwant: "Qwant"
        case .startpage: "Startpage"
        case .kagi: "Kagi"
        case .custom: L("Personnalisé", "Custom")
        }
    }

    /// `%s` is replaced by the percent-encoded query.
    var template: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .duckduckgo: "https://duckduckgo.com/?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .qwant: "https://www.qwant.com/?q=%s"
        case .startpage: "https://www.startpage.com/do/search?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        case .custom: ""
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let defaults = UserDefaults.standard

    // Appearance
    var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: "theme"); applyAppearance() } }
    var accent: Pastel { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    /// How much of the desktop shows through the frame (0 = solid, 1 = most see-through).
    var transparency: Double { didSet { defaults.set(transparency, forKey: "transparency") } }
    /// The soft colored glows in the frame, a nod to Firn. All in one place (`ChromeGlow`), so it
    /// goes away with this switch.
    var softGlows: Bool { didSet { defaults.set(softGlows, forKey: "softGlows") } }
    /// The top bar slides away and comes back when the pointer reaches the top edge.
    var autoHideTopBar: Bool { didSet { defaults.set(autoHideTopBar, forKey: "autoHideTopBar") } }

    // Browsing
    var searchEngine: SearchEngine { didSet { defaults.set(searchEngine.rawValue, forKey: "searchEngine") } }
    var customSearchTemplate: String { didSet { defaults.set(customSearchTemplate, forKey: "customSearchTemplate") } }
    var restoreTabs: Bool { didSet { defaults.set(restoreTabs, forKey: "restoreTabs") } }
    var sleepInactiveTabs: Bool { didSet { defaults.set(sleepInactiveTabs, forKey: "sleepInactiveTabs") } }
    var autoPiP: Bool { didSet { defaults.set(autoPiP, forKey: "autoPiP") } }
    var extensionsAutoUpdate: Bool { didSet { defaults.set(extensionsAutoUpdate, forKey: "extensionsAutoUpdate") } }
    /// Pinned extensions drawn in the bar's one color, like its symbols (off: their own colors).
    var monochromeExtensions: Bool { didSet { defaults.set(monochromeExtensions, forKey: "monochromeExtensions") } }
    /// An extension's side panel (Claude's conversation): its card's width, and on the left of the
    /// page rather than the right.
    var sidePanelWidth: Double { didSet { defaults.set(sidePanelWidth, forKey: "sidePanelWidth") } }
    var sidePanelOnLeft: Bool { didSet { defaults.set(sidePanelOnLeft, forKey: "sidePanelOnLeft") } }
    var autoMeetingPiP: Bool { didSet { defaults.set(autoMeetingPiP, forKey: "autoMeetingPiP") } }
    var blockAutoplayWithSound: Bool { didSet { defaults.set(blockAutoplayWithSound, forKey: "blockAutoplayWithSound") } }
    /// « Partager aussi le son » in the screen sharing question, as last answered.
    var shareScreenAudio: Bool { didSet { defaults.set(shareScreenAudio, forKey: "shareScreenAudio") } }
    /// ⌘+ ⌘− by site (host without www.): 1 is never stored.
    var siteZooms: [String: Double] { didSet { defaults.set(siteZooms, forKey: "siteZooms") } }

    // Privacy
    var adBlockEnabled: Bool { didSet { defaults.set(adBlockEnabled, forKey: "adBlockEnabled"); ContentRules.shared.reload() } }
    var adBlockAllowlist: [String] { didSet { defaults.set(adBlockAllowlist, forKey: "adBlockAllowlist"); ContentRules.shared.reload() } }
    var stripTrackingParameters: Bool { didSet { defaults.set(stripTrackingParameters, forKey: "stripTrackingParameters") } }
    var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: "historyRetention"); HistoryStore.shared.prune() }
    }

    // Downloads
    /// nil = ~/Downloads.
    var downloadFolderPath: String? { didSet { defaults.set(downloadFolderPath, forKey: "downloadFolderPath") } }
    var askDownloadLocation: Bool { didSet { defaults.set(askDownloadLocation, forKey: "askDownloadLocation") } }

    // App
    var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboardingCompleted") } }

    private init() {
        let d = UserDefaults.standard
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        accent = Pastel(rawValue: d.string(forKey: "accent") ?? "") ?? .peach
        transparency = d.object(forKey: "transparency") as? Double ?? 0.8
        softGlows = d.object(forKey: "softGlows") as? Bool ?? true
        autoHideTopBar = d.bool(forKey: "autoHideTopBar")
        searchEngine = SearchEngine(rawValue: d.string(forKey: "searchEngine") ?? "") ?? .duckduckgo
        customSearchTemplate = d.string(forKey: "customSearchTemplate") ?? "https://example.com/search?q=%s"
        restoreTabs = d.object(forKey: "restoreTabs") as? Bool ?? true
        sleepInactiveTabs = d.object(forKey: "sleepInactiveTabs") as? Bool ?? true
        autoPiP = d.object(forKey: "autoPiP") as? Bool ?? true
        extensionsAutoUpdate = d.object(forKey: "extensionsAutoUpdate") as? Bool ?? true
        monochromeExtensions = d.bool(forKey: "monochromeExtensions")
        sidePanelWidth = d.object(forKey: "sidePanelWidth") as? Double ?? ExtensionSidePanel.defaultWidth
        sidePanelOnLeft = d.bool(forKey: "sidePanelOnLeft")
        autoMeetingPiP = d.object(forKey: "autoMeetingPiP") as? Bool ?? true
        // A video that starts speaking by itself is a surprise nobody asked for: off unless chosen.
        blockAutoplayWithSound = d.object(forKey: "blockAutoplayWithSound") as? Bool ?? true
        shareScreenAudio = d.bool(forKey: "shareScreenAudio")
        siteZooms = d.dictionary(forKey: "siteZooms") as? [String: Double] ?? [:]
        adBlockEnabled = d.object(forKey: "adBlockEnabled") as? Bool ?? true
        adBlockAllowlist = d.stringArray(forKey: "adBlockAllowlist") ?? []
        stripTrackingParameters = d.object(forKey: "stripTrackingParameters") as? Bool ?? true
        historyRetention = HistoryRetention(rawValue: d.integer(forKey: "historyRetention")) ?? .year
        downloadFolderPath = d.string(forKey: "downloadFolderPath")
        askDownloadLocation = d.bool(forKey: "askDownloadLocation")
        checkForUpdates = d.object(forKey: "checkForUpdates") as? Bool ?? true
        onboardingCompleted = d.bool(forKey: "onboardingCompleted")
    }

    func searchURL(for query: String) -> URL? {
        let template = searchEngine == .custom ? customSearchTemplate : searchEngine.template
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    var downloadFolder: URL {
        if let downloadFolderPath, FileManager.default.fileExists(atPath: downloadFolderPath) {
            return URL(fileURLWithPath: downloadFolderPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func applyAppearance() {
        switch theme {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
    }

    func siteZoom(for host: String) -> Double { siteZooms[host.nuriNormalizedHost] ?? 1 }

    /// Private windows apply the zooms chosen elsewhere but record none.
    func setSiteZoom(_ zoom: Double, for host: String) {
        let key = host.nuriNormalizedHost
        if abs(zoom - 1) < 0.001 { siteZooms[key] = nil } else { siteZooms[key] = (zoom * 100).rounded() / 100 }
    }

    func toggleAdBlock(for host: String) {
        let h = host.nuriNormalizedHost
        if let i = adBlockAllowlist.firstIndex(of: h) { adBlockAllowlist.remove(at: i) } else { adBlockAllowlist.append(h) }
    }

    func isAdBlockActive(on host: String?) -> Bool {
        guard adBlockEnabled else { return false }
        guard let host else { return true }
        return !adBlockAllowlist.contains(host.nuriNormalizedHost)
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

extension String {
    /// Lower-cased host without a leading "www.".
    var nuriNormalizedHost: String {
        let h = lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

extension NSImage {
    /// The image drawn in a square of `side` pixels, as PNG. nil for data that isn't an image.
    func nuriResizedPNG(side: CGFloat) -> Data? {
        guard isValid else { return nil }
        let px = Int(side)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
        return rep.representation(using: .png, properties: [:])
    }
}
