import Foundation
import WebKit

/// Compiles and installs Nuri's WKContentRuleList on the shared content controller: ad and tracker
/// blocking (compiled WebKit rules, no script, applied before load: it costs nothing per page).
/// Compiled lists are cached by WebKit on disk; recompilation only happens when rules change.
@MainActor
final class ContentRules {
    static let shared = ContentRules()

    private let store = WKContentRuleListStore.default()!
    private var adBlockList: WKContentRuleList?
    private var ready = false
    private var waiters: [() -> Void] = []
    /// Bumped at each install: a compilation that finishes after a newer one started is dropped
    /// (two quick toggles would otherwise leave both lists installed, the stale one for good).
    private var adBlockGeneration = 0
    #if DEBUG
    /// Identifiers of the lists on the content controller, for the self-test.
    private(set) var installedIdentifiers: Set<String> = []
    #endif

    /// The blocker's list as installed (nil when it is off), for web views outside the shared
    /// content controller: the reader view.
    var installedAdBlockList: WKContentRuleList? { adBlockList }

    func start() {
        Task {
            await installAdBlock()
            markReady()
            await removeUnusedLists()
        }
        // Never hold the first page load for more than half a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.markReady() }
    }

    func whenReady(_ block: @escaping () -> Void) {
        if ready { block() } else { waiters.append(block) }
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        waiters.forEach { $0() }
        waiters = []
    }

    func reload() {
        Task { await installAdBlock() }
    }

    /// The blocker's list as it is now (allowlist and on/off), installed before returning: a page
    /// reloaded afterwards gets the new rules.
    func reloadNow() async {
        await installAdBlock()
    }

    // MARK: - Ad blocking

    private func installAdBlock() async {
        adBlockGeneration &+= 1
        let generation = adBlockGeneration
        var list: WKContentRuleList?
        if AppSettings.shared.adBlockEnabled {
            let allowlist = AppSettings.shared.adBlockAllowlist
            list = await lookupOrCompile(identifier: Self.adBlockIdentifier(allowlist: allowlist),
                                         json: AdBlockList.encodedRules(allowlist: allowlist.sorted()))
            guard generation == adBlockGeneration else { return }
        }
        replace(&adBlockList, with: list)
    }

    /// The compiled list's name: a new allowlist is a new list (WebKit caches each on disk).
    static func adBlockIdentifier(allowlist: [String]) -> String {
        "nuri-adblock-\(AdBlockList.version)-\(hash(AdBlockList.encodedRules(allowlist: allowlist.sorted())))"
    }

    /// The new list goes in before the old one comes out: no page loads unblocked in between.
    /// The controller keys lists by identifier, so an identical one is left as it is.
    private func replace(_ current: inout WKContentRuleList?, with new: WKContentRuleList?) {
        let controllers = WebViewFactory.contentControllers
        if let new, new.identifier != current?.identifier { controllers.forEach { $0.add(new) } }
        if let old = current, old.identifier != new?.identifier {
            controllers.forEach { $0.remove(old) }
            // Each allowlist is its own compiled list: the old one
            // would stay on disk for good. The list toggled back later is simply compiled again.
            let identifier = old.identifier
            Task { try? await store.removeContentRuleList(forIdentifier: identifier) }
        }
        #if DEBUG
        if let old = current { installedIdentifiers.remove(old.identifier) }
        if let new { installedIdentifiers.insert(new.identifier) }
        #endif
        current = new
    }

    /// At launch: compiled lists left by earlier allowlists or hidden elements.
    private func removeUnusedLists() async {
        let current = Set([adBlockList?.identifier].compactMap { $0 })
        let identifiers = await store.availableIdentifiers() ?? []
        for identifier in identifiers where identifier.hasPrefix("nuri-") && !current.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    private func lookupOrCompile(identifier: String, json: String) async -> WKContentRuleList? {
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) { return cached }
        return try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
    }

    private static func hash(_ string: String) -> String {
        var h: UInt64 = 1469598103934665603   // FNV-1a
        for byte in string.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return String(h, radix: 36)
    }
}
