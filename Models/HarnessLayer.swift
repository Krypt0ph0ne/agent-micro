import Foundation

/// A simple 8-bit RGB colour used for the whole-pad layer-switch cue.
struct RGBColor: Codable, Hashable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    /// Packs into a 24-bit integer for compact UserDefaults storage.
    var packed: Int { (Int(red) << 16) | (Int(green) << 8) | Int(blue) }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(packed: Int) {
        self.red = UInt8((packed >> 16) & 0xff)
        self.green = UInt8((packed >> 8) & 0xff)
        self.blue = UInt8(packed & 0xff)
    }
}

/// A coding-harness layer. CodexPad ships two: Codex and Claude Code. Each
/// layer is backed by a built-in profile of the same name; switching layers
/// swaps the active profile and shows a whole-pad colour cue.
enum HarnessLayer: String, CaseIterable, Codable, Identifiable, Hashable {
    case codex
    case claude

    var id: String { rawValue }

    /// The built-in profile name that stores this layer's bindings.
    var profileName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var icon: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        }
    }

    /// Default whole-pad cue colour: Codex dark blue, Claude deep orange.
    var defaultSwitchColor: RGBColor {
        switch self {
        case .codex: RGBColor(red: 10, green: 46, blue: 168)
        case .claude: RGBColor(red: 224, green: 82, blue: 8)
        }
    }

    var other: HarnessLayer {
        switch self {
        case .codex: .claude
        case .claude: .codex
        }
    }

    init?(profileName: String) {
        guard let match = HarnessLayer.allCases.first(where: { $0.profileName == profileName }) else { return nil }
        self = match
    }
}

/// How the whole-pad cue behaves after a layer switch.
enum LayerSwitchLightMode: String, CaseIterable, Codable, Identifiable, Hashable {
    /// Pulse once in the layer colour, then return to the normal idle/agent state.
    case pulseOnce
    /// Keep the layer colour lit as the idle base so the active layer stays visible.
    case persistent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pulseOnce: "Einmal aufpulsen"
        case .persistent: "Dauerhaft anzeigen"
        }
    }

    var detail: String {
        switch self {
        case .pulseOnce: "Alle LEDs pulsieren beim Umschalten einmal in der Layer-Farbe."
        case .persistent: "Die LEDs bleiben in der Layer-Farbe, damit der aktive Layer sichtbar ist."
        }
    }
}
