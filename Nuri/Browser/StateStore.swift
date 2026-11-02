import Foundation

/// On-disk session: spaces, pinned tabs, folders of tabs and (optionally) regular tabs.
/// Decoding is tolerant (see the extensions below): a missing or unknown field, or one bad tab,
/// must never cost the whole session — website data is stored per space identifier, so losing
/// the spaces would also sign the user out of every site.
struct SavedState: Codable {
    var version = 1
    var currentSpaceID: UUID
    var spaces: [SavedSpace]
    /// Each icon once (tabs of the same site share it), by `SavedTab.faviconKey`.
    var favicons: [String: Data]? = nil
    /// The ⌘N windows open when this was saved.
    var windows: [SavedWindow]? = nil
}

/// A ⌘N window: its tabs and folders, by space. The spaces' names and colors are the main window's.
struct SavedWindow: Codable {
    var currentSpaceID: UUID
    var frame: String?
    var spaces: [SavedSpace]
}

struct SavedSpace: Codable {
    var id: UUID
    var name: String
    /// A `Pastel`; nil: the app's accent.
    var color: String?
    var tabs: [SavedTab]
    var selectedTabID: UUID?
    var folders: [SavedFolder] = []
}

struct SavedFolder: Codable {
    var id: UUID
    var name: String
    var icon: String? = nil
    /// A `Pastel`; nil: none.
    var color: String? = nil
    var tabs: [SavedTab]
}

struct SavedTab: Codable {
    var id: UUID
    var url: URL?
    var title: String
    var faviconKey: String? = nil
    var isMuted = false
}

/// Decodes one element of an array, or nothing if that element is damaged.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private extension KeyedDecodingContainer {
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        let items = (try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil
        return items?.compactMap(\.value) ?? []
    }
}

extension SavedState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        spaces = c.lossyArray(SavedSpace.self, forKey: .spaces)
        currentSpaceID = ((try? c.decodeIfPresent(UUID.self, forKey: .currentSpaceID)) ?? nil) ?? spaces.first?.id ?? UUID()
        favicons = (try? c.decodeIfPresent([String: Data].self, forKey: .favicons)) ?? nil
        windows = c.lossyArray(SavedWindow.self, forKey: .windows)
    }

    /// A tab's icon, wherever this session keeps it.
    func favicon(of tab: SavedTab) -> Data? {
        tab.faviconKey.flatMap { favicons?[$0] }
    }

    /// Key of an icon in `favicons` (FNV-1a of its bytes).
    static func faviconKey(_ data: Data) -> String {
        var h: UInt64 = 1469598103934665603
        for byte in data { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return String(h, radix: 36)
    }
}

extension SavedSpace {
    /// Only the identifier is required: it names the space's website data store.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "Space"
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? nil
        tabs = c.lossyArray(SavedTab.self, forKey: .tabs)
        selectedTabID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedTabID)) ?? nil
        folders = c.lossyArray(SavedFolder.self, forKey: .folders)
    }
}

extension SavedFolder {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "Folder"
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? nil
        tabs = c.lossyArray(SavedTab.self, forKey: .tabs)
    }
}

extension SavedTab {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        url = (try? c.decodeIfPresent(URL.self, forKey: .url)) ?? nil
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? ""
        faviconKey = (try? c.decodeIfPresent(String.self, forKey: .faviconKey)) ?? nil
        isMuted = ((try? c.decodeIfPresent(Bool.self, forKey: .isMuted)) ?? nil) ?? false
    }
}

/// Back/forward lists of the session's tabs, one file per tab next to session.json: a list can be
/// large and rarely changes, so only those that changed are written. Their pages' addresses and form
/// data are in there: the folder is the user's alone, and erasing the history empties it.
@MainActor
enum TabStates {
    private static var directory: URL { StateStore.sessionDirectory.appendingPathComponent("TabStates", isDirectory: true) }
    /// Past this, the tab comes back with its page but without its list.
    private static let maximumSize = 512 * 1024
    private static var written: [UUID: String] = [:]

    private static func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }

    static func read(_ id: UUID) -> Data? { try? Data(contentsOf: file(id)) }

    /// `ids`: the tabs the session keeps. Anything else in the folder goes.
    static func save(_ tabs: [Tab], keeping ids: Set<UUID>) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for tab in tabs where ids.contains(tab.id) {
            if tab.historyWasErased {
                try? fm.removeItem(at: file(tab.id))
                written[tab.id] = nil
                continue
            }
            // Nil: asleep since the launch, its file is still right.
            guard let state = tab.stateToSave else { continue }
            guard state.count <= maximumSize else {
                try? fm.removeItem(at: file(tab.id))
                written[tab.id] = nil
                continue
            }
            let key = SavedState.faviconKey(state)
            guard written[tab.id] != key else { continue }
            if (try? state.write(to: file(tab.id), options: .atomic)) != nil { written[tab.id] = key }
        }
        let names = Set(ids.map(\.uuidString))
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !names.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// A page that stops Nuri would stop it again at each launch, as soon as its tab is restored. A launch
/// is marked until it has lasted a minute or Nuri quits: a mark found at the next launch means that
/// launch died young, and no restored tab is woken up by itself (see BrowserModel.restore).
enum LaunchGuard {
    private static var mark: URL { StateStore.directory.appendingPathComponent("launching") }

    /// Read before `start` writes the mark.
    static let previousLaunchDied = FileManager.default.fileExists(atPath: mark.path)

    static func start() {
        _ = previousLaunchDied
        FileManager.default.createFile(atPath: mark.path, contents: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { finish() }
    }

    static func finish() {
        try? FileManager.default.removeItem(at: mark)
    }
}

enum StateStore {
    /// ~/Library/Application Support/Nuri
    static let directory: URL = {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        // The self-test never reads or writes the user's history or session.
        if SelfTestRunner.isRequested {
            base = SelfTestRunner.keptDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("nuri-selftest-\(UUID().uuidString)", isDirectory: true)
        }
        #endif
        let dir = base.appendingPathComponent("Nuri", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Where session.json lives (the self-test points it at a temporary folder).
    static var sessionDirectory = directory

    private static var fileURL: URL { sessionDirectory.appendingPathComponent("session.json") }
    /// Copy of the last session that could be read, taken at launch.
    private static var backupURL: URL { sessionDirectory.appendingPathComponent("session.backup.json") }

    static func load() -> SavedState? {
        let fm = FileManager.default
        if let state = decode(fileURL) {
            // Known good: keep a copy to fall back on if a later write is ever damaged.
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
            return state
        }
        guard fm.fileExists(atPath: fileURL.path) else { return nil }   // first launch
        // Unreadable: set it aside (never overwrite it), then fall back on the backup.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let corrupt = sessionDirectory.appendingPathComponent("session.corrupt-\(stamp)-\(UUID().uuidString.prefix(4)).json")
        try? fm.moveItem(at: fileURL, to: corrupt)
        return decode(backupURL)
    }

    private static func decode(_ url: URL) -> SavedState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SavedState.self, from: data),
              !state.spaces.isEmpty else { return nil }
        return state
    }

    static func save(_ state: SavedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
