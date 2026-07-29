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
    case layerSwitch
    case profileSwitch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexAgent: "Codex Agent"
        case .codexShortcut: "Codex Shortcut"
        case .claudeAgent: "Claude Agent"
        case .claudeShortcut: "Claude Shortcut"
        case .keyboardShortcut: "macOS Shortcut"
        case .singleKey: AppLanguage.text("Einzelne Taste", "Single key")
        case .keySequence: AppLanguage.text("Tastensequenz / Makro", "Key sequence / macro")
        case .textSubmission: AppLanguage.text("Text absenden", "Submit text")
        case .media: AppLanguage.text("Mediensteuerung", "Media control")
        case .mouse: AppLanguage.text("Mausaktion", "Mouse action")
        case .disabled: AppLanguage.text("Deaktiviert", "Disabled")
        case .codexDeepLink: "Codex Deep Link"
        case .claudeDeepLink: "Claude Deep Link"
        case .localCommand: AppLanguage.text("Lokaler Befehl", "Local command")
        case .hostEvent: AppLanguage.text("Nur an Agent Micro melden", "Send to Agent Micro only")
        case .layerSwitch: AppLanguage.text("Layer wechseln", "Switch layer")
        case .profileSwitch: AppLanguage.text("Profil wechseln", "Switch profile")
        }
    }

    var isDirectlySupportedByDevice: Bool {
        switch self {
        case .codexAgent, .codexShortcut, .claudeAgent, .claudeShortcut, .keyboardShortcut, .singleKey, .keySequence, .textSubmission, .media, .mouse, .disabled, .hostEvent, .layerSwitch, .profileSwitch:
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

/// How an assigned `.layerSwitch` action picks its target layer.
enum LayerSwitchMode: String, Codable, CaseIterable, Identifiable {
    /// Every press advances to the next layer, wrapping back to the first.
    case cycle
    /// The number of rapid successive taps selects the layer directly
    /// (one tap = layer 1, two taps = layer 2, ...).
    case tapCount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cycle: AppLanguage.text("Zyklisch weiterschalten", "Cycle through layers")
        case .tapCount: AppLanguage.text("Klickanzahl = Layer-Nr.", "Tap count = layer number")
        }
    }

    var detail: String {
        switch self {
        case .cycle: AppLanguage.text("Jeder Druck springt zum nächsten Layer, danach wieder zu Layer 1.", "Each press advances to the next layer, then wraps back to layer 1.")
        case .tapCount: AppLanguage.text("Schnell hintereinander getippt: die Anzahl Klicks bestimmt den Ziel-Layer, z. B. 2× = Layer 2.", "Tap repeatedly: the number of taps selects the target layer, e.g. 2× = layer 2.")
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
    /// The literal text represented by a text-submission macro.
    var submittedText: String?
    var codexActionID: String?
    var deepLink: String?
    var command: String?
    /// Only set for `kind == .layerSwitch`.
    var layerSwitchMode: LayerSwitchMode?

    init(
        id: UUID = UUID(),
        kind: ActionKind,
        label: String,
        icon: String = "command",
        deviceMacro: String? = nil,
        submittedText: String? = nil,
        codexActionID: String? = nil,
        deepLink: String? = nil,
        command: String? = nil,
        layerSwitchMode: LayerSwitchMode? = nil
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
        self.layerSwitchMode = layerSwitchMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, icon, deviceMacro, submittedText, codexActionID, deepLink, command, layerSwitchMode
    }

    /// `id` was added after the first saved profiles shipped, so old
    /// `Profiles.json` files have no `id` key per action. Without this,
    /// synthesized `Decodable` would throw `keyNotFound` on every legacy
    /// action, and `ProfileStore` swallows that error and silently resets
    /// the whole file to factory defaults — wiping the user's key bindings.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(ActionKind.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "command"
        deviceMacro = try container.decodeIfPresent(String.self, forKey: .deviceMacro)
        submittedText = try container.decodeIfPresent(String.self, forKey: .submittedText)
        codexActionID = try container.decodeIfPresent(String.self, forKey: .codexActionID)
        deepLink = try container.decodeIfPresent(String.self, forKey: .deepLink)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        layerSwitchMode = try container.decodeIfPresent(LayerSwitchMode.self, forKey: .layerSwitchMode)
    }

    static let disabled = KeyboardAction(kind: .disabled, label: "Deaktiviert", icon: "minus.circle")

    /// Labels for built-in actions are stored in profiles for backwards
    /// compatibility, but must follow the current app language at display
    /// time. Custom action labels deliberately remain exactly as the user
    /// entered them.
    var displayLabel: String {
        return switch kind {
        case .disabled:
            AppLanguage.text("Deaktiviert", "Disabled")
        case .layerSwitch:
            layerSwitchMode?.title ?? AppLanguage.text("Layer wechseln", "Switch layer")
        case .profileSwitch:
            AppLanguage.text("Profil wechseln", "Switch profile")
        case .textSubmission:
            submittedText.map { AppLanguage.text("„\($0)“ absenden", "Submit “\($0)”") } ?? label
        default:
            label
        }
    }

    static func layerSwitch(mode: LayerSwitchMode) -> KeyboardAction {
        KeyboardAction(kind: .layerSwitch, label: mode.title, icon: "square.stack.3d.up", layerSwitchMode: mode)
    }

    /// Flips between the Codex and Claude built-in profiles — a plain
    /// assignable action like any other, no longer tied to a single
    /// permanently reserved key.
    static let profileSwitch = KeyboardAction(kind: .profileSwitch, label: "Profil wechseln", icon: "arrow.left.arrow.right")

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

    var isEnabled: Bool { kind == .hostEvent || kind == .layerSwitch || kind == .profileSwitch || kind.isAgent || (kind != .disabled && !(deviceMacro?.isEmpty ?? true)) }

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
