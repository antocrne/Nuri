import Foundation
import MetricKit
import os

/// Nuri's journal, in the unified log (Console.app, or `log show --predicate 'subsystem == "app.nuri.browser"'`):
/// what went wrong and could be needed to understand a report. Addresses are hashed unless
/// they are Nuri's own files: the journal mustn't become a history.
enum Log {
    static let subsystem = "app.nuri.browser"
    /// Pages that fail, web processes that stop, certificates.
    static let web = Logger(subsystem: subsystem, category: "web")
    /// Session, bookmarks, history, downloads list: what is read and written on disk.
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let downloads = Logger(subsystem: subsystem, category: "downloads")
    static let updates = Logger(subsystem: subsystem, category: "updates")
    static let blocker = Logger(subsystem: subsystem, category: "blocker")
    /// Crashes and hangs reported by macOS at the next launch (CrashJournal).
    static let crashes = Logger(subsystem: subsystem, category: "crashes")
}

/// Crashes and hangs of Nuri, as macOS reports them at the next launch (MetricKit): written to the
/// journal and kept in ~/Library/Application Support/Nuri/Crashes, the last 20, to attach to a report.
/// Nothing leaves the Mac.
final class CrashJournal: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashJournal()
    static var folder: URL { StateStore.directory.appendingPathComponent("Crashes", isDirectory: true) }

    func start() {
        MXMetricManager.shared.add(self)
        if LaunchGuard.previousLaunchDied { Log.crashes.error("Le lancement précédent s'est arrêté dans sa première minute") }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { Self.keep(payload.jsonRepresentation(), crashes: payload.crashDiagnostics?.count ?? 0, hangs: payload.hangDiagnostics?.count ?? 0) }
    }

    /// `json`: one report of macOS.
    static func keep(_ json: Data, crashes: Int, hangs: Int, now: Date = Date()) {
        Log.crashes.fault("Rapport de macOS : \(crashes, privacy: .public) plantage(s), \(hangs, privacy: .public) blocage(s)")
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        try? json.write(to: folder.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(4)).json"), options: .atomic)
        let kept = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in kept.dropLast(20) { try? fm.removeItem(at: old) }
    }
}
