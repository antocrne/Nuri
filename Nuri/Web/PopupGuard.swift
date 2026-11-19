import Foundation

/// Pop-unders and the files they bring (seen 2026-11-18 on a scan site: a click anywhere in the
/// page opened an ad redirector in a new tab, which saved "OperaSetup.zip" twice at once).
///
/// The ad script listens to every press of the mouse in the page and opens its window from it, so
/// WebKit counts that window as asked for by a click. What tells it apart from a real one is what
/// the user pressed on: a link going where the window goes, or a sign-in / share button opening a
/// small sized window. A plain new tab to another site, after a click on nothing or on a link
/// going elsewhere, is the ad.
enum PopupGuard {
    /// The registrable part of a host, near enough without the public suffix list:
    /// "www.youtube.com" → "youtube.com", "a.b.co.uk" → "b.co.uk". Addresses stay whole.
    static func site(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        // "co.uk", "com.au", "ne.jp", "gouv.fr": a country's own second level.
        let country = labels[labels.count - 1].count == 2
        let second = labels[labels.count - 2]
        let keep = country && (second.count <= 3 || ["gouv", "govt", "nhs"].contains(second)) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return site(url.host())
    }

    static func sameSite(_ a: URL?, _ b: URL?) -> Bool {
        guard let first = site(of: a) else { return false }
        return first == site(of: b)
    }

    /// Whether a window a page opens right after a press of the mouse is an ad.
    /// `request`: where it goes (nil or about:blank: not known yet, judged at its first page).
    /// `opener`: the page asking. `clickedLink`: the link under the pointer when it was pressed.
    /// `pressedControl`: no link but a button ("Visit site", "Pay"). `sized`: the page gave it a
    /// size (a sign-in, a share or a payment window).
    static func isPopunder(request: URL?, opener: URL?, clickedLink: URL?, pressedControl: Bool = false, sized: Bool) -> Bool {
        guard !sized, let request, site(of: request) != nil else { return false }
        // The page's own site: its own business.
        if sameSite(request, opener) { return false }
        // Nothing to follow under the pointer: a button is made to open things, text, a picture or
        // a blank area isn't (an ad listening to every press of the page takes those).
        guard let clickedLink else { return !pressedControl }
        // The link pressed, opened in a new tab.
        if sameSite(request, clickedLink) { return false }
        // A link to another site, sent through a redirector that carries it
        // (go.redirector.com/?url=https%3A%2F%2Fshop.example%2F…). Never for a link of the page's
        // own site: an ad's address often names the site it was shown on.
        if !sameSite(clickedLink, opener), let host = clickedLink.host()?.lowercased(),
           (request.absoluteString.removingPercentEncoding ?? request.absoluteString).lowercased().contains(host) {
            return false
        }
        // A link of the page (a chapter, a menu) whose click opens another site: the ad took it.
        return true
    }

    /// Whether a file is saved without the user having asked for it, and must be asked about.
    /// `file`: where it comes from. `page`: the page it is saved from, or for a tab with no page
    /// yet, the one that opened it. `asked`: the navigation came from a click, a typed address or
    /// a reload. `fromPagePopup`: the tab was opened by a page, not from a link the user pressed.
    /// A file of the page's own site never asks: it is the site the user chose to visit.
    static func isUnrequestedDownload(file: URL?, page: URL?, asked: Bool, fromPagePopup: Bool) -> Bool {
        guard asked == false || fromPagePopup else { return false }
        guard let fileSite = site(of: file) else { return false }
        return fileSite != site(of: page)
    }
}

/// What a blank window opened by a page after a click is judged by, at its first page.
@MainActor
struct BlankPopupCheck {
    weak var opener: Tab?
    let openerURL: URL?
    let clickedLink: URL?
    let pressedControl: Bool
}
