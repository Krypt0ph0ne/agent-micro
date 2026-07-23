import Foundation

struct ControlBinding: Codable, Hashable, Identifiable {
    /// Sensible default before a hold registers, tuned so a deliberate press is
    /// distinguished from a quick tap without feeling sluggish.
    static let defaultHoldThresholdMilliseconds = 320
    static let holdThresholdRange = 200...800

    var control: HardwareControl
    var action: KeyboardAction
    /// Optional second function fired when the key is held past the threshold.
    /// When present, the control is driven by CodexPad (app-only) instead of the
    /// firmware, so the tap and the hold action can differ.
    var holdAction: KeyboardAction?
    var holdThresholdMilliseconds: Int?

    var id: HardwareControl { control }

    /// A binding runs in tap-vs-hold mode only when the hold slot is filled with
    /// an enabled action.
    var isTapHold: Bool { holdAction?.isEnabled == true }

    var resolvedHoldThresholdMilliseconds: Int {
        holdThresholdMilliseconds ?? Self.defaultHoldThresholdMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case control, action, holdAction, holdThresholdMilliseconds
    }

    init(
        control: HardwareControl,
        action: KeyboardAction,
        holdAction: KeyboardAction? = nil,
        holdThresholdMilliseconds: Int? = nil
    ) {
        self.control = control
        self.action = action
        self.holdAction = holdAction
        self.holdThresholdMilliseconds = holdThresholdMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        control = try container.decode(HardwareControl.self, forKey: .control)
        action = try container.decode(KeyboardAction.self, forKey: .action)
        holdAction = try container.decodeIfPresent(KeyboardAction.self, forKey: .holdAction)
        holdThresholdMilliseconds = try container.decodeIfPresent(Int.self, forKey: .holdThresholdMilliseconds)
    }
}

enum LEDEffect: UInt8, Codable, CaseIterable, Identifiable, Hashable {
    case off = 0
    case steady = 1
    case blink = 2
    case pulse = 3

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .off: "Aus"
        case .steady: "Dauerlicht"
        case .blink: "Blinken"
        case .pulse: "Pulsieren"
        }
    }
}

enum LEDReactionEvent: String, Codable, CaseIterable, Identifiable, Hashable {
    case dictation
    case messageSent
    case threadAssigned
    case approvalAccepted
    case approvalDeclined
    case agentRunning
    case agentIdle
    case agentCompleted
    case agentNeedsAttention
    case agentFailed
    case agentInterrupted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Diktat halten"
        case .messageSent: "Nachricht gesendet"
        case .threadAssigned: "Thread zugewiesen"
        case .approvalAccepted: "Genehmigt"
        case .approvalDeclined: "Abgelehnt"
        case .agentRunning: "Agent läuft"
        case .agentIdle: "Agent frei"
        case .agentCompleted: "Agent fertig"
        case .agentNeedsAttention: "Eingabe erforderlich"
        case .agentFailed: "Agent fehlgeschlagen"
        case .agentInterrupted: "Agent unterbrochen"
        }
    }

    var detail: String {
        switch self {
        case .dictation: "Solange die Taste gedrückt ist"
        case .messageSent: "Kurzes Feedback beim Senden"
        case .threadAssigned: "Kurzes Feedback nach Halten-zum-Zuweisen"
        case .approvalAccepted: "Nach Bestätigen einer Anfrage"
        case .approvalDeclined: "Nach Ablehnen einer Anfrage"
        case .agentRunning: "Während ein Thread arbeitet"
        case .agentIdle: "Zugewiesener Thread ohne offene Aufgabe"
        case .agentCompleted: "Wenn ein Thread abschließt"
        case .agentNeedsAttention: "Agent wartet auf dich"
        case .agentFailed: "Thread mit Fehler beendet"
        case .agentInterrupted: "Thread wurde gestoppt"
        }
    }

    var isAgentEvent: Bool {
        switch self {
        case .agentRunning, .agentIdle, .agentCompleted, .agentNeedsAttention, .agentFailed, .agentInterrupted:
            true
        case .dictation, .messageSent, .threadAssigned, .approvalAccepted, .approvalDeclined:
            false
        }
    }

    static func event(for status: CodexAgentStatus) -> LEDReactionEvent? {
        switch status {
        case .running: .agentRunning
        case .idle: .agentIdle
        case .needsAttention: .agentNeedsAttention
        case .completed: .agentCompleted
        case .failed: .agentFailed
        case .interrupted: .agentInterrupted
        case .unassigned: nil
        }
    }
}

enum LEDReactionEffect: String, Codable, CaseIterable, Identifiable, Hashable {
    case off, steady, blink, pulse, flash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Aus"
        case .steady: "An"
        case .blink: "Blinken"
        case .pulse: "Pulsieren"
        case .flash: "Einmal"
        }
    }

    var firmwareEffect: LEDEffect {
        switch self {
        case .off: .off
        case .steady, .flash: .steady
        case .blink: .blink
        case .pulse: .pulse
        }
    }
}

struct LEDReactionConfiguration: Codable, Hashable, Identifiable {
    var event: LEDReactionEvent
    var effect: LEDReactionEffect
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var brightness: UInt8
    var periodMilliseconds: Int
    /// When this agent status is active, suppress the otherwise ambient idle
    /// lighting so the status indication has the pad's full attention.
    var disablesIdle: Bool
    /// Floor for a "Pulsieren" effect, so it breathes between `minBrightness`
    /// and `brightness` instead of the firmware's native 0→`brightness`
    /// sweep. Zero (the default) reproduces the classic firmware-native pulse
    /// exactly. See `KeyLEDConfiguration.isRangePulse`.
    var minBrightness: UInt8

    var id: LEDReactionEvent { event }

    func keyConfiguration(for control: HardwareControl) -> KeyLEDConfiguration {
        KeyLEDConfiguration(
            control: control,
            effect: effect.firmwareEffect,
            red: red,
            green: green,
            blue: blue,
            brightness: brightness,
            periodMilliseconds: periodMilliseconds,
            minBrightness: minBrightness
        )
    }

    static let defaults: [LEDReactionConfiguration] = [
        .init(event: .dictation, effect: .steady, red: 255, green: 255, blue: 255, brightness: 255, periodMilliseconds: 900, disablesIdle: false),
        .init(event: .messageSent, effect: .flash, red: 255, green: 69, blue: 58, brightness: 255, periodMilliseconds: 450, disablesIdle: false),
        .init(event: .threadAssigned, effect: .flash, red: 48, green: 209, blue: 88, brightness: 255, periodMilliseconds: 450, disablesIdle: false),
        .init(event: .approvalAccepted, effect: .flash, red: 48, green: 209, blue: 88, brightness: 255, periodMilliseconds: 450, disablesIdle: false),
        .init(event: .approvalDeclined, effect: .flash, red: 255, green: 69, blue: 58, brightness: 255, periodMilliseconds: 450, disablesIdle: false),
        .init(event: .agentRunning, effect: .pulse, red: 10, green: 132, blue: 255, brightness: 255, periodMilliseconds: 1_000, disablesIdle: true),
        .init(event: .agentIdle, effect: .pulse, red: 48, green: 209, blue: 88, brightness: 180, periodMilliseconds: 2_200, disablesIdle: true, minBrightness: 40),
        .init(event: .agentCompleted, effect: .flash, red: 48, green: 209, blue: 88, brightness: 230, periodMilliseconds: 650, disablesIdle: true),
        .init(event: .agentNeedsAttention, effect: .blink, red: 255, green: 159, blue: 10, brightness: 255, periodMilliseconds: 800, disablesIdle: true),
        .init(event: .agentFailed, effect: .blink, red: 255, green: 69, blue: 58, brightness: 255, periodMilliseconds: 500, disablesIdle: true),
        .init(event: .agentInterrupted, effect: .steady, red: 191, green: 90, blue: 242, brightness: 220, periodMilliseconds: 1_000, disablesIdle: true)
    ]

    private enum CodingKeys: String, CodingKey {
        case event, effect, red, green, blue, brightness, periodMilliseconds, disablesIdle, minBrightness
    }

    init(
        event: LEDReactionEvent,
        effect: LEDReactionEffect,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        periodMilliseconds: Int,
        disablesIdle: Bool = false,
        minBrightness: UInt8 = 0
    ) {
        self.event = event
        self.effect = effect
        self.red = red
        self.green = green
        self.blue = blue
        self.brightness = brightness
        self.periodMilliseconds = periodMilliseconds
        self.disablesIdle = disablesIdle
        self.minBrightness = minBrightness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(LEDReactionEvent.self, forKey: .event)
        effect = try container.decode(LEDReactionEffect.self, forKey: .effect)
        red = try container.decode(UInt8.self, forKey: .red)
        green = try container.decode(UInt8.self, forKey: .green)
        blue = try container.decode(UInt8.self, forKey: .blue)
        brightness = try container.decode(UInt8.self, forKey: .brightness)
        periodMilliseconds = try container.decode(Int.self, forKey: .periodMilliseconds)
        disablesIdle = try container.decodeIfPresent(Bool.self, forKey: .disablesIdle)
            ?? event.isAgentEvent
        minBrightness = try container.decodeIfPresent(UInt8.self, forKey: .minBrightness) ?? 0
    }
}

/// The base ("Grundlicht") layer: how the pad looks at rest, before any
/// event reaction is layered on top. `perKey` switches between a single colour
/// for all keys (stored here) and individual per-key colours (stored in the
/// profile's `led` configuration).
struct IdleLEDConfiguration: Codable, Hashable {
    var enabled: Bool
    var perKey: Bool
    var effect: LEDEffect
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var brightness: UInt8
    var periodMilliseconds: Int
    /// Floor for a "Pulsieren" effect. See `KeyLEDConfiguration.isRangePulse`.
    var minBrightness: UInt8

    static let `default` = IdleLEDConfiguration(
        enabled: true,
        perKey: false,
        effect: .steady,
        red: 255,
        green: 255,
        blue: 255,
        brightness: 96,
        periodMilliseconds: 1_000
    )

    /// The single-colour base applied to every key when `perKey` is off.
    func keyConfiguration(for control: HardwareControl) -> KeyLEDConfiguration {
        KeyLEDConfiguration(
            control: control,
            effect: enabled ? effect : .off,
            red: red,
            green: green,
            blue: blue,
            brightness: brightness,
            periodMilliseconds: periodMilliseconds,
            minBrightness: minBrightness
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, perKey, effect, red, green, blue, brightness, periodMilliseconds, minBrightness
    }

    init(
        enabled: Bool,
        perKey: Bool = false,
        effect: LEDEffect,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        periodMilliseconds: Int,
        minBrightness: UInt8 = 0
    ) {
        self.enabled = enabled
        self.perKey = perKey
        self.effect = effect
        self.red = red
        self.green = green
        self.blue = blue
        self.brightness = brightness
        self.periodMilliseconds = periodMilliseconds
        self.minBrightness = minBrightness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        perKey = try container.decodeIfPresent(Bool.self, forKey: .perKey) ?? false
        effect = try container.decode(LEDEffect.self, forKey: .effect)
        red = try container.decode(UInt8.self, forKey: .red)
        green = try container.decode(UInt8.self, forKey: .green)
        blue = try container.decode(UInt8.self, forKey: .blue)
        brightness = try container.decode(UInt8.self, forKey: .brightness)
        periodMilliseconds = try container.decode(Int.self, forKey: .periodMilliseconds)
        minBrightness = try container.decodeIfPresent(UInt8.self, forKey: .minBrightness) ?? 0
    }
}

struct KeyLEDConfiguration: Codable, Hashable, Identifiable {
    var control: HardwareControl
    var effect: LEDEffect
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var brightness: UInt8
    var periodMilliseconds: Int
    /// Floor for a "Pulsieren" effect, breathing between `minBrightness` and
    /// `brightness` rather than the CH552 firmware's native 0→`brightness`
    /// sweep. Zero (the default) is the classic firmware-native pulse.
    var minBrightness: UInt8

    var id: HardwareControl { control }

    /// True when this key should breathe within a host-managed brightness
    /// range. The firmware has no concept of a pulse floor, so whenever this
    /// is true `CodexPadLEDFeedbackService` must animate it itself instead of
    /// handing the effect off to the device. A degenerate range (min ≥ max)
    /// is treated as a plain pulse, so the default `minBrightness == 0`
    /// reproduces the original firmware-native behaviour exactly.
    var isRangePulse: Bool {
        effect == .pulse && minBrightness > 0 && minBrightness < brightness
    }

    static func steadyWhite(for control: HardwareControl) -> KeyLEDConfiguration {
        KeyLEDConfiguration(
            control: control,
            effect: .steady,
            red: 255,
            green: 255,
            blue: 255,
            brightness: 96,
            periodMilliseconds: 1_000
        )
    }

    private enum CodingKeys: String, CodingKey {
        case control, effect, red, green, blue, brightness, periodMilliseconds, minBrightness
    }

    init(
        control: HardwareControl,
        effect: LEDEffect,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        periodMilliseconds: Int,
        minBrightness: UInt8 = 0
    ) {
        self.control = control
        self.effect = effect
        self.red = red
        self.green = green
        self.blue = blue
        self.brightness = brightness
        self.periodMilliseconds = periodMilliseconds
        self.minBrightness = minBrightness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        control = try container.decode(HardwareControl.self, forKey: .control)
        effect = try container.decode(LEDEffect.self, forKey: .effect)
        red = try container.decode(UInt8.self, forKey: .red)
        green = try container.decode(UInt8.self, forKey: .green)
        blue = try container.decode(UInt8.self, forKey: .blue)
        brightness = try container.decode(UInt8.self, forKey: .brightness)
        periodMilliseconds = try container.decode(Int.self, forKey: .periodMilliseconds)
        minBrightness = try container.decodeIfPresent(UInt8.self, forKey: .minBrightness) ?? 0
    }
}

struct LEDConfiguration: Codable, Hashable {
    /// Legacy CH57x fields remain decodable for existing saved profiles.
    var enabled: Bool
    var mode: Int
    var keys: [KeyLEDConfiguration]

    static let confirmedSteady = LEDConfiguration(
        enabled: true,
        mode: 1,
        keys: HardwareControl.buttons.map(KeyLEDConfiguration.steadyWhite)
    )

    func setting(for control: HardwareControl) -> KeyLEDConfiguration {
        keys.first(where: { $0.control == control }) ?? .steadyWhite(for: control)
    }

    mutating func setSetting(_ setting: KeyLEDConfiguration) {
        guard HardwareControl.buttons.contains(setting.control) else { return }
        if let index = keys.firstIndex(where: { $0.control == setting.control }) {
            keys[index] = setting
        } else {
            keys.append(setting)
        }
    }

    private enum CodingKeys: String, CodingKey { case enabled, mode, keys }

    init(enabled: Bool, mode: Int, keys: [KeyLEDConfiguration]) {
        self.enabled = enabled
        self.mode = mode
        self.keys = keys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = try container.decodeIfPresent(Int.self, forKey: .mode) ?? 1
        keys = try container.decodeIfPresent([KeyLEDConfiguration].self, forKey: .keys)
            ?? HardwareControl.buttons.map(KeyLEDConfiguration.steadyWhite)
    }
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
    var idleLighting: IdleLEDConfiguration
    var ledReactions: [LEDReactionConfiguration]
    var isBuiltIn: Bool
    /// Which external app this profile's shortcuts/encoder/agent bridge
    /// target. `nil` for app-agnostic profiles (macOS, Safe, Factory-like C).
    var automationApp: AutomationApp?

    init(
        formatVersion: Int = currentFormatVersion,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        controls: [ControlBinding],
        led: LEDConfiguration = .confirmedSteady,
        idleLighting: IdleLEDConfiguration = .default,
        ledReactions: [LEDReactionConfiguration] = LEDReactionConfiguration.defaults,
        isBuiltIn: Bool = false,
        automationApp: AutomationApp? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.controls = controls
        self.led = led
        self.idleLighting = idleLighting
        self.ledReactions = ledReactions
        self.isBuiltIn = isBuiltIn
        self.automationApp = automationApp
    }

    func action(for control: HardwareControl) -> KeyboardAction {
        controls.first(where: { $0.control == control })?.action ?? .disabled
    }

    func binding(for control: HardwareControl) -> ControlBinding {
        controls.first(where: { $0.control == control }) ?? ControlBinding(control: control, action: .disabled)
    }

    func holdAction(for control: HardwareControl) -> KeyboardAction? {
        binding(for: control).holdAction
    }

    mutating func setAction(_ action: KeyboardAction, for control: HardwareControl) {
        if let index = controls.firstIndex(where: { $0.control == control }) {
            controls[index].action = action
        } else {
            controls.append(ControlBinding(control: control, action: action))
        }
        updatedAt = .now
    }

    /// Sets or clears the hold slot. Passing `nil` turns the control back into a
    /// plain single-function binding and drops any stored threshold.
    mutating func setHoldAction(_ action: KeyboardAction?, thresholdMilliseconds: Int? = nil, for control: HardwareControl) {
        if let index = controls.firstIndex(where: { $0.control == control }) {
            controls[index].holdAction = action
            controls[index].holdThresholdMilliseconds = action == nil ? nil : thresholdMilliseconds
        } else {
            controls.append(ControlBinding(
                control: control,
                action: .disabled,
                holdAction: action,
                holdThresholdMilliseconds: action == nil ? nil : thresholdMilliseconds
            ))
        }
        updatedAt = .now
    }

    func reaction(for event: LEDReactionEvent) -> LEDReactionConfiguration {
        ledReactions.first(where: { $0.event == event })
            ?? LEDReactionConfiguration.defaults.first(where: { $0.event == event })!
    }

    /// The resting ("Grundlicht") appearance for a key, honouring the per-key
    /// vs. single-colour base mode. Agent-status idle suppression is applied
    /// separately by the live feedback service.
    func baseLighting(for control: HardwareControl) -> KeyLEDConfiguration {
        guard idleLighting.enabled else {
            return KeyLEDConfiguration(
                control: control, effect: .off, red: 0, green: 0, blue: 0,
                brightness: 0, periodMilliseconds: idleLighting.periodMilliseconds
            )
        }
        return idleLighting.perKey
            ? led.setting(for: control)
            : idleLighting.keyConfiguration(for: control)
    }

    mutating func setReaction(_ reaction: LEDReactionConfiguration) {
        if let index = ledReactions.firstIndex(where: { $0.event == reaction.event }) {
            ledReactions[index] = reaction
        } else {
            ledReactions.append(reaction)
        }
        updatedAt = .now
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, createdAt, updatedAt, controls, led, idleLighting, ledReactions, isBuiltIn, automationApp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        controls = try container.decode([ControlBinding].self, forKey: .controls)
        led = try container.decodeIfPresent(LEDConfiguration.self, forKey: .led) ?? .confirmedSteady
        idleLighting = try container.decodeIfPresent(IdleLEDConfiguration.self, forKey: .idleLighting) ?? .default
        ledReactions = try container.decodeIfPresent([LEDReactionConfiguration].self, forKey: .ledReactions)
            ?? LEDReactionConfiguration.defaults
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        automationApp = try container.decodeIfPresent(AutomationApp.self, forKey: .automationApp)
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
            isBuiltIn: true,
            automationApp: .codex
        )
        profile.setAction(reasoningTriggerAction(for: .encoderLeft), for: .encoderLeft)
        profile.setAction(reasoningTriggerAction(for: .encoderPress), for: .encoderPress)
        profile.setAction(reasoningTriggerAction(for: .encoderRight), for: .encoderRight)
        return profile
    }

    static func claude(catalog: CodexActionCatalog) -> MacropadProfile {
        let assignments: [(HardwareControl, String)] = [
            (.key1, "previous-session"), (.key2, "toggle-diff"), (.key3, "next-session"),
            (.key4, "dictation"), (.key5, "new-session"), (.key6, "toggle-terminal"),
            (.encoderLeft, "open-effort-menu"), (.encoderPress, "open-model-menu"), (.encoderRight, "open-effort-menu")
        ]
        var profile = MacropadProfile(
            name: "Claude",
            controls: assignments.map { control, actionID in
                ControlBinding(control: control, action: catalog.keyboardAction(id: actionID) ?? .disabled)
            },
            isBuiltIn: true,
            automationApp: .claude
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

    /// F22/F23/F24 are private triggers with no built-in Codex meaning, so the
    /// firmware never bypasses CodexPad here: every rotate and press edge
    /// reaches `CodexReasoningAutomationService`, which then decides whether
    /// to emit the direct F18/F19 reasoning shortcuts or (in model-list
    /// navigation mode) arrow-key menu navigation.
    static func reasoningTriggerAction(for control: HardwareControl) -> KeyboardAction {
        switch control {
        case .encoderLeft:
            KeyboardAction(kind: .singleKey, label: "Aufwand −", icon: "minus.circle", deviceMacro: "f22", codexActionID: "encoder-effort-decrease")
        case .encoderPress:
            KeyboardAction(kind: .singleKey, label: "Modellwahl umschalten", icon: "cube", deviceMacro: "f23", codexActionID: "encoder-model-modifier")
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
