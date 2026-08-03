import Foundation

enum CodexActionExecution: String, Codable, Hashable {
    case keyboardShortcut
    case configurableShortcut
    case deepLink
    case unavailable
    /// Answers something Agent Micro itself is tracking (e.g. a pending
    /// approval) — reported to the app only, no keyboard macro sent.
    case hostEvent

    var title: String {
        switch self {
        case .keyboardShortcut: AppLanguage.text("Direkter Shortcut", "Direct shortcut")
        case .configurableShortcut: AppLanguage.text("In Codex konfigurierbar", "Configurable in Codex")
        case .deepLink: "Codex Deep Link"
        case .unavailable: AppLanguage.text("Nicht stabil verfügbar", "Not reliably available")
        case .hostEvent: AppLanguage.text("Nur an Agent Micro melden", "Send to Agent Micro only")
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
    /// trigger which Codex can bind in its Keyboard Shortcuts settings. A
    /// host event needs no macro at all — it's answered entirely in-app.
    var isDirectlyAssignable: Bool {
        execution == .hostEvent || ((execution == .keyboardShortcut || execution == .configurableShortcut) && deviceMacro != nil)
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

    /// The catalog JSON ships its user-facing text in German (see
    /// `Resources/CodexActions.json` and `Resources/ClaudeActions.json`). This
    /// is the single place that text is translated: every read path —
    /// `actions`, `categories`, `action(id:)` and the `KeyboardAction`s derived
    /// from them — goes through here, so anything that groups, sorts or
    /// filters by `category` keeps comparing like with like.
    ///
    /// Only the four display fields are touched; `id`, `icon`, `shortcut`,
    /// `deviceMacro`, `deepLink`, `modifiers`, `execution` and `compatibleWith`
    /// stay exactly as decoded. Translating on read rather than once at decode
    /// time means switching the app language takes effect immediately, without
    /// rebuilding the catalog.
    private static func localized(_ action: CodexActionDefinition) -> CodexActionDefinition {
        var localized = action
        localized.title = AppLanguage.localized(action.title)
        localized.description = AppLanguage.localized(action.description)
        localized.category = AppLanguage.localized(action.category)
        localized.availabilityNote = action.availabilityNote.map(AppLanguage.localized)
        // Most shortcuts are pure key symbols, but a few spell out a gesture
        // ("⌘F17 halten"), so they need the same treatment.
        localized.shortcut = action.shortcut.map(AppLanguage.localized)
        return localized
    }

    var actions: [CodexActionDefinition] { document.actions.map(Self.localized) }
    var categories: [String] { Array(Set(actions.map(\.category))).sorted() }

    func action(id: String) -> CodexActionDefinition? {
        document.actions.first(where: { $0.id == id }).map(Self.localized)
    }

    func keyboardAction(id: String) -> KeyboardAction? {
        guard let action = action(id: id), action.isDirectlyAssignable else { return nil }
        if action.execution == .hostEvent {
            return KeyboardAction(kind: .hostEvent, label: action.title, icon: action.icon, codexActionID: action.id)
        }
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
