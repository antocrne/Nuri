import AppKit
import Observation
import os
import Security

/// Nuri's own updates, from the project's GitHub releases: no Sparkle, no server of Nuri's own.
/// At launch then every six hours (unless turned off in Settings → À propos), the newest release is
/// looked up. Nothing is downloaded until « Installer »: the archive (Nuri-<version>.zip) is then
/// unpacked next to the app, kept only if signed by the same team as the running Nuri, and put in
/// the app's place when Nuri quits (« Relancer », or the next ⌘Q).
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable, Sendable {
        let version: String
        let archive: URL
        let page: URL
    }

    enum Phase: Equatable {
        case idle
        case checking
        case available(Release)
        case downloading(Release, progress: Double)
        /// Downloaded and verified: waits for Nuri to quit.
        case ready(Release)
        case failed(Release, String)
    }

    private(set) var phase: Phase = .idle
    /// « Plus tard »: the bar stays away for this version until the next launch or a check from the menu.
    private var dismissed: String?
    private(set) var lastChecked: Date?

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    private static let interval: TimeInterval = 6 * 3600

    /// Where Nuri's versions are published (GitHub releases carrying Nuri-<version>.zip).
    nonisolated static let repository = "antocrne/Nuri"

    nonisolated static var feedURL: URL {
        #if DEBUG
        // The self-test points it at a local file.
        if let feed = UserDefaults.standard.string(forKey: "NuriUpdateFeed"), let url = URL(string: feed) { return url }
        #endif
        return URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!
    }

    private var timer: Timer?
    /// The verified new app, in a folder on the app's volume, waiting for Nuri to quit.
    private var staged: URL?
    private var relaunchAfterInstall = false
    private var progressObservation: NSKeyValueObservation?

    /// At launch (not for a duplicate or the self-test).
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.checkInBackground() }
        }
        // Once the window and the restored tabs are up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.checkInBackground() }
    }

    private func checkInBackground() {
        guard AppSettings.shared.checkForUpdates else { return }
        Task { await check(userInitiated: false) }
    }

    /// `userInitiated` (menu, Settings): the answer is shown even when there's nothing new.
    func check(userInitiated: Bool) async {
        if userInitiated { dismissed = nil }
        switch phase {
        case .checking, .downloading, .ready: return
        default: break
        }
        phase = .checking
        do {
            let newest = try await Self.newestRelease()
            lastChecked = Date()
            if let newest, Self.isNewer(newest.version, than: Self.currentVersion) {
                phase = .available(newest)
            } else {
                phase = .idle
                if userInitiated { BrowserWindows.shared.active.showToast("checkmark.circle", L("Nuri est à jour (\(Self.currentVersion))", "Nuri is up to date (\(Self.currentVersion))")) }
            }
        } catch {
            phase = .idle
            if userInitiated { BrowserWindows.shared.active.showToast("exclamationmark.triangle", L("Impossible de vérifier les mises à jour", "Couldn't check for updates")) }
        }
    }

    // MARK: - The bar above the page

    var showsBar: Bool {
        switch phase {
        case .available(let release), .ready(let release): dismissed != release.version
        case .downloading, .failed: true
        case .idle, .checking: false
        }
    }

    func dismiss() {
        switch phase {
        case .available(let release), .ready(let release): dismissed = release.version
        case .failed(let release, _): phase = .available(release); dismissed = release.version
        default: break
        }
    }

    func retry() {
        guard case .failed(let release, _) = phase else { return }
        phase = .available(release)
        install()
    }

    // MARK: - Download and verification

    /// Nuri can take a new version's place: a folder it may write to, not a disk image or a copy
    /// macOS moved elsewhere to open it (App Translocation).
    static var canReplaceApp: Bool {
        let app = Bundle.main.bundleURL
        guard !app.path.hasPrefix("/Volumes/"), !app.path.contains("/AppTranslocation/") else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: app.path)
    }

    func install() {
        guard case .available(let release) = phase else { return }
        guard Self.canReplaceApp else {
            NSWorkspace.shared.open(release.page)
            return
        }
        phase = .downloading(release, progress: 0)
        let task = URLSession.shared.downloadTask(with: release.archive) { file, response, error in
            // The downloaded file is deleted once this returns: moved first.
            var archive: URL?
            if let file, error == nil, (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Nuri-\(release.version)-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: file, to: destination)) != nil { archive = destination }
            }
            Task { @MainActor in await Updater.shared.finishDownload(archive, release: release) }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                let updater = Updater.shared
                if case .downloading(let current, _) = updater.phase, current == release {
                    updater.phase = .downloading(release, progress: value)
                }
            }
        }
        task.resume()
    }

    private func finishDownload(_ archive: URL?, release: Release) async {
        progressObservation = nil
        guard let archive else {
            Log.updates.error("Téléchargement de la version \(release.version, privacy: .public) en échec")
            phase = .failed(release, L("Le téléchargement a échoué. Vérifiez la connexion.", "The download failed. Check your connection."))
            return
        }
        let current = Bundle.main.bundleURL
        switch await Task.detached(operation: { Self.prepare(archive, version: release.version, replacing: current) }).value {
        case .success(let app):
            staged = app
            phase = .ready(release)
        case .failure(let problem):
            Log.updates.error("Version \(release.version, privacy: .public) refusée : \(String(describing: problem), privacy: .public)")
            phase = .failed(release, problem.message)
        }
    }

    enum Problem: Error {
        case unpack, content, signature
        @MainActor var message: String {
            switch self {
            case .unpack: L("L'archive n'a pas pu être ouverte.", "The archive couldn't be opened.")
            case .content: L("L'archive ne contient pas la version attendue de Nuri.", "The archive doesn't hold the expected version of Nuri.")
            case .signature: L("La signature de la nouvelle version ne correspond pas à celle de Nuri : elle n'est pas installée.", "The new version's signature doesn't match Nuri's: it isn't installed.")
            }
        }
    }

    /// Unpacks `archive` next to `current` (same volume: the swap at quit is a rename) and checks
    /// what it holds: Nuri, the expected version, signed by the same team.
    nonisolated static func prepare(_ archive: URL, version: String, replacing current: URL) -> Result<URL, Problem> {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: archive) }
        guard let folder = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true) else {
            return .failure(.unpack)
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, folder.path]
        do { try unzip.run() } catch { return .failure(.unpack) }
        unzip.waitUntilExit()
        let app = folder.appendingPathComponent("Nuri.app")
        guard unzip.terminationStatus == 0, fm.fileExists(atPath: app.path) else {
            try? fm.removeItem(at: folder)
            return .failure(.unpack)
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version else {
            try? fm.removeItem(at: folder)
            return .failure(.content)
        }
        guard isSignedLikeThisApp(app) else {
            try? fm.removeItem(at: folder)
            return .failure(.signature)
        }
        return .success(app)
    }

    /// Valid signature, from Apple's chain, same bundle identifier and same team as the running Nuri.
    /// A Nuri without a team (ad hoc) accepts nothing.
    nonisolated static func isSignedLikeThisApp(_ app: URL) -> Bool {
        guard let team = teamIdentifier(), let id = Bundle.main.bundleIdentifier else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    nonisolated static func teamIdentifier() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Installation

    /// « Relancer »: quits; the new version takes the app's place, then opens.
    func relaunch() {
        guard case .ready = phase else { return }
        relaunchAfterInstall = true
        NSApp.terminate(nil)
        relaunchAfterInstall = false   // only reached when quitting was cancelled
    }

    /// Called as Nuri quits: once this process is gone, the verified version takes the app's place
    /// (the old one comes back if the move fails). Returns false when there is nothing to install.
    func installIfReady(relaunch alsoRequested: Bool) -> Bool {
        guard let staged else { return false }
        let script = """
            while /bin/kill -0 "$0" 2>/dev/null; do sleep 0.2; done
            old="$(dirname "$2")/Nuri-ancienne.app"
            /bin/rm -rf "$old"
            if /bin/mv "$1" "$old"; then
              if /bin/mv "$2" "$1"; then /bin/rm -rf "$(dirname "$2")"; else /bin/mv "$old" "$1"; fi
            fi
            [ "$3" = 1 ] && /usr/bin/open "$1"
            exit 0
            """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath, staged.path,
                          relaunchAfterInstall || alsoRequested ? "1" : "0"]
        do { try swap.run() } catch { return false }
        return true
    }

    // MARK: - Releases

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let draft: Bool
        let html_url: URL
        let assets: [Asset]
    }

    /// The newest published release that carries its archive (Nuri-<version>.zip).
    nonisolated static func newestRelease() async throws -> Release? {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
            .compactMap { release -> Release? in
                guard !release.draft else { return nil }
                let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                guard let asset = release.assets.first(where: { $0.name == "Nuri-\(version).zip" }) else { return nil }
                return Release(version: version, archive: asset.browser_download_url, page: release.html_url)
            }
            .max { isNewer($1.version, than: $0.version) }
    }

    /// "0.2.1" > "0.2" > "0.1.9": numbers compared one by one, missing ones count as 0.
    nonisolated static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
