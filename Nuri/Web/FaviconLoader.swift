import Foundation
import AppKit
import os
import WebKit

/// Finds the page's icon (link rel=icon, else /favicon.ico) and stores a 32 px PNG on the tab.
///
/// The icon is asked for by the page itself first (a fetch in Nuri's world, through WebKit: the
/// blocker's rules, the space's own network and Safari's name, as for any of its images). Only an
/// icon on another site that refuses to be read that way (no CORS) is fetched by Nuri, unless the
/// blocker would have stopped it, with WebKit's user agent and nothing that ties it to the user.
/// A private window fetches nothing: its tabs get an icon only if a normal window already has it.
@MainActor
enum FaviconLoader {
    /// Shared by every space: no cookies and no cache, which would let a site recognize the same user
    /// across them. Made again when a VPN extension changes the route (ExtensionProxy): icons come
    /// from the sites, and would tell them the real address.
    nonisolated private static let sessions = OSAllocatedUnfairLock<(revision: Int, agent: String, session: URLSession)?>(initialState: nil)

    nonisolated private static func session(agent: String) -> URLSession {
        let routing = ExtensionProxy.routing.withLock { $0 }
        return sessions.withLock { kept in
            if let kept, kept.revision == routing.revision, kept.agent == agent { return kept.session }
            kept?.session.finishTasksAndInvalidate()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.proxyConfigurations = routing.configurations
            // The browser's own name, not "Nuri CFNetwork": an icon request says nothing more than
            // the page's do.
            if !agent.isEmpty { configuration.httpAdditionalHeaders = ["User-Agent": agent] }
            let made = URLSession(configuration: configuration)
            kept = (routing.revision, agent, made)
            return made
        }
    }
    private static var cache: [String: (NSImage, Data)] = [:]

    #if DEBUG
    /// Self-test: icons fetched outside WebKit, and through the page.
    private(set) static var downloadsOutsideWebKit: [URL] = []
    private(set) static var fetchesInPage: [URL] = []
    #endif

    static func load(for tab: Tab) {
        guard let webView = tab.webView, let pageURL = webView.url, let host = pageURL.host() else { return }
        if let cached = cache[host] {
            if tab.faviconData != cached.1 { tab.setFavicon(cached.0, data: cached.1, host: host) }
            return
        }
        // Nothing leaves a private window for an icon.
        guard !tab.isPrivate else { return }
        Task {
            let script = """
            const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="shortcut icon"]')];
            const score = l => { const s = parseInt((l.sizes && l.sizes.value || '').split('x')[0]) || 16; const svg = /svg/.test(l.type || l.href); return svg ? -1 : Math.abs(64 - s); };
            links.sort((a, b) => score(a) - score(b));
            return { links: links.map(l => l.href).filter(h => /^https?:/.test(h)), agent: navigator.userAgent };
            """
            let found = await webView.nuriCall(script) as? [String: Any]
            var candidates = (found?["links"] as? [String] ?? []).compactMap(URL.init(string:))
            let agent = found?["agent"] as? String ?? ""
            if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(fallback) }
            for url in candidates.prefix(3) {
                var data = await fetchInPage(url, webView: webView)
                if data == nil, mayFetchOutside(url, pageHost: host) { data = await download(url, agent: agent) }
                guard let data, let image = NSImage(data: data),
                      let png = image.nuriResizedPNG(side: 32),
                      let resized = NSImage(data: png) else { continue }
                if cache.count >= 300 { cache.removeAll() }
                cache[host] = (resized, png)
                // The tab may have gone to another site while this one's icon was downloading.
                guard tab.webView?.url?.host() == host else { return }
                tab.setFavicon(resized, data: png, host: host)
                return
            }
        }
    }

    /// Through the page: WebKit's network, its blocker, the page's own address. Without cookies.
    /// nil when the site doesn't let the page read it (another site without CORS), or it isn't an image.
    private static func fetchInPage(_ url: URL, webView: WKWebView) async -> Data? {
        #if DEBUG
        fetchesInPage.append(url)
        #endif
        let script = """
            const response = await fetch(address, { credentials: 'omit', cache: 'force-cache', redirect: 'follow' });
            if (!response.ok) return null;
            const blob = await response.blob();
            if (blob.size > limit || !/^image\\/|octet-stream|^$/.test(blob.type)) return null;
            const bytes = new Uint8Array(await blob.arrayBuffer());
            let text = '';
            for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
            return btoa(text);
            """
        let encoded = await webView.nuriCall(script, arguments: ["address": url.absoluteString, "limit": maximumSize], timeout: 4) as? String
        return encoded.flatMap { Data(base64Encoded: $0) }
    }

    /// An icon on another site, which the blocker would stop as a resource of this page: not
    /// fetched behind its back either.
    static func mayFetchOutside(_ url: URL, pageHost: String) -> Bool {
        guard let host = url.host()?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        guard AppSettings.shared.isAdBlockActive(on: pageHost) else { return true }
        let thirdParty = host.nuriNormalizedHost != pageHost.nuriNormalizedHost && !host.hasSuffix("." + pageHost.nuriNormalizedHost)
        guard thirdParty else { return true }
        return !AdBlockList.blocks(host: host)
    }

    /// An icon is a few kilobytes: a page pointing its icon at a huge file doesn't get it read into memory.
    nonisolated private static let maximumSize = 512 * 1024

    private static func download(_ url: URL, agent: String) async -> Data? {
        #if DEBUG
        downloadsOutsideWebKit.append(url)
        #endif
        let session = session(agent: agent)
        return await Task.detached {
            guard let (bytes, response) = try? await session.bytes(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  response.expectedContentLength <= Int64(maximumSize) else { return nil }
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > maximumSize { return nil }
                }
            } catch {
                return nil
            }
            return data
        }.value
    }
}
