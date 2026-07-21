import Foundation

enum CodexPadPacketError: LocalizedError, Equatable {
    case unsupportedAction(HardwareControl, String)
    case invalidMacro(HardwareControl, String)
    case tooManySteps(HardwareControl)

    var errorDescription: String? {
        switch self {
        case .unsupportedAction(let control, let value):
            "\(control.title) wird von der CH552-Firmware noch nicht direkt unterstützt: \(value)"
        case .invalidMacro(let control, let value):
            "Ungültiger Geräteausdruck für \(control.title): \(value)"
        case .tooManySteps(let control):
            "\(control.title) enthält mehr als fünf Tastenschritte."
        }
    }
}

struct CodexPadPacketEncoder {
    static let packetSize = 32

    func packets(profile: MacropadProfile, layout: KeyboardLayout = .usANSI) throws -> [[UInt8]] {
        try HardwareControl.allCases.map { control -> [UInt8] in
            let binding = profile.binding(for: control)
            // Tap-vs-hold controls are driven by CodexPad: the firmware only
            // reports the physical edges while the app synthesizes the resolved
            // tap or hold action, so nothing is bound on the device itself.
            if binding.isTapHold {
                return appOnlyPacket(control: control)
            }
            return try bindingPacket(action: binding.action, control: control, layout: layout)
        }
        + HardwareControl.buttons.map { ledPacket(setting: profile.led.setting(for: $0)) }
    }

    /// Binds a control to the app-only mode (`mode 3`): the pad reports key-down
    /// and key-up but emits no HID macro of its own.
    func appOnlyPacket(control: HardwareControl) -> [UInt8] {
        var packet = base(command: 0x20)
        packet[4] = control.firmwareControlIndex
        packet[5] = 3
        return finalized(packet)
    }

    /// Full transfer sequence. Idle packets deliberately come last so the
    /// board enters the configured resting state as soon as upload completes.
    ///
    /// A range-limited pulse (`KeyLEDConfiguration.isRangePulse`) has no
    /// firmware representation — the packet format has no floor byte, and
    /// `ledPacket` simply writes the plain `.pulse` effect. The persisted,
    /// flashed baseline therefore falls back to a classic 0→brightness pulse;
    /// the configured floor only actually breathes while CodexPad is running
    /// and driving it live, via `CodexPadLEDFeedbackService`.
    func uploadPackets(profile: MacropadProfile, layout: KeyboardLayout = .usANSI) throws -> [[UInt8]] {
        try packets(profile: profile, layout: layout)
            + HardwareControl.buttons.map {
                ledPacket(setting: profile.baseLighting(for: $0))
            }
    }

    func ledPacket(setting: KeyLEDConfiguration) -> [UInt8] {
        var packet = base(command: 0x10)
        packet[4] = setting.control.firmwareControlIndex
        packet[5] = setting.effect.rawValue
        packet[6] = setting.red
        packet[7] = setting.green
        packet[8] = setting.blue
        packet[9] = UInt8(max(5, min(250, setting.periodMilliseconds / 20)))
        packet[10] = setting.brightness
        return finalized(packet)
    }

    func allOffPacket() -> [UInt8] { finalized(base(command: 0x12)) }

    func allLEDs(effect: LEDEffect, red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8, periodMilliseconds: Int) -> [[UInt8]] {
        HardwareControl.buttons.map {
            ledPacket(setting: KeyLEDConfiguration(
                control: $0,
                effect: effect,
                red: red,
                green: green,
                blue: blue,
                brightness: brightness,
                periodMilliseconds: periodMilliseconds
            ))
        }
    }

    func statusRequestPacket() -> [UInt8] { finalized(base(command: 0x30, version: 2)) }

    func bindingPacket(action: KeyboardAction, control: HardwareControl, layout: KeyboardLayout = .usANSI) throws -> [UInt8] {
        var packet = base(command: 0x20)
        packet[4] = control.firmwareControlIndex
        guard action.kind != .disabled else { return finalized(packet) }
        if action.kind == .hostEvent || action.kind.isAgent {
            packet[5] = 3
            return finalized(packet)
        }
        guard let expression = action.deviceMacro?.lowercased(), !expression.isEmpty else {
            throw CodexPadPacketError.invalidMacro(control, action.deviceMacro ?? "")
        }

        if action.kind == .media {
            guard let usage = Self.consumerUsages[expression] else {
                throw CodexPadPacketError.unsupportedAction(control, expression)
            }
            packet[5] = 2
            packet[6] = 1
            packet[7] = UInt8((usage >> 8) & 0xff)
            packet[8] = UInt8(usage & 0xff)
            return finalized(packet)
        }
        guard action.kind != .mouse else {
            throw CodexPadPacketError.unsupportedAction(control, expression)
        }

        let tokens = expression.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count <= 5 else { throw CodexPadPacketError.tooManySteps(control) }
        let chords = try tokens.map { try keyboardChord($0, control: control, layout: layout.resolved) }
        packet[5] = action.codexActionID == "dictation" ? 4 : 1
        packet[6] = UInt8(chords.count)
        for (index, chord) in chords.enumerated() {
            packet[7 + index * 2] = chord.modifier
            packet[8 + index * 2] = chord.usage
        }
        return finalized(packet)
    }

    private func keyboardChord(_ expression: String, control: HardwareControl, layout: KeyboardLayout) throws -> (modifier: UInt8, usage: UInt8) {
        let parts = expression.split(separator: "-").map(String.init)
        guard let keyName = parts.last, let base = Self.keyStroke(for: keyName, layout: layout) else {
            throw CodexPadPacketError.invalidMacro(control, expression)
        }
        var modifier = base.modifier
        for part in parts.dropLast() {
            switch part {
            case "ctrl": modifier |= 0x01
            case "shift": modifier |= 0x02
            case "alt", "opt": modifier |= 0x04
            case "cmd", "gui": modifier |= 0x08
            default: throw CodexPadPacketError.invalidMacro(control, expression)
            }
        }
        return (modifier, base.usage)
    }

    private func base(command: UInt8, version: UInt8 = 1) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: Self.packetSize)
        packet[0] = 0x43
        packet[1] = 0x50
        packet[2] = version
        packet[3] = command
        return packet
    }

    private func finalized(_ source: [UInt8]) -> [UInt8] {
        var packet = source
        packet[Self.packetSize - 1] = packet[..<(Self.packetSize - 1)].reduce(0, ^)
        return packet
    }

    private static func keyStroke(for name: String, layout: KeyboardLayout) -> (modifier: UInt8, usage: UInt8)? {
        if name.count == 1, let scalar = name.unicodeScalars.first {
            switch scalar.value {
            case 97...122:
                if layout == .germanISO, name == "y" { return (0, 0x1D) }
                if layout == .germanISO, name == "z" { return (0, 0x1C) }
                return (0, UInt8(scalar.value - 97 + 0x04))
            case 49...57: return (0, UInt8(scalar.value - 49 + 0x1e))
            case 48: return (0, 0x27)
            default: break
            }
        }
        if name.hasPrefix("f"), let number = Int(name.dropFirst()) {
            if (1...12).contains(number) { return (0, UInt8(0x3a + number - 1)) }
            if (13...24).contains(number) { return (0, UInt8(0x68 + number - 13)) }
        }
        if layout == .germanISO, let stroke = germanKeyStrokes[name] { return stroke }
        return keyboardUsages[name].map { (0, $0) }
    }

    private static let keyboardUsages: [String: UInt8] = [
        "enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29,
        "backspace": 0x2a, "tab": 0x2b, "space": 0x2c, "minus": 0x2d,
        "equal": 0x2e, "leftbracket": 0x2f, "rightbracket": 0x30,
        "backslash": 0x31, "semicolon": 0x33, "quote": 0x34, "grave": 0x35,
        "comma": 0x36, "period": 0x37, "slash": 0x38, "capslock": 0x39,
        "right": 0x4f, "left": 0x50, "down": 0x51, "up": 0x52,
        "home": 0x4a, "pageup": 0x4b, "delete": 0x4c, "end": 0x4d, "pagedown": 0x4e
    ]

    // Semantic character keys for Apple's German ISO input source. Modifier
    // bits are intrinsic and are combined with modifiers written in the macro.
    private static let germanKeyStrokes: [String: (modifier: UInt8, usage: UInt8)] = [
        "minus": (0, 0x38),
        "equal": (0x02, 0x27),
        "leftbracket": (0x04, 0x22),
        "rightbracket": (0x04, 0x23),
        "backslash": (0x06, 0x24),
        "semicolon": (0x02, 0x36),
        "quote": (0x02, 0x32),
        "comma": (0, 0x36),
        "period": (0, 0x37),
        "slash": (0x02, 0x24)
    ]

    private static let consumerUsages: [String: UInt16] = [
        "mute": 0x00e2, "volumeup": 0x00e9, "volumedown": 0x00ea,
        "playpause": 0x00cd, "nexttrack": 0x00b5, "previoustrack": 0x00b6,
        "stop": 0x00b7
    ]
}
