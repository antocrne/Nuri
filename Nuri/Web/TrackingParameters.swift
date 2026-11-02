import Foundation

/// Removes from an address the parameters that only follow people around (utm_source, fbclid…).
/// Applied to links clicked in a page, never to what the user types.
@MainActor
enum TrackingParameters {
    private static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "twclid", "ttclid", "yclid",
        "igshid", "igsh", "mc_eid", "mc_cid", "oly_anon_id", "oly_enc_id", "vero_id", "_hsenc", "_hsmi",
        "mkt_tok", "s_cid", "spm", "ref_src", "ref_url", "epik", "sc_cid", "__s", "rb_clickid",
    ]
    private static let prefixes = ["utm_", "pk_", "hsa_", "stm_", "ga_"]

    /// Works on the address as it is written: decoding and encoding the parameters again would change
    /// those that stay ("a%2Bb" would become "a+b", another value for the server, and break a signature).
    static func cleaned(_ url: URL) -> URL {
        guard AppSettings.shared.stripTrackingParameters, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.query != nil else { return url }
        let address = url.absoluteString
        let end = address.firstIndex(of: "#") ?? address.endIndex
        guard let mark = address[..<end].firstIndex(of: "?") else { return url }
        let items = address[address.index(after: mark)..<end].split(separator: "&", omittingEmptySubsequences: false)
        let kept = items.filter { item in
            let raw = item.prefix { $0 != "=" }
            let name = (raw.removingPercentEncoding ?? String(raw)).lowercased()
            return !exact.contains(name) && !prefixes.contains { name.hasPrefix($0) }
        }
        guard kept.count != items.count else { return url }
        let query = kept.isEmpty ? "" : "?" + kept.joined(separator: "&")
        return URL(string: address[..<mark] + query + address[end...]) ?? url
    }
}
