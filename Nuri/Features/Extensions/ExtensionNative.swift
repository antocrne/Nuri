import AppKit
import WebKit
import os

/// What extension-shim.js asks Nuri itself, through runtime.sendNativeMessage to one of Nuri's own
/// names (`app.nuri.…`). WebKit hands every such message to ExtensionHost, which never passes one
/// to an app of the Mac. Here: the side panel, tab groups and the log; chrome.proxy, the debugger
/// and sign-in pages have their own files.
@available(macOS 15.4, *)
@MainActor
enum ExtensionNative {
    static let prefix = "app.nuri."

    /// The reply, or `["error": …]`, which the shim turns into a rejected promise.
    static func handle(_ app: String, _ message: Any, from context: WKWebExtensionContext) async -> Any {
        let body = message as? [String: Any] ?? [:]
        switch app {
        case "proxy":
            guard ExtensionHost.wantsProxy(context.webExtension) else { return refusal }
            return await ExtensionProxy.shared.handle(message, from: context)
        case "panel": return panel(body, from: context)
        case "tabgroups": return TabGroups.of(context.uniqueIdentifier).handle(body)
        case "debugger": return await ExtensionDebugger.handle(body, from: context)
        case "identity": return await ExtensionAuthFlow.handle(body, from: context)
        case "socket": return ExtensionSockets.shared.handle(body, from: context)
        case "headers": return headers(body, from: context)
        case "log": return log(body, from: context)
        default: return refusal
        }
    }

    static let refusal: [String: Any] = ["error": L("Nuri ne relie pas les extensions aux apps du Mac.", "Nuri doesn't connect extensions to Mac apps.")]

    // MARK: - Side panel

    private static func panel(_ body: [String: Any], from context: WKWebExtensionContext) -> Any {
        let id = context.uniqueIdentifier
        let panels = BrowserWindows.shared.all.compactMap(\.sidePanel).filter { $0.extensionID == id }
        if body["close"] != nil {
            let browser = BrowserWindows.shared.normalTarget
            if let panel = browser.sidePanel, panel.extensionID == id { panel.close() }
            return [:]
        }
        return ["contexts": panels.map(\.context)]
    }

    // MARK: - Headers WebKit's declarativeNetRequest refuses (extension-shim.js)

    /// By extension: rule id → its URL pattern and headers, for the extension's own requests.
    private static var headerRules: [String: [Int: [String: Any]]] = [:]

    private static func headers(_ body: [String: Any], from context: WKWebExtensionContext) -> Any {
        let id = context.uniqueIdentifier
        var rules = headerRules[id] ?? [:]
        for removed in body["remove"] as? [Any] ?? [] {
            if let number = (removed as? NSNumber)?.intValue { rules[number] = nil }
        }
        for rule in body["add"] as? [[String: Any]] ?? [] {
            guard let number = (rule["id"] as? NSNumber)?.intValue else { continue }
            var kept = rules[number] ?? ["regex": rule["regex"] ?? "", "headers": [Any]()]
            kept["regex"] = rule["regex"] ?? kept["regex"]
            kept["headers"] = (kept["headers"] as? [Any] ?? []) + (rule["headers"] as? [Any] ?? [])
            rules[number] = kept
        }
        headerRules[id] = rules
        return ["rules": Array(rules.values)]
    }

    static func forget(_ id: String) {
        headerRules[id] = nil
        TabGroups.forget(id)
    }

    // MARK: - Log

    /// What Nuri does for an extension, in the same log as its errors.
    static func note(_ context: WKWebExtensionContext, _ text: String) {
        ExtensionLog.note(context.webExtension.displayName ?? context.uniqueIdentifier, text)
    }

    private static func log(_ body: [String: Any], from context: WKWebExtensionContext) -> Any {
        if let text = body["log"] as? String, ExtensionLog.isOn {
            ExtensionLog.write(context.webExtension.displayName ?? context.uniqueIdentifier, text)
        }
        return ["enabled": ExtensionLog.isOn]
    }
}

/// `defaults write app.nuri.browser extensionConsoleLog -bool YES`: what goes wrong in the
/// extensions' pages, and what Nuri does for them, is written in the system log (Console.app, or
/// `log stream --predicate 'subsystem == "app.nuri.browser"'`).
enum ExtensionLog {
    private static let logger = Logger(subsystem: "app.nuri.browser", category: "extensions")

    static var isOn: Bool { UserDefaults.standard.bool(forKey: "extensionConsoleLog") }

    static func write(_ name: String, _ text: String) {
        logger.notice("\(name, privacy: .public) \(text, privacy: .public)")
    }

    /// Nuri's own doing, marked as such.
    static func note(_ name: String, _ text: String) {
        guard isOn else { return }
        write(name, "[Nuri] " + text)
    }
}

/// An extension's tab groups (chrome.tabGroups), shared by all its contexts. Tabs are named by the
/// identifiers WebKit gives the extension: Nuri only keeps them, and draws no group.
@MainActor
final class TabGroups {
    private static var byExtension: [String: TabGroups] = [:]

    static func of(_ id: String) -> TabGroups {
        if let known = byExtension[id] { return known }
        let made = TabGroups()
        byExtension[id] = made
        return made
    }

    static func forget(_ id: String) { byExtension[id] = nil }

    private struct Group {
        var id: Int
        var title = ""
        var color = "grey"
        var collapsed = false
        var windowId: Int

        var dictionary: [String: Any] { ["id": id, "title": title, "color": color, "collapsed": collapsed, "windowId": windowId] }
    }

    private var groups: [Int: Group] = [:]
    /// Tab → group.
    private var members: [Int: Int] = [:]
    private var nextID = 1
    private static let colors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

    func handle(_ body: [String: Any]) -> [String: Any] {
        if body["members"] != nil {
            return ["members": Dictionary(uniqueKeysWithValues: members.map { (String($0.key), $0.value) })]
        }
        if let id = Self.number(body["get"]) {
            guard let group = groups[id] else { return missing(id) }
            return ["group": group.dictionary]
        }
        if let filter = body["query"] as? [String: Any] {
            let found = groups.values.sorted { $0.id < $1.id }.filter { group in
                (filter["title"] as? String).map { Self.matches(group.title, pattern: $0) } ?? true
                    && (filter["color"] as? String).map { $0 == group.color } ?? true
                    && (filter["collapsed"] as? Bool).map { $0 == group.collapsed } ?? true
                    && Self.number(filter["windowId"]).map { $0 == -2 || $0 == group.windowId } ?? true
            }
            return ["groups": found.map(\.dictionary)]
        }
        if let id = Self.number(body["update"]) {
            guard var group = groups[id] else { return missing(id) }
            let properties = body["properties"] as? [String: Any] ?? [:]
            if let title = properties["title"] as? String { group.title = title }
            if let color = properties["color"] as? String, Self.colors.contains(color) { group.color = color }
            if let collapsed = properties["collapsed"] as? Bool { group.collapsed = collapsed }
            groups[id] = group
            return ["group": group.dictionary, "updated": [group.dictionary]]
        }
        if let tabs = body["group"] as? [Any] {
            let ids = tabs.compactMap(Self.number)
            var created: [[String: Any]] = []
            let id: Int
            if let wanted = Self.number(body["groupId"]) {
                guard groups[wanted] != nil else { return missing(wanted) }
                id = wanted
            } else {
                id = nextID
                nextID += 1
                let group = Group(id: id, color: Self.colors[(id - 1) % Self.colors.count], windowId: Self.number(body["windowId"]) ?? -1)
                groups[id] = group
                created.append(group.dictionary)
            }
            var reply = leave(ids.filter { members[$0] != id })
            for tab in ids { members[tab] = id }
            reply["groupId"] = id
            reply["created"] = created
            return reply
        }
        if let tabs = body["ungroup"] as? [Any] {
            return leave(tabs.compactMap(Self.number))
        }
        return [:]
    }

    /// The tabs leave their groups; a group left empty goes.
    private func leave(_ tabs: [Int]) -> [String: Any] {
        let left = Set(tabs.compactMap { members[$0] })
        for tab in tabs { members[tab] = nil }
        let emptied = left.filter { group in !members.values.contains(group) }
        let removed = emptied.compactMap { groups.removeValue(forKey: $0)?.dictionary }
        return ["removed": removed]
    }

    private func missing(_ id: Int) -> [String: Any] { ["error": "No group with id: \(id)."] }

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    /// Chrome's title filter: `*` stands for anything.
    private static func matches(_ title: String, pattern: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard let expression = try? NSRegularExpression(pattern: "^" + parts.joined(separator: ".*") + "$") else { return title == pattern }
        return expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }
}
