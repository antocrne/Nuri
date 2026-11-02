import AppKit
import JavaScriptCore
import Network
import Observation
import os
import WebKit

/// chrome.proxy, which VPN extensions run on and WebKit doesn't have. extension-shim.js sends what
/// the extension sets here (runtime.sendNativeMessage to `appID`), and Nuri routes pages through
/// that server (WKWebsiteDataStore.proxyConfigurations): every space, private windows, the reader,
/// downloads and favicons, as Chrome does with a "regular" setting. The extensions' own pages and
/// backgrounds stay direct, so that a VPN can always reach its service for a new password. One
/// extension at a time, and only one the user allowed (Settings › Extensions › VPN).
///
/// The server's password comes from the extension's webRequest.onAuthRequired, which the shim calls
/// in its background when Nuri asks: when the server is set, every few minutes (Proton's last 20
/// minutes, and with a stale one the network layer fails the page without asking), and when a page
/// meets the server's 407.
///
/// A new route only applies to new connections: a site already open keeps its own (an HTTP/2
/// connection lasts minutes), direct. WebKit has no way to close them but ending its network
/// process, which leaves extensions' backgrounds unable to answer (tried 2026-11-02). At launch
/// the route is in place before the first page.
@MainActor @Observable
final class ExtensionProxy {
    static let shared = ExtensionProxy()
    /// What the shim names in runtime.sendNativeMessage.
    static let appID = "app.nuri.proxy"

    struct Server: Equatable, Codable {
        /// http, https (TLS to the server) or socks5.
        var scheme: String
        var host: String
        var port: Int
        /// Hosts that never go through it.
        var bypass: [String]
    }

    struct Credential: Equatable {
        let user: String
        let password: String
    }

    /// Why a setting can't be followed, said to the extension.
    struct Refusal: Error { let message: String }

    /// The extension routing pages now, and where.
    private(set) var owner: String?
    private(set) var server: Server?
    /// What it set, as chrome.proxy.settings.get gives it back.
    @ObservationIgnored private var value: [String: Any] = [:]
    @ObservationIgnored private var credential: Credential?
    @ObservationIgnored private let stores = NSHashTable<WKWebsiteDataStore>.weakObjects()
    @ObservationIgnored private var renewal: Task<Void, Never>?
    @ObservationIgnored private var lastRenewal = Date.distantPast

    /// Read off the main thread (FaviconLoader's session); `revision` changes with the route.
    nonisolated static let routing = OSAllocatedUnfairLock(initialState: (revision: 0, configurations: [ProxyConfiguration]()))

    private init() {}

    var isRouting: Bool { server != nil }

    /// A store pages load from. Untouched while nothing is routed.
    func attach(to store: WKWebsiteDataStore) {
        guard !stores.contains(store) else { return }
        stores.add(store)
        if server != nil { store.proxyConfigurations = configurations() }
    }

    // MARK: - What extensions ask

    /// A message from an extension's shim: `get`, `set` (a chrome.proxy value) or `clear`. An
    /// `error` in the answer rejects the extension's promise.
    @available(macOS 15.4, *)
    func handle(_ message: Any, from context: WKWebExtensionContext) async -> [String: Any] {
        let id = context.uniqueIdentifier
        let host = ExtensionHost.shared
        guard let message = message as? [String: Any] else { return [:] }
        if message["get"] != nil { return state(for: id, allowed: host.proxyAllowed(id)) }
        if message["clear"] != nil {
            if owner == id {
                stop()
                host.rememberProxy(nil, for: id)
            }
            return [:]
        }
        guard let value = message["set"] as? [String: Any] else { return [:] }
        guard host.mayRoute(context) else {
            return ["error": L("Nuri ne laisse pas cette extension faire passer la navigation par ses serveurs (Réglages › Extensions › VPN).",
                               "Nuri doesn't let this extension route browsing through its servers (Settings › Extensions › VPN).")]
        }
        do {
            let server = try await Self.server(from: value)
            let previous = owner
            route(value, through: server, for: id)
            host.rememberProxy(SavedProxy(value: value, server: server), for: id)
            if let previous, previous != id {
                host.tellProxyChanged(previous, ["value": value, "levelOfControl": "controlled_by_other_extensions"])
            }
            // Its password before saying it's done: the pages after that go through with it.
            if server != nil { await renewCredential() }
            return [:]
        } catch let refusal as Refusal {
            return ["error": refusal.message]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// chrome.proxy.settings.get, for `id`.
    private func state(for id: String, allowed: Bool?) -> [String: Any] {
        let level = allowed == false ? "not_controllable"
            : owner == id ? "controlled_by_this_extension"
            : owner != nil ? "controlled_by_other_extensions"
            : "controllable_by_this_extension"
        let current: [String: Any] = owner != nil ? value : ["mode": "system"]
        return ["levelOfControl": level, "value": current]
    }

    private func route(_ value: [String: Any], through server: Server?, for id: String) {
        owner = id
        self.value = value
        if server != self.server { credential = nil }
        self.server = server
        apply()
        renewal?.cancel()
        renewal = nil
        guard server != nil else { return }
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled, let self, self.owner == id else { return }
                await self.renewCredential()
            }
        }
    }

    /// At launch, what the extension had set before (Chrome keeps it too), before any page loads.
    /// Its password is asked once its background is up; a page earlier meets the 407 and asks.
    @available(macOS 15.4, *)
    func restore(_ saved: SavedProxy, for id: String) {
        guard owner == nil, let value = saved.decodedValue else { return }
        route(value, through: saved.server, for: id)
        guard saved.server != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await renewCredential()
        }
    }

    /// The extension leaves (turned off, removed, no longer allowed). `telling`: its
    /// chrome.proxy.settings.onChange hears it, when it still runs.
    @available(macOS 15.4, *)
    func release(_ id: String, telling: Bool) {
        guard owner == id else { return }
        stop()
        if telling { ExtensionHost.shared.tellProxyChanged(id, ["value": ["mode": "system"], "levelOfControl": "not_controllable"]) }
    }

    private func stop() {
        owner = nil
        value = [:]
        server = nil
        credential = nil
        renewal?.cancel()
        renewal = nil
        apply()
    }

    // MARK: - The server's password

    /// Asked of the extension again. True when it changed.
    @discardableResult
    func renewCredential() async -> Bool {
        guard #available(macOS 15.4, *), let owner, let server else { return false }
        lastRenewal = Date()
        guard let fresh = await ExtensionHost.shared.proxyCredential(from: owner, for: server),
              self.owner == owner, self.server == server, fresh != credential else { return false }
        credential = fresh
        apply()
        return true
    }

    /// A page failed for want of the right password (NSURLErrorUserAuthenticationRequired): it may
    /// have expired. True when a new one came, for the page to load again. Not more than every 10 s.
    func renewAfterFailure() async -> Bool {
        guard server != nil, Date().timeIntervalSince(lastRenewal) > 10 else { return false }
        return await renewCredential()
    }

    /// The server's 407 reached a page (no password yet, or a refused one): the extension's answer.
    /// nil when the challenge isn't this server's.
    func answer(_ challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
        let space = challenge.protectionSpace
        guard space.isProxy(), let server, space.host.lowercased() == server.host.lowercased() else { return nil }
        guard challenge.previousFailureCount < 3 else { return (.cancelAuthenticationChallenge, nil) }
        if credential == nil || challenge.previousFailureCount > 0 { await renewCredential() }
        guard let credential else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: credential.user, password: credential.password, persistence: .forSession))
    }

    // MARK: - Routing

    private func apply() {
        let configurations = configurations()
        for store in stores.allObjects { store.proxyConfigurations = configurations }
        Self.routing.withLock { $0 = ($0.revision + 1, configurations) }
    }

    private func configurations() -> [ProxyConfiguration] {
        guard let server, let port = NWEndpoint.Port(rawValue: UInt16(clamping: server.port)) else { return [] }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(server.host), port: port)
        var configuration = server.scheme == "socks5"
            ? ProxyConfiguration(socksv5Proxy: endpoint)
            : ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: server.scheme == "https" ? NWProtocolTLS.Options() : nil)
        configuration.excludedDomains = server.bypass
        // A server that doesn't answer stops the pages rather than letting them out without it.
        configuration.allowFailover = false
        if let credential { configuration.applyCredential(username: credential.user, password: credential.password) }
        return [configuration]
    }

    // MARK: - Reading chrome.proxy values

    /// Where a chrome.proxy value sends pages: nil for none ("direct", "system").
    static func server(from value: [String: Any]) async throws -> Server? {
        switch value["mode"] as? String {
        case "direct", "system":
            return nil
        case "fixed_servers":
            let rules = value["rules"] as? [String: Any] ?? [:]
            let proxy = (rules["singleProxy"] ?? rules["proxyForHttps"] ?? rules["proxyForHttp"] ?? rules["fallbackProxy"]) as? [String: Any]
            guard let proxy, let host = proxy["host"] as? String else {
                throw Refusal(message: L("Aucun serveur dans ce réglage de proxy.", "No server in this proxy setting."))
            }
            let scheme = (proxy["scheme"] as? String ?? "http").lowercased()
            return try made(scheme: scheme, host: host, port: (proxy["port"] as? NSNumber)?.intValue,
                            bypass: rules["bypassList"] as? [String] ?? [])
        case "pac_script":
            // One server for every page: Nuri can't follow a script's choice page by page. It is
            // the one the script gives an ordinary site.
            guard let script = (value["pacScript"] as? [String: Any])?["data"] as? String,
                  let found = await firstServer(inPAC: script) else {
                throw Refusal(message: L("Nuri ne suit pas les règles par site de ce VPN : choisissez de tout faire passer par lui.",
                                         "Nuri doesn't follow this VPN's per-site rules: choose to route everything through it."))
            }
            return try made(scheme: found.scheme, host: found.host, port: found.port, bypass: [])
        default:
            throw Refusal(message: L("Ce réglage de proxy n'est pas pris en charge par Nuri.", "This proxy setting isn't supported by Nuri."))
        }
    }

    private static func made(scheme: String, host: String, port: Int?, bypass: [String]) throws -> Server {
        guard ["http", "https", "socks5"].contains(scheme) else {
            throw Refusal(message: L("Nuri ne sait pas passer par un serveur \(scheme).", "Nuri can't go through a \(scheme) server."))
        }
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let port = port ?? ["http": 80, "https": 443, "socks5": 1080][scheme]!
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:_".contains($0) }), (1...65535).contains(port) else {
            throw Refusal(message: L("Ce serveur de proxy n'est pas valable.", "This proxy server isn't valid."))
        }
        return Server(scheme: scheme, host: host, port: port, bypass: excludedDomains(bypass))
    }

    /// Chrome's bypass list as the hosts the network layer leaves out: "*.site" and ".site" give the
    /// site and its subdomains, a port or a scheme goes. Address ranges and "<local>" have no
    /// equivalent and are dropped.
    static func excludedDomains(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.compactMap { entry in
            var rule = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if let range = rule.range(of: "://") { rule = String(rule[range.upperBound...]) }
            if rule.hasPrefix("*.") { rule.removeFirst(2) } else if rule.hasPrefix(".") { rule.removeFirst() }
            if rule.hasPrefix("[") {
                rule = String(rule.dropFirst().prefix { $0 != "]" })
            } else if rule.filter({ $0 == ":" }).count == 1 {
                rule = String(rule.prefix { $0 != ":" })
            }
            guard !rule.isEmpty, !rule.contains(where: { "/*<> ".contains($0) }), seen.insert(rule).inserted else { return nil }
            return rule
        }
    }

    /// The first server a proxy auto-config script names for an ordinary site, in a context of its
    /// own off the main thread. A script that doesn't answer within 2 s gives nothing.
    static func firstServer(inPAC script: String) async -> (scheme: String, host: String, port: Int)? {
        final class Once: @unchecked Sendable {
            let lock = OSAllocatedUnfairLock(initialState: false)
            func first() -> Bool { lock.withLock { done in defer { done = true }; return !done } }
        }
        let once = Once()
        let answer: String? = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let context = JSContext()
                context?.evaluateScript(pacFunctions)
                context?.evaluateScript(script)
                let result = context?.evaluateScript(#"String(FindProxyForURL("https://www.example.com/", "www.example.com"))"#)
                let text = result?.isString == true ? result?.toString() : nil
                if once.first() { continuation.resume(returning: text) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if once.first() { continuation.resume(returning: nil) } }
        }
        let schemes = ["PROXY": "http", "HTTP": "http", "HTTPS": "https", "SOCKS5": "socks5", "SOCKS": "socks4", "SOCKS4": "socks4"]
        for entry in (answer ?? "").split(separator: ";") {
            let parts = entry.split(separator: " ")
            guard parts.count == 2, let scheme = schemes[parts[0].uppercased()],
                  let colon = parts[1].lastIndex(of: ":"), let port = Int(parts[1][parts[1].index(after: colon)...]) else { continue }
            return (scheme, String(parts[1][..<colon]), port)
        }
        return nil
    }

    /// What a PAC script may call. No DNS: a name is never resolved here.
    nonisolated private static let pacFunctions = #"""
    function isPlainHostName(h) { return h.indexOf(".") < 0; }
    function dnsDomainIs(h, d) { return h.length >= d.length && h.substring(h.length - d.length) === d; }
    function localHostOrDomainIs(h, d) { return h === d || d.lastIndexOf(h + ".", 0) === 0; }
    function isResolvable() { return true; }
    function isValidIpAddress(h) { return /^\d+(\.\d+){3}$/.test(h); }
    function dnsResolve(h) { return isValidIpAddress(h) ? h : null; }
    function myIpAddress() { return "127.0.0.1"; }
    function dnsDomainLevels(h) { return h.split(".").length - 1; }
    function convert_addr(ip) { return ip.split(".").reduce(function (n, part) { return (n * 256) + (parseInt(part, 10) & 255); }, 0); }
    function isInNet(h, pattern, mask) {
      if (!isValidIpAddress(h)) return false;
      var m = convert_addr(mask);
      return (convert_addr(h) & m) === (convert_addr(pattern) & m);
    }
    function shExpMatch(s, p) {
      return new RegExp("^" + p.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$").test(s);
    }
    function weekdayRange() { return true; }
    function dateRange() { return true; }
    function timeRange() { return true; }
    """#
}

/// What an extension had set, kept in extensions.json for the next launch (never its password).
struct SavedProxy: Codable, Equatable {
    /// The chrome.proxy value, as JSON.
    var value: String
    var server: ExtensionProxy.Server?

    init(value: [String: Any], server: ExtensionProxy.Server?) {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        self.value = String(decoding: data, as: UTF8.self)
        self.server = server
    }

    var decodedValue: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
    }
}
