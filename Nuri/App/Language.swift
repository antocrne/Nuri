import AppKit
import Observation

/// The interface's language: the system's by default (French if it comes first, English
/// otherwise), or the one picked in Settings. Texts live next to the code, in both languages (`L`):
/// nothing can be left untranslated, and a change applies at once.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, fr, en
    var id: String { rawValue }

    /// Each language is named in itself, so it can be found whatever the current one.
    @MainActor var label: String {
        switch self {
        case .system: L("Langue du système", "System language")
        case .fr: "Français"
        case .en: "English"
        }
    }
}

@MainActor @Observable
final class LanguageStore {
    static let shared = LanguageStore()
    private static let key = "language"

    var choice: AppLanguage {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: Self.key)
            // What the system draws for Nuri (WebKit's menus, panels) follows at the next launch.
            if choice == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([choice.rawValue], forKey: "AppleLanguages")
            }
            NuriMenu.rebuild()
        }
    }

    private init() {
        choice = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .system
    }

    /// The system's languages, whatever was chosen for Nuri.
    private static let systemIsFrench: Bool = {
        let list = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? Locale.preferredLanguages
        return list.first?.hasPrefix("fr") ?? false
    }()

    var isFrench: Bool {
        switch choice {
        case .fr: true
        case .en: false
        case .system: Self.systemIsFrench
        }
    }
}

/// A text of the interface, in French and English. Read from a view's body, it refreshes the view
/// when the language changes.
@MainActor
func L(_ fr: String, _ en: String) -> String {
    LanguageStore.shared.isFrench ? fr : en
}
