import Foundation
import AppKit
import os
import WebKit

/// Finds the page's icon (link rel=icon, else /favicon.ico) and stores a 32 px PNG on the tab.
@MainActor
enum FaviconLoader {
    /// Shared by every space and private window: no cookies and no cache, which would let a site
    /// recognize the same user across them (an ephemeral session keeps both while Nuri runs).
    /// Made again when a VPN extension changes the route (ExtensionProxy): icons come from the
    /// sites, and would tell them the real address.
    nonisolated private static let sessions = OSAllocatedUnfairLock<(revision: Int, session: URLSession)?>(initialState: nil)

    nonisolated private static var session: URLSession {
        let routing = ExtensionProxy.routing.withLock { $0 }
        return sessions.withLock { kept in
            if let kept, kept.revision == routing.revision { return kept.session }
            kept?.session.finishTasksAndInvalidate()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.proxyConfigurations = routing.configurations
            let made = URLSession(configuration: configuration)
            kept = (routing.revision, made)
            return made
        }
    }
    private static var cache: [String: (NSImage, Data)] = [:]

    static func load(for tab: Tab) {
        guard let webView = tab.webView, let pageURL = webView.url, let host = pageURL.host() else { return }
        if let cached = cache[host] {
            if tab.faviconData != cached.1 { tab.setFavicon(cached.0, data: cached.1) }
            return
        }
        Task {
            let script = """
            const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="shortcut icon"]')];
            const score = l => { const s = parseInt((l.sizes && l.sizes.value || '').split('x')[0]) || 16; const svg = /svg/.test(l.type || l.href); return svg ? -1 : Math.abs(64 - s); };
            links.sort((a, b) => score(a) - score(b));
            return links.map(l => l.href).filter(h => /^https?:/.test(h));
            """
            var candidates = (await webView.nuriCall(script) as? [String] ?? []).compactMap(URL.init(string:))
            if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(fallback) }
            for url in candidates.prefix(3) {
                guard let data = await download(url),
                      let image = NSImage(data: data),
                      let png = image.nuriResizedPNG(side: 32),
                      let resized = NSImage(data: png) else { continue }
                // Private windows leave no trace, not even in this in-memory cache.
                if !tab.isPrivate {
                    if cache.count >= 300 { cache.removeAll() }
                    cache[host] = (resized, png)
                }
                // The tab may have gone to another site while this one's icon was downloading.
                guard tab.webView?.url?.host() == host else { return }
                tab.setFavicon(resized, data: png)
                return
            }
        }
    }

    /// An icon is a few kilobytes: a page pointing its icon at a huge file doesn't get it read into memory.
    nonisolated private static let maximumSize = 512 * 1024

    nonisolated private static func download(_ url: URL) async -> Data? {
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
    }
}
