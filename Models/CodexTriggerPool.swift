import Foundation

/// Generates collision-free trigger chords for the assignment wizard.
///
/// Configurable Codex actions have no default keybinding. The wizard gives one
/// a unique "Hyper" chord (`⌃⌥⇧⌘` + a key) that the pad sends
/// straight to Codex; the user binds that same chord to the action once inside
/// Codex › Settings › Keyboard Shortcuts. Hyper chords are never produced by
/// normal typing and do not overlap the plain function-key triggers that the
/// encoder automation listens for, so they are safe global triggers.
enum CodexTriggerPool {
    static let hyperModifier = "cmd-ctrl-opt-shift"

    static let letterCandidates = "abcdefghijklmnopqrstuvwxyz".map { "\(hyperModifier)-\($0)" }
    static let numberCandidates = "1234567890".map { "\(hyperModifier)-\($0)" }
    static let functionKeyCandidates = (1...12).map { "\(hyperModifier)-f\($0)" }

    /// Stable priority: familiar letters first, then number-row and function
    /// keys. Every entry is supported by both firmware upload paths.
    static let candidates = letterCandidates + numberCandidates + functionKeyCandidates

    /// Device macros already used by any tap or hold slot in a profile.
    static func usedTriggers(in profile: MacropadProfile) -> Set<String> {
        usedTriggers(in: [profile])
    }

    /// Device macros already used across every saved profile. Configurable
    /// shortcuts must stay unique even when their profile is not active.
    static func usedTriggers(in profiles: [MacropadProfile]) -> Set<String> {
        var used: Set<String> = []
        for profile in profiles {
            for binding in profile.controls {
                if let macro = binding.action.deviceMacro?.lowercased() { used.insert(macro) }
                if let macro = binding.holdAction?.deviceMacro?.lowercased() { used.insert(macro) }
            }
        }
        return used
    }

    /// The first candidate not already bound elsewhere. `keeping` lets a control
    /// that is being re-edited hold on to its own current trigger.
    static func nextFreeTrigger(in profile: MacropadProfile, keeping current: String? = nil) -> String? {
        nextFreeTrigger(in: [profile], keeping: current)
    }

    /// The first candidate that is unused across all profiles and the durable
    /// reservation store. `keeping` lets a control retain its own trigger
    /// while it is re-edited.
    static func nextFreeTrigger(in profiles: [MacropadProfile], keeping current: String? = nil, reserved: Set<String> = []) -> String? {
        var used = usedTriggers(in: profiles)
        used.formUnion(reserved.map { $0.lowercased() })
        if let current = current?.lowercased() { used.remove(current) }
        return candidates.first { !used.contains($0) }
    }

    /// A different free trigger than the one given, for a "try another" action.
    static func alternativeTrigger(to trigger: String, in profile: MacropadProfile) -> String? {
        alternativeTrigger(to: trigger, in: [profile])
    }

    static func alternativeTrigger(to trigger: String, in profiles: [MacropadProfile], reserved: Set<String> = []) -> String? {
        var used = usedTriggers(in: profiles)
        used.formUnion(reserved.map { $0.lowercased() })
        return candidates.first { $0 != trigger.lowercased() && !used.contains($0) }
    }

    /// Human-readable rendering such as `⌃⌥⇧⌘A`.
    static func displayLabel(for trigger: String) -> String {
        trigger
            .replacingOccurrences(of: "cmd", with: "⌘")
            .replacingOccurrences(of: "opt", with: "⌥")
            .replacingOccurrences(of: "alt", with: "⌥")
            .replacingOccurrences(of: "ctrl", with: "⌃")
            .replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
    }
}
