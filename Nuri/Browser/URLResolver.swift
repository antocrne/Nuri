import Foundation

/// Turns what the user typed in the address bar into a URL, or nil when it's a search.
enum URLResolver {
    static func url(from rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(" ") else { return nil }
        let lower = input.lowercased()

        for scheme in ["http://", "https://", "file://", "about:", "data:", "view-source:"] where lower.hasPrefix(scheme) {
            return URL(string: input)
        }
        for local in ["localhost", "127.0.0.1", "[::1]"] where lower == local || lower.hasPrefix(local + ":") || lower.hasPrefix(local + "/") {
            return URL(string: "http://" + input)
        }
        // "nas:5000", "routeur:8080/admin": a name and a port is a device of the local network.
        // The name needs a letter ("12:30" stays a search).
        let nameAndPort = lower.split(separator: "/", maxSplits: 1).first.map { $0.split(separator: ":", omittingEmptySubsequences: false) } ?? []
        if nameAndPort.count == 2, let port = Int(nameAndPort[1]), (1...65535).contains(port),
           nameAndPort[0].contains(where: \.isLetter), nameAndPort[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            return URL(string: "http://" + input)
        }
        // host[:port][/path] with a plausible TLD or an IPv4 address
        let hostPart = lower.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? lower
        // "jean@exemple.fr" is an e-mail address, looked up — not exemple.fr signed in as "jean".
        if hostPart.contains("@") { return nil }
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let labels = host.split(separator: ".")
        let isIPv4 = labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
        if isIPv4 { return URL(string: "http://" + input) }
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter || $0 == "-" }) || tld.hasPrefix("xn--"),
              labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return URL(string: "https://" + input)
    }

    /// Typed without its scheme: Nuri chose it ("apple.com" → https), so it may try another way
    /// if that fails (see TypedAddressFallback).
    static func isTypedWithoutScheme(_ rawInput: String) -> Bool {
        let lower = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !lower.contains("://") && !["about:", "data:", "view-source:"].contains { lower.hasPrefix($0) }
    }
}
