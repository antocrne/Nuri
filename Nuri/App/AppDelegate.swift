import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if SingleInstance.isDuplicate {
            SingleInstance.startDuplicate()
            return
        }
        var selfTest = false
        #if DEBUG
        selfTest = SelfTestRunner.isRequested   // its session isn't the user's: left alone
        #endif
        // Before any web view creates its store: folders of spaces deleted earlier.
        if !selfTest {
            LaunchGuard.start()
            Space.removePendingStores(keeping: Set(BrowserModel.shared.spaces.map(\.id)))
            // Files of downloads the last session didn't finish (crash).
            DownloadManager.shared.removeUnfinishedFiles()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Another Nuri is running: this one only passes links on (see SingleInstance).
        guard !SingleInstance.isDuplicate else { return }
        AppSettings.shared.applyAppearance()
        NuriMenu.rebuild()
        BrowserWindows.shared.start()
        ContentRules.shared.start()
        Extensions.start()
        BrowserWindows.shared.showMainWindow()
        var selfTest = false
        #if DEBUG
        selfTest = SelfTestRunner.isRequested
        SelfTestRunner.startIfRequested()
        #endif
        if !selfTest {
            BrowserWindows.shared.reopenSavedWindows()
            Updater.shared.start()
            // First launch: let the user choose how Nuri looks (Settings can replay it).
            if !AppSettings.shared.onboardingCompleted { BrowserModel.shared.onboardingStep = 0 }
            if LaunchGuard.previousLaunchDied {
                BrowserModel.shared.showToast("exclamationmark.triangle", L("Nuri s'est arrêté au dernier lancement : vos onglets attendent, endormis", "Nuri stopped during its last launch: your tabs are waiting, asleep"))
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if SingleInstance.isDuplicate { return SingleInstance.forward(urls) }
        // Links from other apps never land in a private window.
        for url in urls { BrowserWindows.shared.normalTarget.openExternal(url) }
    }

    /// Closing the last window doesn't quit: downloads go on, and the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { BrowserWindows.shared.showMainWindow() }
        return true
    }

    /// Right-click on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Nouvelle fenêtre", "New Window"), action: #selector(newWindowFromDock), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Nouvelle fenêtre privée", "New Private Window"), action: #selector(newPrivateWindowFromDock), keyEquivalent: "").target = self
        return menu
    }

    @objc private func newWindowFromDock() {
        BrowserWindows.shared.openNormalWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newPrivateWindowFromDock() {
        BrowserWindows.shared.openPrivateWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quitting stops downloads for good, paused ones too (they can't resume after a relaunch): ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if SelfTestRunner.isRequested { return .terminateNow }
        #endif
        guard mayLoseDownloads() else { return .terminateCancel }
        // The pages answer late, so the answer comes later too.
        let typing = BrowserWindows.shared.all.flatMap(\.allTabs).filter(\.hasUserInput)
        guard !typing.isEmpty else { return .terminateNow }
        Task {
            let go = await BrowserWindows.shared.mayLoseTypedText(in: typing, leaving: L("Quitter quand même", "Quit Anyway"))
            NSApp.reply(toApplicationShouldTerminate: go)
        }
        return .terminateLater
    }

    private func mayLoseDownloads() -> Bool {
        let running = DownloadManager.shared.unfinishedCount
        guard running > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = running == 1 ? L("Un téléchargement est en cours", "A download is in progress")
                                         : L("\(running) téléchargements sont en cours", "\(running) downloads are in progress")
        alert.informativeText = L("Si vous quittez Nuri maintenant, les fichiers incomplets seront supprimés.",
                                  "If you quit Nuri now, the incomplete files will be deleted.")
        alert.addButton(withTitle: L("Continuer les téléchargements", "Keep Downloading"))
        alert.addButton(withTitle: L("Quitter", "Quit"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserModel.shared.saveNow()
        if let frame = BrowserModel.shared.window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: "mainWindowFrame")
        }
        if !SingleInstance.isDuplicate {
            LaunchGuard.finish()
            DownloadManager.shared.removeUnfinishedFiles()
        }
        // A downloaded update takes the app's place, and opens if a relaunch was asked for.
        if !SingleInstance.isDuplicate { _ = Updater.shared.installIfReady(relaunch: false) }
    }
}
