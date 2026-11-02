import Foundation
import CryptoKit
@preconcurrency import Security

/// Devices of the local network (router, NAS, printer, Home Assistant…): they often serve plain
/// HTTP or HTTPS with a certificate of their own, which no browser can check.
enum LocalNetwork {
    /// Private and link-local addresses, `.local`, `.lan`, `.home.arpa`, `.internal`, and names without a dot.
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if h == "localhost" || !h.contains(".") && !h.contains(":") { return true }
        if [".local", ".lan", ".home.arpa", ".internal", ".localhost"].contains(where: { h.hasSuffix($0) }) { return true }
        // Every label a number: "10.0.0.1.evil.com" is a name on the Internet.
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        let parts = labels.compactMap { UInt8($0) }
        if labels.count == 4, parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        // IPv6: loopback, link-local (fe80::/10), unique local (fc00::/7).
        if h.contains(":") { return h == "::1" || h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") || h.hasPrefix("fc") || h.hasPrefix("fd") }
        return false
    }
}

/// "Continuer vers 192.168.1.1": a device of the local network whose certificate can't be checked,
/// accepted once by the user for that certificate only (its SHA-256). A new certificate asks again.
/// Never offered for a site on the Internet.
@MainActor
enum CertificateExceptions {
    private static let key = "certificateExceptions"

    /// A certificate refused on a local device, which the error page offers to accept.
    struct Pending: Equatable {
        let host: String
        let fingerprint: String
    }

    private static var stored: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Accepted from a private window: forgotten when Nuri quits, never written.
    private static var session: [String: String] = [:]

    private static func accepted(_ host: String) -> String? { stored[host] ?? session[host] }

    /// The address shows an open lock for these hosts.
    static func isExcepted(_ host: String?) -> Bool {
        guard let host else { return false }
        return accepted(host.lowercased()) != nil
    }

    static func accept(_ pending: Pending, persist: Bool = true) {
        if persist { stored[pending.host.lowercased()] = pending.fingerprint } else { session[pending.host.lowercased()] = pending.fingerprint }
    }

    static var hosts: [String] { stored.keys.sorted() }

    static func remove(_ host: String) { stored[host] = nil; session[host] = nil }

    /// WebKit's question about a server's certificate. Sites on the Internet: WebKit decides, as
    /// always. A local device whose certificate fails: accepted if the user accepted that very
    /// certificate, otherwise refused and kept on the tab for its error page.
    static func decide(host: String, trust: SecTrust, tab: Tab?) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard LocalNetwork.isLocal(host) else { return (.performDefaultHandling, nil) }
        // Off the main thread, as it may wait on the network. Not SecTrustEvaluateAsyncWithError from
        // here: it must be called on the queue it answers on, or macOS stops the app.
        let valid = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SecTrustEvaluateWithError(trust, nil))
            }
        }
        guard !valid else { return (.performDefaultHandling, nil) }
        guard let fingerprint = fingerprint(of: trust) else { return (.performDefaultHandling, nil) }
        if accepted(host.lowercased()) == fingerprint { return (.useCredential, URLCredential(trust: trust)) }
        tab?.untrustedCertificate = Pending(host: host, fingerprint: fingerprint)
        return (.performDefaultHandling, nil)
    }

    nonisolated static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Pages served over plain HTTP from the Internet: the tab asks before showing them. Only the page
/// finally served counts: an address that redirects to HTTPS (the link shim of Threads and others)
/// never reaches this question. Devices of the local network aren't concerned, nor is a host the
/// user accepted, until Nuri quits or the private window closes.
@MainActor
enum PlainHTTP {
    private static var accepted: Set<String> = []

    static func needsWarning(_ url: URL?, in browser: BrowserModel) -> Bool {
        guard url?.scheme?.lowercased() == "http", let host = url?.host()?.lowercased(), !LocalNetwork.isLocal(host) else { return false }
        return !(browser.isPrivate ? browser.acceptedHTTPHosts : accepted).contains(host)
    }

    static func accept(_ url: URL, in browser: BrowserModel) {
        guard let host = url.host()?.lowercased() else { return }
        if browser.isPrivate { browser.acceptedHTTPHosts.insert(host) } else { accepted.insert(host) }
    }
}

/// What the address bar does when an address typed without `https://` fails: the same address
/// over plain HTTP when nothing answered over HTTPS (old sites, devices), or a search for what was
/// typed when no such site exists ("node.js", "readme.md").
enum TypedAddressFallback: Equatable {
    case http(URL)
    case search(String)

    /// The address as typed, and the page Nuri tried for it.
    struct Typed: Equatable {
        let text: String
        let url: URL
    }

    static func decide(_ typed: Typed, error: NSError) -> TypedAddressFallback? {
        guard error.domain == NSURLErrorDomain else { return nil }
        if let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
           failing.host()?.lowercased() != typed.url.host()?.lowercased() { return nil }
        let host = typed.url.host() ?? ""
        switch error.code {
        case NSURLErrorCannotFindHost:
            return LocalNetwork.isLocal(host) ? nil : .search(typed.text)
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorSecureConnectionFailed:
            guard typed.url.scheme == "https", var components = URLComponents(url: typed.url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = "http"
            return components.url.map { .http($0) }
        default:
            // A certificate that can't be checked: never a silent switch to HTTP (that is what an
            // attacker on the network would want); a local device gets "Continuer vers…" instead.
            return nil
        }
    }
}
