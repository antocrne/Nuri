import Foundation

/// JavaScript sources bundled in Resources/Scripts.
enum Scripts {
    static let core = load("core")
    static let media = load("media")
    static let reader = load("reader")
    static let activity = load("activity")
    static let shareAudio = load("shareaudio")
    static let shareAudioPage = load("shareaudio-page")
    static let extensionShim = load("extension-shim")
    static let extensionExternal = load("extension-external")
    static let notificationPage = load("notification-page")

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Missing script \(name).js")
            return ""
        }
        return source
    }
}
