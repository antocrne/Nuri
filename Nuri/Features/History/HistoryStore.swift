import Foundation
import Observation

struct HistoryEntry: Identifiable, Hashable {
    var id: String { space.uuidString + url.absoluteString }
    let url: URL
    let title: String
    let visits: Int
    let lastVisit: Date
    let space: UUID
}

/// Browsing history in ~/Library/Application Support/Nuri/history.sqlite, one per space in the same
/// file (the same page visited in two spaces is two lines). Private tabs never write here.
@MainActor @Observable
final class HistoryStore {
    static let shared = HistoryStore()
    @ObservationIgnored private let db: SQLiteDB?
    /// Changes when the pages listed change: the history window reads it.
    private(set) var revision = 0

    private init() {
        db = SQLiteDB(path: StateStore.directory.appendingPathComponent("history.sqlite").path, ownDatabase: true)
        db?.execute("""
        CREATE TABLE IF NOT EXISTS history (url TEXT NOT NULL, space TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
                                            visits INTEGER NOT NULL DEFAULT 1, last REAL NOT NULL, PRIMARY KEY (url, space))
        """)
        db?.execute("CREATE INDEX IF NOT EXISTS history_last ON history(last DESC)")
        prune()
    }

    @ObservationIgnored private var lastPrune = Date.distantPast

    /// Removes the pages not visited for longer than the period chosen in Settings.
    /// Runs at launch, then at most once a day as pages are visited.
    func prune() {
        lastPrune = Date()
        let cutoff = Date().addingTimeInterval(-Double(AppSettings.shared.historyRetention.rawValue) * 86_400)
        db?.execute("DELETE FROM history WHERE last < ?", [cutoff.timeIntervalSince1970])
        revision += 1
    }

    func record(url: URL, title: String, space: UUID, at date: Date = Date()) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        if Date().timeIntervalSince(lastPrune) > 86_400 { prune() }
        db?.execute("""
        INSERT INTO history(url, space, title, visits, last) VALUES(?, ?, ?, 1, ?)
        ON CONFLICT(url, space) DO UPDATE SET visits = visits + 1, last = excluded.last,
            title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
        """, [url.absoluteString, space.uuidString, title, date.timeIntervalSince1970])
        revision += 1
    }

    /// Last title written per URL: pages that animate their title (unread counters, tickers)
    /// would otherwise write to disk continuously.
    @ObservationIgnored private var writtenTitles: [String: String] = [:]

    func updateTitle(url: URL, title: String, space: UUID) {
        let key = space.uuidString + url.absoluteString
        guard writtenTitles[key] != title else { return }
        if writtenTitles.count > 500 { writtenTitles.removeAll() }
        writtenTitles[key] = title
        db?.execute("UPDATE history SET title = ? WHERE url = ? AND space = ?", [title, url.absoluteString, space.uuidString])
    }

    /// Pages matching `text` (the latest ones without it), in one space or in all of them.
    func search(_ text: String, space: UUID?, limit: Int = 8) -> [HistoryEntry] {
        let q = text.trimmingCharacters(in: .whitespaces)
        let scope = space == nil ? "" : "space = ? AND "
        let spaceArgs: [Any?] = space.map { [$0.uuidString] } ?? []
        guard !q.isEmpty else {
            return fetch("SELECT url, title, visits, last, space FROM history WHERE \(scope)1 ORDER BY last DESC LIMIT ?", spaceArgs + [limit])
        }
        // Typed text is matched as is: % and _ aren't wildcards here.
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let like = "%" + escaped + "%"
        return fetch("""
        SELECT url, title, visits, last, space FROM history WHERE \(scope)(url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')
        ORDER BY (CASE WHEN url LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END), visits DESC, last DESC LIMIT ?
        """, spaceArgs + [like, like, "%://" + escaped + "%", limit])
    }

    func delete(_ entry: HistoryEntry) {
        db?.execute("DELETE FROM history WHERE url = ? AND space = ?", [entry.url.absoluteString, entry.space.uuidString])
        revision += 1
    }

    /// What the history window erases: the last hour, day, 30 days, year, or everything.
    enum Range: CaseIterable, Identifiable {
        case hour, day, month, year, all
        var id: Self { self }
        var seconds: TimeInterval? {
            switch self {
            case .hour: 3600
            case .day: 86_400
            case .month: 30 * 86_400
            case .year: 365 * 86_400
            case .all: nil
            }
        }
        @MainActor var label: String {
            switch self {
            case .hour: L("La dernière heure", "The last hour")
            case .day: L("Le dernier jour", "The last day")
            case .month: L("Les 30 derniers jours", "The last 30 days")
            case .year: L("La dernière année", "The last year")
            case .all: L("Tout l'historique", "All history")
            }
        }
    }

    /// Nothing left on disk either — the write-ahead log, which still holds the old pages until a
    /// checkpoint, is emptied, and the file is rewritten.
    func erase(_ range: Range, now: Date = Date()) {
        if let seconds = range.seconds {
            db?.execute("DELETE FROM history WHERE last >= ?", [now.addingTimeInterval(-seconds).timeIntervalSince1970])
        } else {
            db?.execute("DELETE FROM history")
        }
        db?.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db?.execute("VACUUM")
        writtenTitles.removeAll()
        revision += 1
    }

    func deleteAll(ofSpace space: UUID) {
        db?.execute("DELETE FROM history WHERE space = ?", [space.uuidString])
        revision += 1
    }

    private func fetch(_ sql: String, _ args: [Any?]) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        db?.query(sql, args) { row in
            guard let url = URL(string: row.string(0)), let space = UUID(uuidString: row.string(4)) else { return }
            out.append(HistoryEntry(url: url, title: row.string(1), visits: Int(row.int(2)),
                                    lastVisit: Date(timeIntervalSince1970: row.double(3)), space: space))
        }
        return out
    }
}
