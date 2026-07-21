import Foundation

enum CodexActionExecution: String, Codable, Hashable {
    case keyboardShortcut
    case configurableShortcut
    case deepLink
    case unavailable

    var title: String {
        switch self {
        case .keyboardShortcut: "Direkter Shortcut"
        case .configurableShortcut: "In Codex konfigurierbar"
        case .deepLink: "Codex Deep Link"
        case .unavailable: "Nicht stabil verfügbar"
        }
    }
}

struct CodexActionDefinition: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var description: String
    var category: String
    var icon: String
    var shortcut: String?
    var deviceMacro: String?
    var modifiers: [String]
    var execution: CodexActionExecution
    var codexCommandID: String?
    var deepLink: String?
    var compatibleWith: String
    var availabilityNote: String?

    /// A configurable action can be assigned when the pad emits a dedicated
    /// trigger which Codex can bind in its Keyboard Shortcuts settings.
    var isDirectlyAssignable: Bool {
        (execution == .keyboardShortcut || execution == .configurableShortcut) && deviceMacro != nil
    }
}

struct CodexActionCatalogDocument: Codable {
    var schemaVersion: Int
    var source: String
    var verifiedAgainst: String
    var actions: [CodexActionDefinition]
}

struct CodexActionCatalog {
    let document: CodexActionCatalogDocument
    /// Which app this catalog's shortcuts target; picks the `ActionKind`
    /// (`.codexShortcut`/`.claudeShortcut`, `.codexDeepLink`/`.claudeDeepLink`)
    /// resolved actions carry.
    let app: AutomationApp

    init(bundle: Bundle = .module, resourceName: String = "CodexActions", app: AutomationApp = .codex) {
        self.app = app
        guard
            let url = bundle.url(forResource: resourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let document = try? JSONDecoder().decode(CodexActionCatalogDocument.self, from: data)
        else {
            self.document = CodexActionCatalogDocument(schemaVersion: 0, source: "Unavailable", verifiedAgainst: "Unavailable", actions: [])
            return
        }
        self.document = document
    }

    var actions: [CodexActionDefinition] { document.actions }
    var categories: [String] { Array(Set(actions.map(\.category))).sorted() }

    func action(id: String) -> CodexActionDefinition? {
        actions.first(where: { $0.id == id })
    }

    func keyboardAction(id: String) -> KeyboardAction? {
        guard let action = action(id: id), action.isDirectlyAssignable else { return nil }
        return KeyboardAction(
            kind: app == .claude ? .claudeShortcut : .codexShortcut,
            label: action.title,
            icon: action.icon,
            deviceMacro: action.deviceMacro,
            codexActionID: action.id,
            deepLink: action.deepLink
        )
    }

    func deferredAction(id: String) -> KeyboardAction? {
        guard let action = action(id: id), action.execution == .deepLink, let deepLink = action.deepLink else { return nil }
        return KeyboardAction(kind: app == .claude ? .claudeDeepLink : .codexDeepLink, label: action.title, icon: action.icon, codexActionID: action.id, deepLink: deepLink)
    }
}
