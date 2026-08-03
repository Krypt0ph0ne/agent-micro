import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case german = "de"
    case english = "en"

    static let defaultsKey = "AgentMicro.appLanguage"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var nativeTitle: String {
        switch self {
        case .german: "Deutsch"
        case .english: "English"
        }
    }

    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("de") == true ? .german : .english
    }

    static var current: AppLanguage {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(AppLanguage.init(rawValue:)) ?? systemDefault
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    func text(_ german: String, _ english: String) -> String {
        self == .german ? german : english
    }

    static func text(_ german: String, _ english: String) -> String {
        current.text(german, english)
    }

    /// Looks a German source string up in the selected language's
    /// `Localizable.strings`, the same table SwiftUI's `Text("…")` reads.
    ///
    /// Needed wherever a translation has to be produced as a plain `String` at
    /// runtime — catalog data decoded from JSON, `NSMenu` titles, values fed
    /// into `Text(verbatim:)` — because those never pass through
    /// `LocalizedStringKey`. Falls back to the German source when no entry
    /// exists, so an untranslated string still renders.
    static func localized(_ german: String) -> String {
        current.localized(german)
    }

    func localized(_ german: String) -> String {
        guard self != .german else { return german }
        guard
            let path = Bundle.module.path(forResource: rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return german }
        return bundle.localizedString(forKey: german, value: german, table: nil)
    }
}
