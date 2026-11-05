import Foundation

/// Turns what the user typed in the address bar into a URL, or nil when it's a search.
enum URLResolver {
    /// Addresses of other apps (Mail, Phone, FaceTime, Messages), handed to macOS.
    static let externalSchemes = ["mailto", "tel", "sms", "facetime", "facetime-audio"]

    static func url(from rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let lower = input.lowercased()

        // "mailto:jean@exemple.fr?subject=Bonjour à tous": its spaces belong to it.
        for scheme in externalSchemes where lower.hasPrefix(scheme + ":") && input.count > scheme.count + 1 {
            return make(input)
        }
        for scheme in ["http://", "https://", "file://", "about:", "data:"] where lower.hasPrefix(scheme) {
            return scheme == "data:" ? URL(string: input) : make(input)
        }
        // From here an address has no space before its path ("exemple.fr/ma page" is one, "le
        // monde.fr" a search).
        let head = String(input.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !head.contains(where: \.isWhitespace) else { return nil }
        let address = input
        let lowerHead = head.lowercased()

        for local in ["localhost", "127.0.0.1", "[::1]"] where lowerHead == local || lowerHead.hasPrefix(local + ":") {
            return make("http://" + address)
        }
        // IPv6: "[2001:db8::1]:8080/admin", or the address alone ("fe80::1").
        if lowerHead.hasPrefix("["), let close = lowerHead.firstIndex(of: "]"),
           isIPv6(String(lowerHead[lowerHead.index(after: lowerHead.startIndex)..<close])) {
            let after = lowerHead[lowerHead.index(after: close)...]
            if after.isEmpty || after.hasPrefix(":") && Int(after.dropFirst()).map({ (1...65535).contains($0) }) == true {
                return make("http://" + address)
            }
        }
        if head == input, isIPv6(lowerHead) { return URL(string: "http://[\(input)]") }
        // "nas:5000", "routeur:8080/admin": a name and a port is a device of the local network.
        // The name needs a letter ("12:30" stays a search).
        let nameAndPort = lowerHead.split(separator: ":", omittingEmptySubsequences: false)
        if nameAndPort.count == 2, let port = Int(nameAndPort[1]), (1...65535).contains(port),
           nameAndPort[0].contains(where: \.isLetter), nameAndPort[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            return make("http://" + address)
        }
        // "intranet/", "wiki/accueil/", "nas/index.html": a name of the local network followed by a
        // path that looks like one ("and/or" stays a search).
        if let slash = input.firstIndex(of: "/"), !head.isEmpty, !head.contains("."), !head.contains(":"),
           head.contains(where: \.isLetter), head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            let path = input[input.index(after: slash)...]
            if path.isEmpty || path.hasSuffix("/") || path.contains("/") || path.contains(".") || path.contains("?") {
                return make("http://" + address)
            }
        }
        // host[:port][/path] with a plausible TLD or an IPv4 address
        // "jean@exemple.fr" is an e-mail address, looked up — not exemple.fr signed in as "jean".
        if lowerHead.contains("@") { return nil }
        let host = lowerHead.split(separator: ":").first.map(String.init) ?? lowerHead
        let labels = host.split(separator: ".")
        let isIPv4 = labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
        if isIPv4 { return make("http://" + address) }
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter || $0 == "-" }) || tld.hasPrefix("xn--"),
              labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return make("https://" + address)
    }

    /// Typed without its scheme: Nuri chose it ("apple.com" → https), so it may try another way
    /// if that fails (see TypedAddressFallback).
    static func isTypedWithoutScheme(_ rawInput: String) -> Bool {
        let lower = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !lower.contains("://") && !(["about:", "data:"] + externalSchemes.map { $0 + ":" }).contains { lower.hasPrefix($0) }
    }

    /// "view-source:https://exemple.fr/": the page whose source to show (see BrowserModel.showSource).
    static func viewSourceTarget(_ rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.lowercased().hasPrefix("view-source:") else { return nil }
        let rest = String(input.dropFirst("view-source:".count))
        guard let url = url(from: rest), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// A space or an accent typed in a path or a query: percent-encoded, as every browser sends it
    /// (what is already encoded stays as it is).
    private static func make(_ text: String) -> URL? {
        URL(string: text, encodingInvalidCharacters: true)
    }

    private static func isIPv6(_ text: String) -> Bool {
        guard text.filter({ $0 == ":" }).count >= 2 else { return false }
        // A zone ("fe80::1%en0") isn't part of the address.
        let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var storage = in6_addr()
        return inet_pton(AF_INET6, address, &storage) == 1
    }
}
