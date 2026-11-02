import AppKit

/// Nuri runs once. Several copies of the app can be installed (/Applications, Xcode builds…) and
/// macOS may hand a link to a copy other than the one running: that copy then launches too, on
/// the same session and website data, and saves its own session over the other's. Such a
/// duplicate shows nothing, passes its links to the running Nuri and quits without saving.
@MainActor
enum SingleInstance {
    /// An exclusive lock on a file of Nuri's folder, held for the whole life of the Nuri that got
    /// it (the system releases it when the process ends, crash included). Two copies started at
    /// the same instant can't both take it, where looking at the running apps, each would see the
    /// other and both would quit.
    private static let holdsLock: Bool = {
        #if DEBUG
        if SelfTestRunner.isRequested { return true }
        #endif
        let path = StateStore.directory.appendingPathComponent("instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return true }   // can't tell: behave as the only one
        // The descriptor stays open on purpose: closing it would release the lock.
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }()

    static var isDuplicate: Bool { !holdsLock }

    /// The Nuri holding the lock (it may still be registering when this one starts).
    private static func runningCopy() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let me = NSRunningApplication.current.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    private static var forwarding = false
    /// Links received so far, all passed on together.
    private static var pending: [URL] = []
    private static var lookups = 0
    private static var lookupScheduled = false

    /// Launch of a duplicate: no Dock icon, no window, and it leaves if no link arrives.
    static func startDuplicate() {
        NSApp.setActivationPolicy(.prohibited)
        // Links arrive right after launch; without any (another copy opened from the Finder),
        // the running Nuri just comes to the front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !forwarding { forward([]) }
        }
    }

    /// Hands `urls` to the running Nuri, which comes to the front, then quits. `exit` skips
    /// `applicationWillTerminate`: this instance must not save its (empty) session.
    static func forward(_ urls: [URL]) {
        pending += urls
        guard !forwarding else { return }
        guard let existing = runningCopy() else {
            // The other copy is still starting: look again for a few seconds, then give up.
            guard !lookupScheduled else { return }
            guard lookups < 15 else { exit(0) }
            lookups += 1
            lookupScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                lookupScheduled = false
                forward([])
            }
            return
        }
        forwarding = true
        guard !pending.isEmpty, let app = existing.bundleURL else {
            existing.activate()
            exit(0)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(pending, withApplicationAt: app, configuration: configuration) { _, _ in
            DispatchQueue.main.async { exit(0) }
        }
    }
}
