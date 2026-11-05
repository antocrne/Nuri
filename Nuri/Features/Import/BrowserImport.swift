import AppKit
import Foundation
import os
import UniformTypeIdentifiers

/// A page kept in another browser, or in a bookmarks file.
struct ImportedBookmark: Equatable {
    let url: URL
    let title: String
}

/// A page of another browser's history.
struct ImportedVisit: Equatable {
    let url: URL
    let title: String
    let visits: Int
    let last: Date
}

/// Another browser found on this Mac: where its bookmarks and its history are.
struct ImportSource: Identifiable, Equatable {
    enum Kind { case safari, chromium, firefox }
    let kind: Kind
    /// "Google Chrome", "Firefox (default-release)".
    let name: String
    let bookmarks: URL?
    let history: URL?
    var id: String { (bookmarks ?? history)?.path ?? name }
}

/// Bookmarks and history from Safari, the Chromium browsers (Chrome, Brave, Edge, Arc, Vivaldi) and
/// Firefox, or from a bookmarks file (the HTML every browser exports); bookmarks exported in that same
/// format. Only the files of bookmarks and history are read: never cookies or passwords. The
/// databases are read from a copy, since the browser may be running and holding them.
/// Folders aren't kept: Nuri's bookmarks are one list per space.
enum BrowserImport {
    private static let log = Logger(subsystem: "app.nuri.browser", category: "import")

    /// The most recent pages of a history: enough to find one's sites again.
    static let historyLimit = 20_000

    enum Failure: Error, Equatable {
        /// macOS keeps Safari's files from apps without Full Disk Access.
        case noAccess
        case unreadable

        @MainActor var message: String {
            switch self {
            case .noAccess:
                L("Nuri n'a pas accès à ces fichiers : Réglages Système → Confidentialité et sécurité → Accès complet au disque, ou exportez les favoris en HTML depuis ce navigateur et importez le fichier.",
                  "Nuri can't read these files: System Settings → Privacy & Security → Full Disk Access, or export the bookmarks as HTML from that browser and import the file.")
            case .unreadable:
                L("Ces fichiers n'ont pas pu être lus.", "These files couldn't be read.")
            }
        }
    }

    // MARK: Finding the browsers

    /// Chromium browsers keep a folder per profile ("Default", "Profile 1"…), each with `Bookmarks`
    /// (JSON) and `History` (SQLite).
    private static let chromiumFolders: [(name: String, path: String)] = [
        ("Google Chrome", "Google/Chrome"), ("Chrome Beta", "Google/Chrome Beta"), ("Chromium", "Chromium"),
        ("Brave", "BraveSoftware/Brave-Browser"), ("Microsoft Edge", "Microsoft Edge"), ("Vivaldi", "Vivaldi"), ("Arc", "Arc/User Data"),
    ]

    /// `library`: ~/Library (the self-test has its own).
    static func sources(library: URL? = nil) -> [ImportSource] {
        let fm = FileManager.default
        let library = library ?? fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        var found: [ImportSource] = []
        // Safari's folder can't even be listed without Full Disk Access: it is offered anyway, and
        // says so when it's chosen.
        let safari = library.appendingPathComponent("Safari", isDirectory: true)
        if fm.fileExists(atPath: safari.path) {
            found.append(ImportSource(kind: .safari, name: "Safari", bookmarks: safari.appendingPathComponent("Bookmarks.plist"),
                                      history: safari.appendingPathComponent("History.db")))
        }
        for browser in chromiumFolders {
            let base = support.appendingPathComponent(browser.path, isDirectory: true)
            let profiles = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for profile in profiles {
                let bookmarks = profile.appendingPathComponent("Bookmarks")
                let history = profile.appendingPathComponent("History")
                let hasBookmarks = fm.fileExists(atPath: bookmarks.path), hasHistory = fm.fileExists(atPath: history.path)
                guard hasBookmarks || hasHistory else { continue }
                let name = profiles.count > 1 ? "\(browser.name) (\(profile.lastPathComponent))" : browser.name
                found.append(ImportSource(kind: .chromium, name: name, bookmarks: hasBookmarks ? bookmarks : nil, history: hasHistory ? history : nil))
            }
        }
        let firefox = support.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        let profiles = ((try? fm.contentsOfDirectory(at: firefox, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("places.sqlite").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for profile in profiles {
            let places = profile.appendingPathComponent("places.sqlite")
            // "abcd1234.default-release": the part after the dot is its name.
            let label = profile.lastPathComponent.split(separator: ".", maxSplits: 1).last.map(String.init) ?? profile.lastPathComponent
            found.append(ImportSource(kind: .firefox, name: profiles.count > 1 ? "Firefox (\(label))" : "Firefox", bookmarks: places, history: places))
        }
        return found
    }

    // MARK: Reading

    static func bookmarks(of source: ImportSource) -> Result<[ImportedBookmark], Failure> {
        guard let file = source.bookmarks else { return .success([]) }
        switch source.kind {
        case .safari:
            return read(file).map(safariBookmarks)
        case .chromium:
            return read(file).map(chromiumBookmarks)
        case .firefox:
            return withCopy(of: file) { db in
                var out: [ImportedBookmark] = []
                db.query("SELECT p.url, COALESCE(b.title, p.title, '') FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk WHERE b.type = 1") { row in
                    if let bookmark = bookmark(row.string(0), row.string(1)) { out.append(bookmark) }
                }
                return out
            }
        }
    }

    static func history(of source: ImportSource) -> Result<[ImportedVisit], Failure> {
        guard let file = source.history else { return .success([]) }
        let limit = historyLimit
        switch source.kind {
        case .safari:
            // Visits are counted since 2001; the title is the latest visit's.
            return withCopy(of: file) { db in
                visits(db, """
                SELECT i.url, COALESCE((SELECT v.title FROM history_visits v WHERE v.history_item = i.id ORDER BY v.visit_time DESC LIMIT 1), ''),
                       i.visit_count, (SELECT MAX(v.visit_time) FROM history_visits v WHERE v.history_item = i.id) AS last
                FROM history_items i WHERE last IS NOT NULL ORDER BY last DESC LIMIT \(limit)
                """) { Date(timeIntervalSinceReferenceDate: $0) }
            }
        case .chromium:
            // Microseconds since 1601.
            return withCopy(of: file) { db in
                visits(db, "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT \(limit)") {
                    Date(timeIntervalSince1970: $0 / 1_000_000 - 11_644_473_600)
                }
            }
        case .firefox:
            // Microseconds since 1970.
            return withCopy(of: file) { db in
                visits(db, "SELECT url, COALESCE(title, ''), visit_count, last_visit_date FROM moz_places WHERE visit_count > 0 AND last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT \(limit)") {
                    Date(timeIntervalSince1970: $0 / 1_000_000)
                }
            }
        }
    }

    private static func visits(_ db: SQLiteDB, _ sql: String, date: (Double) -> Date) -> [ImportedVisit] {
        var out: [ImportedVisit] = []
        db.query(sql) { row in
            guard let url = webURL(row.string(0)) else { return }
            out.append(ImportedVisit(url: url, title: row.string(1), visits: max(1, Int(row.int(2))), last: date(row.double(3))))
        }
        return out
    }

    private static func read(_ file: URL) -> Result<Data, Failure> {
        do {
            return .success(try Data(contentsOf: file))
        } catch {
            log.error("Lecture impossible de \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(isPermissionError(error) ? .noAccess : .unreadable)
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(underlying?.code ?? 0)
    }

    /// The database and its journal copied apart: the browser may be writing it, and SQLite would
    /// otherwise wait on its lock or touch its files.
    private static func withCopy<T>(of file: URL, _ body: (SQLiteDB) -> T) -> Result<T, Failure> {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("nuri-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(file.lastPathComponent)
            try fm.copyItem(at: file, to: copy)
            for suffix in ["-wal", "-shm", "-journal"] {
                let side = URL(fileURLWithPath: file.path + suffix)
                if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
            }
            guard let db = SQLiteDB(path: copy.path) else { return .failure(.unreadable) }
            return .success(body(db))
        } catch {
            log.error("Copie impossible de \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(isPermissionError(error) ? .noAccess : .unreadable)
        }
    }

    /// Only pages of the web: no `javascript:` bookmarklets, `place:` queries or local files.
    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }

    private static func bookmark(_ address: String, _ title: String) -> ImportedBookmark? {
        webURL(address).map { ImportedBookmark(url: $0, title: title.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func safariBookmarks(_ data: Data) -> [ImportedBookmark] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var out: [ImportedBookmark] = []
        func walk(_ node: [String: Any]) {
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                if let address = node["URLString"] as? String, let bookmark = bookmark(address, title) { out.append(bookmark) }
            case "WebBookmarkTypeList":
                // The reading list is a list of things to read once, not bookmarks.
                guard node["Title"] as? String != "com.apple.ReadingList" else { return }
                (node["Children"] as? [[String: Any]] ?? []).forEach(walk)
            default:
                break
            }
        }
        walk(root)
        return out
    }

    static func chromiumBookmarks(_ data: Data) -> [ImportedBookmark] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return [] }
        var out: [ImportedBookmark] = []
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "url" {
                if let address = node["url"] as? String, let bookmark = bookmark(address, node["name"] as? String ?? "") { out.append(bookmark) }
            }
            (node["children"] as? [[String: Any]] ?? []).forEach(walk)
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] as? [String: Any] { walk(node) }
        }
        return out
    }

    // MARK: The bookmarks file (Netscape HTML)

    /// What Safari, Chrome, Firefox and Edge export: `<DT><A HREF="…">title</A>` in nested lists.
    static func htmlBookmarks(_ html: String) -> [ImportedBookmark] {
        guard let link = try? NSRegularExpression(pattern: #"<a\s[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>"#,
                                                  options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let text = html as NSString
        return link.matches(in: html, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let address = decodeEntities(text.substring(with: match.range(at: 1)))
            let title = decodeEntities(text.substring(with: match.range(at: 2)).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            return bookmark(address, title)
        }
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        if let numeric = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let source = out as NSString
            var rebuilt = ""
            var last = 0
            for match in numeric.matches(in: out, range: NSRange(location: 0, length: source.length)) {
                rebuilt += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let hex = source.substring(with: match.range(at: 1)) == "x"
                let value = UInt32(source.substring(with: match.range(at: 2)), radix: hex ? 16 : 10)
                rebuilt += value.flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? source.substring(with: match.range)
                last = match.range.location + match.range.length
            }
            rebuilt += source.substring(from: last)
            out = rebuilt
        }
        for (entity, character) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The bookmarks file every browser imports. The favorites go in their own folder.
    @MainActor
    static func exportHTML(_ bookmarks: [Bookmark]) -> String {
        func line(_ bookmark: Bookmark, indent: String) -> String {
            "\(indent)<DT><A HREF=\"\(escape(bookmark.url.absoluteString))\">\(escape(bookmark.displayTitle))</A>\n"
        }
        var html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        let favorites = bookmarks.filter(\.isFavorite)
        if !favorites.isEmpty {
            html += "    <DT><H3>\(escape(L("Favoris", "Favorites")))</H3>\n    <DL><p>\n"
            favorites.forEach { html += line($0, indent: "        ") }
            html += "    </DL><p>\n"
        }
        bookmarks.filter { !$0.isFavorite }.forEach { html += line($0, indent: "    ") }
        html += "</DL><p>\n"
        return html
    }
}

// MARK: - Into Nuri

extension BrowserImport {
    /// What an import added (pages already there aren't counted twice).
    struct Outcome: Equatable {
        var bookmarks = 0
        var pages = 0
    }

    /// `space`: where everything goes (each space has its own bookmarks and history).
    @MainActor
    static func run(_ source: ImportSource, bookmarks: Bool, history: Bool, into space: UUID) async -> Result<Outcome, Failure> {
        let read = await Task.detached(priority: .userInitiated) { () -> Result<([ImportedBookmark], [ImportedVisit]), Failure> in
            let marks = bookmarks ? Self.bookmarks(of: source) : .success([])
            let visits = history ? Self.history(of: source) : .success([])
            switch (marks, visits) {
            case (.success(let m), .success(let v)): return .success((m, v))
            // One of the two read is still worth taking.
            case (.success(let m), .failure(let f)): return m.isEmpty ? .failure(f) : .success((m, []))
            case (.failure(let f), .success(let v)): return v.isEmpty ? .failure(f) : .success(([], v))
            case (.failure(let f), .failure): return .failure(f)
            }
        }.value
        return read.map { marks, visits in
            Outcome(bookmarks: BookmarkStore.shared.importBookmarks(marks, space: space),
                    pages: HistoryStore.shared.importVisits(visits, space: space))
        }
    }

    @MainActor
    static func runFile(_ file: URL, into space: UUID) -> Result<Outcome, Failure> {
        guard let data = try? Data(contentsOf: file) else { return .failure(.unreadable) }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let marks = htmlBookmarks(html)
        guard !marks.isEmpty else { return .failure(.unreadable) }
        return .success(Outcome(bookmarks: BookmarkStore.shared.importBookmarks(marks, space: space)))
    }

    @MainActor
    static func summary(_ outcome: Outcome, space: String) -> String {
        L("\(outcome.bookmarks) signets et \(outcome.pages) pages d'historique ajoutés à « \(space) ».",
          "\(outcome.bookmarks) bookmarks and \(outcome.pages) history pages added to “\(space)”.")
    }
}

extension BrowserImport {
    /// "Exporter les signets…": the space's bookmarks, where the user says.
    @MainActor
    static func exportWithPanel(space: Space) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = L("Signets Nuri - \(space.name).html", "Nuri Bookmarks - \(space.name).html")
        panel.prompt = L("Exporter", "Export")
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let html = exportHTML(BookmarkStore.shared.items.filter { $0.spaceID == space.id })
        do {
            try html.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            log.error("Export impossible : \(error.localizedDescription, privacy: .public)")
            BrowserWindows.shared.active.showToast("exclamationmark.triangle", L("Export impossible : \(error.localizedDescription)", "Couldn't export: \(error.localizedDescription)"))
        }
    }
}
