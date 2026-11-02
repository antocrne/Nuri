import Foundation
import AppKit

/// What to do with a link whose scheme belongs to another app (mailto:, zoommtg:, vscode:…).
enum ExternalURLPolicy: Equatable {
    case open, ask, refuse

    /// Schemes that mount network shares or open remote sessions: a web page never gets to
    /// trigger them (a smb:// link can leak the user's credentials to a hostile server).
    static let refusedSchemes: Set<String> = ["smb", "afp", "nfs", "cifs", "ftp", "ftps", "vnc", "ssh", "telnet",
                                             "file", "x-man-page"]
    /// Handed straight to the system app, as every browser does.
    static let trustedSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio", "maps"]

    /// Only from the page itself (not a frame of another site). A click on a link opens the usual
    /// system apps at once and asks for the others. Without a link clicked — « Ouvrir dans l'app »
    /// buttons of Teams, Zoom or Slack set `location.href` from a script — it is asked, and only
    /// for the tab on screen: refusing those without a word left the button doing nothing.
    static func decide(scheme: String, userClick: Bool, fromMainFrame: Bool, tabShown: Bool = false) -> ExternalURLPolicy {
        let scheme = scheme.lowercased()
        guard fromMainFrame, !refusedSchemes.contains(scheme) else { return .refuse }
        if userClick { return trustedSchemes.contains(scheme) ? .open : .ask }
        return tabShown ? .ask : .refuse
    }

    /// Sites whose question was just declined: a page asking in a loop doesn't get the sheet back at once.
    @MainActor private static var declined: [String: Date] = [:]

    @MainActor static func recentlyDeclined(_ host: String) -> Bool {
        declined[host].map { Date().timeIntervalSince($0) < 60 } ?? false
    }

    @MainActor static func noteDeclined(_ host: String) { declined[host] = Date() }

    /// Asks before opening an app on behalf of `host`.
    @MainActor
    static func confirmAndOpen(_ url: URL, from host: String, in window: NSWindow?) {
        // One question at a time, and not again right after a « Annuler ».
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url), window?.attachedSheet == nil, !recentlyDeclined(host) else { return }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = L("Ouvrir « \(name) » ?", "Open “\(name)”?")
        alert.informativeText = host.isEmpty ? L("Cette page veut ouvrir un lien dans l'app \(name).", "This page wants to open a link in \(name).")
                                             : L("\(host) veut ouvrir un lien dans l'app \(name).", "\(host) wants to open a link in \(name).")
        alert.addButton(withTitle: L("Ouvrir", "Open"))
        alert.addButton(withTitle: L("Annuler", "Cancel"))
        let open = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) } else { noteDeclined(host) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: open) } else { open(alert.runModal()) }
    }
}
