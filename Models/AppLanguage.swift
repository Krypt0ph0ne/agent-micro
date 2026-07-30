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
}
