import Foundation

struct ControlBinding: Codable, Hashable, Identifiable {
    var control: HardwareControl
    var action: KeyboardAction

    var id: HardwareControl { control }
}

struct LEDConfiguration: Codable, Hashable {
    /// Only mode 1 is confirmed for the connected 0x8890 family.
    var enabled: Bool
    var mode: Int

    static let confirmedSteady = LEDConfiguration(enabled: true, mode: 1)
}

struct MacropadProfile: Codable, Hashable, Identifiable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var controls: [ControlBinding]
    var led: LEDConfiguration
    var isBuiltIn: Bool

    init(
        formatVersion: Int = currentFormatVersion,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        controls: [ControlBinding],
        led: LEDConfiguration = .confirmedSteady,
        isBuiltIn: Bool = false
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.controls = controls
        self.led = led
        self.isBuiltIn = isBuiltIn
    }

    func action(for control: HardwareControl) -> KeyboardAction {
        controls.first(where: { $0.control == control })?.action ?? .disabled
    }

    mutating func setAction(_ action: KeyboardAction, for control: HardwareControl) {
        if let index = controls.firstIndex(where: { $0.control == control }) {
            controls[index].action = action
        } else {
            controls.append(ControlBinding(control: control, action: action))
        }
        updatedAt = .now
    }
}

enum ProfileFactory {
    static func codex(catalog: CodexActionCatalog) -> MacropadProfile {
        let assignments: [(HardwareControl, String)] = [
            (.key1, "previous-chat"), (.key2, "quick-chat"), (.key3, "next-chat"),
            (.key4, "dictation"), (.key5, "new-chat"), (.key6, "open-review-tab"),
            (.encoderLeft, "reasoning-decrease"), (.encoderPress, "open-model-picker"), (.encoderRight, "reasoning-increase")
        ]
        var profile = MacropadProfile(
            name: "Codex",
            controls: assignments.map { control, actionID in
                ControlBinding(control: control, action: catalog.keyboardAction(id: actionID) ?? .disabled)
            },
            isBuiltIn: true
        )
        profile.setAction(reasoningTriggerAction(for: .encoderLeft), for: .encoderLeft)
        profile.setAction(reasoningTriggerAction(for: .encoderPress), for: .encoderPress)
        profile.setAction(reasoningTriggerAction(for: .encoderRight), for: .encoderRight)
        return profile
    }

    static func safe() -> MacropadProfile {
        let controls = zip(HardwareControl.allCases, ["f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21"])
            .map { control, key in
                ControlBinding(
                    control: control,
                    action: KeyboardAction(kind: .singleKey, label: key.uppercased(), icon: "keyboard", deviceMacro: key)
                )
            }
        return MacropadProfile(name: "Sichere F13–F21-Belegung", controls: controls)
    }

    static func macOS() -> MacropadProfile {
        let values: [(HardwareControl, String, String)] = [
            (.key1, "Kopieren", "cmd-c"), (.key2, "Einfügen", "cmd-v"), (.key3, "Rückgängig", "cmd-z"),
            (.key4, "Alles auswählen", "cmd-a"), (.key5, "Suchen", "cmd-f"), (.key6, "Sichern", "cmd-s"),
            (.encoderLeft, "Lautstärke −", "volumedown"), (.encoderPress, "Stumm", "mute"), (.encoderRight, "Lautstärke +", "volumeup")
        ]
        return MacropadProfile(
            name: "macOS",
            controls: values.map { control, label, macro in
                let kind: ActionKind = ["volumedown", "mute", "volumeup"].contains(macro) ? .media : .keyboardShortcut
                return ControlBinding(control: control, action: KeyboardAction(kind: kind, label: label, icon: "command", deviceMacro: macro))
            },
            isBuiltIn: true
        )
    }

    /// Fixed private triggers for normal rotation plus held-button rotation.
    static func codexReasoningTriggers(catalog: CodexActionCatalog) -> MacropadProfile {
        var profile = codex(catalog: catalog)
        profile.name = "Codex · Reasoning triggers"
        return profile
    }

    static func reasoningTriggerAction(for control: HardwareControl) -> KeyboardAction {
        switch control {
        case .encoderLeft:
            KeyboardAction(kind: .singleKey, label: "Aufwand −", icon: "minus.circle", deviceMacro: "f22", codexActionID: "encoder-effort-decrease")
        case .encoderPress:
            KeyboardAction(kind: .singleKey, label: "Halten: Modellwahl", icon: "cube", deviceMacro: "f23", codexActionID: "encoder-model-modifier")
        case .encoderRight:
            KeyboardAction(kind: .singleKey, label: "Aufwand +", icon: "plus.circle", deviceMacro: "f24", codexActionID: "encoder-effort-increase")
        case .key1, .key2, .key3, .key4, .key5, .key6:
            .disabled
        }
    }

    static func factoryLikeC() -> MacropadProfile {
        MacropadProfile(
            name: "Factory-like C mapping",
            controls: HardwareControl.allCases.map {
                ControlBinding(control: $0, action: KeyboardAction(kind: .singleKey, label: "C (approximativ)", icon: "c.circle", deviceMacro: "c"))
            }
        )
    }
}
