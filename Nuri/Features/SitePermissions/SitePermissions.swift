import AppKit
import SwiftUI
import UserNotifications
import WebKit

/// What a page asks that can wait for an answer: a small capsule over the page rather than a sheet,
/// so that a site asking as soon as it opens doesn't stop anything.
enum TabRequest {
    /// A window opened without a click. `url`: where it would go, when that means something.
    case popup(url: URL?, host: String)
    /// `answer`: true allows the site for good, false refuses it for good, nil lets the question go.
    case notifications(host: String, answer: (Bool?) -> Void)
}

/// A list of sites kept in the preferences.
struct SiteList {
    let key: String

    var hosts: [String] { (UserDefaults.standard.stringArray(forKey: key) ?? []).sorted() }
    func contains(_ host: String) -> Bool { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(host) }
    func add(_ host: String) { UserDefaults.standard.set(Array(Set(hosts + [host])), forKey: key) }
    func remove(_ host: String) { UserDefaults.standard.set(hosts.filter { $0 != host }, forKey: key) }
}

/// Sites allowed to open windows without a click. A private window's answers are forgotten with it.
@MainActor
enum PopupPermission {
    static let allowedSites = SiteList(key: "popupAllowedHosts")

    static func isAllowed(_ host: String, in browser: BrowserModel) -> Bool {
        browser.isPrivate ? browser.allowedPopupHosts.contains(host) : allowedSites.contains(host)
    }

    static func allow(_ host: String, in browser: BrowserModel) {
        if browser.isPrivate { browser.allowedPopupHosts.insert(host) } else { allowedSites.add(host) }
    }
}

/// Web notifications, shown by macOS. Asked in a capsule, answered for good by site; never in a
/// private window, and only for the page itself, not a frame of another site.
@MainActor
final class WebNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WebNotifications()
    static let allowedSites = SiteList(key: "notificationAllowedHosts")
    static let refusedSites = SiteList(key: "notificationRefusedHosts")

    private var delegateIsSet = false

    #if DEBUG
    /// Self-test: what would have been shown (macOS would ask for its own permission otherwise).
    private(set) var lastShown: (title: String, body: String, host: String)?
    #endif

    /// A page asks. WebKit's answer to it lasts until Nuri quits (see `pageCommitted`).
    func request(host rawHost: String, tab: Tab?, webView: WKWebView, answer: @escaping (Bool) -> Void) {
        let host = rawHost.nuriNormalizedHost
        guard let tab, !tab.isPrivate, tab.request == nil, webView.url?.host()?.nuriNormalizedHost == host,
              !Self.refusedSites.contains(host) else { return answer(false) }
        if Self.allowedSites.contains(host) {
            return wrap(webView) { answer(true) }
        }
        tab.request = .notifications(host: host) { [weak self, weak webView] decision in
            switch decision {
            case true?:
                Self.allowedSites.add(host)
                self?.askSystem()
                guard let self, let webView else { return answer(true) }
                self.wrap(webView) { answer(true) }
            case false?:
                Self.refusedSites.add(host)
                answer(false)
            case nil:
                answer(false)
            }
        }
    }

    /// A page of an allowed site: its notifications go to macOS, and WebKit, which forgets at each
    /// launch, says yes again. On other sites nothing is added to the page.
    func pageCommitted(_ tab: Tab) {
        guard !tab.isPrivate, let webView = tab.webView, let host = webView.url?.host()?.nuriNormalizedHost,
              Self.allowedSites.contains(host) else { return }
        Task { _ = await webView.nuriCall(Scripts.notificationPage + "\nreturn await Notification.requestPermission();", world: .page, timeout: 2) }
    }

    private func wrap(_ webView: WKWebView, then done: @escaping () -> Void) {
        Task {
            _ = await webView.nuriCall(Scripts.notificationPage + "\nreturn true;", world: .page, timeout: 2)
            done()
        }
    }

    /// What the page showed (activity.js). The frame is the main one: a frame of another site, or a
    /// site taken off the list since, shows nothing.
    func show(_ body: [String: Any], from frame: WKFrameInfo, tab: Tab) {
        let host = frame.securityOrigin.host.nuriNormalizedHost
        guard frame.isMainFrame, !tab.isPrivate, Self.allowedSites.contains(host), let title = body["title"] as? String else { return }
        let text = body["body"] as? String ?? ""
        #if DEBUG
        if SelfTestRunner.isRequested {
            lastShown = (title, text, host)
            return
        }
        #endif
        let content = UNMutableNotificationContent()
        content.title = title
        // Always the site's name: a page can't pass for something else.
        content.subtitle = host
        content.body = text
        content.sound = .default
        content.userInfo = ["tab": tab.id.uuidString, "id": body["id"] as? String ?? "", "url": tab.url?.absoluteString ?? ""]
        let tag = body["tag"] as? String ?? ""
        let identifier = tag.isEmpty ? UUID().uuidString : "\(host)|\(tag)"
        askSystem()
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// macOS's own permission, asked the first time.
    private func askSystem() {
        #if DEBUG
        if SelfTestRunner.isRequested { return }
        #endif
        let center = UNUserNotificationCenter.current()
        if !delegateIsSet {
            delegateIsSet = true
            center.delegate = self
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard !granted else { return }
            Task { @MainActor in
                BrowserWindows.shared.active.showToast("bell.slash", L("macOS bloque les notifications de Nuri : Réglages Système → Notifications", "macOS blocks Nuri's notifications: System Settings → Notifications"))
            }
        }
    }

    /// A click on a notification: its tab comes forward and the page hears the click.
    func opened(tabID: String, id: String, url: String) {
        let tab = BrowserWindows.shared.all.flatMap(\.allTabs).first { $0.id.uuidString == tabID && !$0.isClosed }
        NSApp.activate(ignoringOtherApps: true)
        guard let tab, let browser = tab.browser else {
            // Its tab is gone (Nuri was quit since): the page it came from.
            if let page = URL(string: url) { BrowserWindows.shared.normalTarget.openExternal(page) }
            return
        }
        browser.select(tab)
        BrowserWindows.shared.show(browser)
        browser.window?.makeKeyAndOrderFront(nil)
        tab.webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('nurinotificationclick', { detail: \(Self.literal(id)) }))", in: nil, in: .page)
    }

    /// `id` comes from a page: a JavaScript string, nothing else.
    private static func literal(_ id: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Also when Nuri is in front: the notification may come from another tab.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let (tab, id, url) = (info["tab"] as? String ?? "", info["id"] as? String ?? "", info["url"] as? String ?? "")
        await WebNotifications.shared.opened(tabID: tab, id: id, url: url)
    }
}

/// The capsule over a page.
struct TabRequestBar: View {
    let tab: Tab
    let request: TabRequest
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        HStack(spacing: 8) {
            switch request {
            case .popup(let url, let host):
                Image(systemName: "macwindow.badge.plus").foregroundStyle(Theme.accent)
                Text(L("Fenêtre bloquée", "Window blocked")).lineLimit(1)
                if let shown = url?.host() { Text(shown.nuriNormalizedHost).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle) }
                if let url {
                    Button(L("Ouvrir", "Open")) {
                        tab.request = nil
                        browser.openTab(url: url, after: tab)
                    }
                }
                Button(L("Toujours sur ce site", "Always on This Site")) {
                    tab.request = nil
                    PopupPermission.allow(host, in: browser)
                    if let url { browser.openTab(url: url, after: tab) }
                }
                dismiss { tab.request = nil }
            case .notifications(let host, let answer):
                Image(systemName: "bell").foregroundStyle(Theme.accent)
                Text(L("« \(host) » veut envoyer des notifications", "“\(host)” wants to send notifications")).lineLimit(1).truncationMode(.middle)
                Button(L("Autoriser", "Allow")) {
                    tab.request = nil
                    answer(true)
                }
                Button(L("Refuser", "Deny")) {
                    tab.request = nil
                    answer(false)
                }
                dismiss {
                    tab.request = nil
                    answer(nil)
                }
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.hairline))
        .shadow(color: Theme.shadow, radius: 8, y: 3)
        .padding(10)
    }

    private func dismiss(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondaryText)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Fermer", "Close"))
    }
}

/// What sites keep in a space's store: cookies, local storage, caches, databases. Listed by site
/// (WebKit groups them by registrable domain), each can be erased alone.
@MainActor
enum SiteData {
    struct Site: Identifiable, Equatable {
        let name: String
        let types: Set<String>
        var id: String { name }

        /// "cookies, stockage", in a word or two.
        @MainActor var kinds: String {
            var words: [String] = []
            if types.contains(WKWebsiteDataTypeCookies) { words.append(L("cookies", "cookies")) }
            if !types.isDisjoint(with: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases,
                                        WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeFileSystem]) { words.append(L("stockage", "storage")) }
            if !types.isDisjoint(with: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
                                        WKWebsiteDataTypeOfflineWebApplicationCache]) { words.append(L("cache", "cache")) }
            if types.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { words.append(L("service worker", "service worker")) }
            return words.joined(separator: ", ")
        }
    }

    static func sites(in store: WKWebsiteDataStore) async -> [Site] {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return records.map { Site(name: $0.displayName, types: $0.dataTypes) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func remove(_ site: Site, from store: WKWebsiteDataStore) async {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).filter { $0.displayName == site.name }
        guard !records.isEmpty else { return }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }
}
