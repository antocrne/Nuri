import Foundation
import CryptoKit
import os
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
/// On the Internet only an expired certificate (or one not valid yet: a Mac's clock off) is offered
/// a way through, discreetly, for that certificate until Nuri quits (a private window: until it
/// closes), never written; and never for a site that requires HTTPS (StrictTransport), as the
/// standard says. Any other failure there (wrong name, unknown authority) stays WebKit's refusal.
@MainActor
enum CertificateExceptions {
    private static let key = "certificateExceptions"

    /// A certificate refused, which the error page offers to accept.
    struct Pending: Equatable {
        let host: String
        let fingerprint: String
        /// A site on the Internet whose certificate has only expired.
        var onInternet = false
    }

    private static var stored: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Accepted from a private window: forgotten when Nuri quits, never written.
    private static var session: [String: String] = [:]
    /// Expired certificates of the Internet accepted in a normal window, until Nuri quits.
    private static var internet: [String: String] = [:]

    private static func accepted(_ host: String) -> String? { stored[host] ?? session[host] }

    /// The address shows an open lock for these hosts.
    static func isExcepted(_ host: String?, in browser: BrowserModel? = nil) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return accepted(host) != nil || internet[host] != nil || browser?.acceptedCertificates[host] != nil
    }

    static func accept(_ pending: Pending, persist: Bool = true, in browser: BrowserModel? = nil) {
        let host = pending.host.lowercased()
        if pending.onInternet {
            if let browser, browser.isPrivate { browser.acceptedCertificates[host] = pending.fingerprint } else { internet[host] = pending.fingerprint }
            return
        }
        if persist { stored[host] = pending.fingerprint } else { session[host] = pending.fingerprint }
    }

    static var hosts: [String] { stored.keys.sorted() }

    static func remove(_ host: String) { stored[host] = nil; session[host] = nil; internet[host] = nil }

    /// WebKit's question about a server's certificate. A valid one: WebKit decides, as always. A
    /// local device whose certificate fails: accepted if the user accepted that very certificate,
    /// otherwise refused and kept on the tab for its error page. A site of the Internet: the same
    /// for an expired certificate of a site that doesn't require HTTPS.
    static func decide(host: String, trust: SecTrust, tab: Tab?) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let local = LocalNetwork.isLocal(host)
        let browser = tab?.browser
        // Off the main thread, as it may wait on the network. Not SecTrustEvaluateAsyncWithError from
        // here: it must be called on the queue it answers on, or macOS stops the app.
        let (valid, dateOnly) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let valid = SecTrustEvaluateWithError(trust, nil)
                continuation.resume(returning: (valid, !valid && !local && failsOnlyByDate(trust)))
            }
        }
        guard !valid else { return (.performDefaultHandling, nil) }
        guard local || dateOnly && !StrictTransport.isRequired(host, in: browser) else { return (.performDefaultHandling, nil) }
        guard let fingerprint = fingerprint(of: trust) else { return (.performDefaultHandling, nil) }
        let lower = host.lowercased()
        let known = local ? accepted(lower) : (browser?.isPrivate == true ? browser?.acceptedCertificates[lower] : internet[lower])
        if known == fingerprint { return (.useCredential, URLCredential(trust: trust)) }
        tab?.untrustedCertificate = Pending(host: host, fingerprint: fingerprint, onInternet: !local)
        if !local { Log.web.notice("Certificat expiré pour \(host, privacy: .private(mask: .hash))") }
        return (.performDefaultHandling, nil)
    }

    /// The chain would be valid on a day its certificate was: only its dates are wrong (expired, or
    /// not valid yet). Checked again with the same policies (the site's name included), on the last
    /// day of the server's certificate, or its first.
    nonisolated static func failsOnlyByDate(_ trust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(leaf, keys, nil) as? [String: [String: Any]],
              let notBefore = (values[kSecOIDX509V1ValidityNotBefore as String]?[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue,
              let notAfter = (values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue else { return false }
        let now = Date().timeIntervalSinceReferenceDate
        guard now > notAfter || now < notBefore else { return false }
        var policies: CFArray?
        guard SecTrustCopyPolicies(trust, &policies) == errSecSuccess, let policies else { return false }
        var copy: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, policies, &copy) == errSecSuccess, let copy else { return false }
        let day = now > notAfter ? notAfter - 3600 : notBefore + 3600
        SecTrustSetVerifyDate(copy, Date(timeIntervalSinceReferenceDate: day) as CFDate)
        return SecTrustEvaluateWithError(copy, nil)
    }

    nonisolated static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Sites that require HTTPS (HTTP Strict Transport Security): no way through a certificate error
/// for them. The top-level domains preloaded in every browser as a whole, a few sites everyone
/// knows, and those whose answer said so (Strict-Transport-Security), as WebKit doesn't tell.
/// What a private window learns stays in it.
@MainActor
enum StrictTransport {
    private static let preloadedSuffixes = ["app", "dev", "page", "bank", "insurance", "new", "day", "foo", "gle", "google",
                                            "youtube", "android", "chrome", "gmail", "how", "soy", "boo", "esq", "ing", "meme", "mov", "nexus", "phd", "prof", "rsvp", "zip"]
    private static let preloadedSites = ["google.com", "gmail.com", "youtube.com", "facebook.com", "instagram.com", "twitter.com", "x.com",
                                         "paypal.com", "github.com", "apple.com", "icloud.com", "microsoft.com", "live.com", "dropbox.com",
                                         "wikipedia.org", "mozilla.org", "proton.me", "protonmail.com", "stripe.com", "amazon.com"]
    static let hosts = SiteList(key: "strictTransportHosts")
    /// Those whose rule covers their subdomains too (includeSubDomains).
    static let withSubdomains = SiteList(key: "strictTransportSubdomains")

    static func isRequired(_ rawHost: String, in browser: BrowserModel?) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = host.split(separator: ".").map(String.init)
        if let tld = labels.last, preloadedSuffixes.contains(tld) { return true }
        let parents = labels.indices.map { labels[$0...].joined(separator: ".") }
        if parents.contains(where: preloadedSites.contains) { return true }
        let (exact, broad): (Set<String>, Set<String>) = browser?.isPrivate == true
            ? (browser!.strictTransportHosts, browser!.strictTransportSubdomains)
            : (Set(hosts.hosts), Set(withSubdomains.hosts))
        return exact.contains(host) || parents.contains(where: broad.contains)
    }

    /// A page served over HTTPS said whether it requires it (max-age=0 takes it back).
    static func record(_ response: URLResponse, in browser: BrowserModel?) {
        guard let http = response as? HTTPURLResponse, http.url?.scheme?.lowercased() == "https",
              let host = http.url?.host()?.lowercased(),
              let header = http.value(forHTTPHeaderField: "Strict-Transport-Security")?.lowercased() else { return }
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let maxAge = parts.first { $0.hasPrefix("max-age") }.flatMap { Int($0.split(separator: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) ?? "") } ?? 0
        let subdomains = parts.contains("includesubdomains")
        if let browser, browser.isPrivate {
            if maxAge > 0 { browser.strictTransportHosts.insert(host) } else { browser.strictTransportHosts.remove(host) }
            if maxAge > 0 && subdomains { browser.strictTransportSubdomains.insert(host) } else { browser.strictTransportSubdomains.remove(host) }
            return
        }
        if maxAge > 0 { if !hosts.contains(host) { hosts.add(host) } } else if hosts.contains(host) { hosts.remove(host) }
        if maxAge > 0 && subdomains { if !withSubdomains.contains(host) { withSubdomains.add(host) } }
        else if withSubdomains.contains(host) { withSubdomains.remove(host) }
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

    /// "node.js", "readme.md": a word with dots, nothing after it.
    static func isSimpleName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains { "/?#:@".contains($0) }
    }

    static func decide(_ typed: Typed, error: NSError) -> TypedAddressFallback? {
        guard error.domain == NSURLErrorDomain else { return nil }
        if let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
           failing.host()?.lowercased() != typed.url.host()?.lowercased() { return nil }
        let host = typed.url.host() ?? ""
        switch error.code {
        case NSURLErrorCannotFindHost:
            // Only a name alone ("node.js"): with a path, parameters or a port, it was an address,
            // and its error page says what happened ("exemple.fr/contact" isn't a search).
            return LocalNetwork.isLocal(host) || !isSimpleName(typed.text) ? nil : .search(typed.text)
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
