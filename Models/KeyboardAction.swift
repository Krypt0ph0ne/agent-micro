import Foundation

/// Which half of a tap-vs-hold binding an action gets written to. Tap and hold
/// share the same catalog of assignable actions, this only picks the target.
enum ActionSlot {
    case tap
    case hold
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case codexAgent
    case codexShortcut
    case claudeAgent
    case claudeShortcut
    case keyboardShortcut
    case singleKey
    case keySequence
    case textSubmission
    case media
    case mouse
    case disabled
    case codexDeepLink
    case claudeDeepLink
    case localCommand
    case hostEvent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexAgent: "Codex Agent"
        case .codexShortcut: "Codex Shortcut"
        case .claudeAgent: "Claude Agent"
        case .claudeShortcut: "Claude Shortcut"
        case .keyboardShortcut: "macOS Shortcut"
        case .singleKey: "Einzelne Taste"
        case .keySequence: "Tastensequenz / Makro"
        case .textSubmission: "Text absenden"
        case .media: "Mediensteuerung"
        case .mouse: "Mausaktion"
        case .disabled: "Deaktiviert"
        case .codexDeepLink: "Codex Deep Link"
        case .claudeDeepLink: "Claude Deep Link"
        case .localCommand: "Lokaler Befehl"
        case .hostEvent: "Nur an CodexPad melden"
        }
    }

    var isDirectlySupportedByDevice: Bool {
        switch self {
        case .codexAgent, .codexShortcut, .claudeAgent, .claudeShortcut, .keyboardShortcut, .singleKey, .keySequence, .textSubmission, .media, .mouse, .disabled, .hostEvent:
            true
        case .codexDeepLink, .claudeDeepLink, .localCommand:
            false
        }
    }

    /// True for a shortcut resolved against either app's action catalog, so UI
    /// that only cares "is this a catalog-backed shortcut" doesn't need to
    /// enumerate both apps.
    var isAppShortcut: Bool { self == .codexShortcut || self == .claudeShortcut }

    var isAppDeepLink: Bool { self == .codexDeepLink || self == .claudeDeepLink }

    var isAgent: Bool { self == .codexAgent || self == .claudeAgent }
}

struct KeyboardAction: Codable, Hashable, Identifiable {
    var id: UUID
    var kind: ActionKind
    var label: String
    var icon: String
    /// A verified ch57x-keyboard-tool action expression, e.g. "cmd-shift-p".
    var deviceMacro: String?
    /// The literal text represented by a text-submission macro.
    var submittedText: String?
    var codexActionID: String?
    var deepLink: String?
    var command: String?

    init(
        id: UUID = UUID(),
        kind: ActionKind,
        label: String,
        icon: String = "command",
        deviceMacro: String? = nil,
        submittedText: String? = nil,
        codexActionID: String? = nil,
        deepLink: String? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.icon = icon
        self.deviceMacro = deviceMacro
        self.submittedText = submittedText
        self.codexActionID = codexActionID
        self.deepLink = deepLink
        self.command = command
    }

    static let disabled = KeyboardAction(kind: .disabled, label: "Deaktiviert", icon: "minus.circle")

    /// Creates a hardware-compatible text action. The CH57x can send at most
    /// five chords, so the text is limited to four ASCII letters or digits plus Enter.
    static func textSubmission(_ text: String) -> KeyboardAction? {
        guard let macro = TextSubmissionMacro.macro(for: text) else { return nil }
        return KeyboardAction(
            kind: .textSubmission,
            label: "„\(text)“ absenden",
            icon: "paperplane.fill",
            deviceMacro: macro,
            submittedText: text
        )
    }

    var isEnabled: Bool { kind == .hostEvent || kind.isAgent || (kind != .disabled && !(deviceMacro?.isEmpty ?? true)) }

    var displayShortcut: String {
        guard let deviceMacro, !deviceMacro.isEmpty else { return "—" }
        return deviceMacro
            .replacingOccurrences(of: "cmd", with: "⌘")
            .replacingOccurrences(of: "opt", with: "⌥")
            .replacingOccurrences(of: "alt", with: "⌥")
            .replacingOccurrences(of: "ctrl", with: "⌃")
            .replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
    }
}

enum TextSubmissionMacro {
    static let maximumTextLength = 4

    static func macro(for text: String) -> String? {
        guard !text.isEmpty, text.count <= maximumTextLength else { return nil }
        let keys = text.compactMap(keyExpression(for:))
        guard keys.count == text.count else { return nil }
        return (keys + ["enter"]).joined(separator: ",")
    }

    private static func keyExpression(for character: Character) -> String? {
        guard character.isASCII, character.isLetter || character.isNumber else { return nil }
        let key = String(character).lowercased()
        return character.isUppercase ? "shift-\(key)" : key
    }
}
