import CoreGraphics
import Foundation

/// Turns a `ch57x-keyboard-tool` style macro expression (for example
/// `cmd-shift-p` or `h,i`) into synthetic key events. This is only used for
/// app-mediated controls such as tap-vs-hold, where the pad itself sends no HID
/// macro and CodexPad decides which action to emit.
///
/// Posting synthetic events to other applications requires the Accessibility
/// permission, which CodexPad already requests for the encoder automation.
enum KeystrokeSynthesizer {
    /// `true` when every comma-separated chord in the expression maps to a
    /// known virtual key. Media, mouse and other non-keyboard expressions are
    /// rejected so the UI can refuse to build an un-synthesizable hold action.
    static func canSynthesize(_ macro: String?, layout: KeyboardLayout = .automatic) -> Bool {
        guard let chords = chords(from: macro) else { return false }
        return chords.allSatisfy { mapChord($0, layout: layout.resolved) != nil }
    }

    @discardableResult
    static func post(macro: String?, layout: KeyboardLayout = .automatic) -> Bool {
        guard let chords = chords(from: macro) else { return false }
        var mapped: [(key: CGKeyCode, flags: CGEventFlags)] = []
        for chord in chords {
            guard let resolved = mapChord(chord, layout: layout.resolved) else { return false }
            mapped.append(resolved)
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for chord in mapped {
            post(key: chord.key, flags: chord.flags, source: source)
        }
        return true
    }

    private static func chords(from macro: String?) -> [String]? {
        guard let macro else { return nil }
        let trimmed = macro.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let chords = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return chords.contains(where: \.isEmpty) ? nil : chords
    }

    private static func post(key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private static func mapChord(
        _ chord: String,
        layout: KeyboardLayout
    ) -> (key: CGKeyCode, flags: CGEventFlags)? {
        let parts = chord.split(separator: "-").map(String.init)
        guard let keyName = parts.last else { return nil }
        let intrinsic: (key: Int, flags: CGEventFlags)?
        if layout == .germanISO, let german = germanVirtualKeys[keyName] {
            intrinsic = german
        } else if let key = virtualKeyCodes[keyName] {
            intrinsic = (key, [])
        } else {
            intrinsic = nil
        }
        guard let intrinsic else { return nil }
        var flags = intrinsic.flags
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "gui", "win", "rcmd", "rwin": flags.insert(.maskCommand)
            case "ctrl", "rctrl": flags.insert(.maskControl)
            case "shift", "rshift": flags.insert(.maskShift)
            case "alt", "opt", "ralt", "ropt": flags.insert(.maskAlternate)
            default: return nil
            }
        }
        return (CGKeyCode(intrinsic.key), flags)
    }

    /// US-ANSI virtual key codes keyed by the macro token names CodexPad uses.
    /// These are the stable Carbon `kVK_*` values.
    private static let virtualKeyCodes: [String: Int] = [
        // Letters
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
        // Digits
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
        "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
        // Punctuation
        "minus": 0x1B, "equal": 0x18, "leftbracket": 0x21, "rightbracket": 0x1E,
        "backslash": 0x2A, "semicolon": 0x29, "quote": 0x27, "grave": 0x32,
        "comma": 0x2B, "period": 0x2F, "slash": 0x2C,
        // Editing and navigation
        "enter": 0x24, "return": 0x24, "esc": 0x35, "escape": 0x35,
        "space": 0x31, "tab": 0x30, "backspace": 0x33, "delete": 0x75,
        "capslock": 0x39, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        // Function keys (F13–F20 double as the private/assignable triggers)
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A, "f17": 0x40,
        "f18": 0x4F, "f19": 0x50, "f20": 0x5A
    ]

    /// Character-correct virtual keys for the German ISO input source. Most
    /// letters/digits share the ANSI position; punctuation does not. In
    /// particular "/" is ⇧7, while the US slash position is "-" on German
    /// keyboards (and therefore used to trigger Codex's zoom-out command).
    private static let germanVirtualKeys: [String: (key: Int, flags: CGEventFlags)] = [
        "slash": (0x1A, .maskShift),
        "minus": (0x2C, []),
        "semicolon": (0x2B, .maskShift),
        "comma": (0x2B, []),
        "period": (0x2F, [])
    ]
}
