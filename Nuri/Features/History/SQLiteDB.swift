import Foundation
import SQLite3

/// Minimal SQLite wrapper (system libsqlite3, no dependency).
final class SQLiteDB {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `ownDatabase`: one of Nuri's own files (not another browser's copy). It then uses a
    /// write-ahead log: a write no longer waits for a full sync to disk (it runs on the main
    /// thread at every page load), and readers don't block the writer.
    init?(path: String, readOnly: Bool = false, ownDatabase: Bool = false) {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        if ownDatabase {
            sqlite3_busy_timeout(handle, 2000)
            execute("PRAGMA journal_mode=WAL")
            execute("PRAGMA synchronous=NORMAL")
            // What is deleted is overwritten with zeros, not just marked free: a page removed from
            // the history can't be read back from the file.
            execute("PRAGMA secure_delete=ON")
        }
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func execute(_ sql: String, _ args: [Any?] = []) -> Bool {
        guard let stmt = prepare(sql, args) else { return false }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    func query(_ sql: String, _ args: [Any?] = [], _ row: (Row) -> Void) {
        guard let stmt = prepare(sql, args) else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(Row(stmt: stmt)) }
    }

    /// Runs `body` in a transaction, rolled back if it returns false.
    func transaction(_ body: () -> Bool) {
        execute("BEGIN")
        execute(body() ? "COMMIT" : "ROLLBACK")
    }

    /// First column of the first row, as text.
    func string(_ sql: String, _ args: [Any?] = []) -> String? {
        var value: String?
        query(sql, args) { row in if value == nil { value = row.string(0) } }
        return value
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[Nuri] SQLite: %@", String(cString: sqlite3_errmsg(handle)))
            return nil
        }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, index, v)
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    struct Row {
        let stmt: OpaquePointer
        func string(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func data(_ i: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(stmt, i))
            guard count > 0, let bytes = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }
}
