import Foundation

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case codexShortcut
    case keyboardShortcut
    case singleKey
    case keySequence
    case media
    case mouse
    case disabled
    case codexDeepLink
    case localCommand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexShortcut: "Codex Shortcut"
        case .keyboardShortcut: "macOS Shortcut"
        case .singleKey: "Einzelne Taste"
        case .keySequence: "Tastensequenz / Makro"
        case .media: "Mediensteuerung"
        case .mouse: "Mausaktion"
        case .disabled: "Deaktiviert"
        case .codexDeepLink: "Codex Deep Link"
        case .localCommand: "Lokaler Befehl"
        }
    }

    var isDirectlySupportedByDevice: Bool {
        switch self {
        case .codexShortcut, .keyboardShortcut, .singleKey, .keySequence, .media, .mouse, .disabled:
            true
        case .codexDeepLink, .localCommand:
            false
        }
    }
}

struct KeyboardAction: Codable, Hashable, Identifiable {
    var id: UUID
    var kind: ActionKind
    var label: String
    var icon: String
    /// A verified ch57x-keyboard-tool action expression, e.g. "cmd-shift-p".
    var deviceMacro: String?
    var codexActionID: String?
    var deepLink: String?
    var command: String?

    init(
        id: UUID = UUID(),
        kind: ActionKind,
        label: String,
        icon: String = "command",
        deviceMacro: String? = nil,
        codexActionID: String? = nil,
        deepLink: String? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.icon = icon
        self.deviceMacro = deviceMacro
        self.codexActionID = codexActionID
        self.deepLink = deepLink
        self.command = command
    }

    static let disabled = KeyboardAction(kind: .disabled, label: "Deaktiviert", icon: "minus.circle")

    var isEnabled: Bool { kind != .disabled && !(deviceMacro?.isEmpty ?? true) }

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
