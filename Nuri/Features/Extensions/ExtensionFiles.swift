import Foundation

/// An extension kept in Nuri's folder.
struct InstalledExtension: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case webStore, browser }
    /// Chrome's identifier: 32 letters from a to p.
    let id: String
    var name: String
    var version: String
    var source: Source
    var enabled = true
    /// Allowed after it was added, when it asked (WebKit doesn't remember them from one launch to
    /// the next): permissions' raw values, match patterns.
    var laterPermissions: [String]?
    var laterSites: [String]?
    /// Its own button in the bar, beside the extensions button (nil: only in the panel).
    var pinned: Bool?
    /// A VPN (chrome.proxy): whether the user lets it route pages through its servers (nil: not
    /// asked yet), and what it set, restored at the next launch.
    var proxyAllowed: Bool?
    var proxy: SavedProxy?
}

/// An extension found in another browser's folder.
struct BrowserExtensionCopy: Identifiable, Equatable {
    let id: String
    let version: String
    let folder: URL
    let browser: String
    let profile: String
}

enum ExtensionFileError: LocalizedError {
    case notAPackage, unpackFailed, unsafeContent, download(Int)

    @MainActor var message: String {
        switch self {
        case .notAPackage: L("Ce fichier n'est pas une extension Chrome.", "This file isn't a Chrome extension.")
        case .unpackFailed: L("L'extension n'a pas pu être décompressée.", "The extension couldn't be unpacked.")
        case .unsafeContent: L("Cette extension contient des liens vers d'autres dossiers : refusée.", "This extension links to other folders: refused.")
        case .download(204): L("Cette extension n'est pas sur le Chrome Web Store.", "This extension isn't on the Chrome Web Store.")
        case .download(let status): L("Le Chrome Web Store a répondu \(status).", "The Chrome Web Store answered \(status).")
        }
    }
}

/// What extensions are on disk: Nuri's own folder, the Chrome Web Store's packages, and the copies
/// other browsers keep. Nothing here runs an extension, and nothing happens without being asked.
enum ExtensionFiles {
    static var directory: URL { StateStore.directory.appendingPathComponent("Extensions", isDirectory: true) }
    private static var recordsURL: URL { StateStore.directory.appendingPathComponent("extensions.json") }

    static func folder(of id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }

    static func loadRecords() -> [InstalledExtension] {
        guard let data = try? Data(contentsOf: recordsURL) else { return [] }
        return (try? JSONDecoder().decode([InstalledExtension].self, from: data)) ?? []
    }

    static func save(_ records: [InstalledExtension]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsURL, options: .atomic)
    }

    // MARK: - The Chrome Web Store

    static func isExtensionID(_ text: some StringProtocol) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The identifier in a store address (chromewebstore.google.com/detail/name/id, or the older
    /// chrome.google.com/webstore/detail/name/id), or the identifier by itself.
    static func webStoreID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExtensionID(trimmed) { return trimmed }
        guard let url = URL(string: trimmed), let host = url.host()?.lowercased(),
              host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        let parts = url.pathComponents
        guard let detail = parts.firstIndex(of: "detail") else { return nil }
        return parts[(detail + 1)...].first { isExtensionID($0) }
    }

    /// Where Chrome itself gets a package. Only the extension's identifier and a Chrome version are
    /// sent; a version far ahead, or the store withholds what asks for a newer Chrome than it is told.
    static func packageURL(id: String) -> URL? {
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=999.0.0.0&acceptformat=crx2,crx3&x=id%3D\(id)%26uc")
    }

    /// The version the store has now: the same address answers it without sending the package.
    static func latestVersion(id: String) async -> String? {
        guard let url = packageURL(id: id), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = components.queryItems?.map { $0.name == "response" ? URLQueryItem(name: "response", value: "updatecheck") : $0 }
        guard let check = components.url, let (data, response) = try? await URLSession.shared.data(from: check),
              (response as? HTTPURLResponse)?.statusCode == 200, let xml = String(data: data, encoding: .utf8),
              let tag = xml.range(of: "<updatecheck[^>]*>", options: .regularExpression),
              let version = xml[tag].range(of: #"\sversion="[0-9.]+""#, options: .regularExpression) else { return nil }
        return String(xml[tag][version].dropFirst(10).dropLast())
    }

    /// Downloads and unpacks a package; the caller owns the folder returned.
    static func download(id: String) async throws -> URL {
        guard let url = packageURL(id: id) else { throw ExtensionFileError.notAPackage }
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw ExtensionFileError.download(status) }
        return try await Task.detached { try unpack(package: Data(contentsOf: file)) }.value
    }

    /// The zip inside a package: "Cr24", then its version and signature header, in either format.
    static func zipPayload(ofPackage data: Data) -> Data? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 12, bytes[0...3].elementsEqual("Cr24".utf8) else { return nil }
        func number(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        let start: Int
        switch number(4) {
        case 3: start = 12 + number(8)
        case 2:
            guard bytes.count == 16 else { return nil }
            start = 16 + number(8) + number(12)
        default: return nil
        }
        guard start < data.count else { return nil }
        return data.suffix(from: data.startIndex + start)
    }

    /// A folder with the package's files. `unzip` leaves out paths going up; a link to somewhere
    /// else on the Mac is refused.
    static func unpack(package: Data) throws -> URL {
        guard let zip = zipPayload(ofPackage: package) else { throw ExtensionFileError.notAPackage }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("nuri-extension-\(UUID().uuidString)", isDirectory: true)
        let folder = work.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("package.zip")
        try zip.write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", archive.path, "-d", folder.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
            throw ExtensionFileError.unpackFailed
        }
        if hasLinks(in: folder) { throw ExtensionFileError.unsafeContent }
        return folder
    }

    static func hasLinks(in folder: URL) -> Bool {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let file = files?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return true }
        }
        return false
    }

    // MARK: - What Chrome gives and WebKit doesn't

    private static let shimFile = "nuri-shim.js"
    private static let backgroundWrapperFile = "nuri-background.js"
    /// An empty page of the extension's own, to act as the extension (see ExtensionHost.revive).
    static let blankPageFile = "nuri-blank.html"
    /// Written once the shim is in: the same shim and the same version skip the work next launch.
    private static let stampFile = "nuri-shim.stamp"
    private static let inlineShimStart = "/*nuri-shim:start*/"
    private static let inlineShimEnd = "/*nuri-shim:end*/\n"

    /// chrome.runtime for the sites the extension lets talk to it (extension-external.js).
    private static let externalFile = "nuri-external.js"
    private static let externalIDPlaceholder = "__NURI_EXTENSION_ID__"

    private static let shimStamp: String = {
        var hash: UInt64 = 1469598103934665603   // FNV-1a
        for byte in (Scripts.extensionShim + Scripts.extensionExternal).utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 36)
    }()

    /// Nuri's copy of an extension gets extension-shim.js, run first in each of its contexts: its
    /// background script, its pages and its content scripts. Scripts it injects itself get it at
    /// their top. Never outside Nuri's folder. Every write is atomic, so it replaces a file and
    /// never follows a link out of the folder. Files only: this runs off the main thread (a large
    /// extension has megabytes of scripts to scan).
    static func addShims(to folder: URL) {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let stampURL = folder.appendingPathComponent(stampFile)
        guard folder.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/"), !hasLinks(in: folder),
              let data = try? Data(contentsOf: manifestURL),
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let stamp = shimStamp + "|" + (manifest["version"] as? String ?? "")
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp,
           FileManager.default.fileExists(atPath: folder.appendingPathComponent(shimFile).path) { return }
        guard (try? Data(Scripts.extensionShim.utf8).write(to: folder.appendingPathComponent(shimFile), options: .atomic)) != nil else { return }
        defer { try? Data(stamp.utf8).write(to: stampURL, options: .atomic) }
        try? Data("<!doctype html><meta charset=utf-8><title>Nuri</title>".utf8).write(to: folder.appendingPathComponent(blankPageFile), options: .atomic)
        var changed = false

        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, worker != backgroundWrapperFile {
                // A service worker is one file: a new one imports the shim, then the extension's.
                func literal(_ path: String) -> String {
                    let data = try? JSONSerialization.data(withJSONObject: "/" + path.drop { $0 == "/" }, options: [.fragmentsAllowed, .withoutEscapingSlashes])
                    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"/\(path)\""
                }
                let source = background["type"] as? String == "module"
                    ? "import \(literal(shimFile));\nimport \(literal(worker));\n"
                    : "importScripts(\(literal(shimFile)), \(literal(worker)));\n"
                if (try? Data(source.utf8).write(to: folder.appendingPathComponent(backgroundWrapperFile), options: .atomic)) != nil {
                    background["service_worker"] = backgroundWrapperFile
                    changed = true
                }
            } else if var scripts = background["scripts"] as? [String], scripts.first != shimFile {
                scripts.insert(shimFile, at: 0)
                background["scripts"] = scripts
                changed = true
            }
            manifest["background"] = background
        }

        // Content scripts, in the extension's isolated world (not those running in the page's own).
        if var entries = manifest["content_scripts"] as? [[String: Any]] {
            for index in entries.indices where (entries[index]["world"] as? String)?.uppercased() != "MAIN" {
                guard var scripts = entries[index]["js"] as? [String], scripts.first != shimFile else { continue }
                scripts.insert(shimFile, at: 0)
                entries[index]["js"] = scripts
                changed = true
            }
            manifest["content_scripts"] = entries
        }

        // The sites it lets talk to it get chrome.runtime, in their own world, before their scripts.
        let connectable = ((manifest["externally_connectable"] as? [String: Any])?["matches"] as? [String])?
            .filter { $0.hasPrefix("https://") } ?? []
        var entries = manifest["content_scripts"] as? [[String: Any]] ?? []
        let hasExternal = entries.contains { ($0["js"] as? [String])?.contains(externalFile) == true }
        if !connectable.isEmpty, isExtensionID(folder.lastPathComponent),
           (try? Data(Scripts.extensionExternal.replacingOccurrences(of: externalIDPlaceholder, with: folder.lastPathComponent).utf8)
                .write(to: folder.appendingPathComponent(externalFile), options: .atomic)) != nil {
            if !hasExternal {
                entries.append(["matches": connectable, "js": [externalFile], "run_at": "document_start", "world": "MAIN", "all_frames": true])
                manifest["content_scripts"] = entries
                changed = true
            }
        }

        if changed, let patched = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? patched.write(to: manifestURL, options: .atomic)
        }

        prependShim(toScriptsInjectedBy: folder)

        // Pages: the shim as their first script, right after <head>, or <html>, or the doctype.
        let tag = "<script src=\"/\(shimFile)\"></script>"
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.lastPathComponent == "_metadata" { files?.skipDescendants(); continue }
            guard ["html", "htm"].contains(url.pathExtension.lowercased()),
                  let page = try? String(contentsOf: url, encoding: .utf8), !page.contains(tag) else { continue }
            var insertion = page.startIndex
            for pattern in ["<head(\\s[^>]*)?>", "<html(\\s[^>]*)?>", "<!doctype[^>]*>"] {
                if let range = page.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    insertion = range.upperBound
                    break
                }
            }
            var patched = page
            patched.insert(contentsOf: tag, at: insertion)
            try? patched.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Scripts the extension injects itself (chrome.scripting.executeScript({ files: [...] })) have
    /// no manifest entry to add the shim to: their lists are looked for in its code, and the shim
    /// goes at the top of each, replacing an older copy. It guards itself: running twice, or in a
    /// page's own world (no extension API there), does nothing.
    private static func prependShim(toScriptsInjectedBy folder: URL) {
        guard let listPattern = try? NSRegularExpression(pattern: #"(?:files|js)\s*:\s*\[([^\]]*)\]"#),
              let namePattern = try? NSRegularExpression(pattern: #"["'`]/?([^"'`]+\.js)["'`]"#) else { return }
        var injected = Set<String>()
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.lastPathComponent == "_metadata" { files?.skipDescendants(); continue }
            guard url.pathExtension == "js", let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for list in listPattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(list.range(at: 1), in: source) else { continue }
                let items = String(source[range])
                for name in namePattern.matches(in: items, range: NSRange(items.startIndex..., in: items)) {
                    if let found = Range(name.range(at: 1), in: items) { injected.insert(String(items[found])) }
                }
            }
        }
        let shim = inlineShimStart + Scripts.extensionShim + "\n" + inlineShimEnd
        for path in injected where path != shimFile && path != backgroundWrapperFile {
            let url = folder.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(folder.standardizedFileURL.path + "/"), var source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if source.hasPrefix(inlineShimStart), let end = source.range(of: inlineShimEnd) {
                source.removeSubrange(source.startIndex..<end.upperBound)
            }
            try? (shim + source).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Other browsers

    /// Chromium browsers keep extensions at <profile>/Extensions/<id>/<version>.
    private static let browserFolders: [(name: String, path: String)] = [
        ("Google Chrome", "Google/Chrome"), ("Chrome Beta", "Google/Chrome Beta"), ("Chrome Canary", "Google/Chrome Canary"),
        ("Chromium", "Chromium"), ("Brave", "BraveSoftware/Brave-Browser"), ("Microsoft Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"), ("Arc", "Arc/User Data"),
    ]

    /// Chrome's own: every profile has them, nobody chose them.
    private static let builtIn: Set<String> = [
        "nmmhkkegccagdldgiimedpiccmgmieda", "ghbmnnjooekpmoecnnnilnnbdlolhkhi", "aapocclcgogkmnckokdopfmhonfmgoek",
        "aohghmighlieiainnegkcijnfilokake", "apdfllckaahabafndbhieahigkjlhalf", "blpcfgokakmgnkcojhhkbfbldkacnbeo",
        "felcaaldnbdncclmgdcncolpebgiejap", "pjkljhegncpnkpknbcohdijeoejaedia", "pkedcjkdefgpdelpbcmbmeomcjbeemfm",
    ]

    /// Only the extensions' folders are looked at: not the browser's cookies, history or passwords.
    /// `root`: where the browsers' folders are (the self-test has its own).
    static func findInBrowsers(root: URL? = nil) -> [BrowserExtensionCopy] {
        let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var found: [String: BrowserExtensionCopy] = [:]
        for browser in browserFolders {
            let base = root.appendingPathComponent(browser.path, isDirectory: true)
            for profile in contents(of: base) {
                let extensions = profile.appendingPathComponent("Extensions", isDirectory: true)
                for folder in contents(of: extensions) where isExtensionID(folder.lastPathComponent) && !builtIn.contains(folder.lastPathComponent) {
                    let versions = contents(of: folder).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
                    guard let latest = versions.max(by: { isOlder($0.lastPathComponent, than: $1.lastPathComponent) }) else { continue }
                    let id = folder.lastPathComponent
                    if let known = found[id], !isOlder(known.version, than: latest.lastPathComponent) { continue }
                    found[id] = BrowserExtensionCopy(id: id, version: latest.lastPathComponent, folder: latest,
                                                     browser: browser.name, profile: profile.lastPathComponent)
                }
            }
        }
        return found.values.sorted { $0.id < $1.id }
    }

    /// Browsers whose folder is there but can't be read: macOS said no, which isn't the same as
    /// having no extensions.
    static func unreadableBrowsers(root: URL? = nil) -> [String] {
        let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return browserFolders.filter { browser in
            let base = root.appendingPathComponent(browser.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: base.path) else { return false }
            return (try? FileManager.default.contentsOfDirectory(atPath: base.path)) == nil
        }.map(\.name)
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    /// Versions are numbers separated by dots (Chrome's folders add "_0").
    static func isOlder(_ a: String, than b: String) -> Bool {
        let numbers = { (text: String) in text.split(whereSeparator: { $0 == "." || $0 == "_" }).map { Int($0) ?? 0 } }
        let (x, y) = (numbers(a), numbers(b))
        for index in 0..<max(x.count, y.count) {
            let (p, q) = (index < x.count ? x[index] : 0, index < y.count ? y[index] : 0)
            if p != q { return p < q }
        }
        return false
    }
}
