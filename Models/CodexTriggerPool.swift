import Foundation

/// Generates collision-free trigger chords for the assignment wizard.
///
/// The 26 configurable Codex actions have no default keybinding. The wizard
/// gives one a unique "Hyper" chord (`⌃⌥⇧⌘` + a letter) that the pad sends
/// straight to Codex; the user binds that same chord to the action once inside
/// Codex › Settings › Keyboard Shortcuts. Hyper chords are never produced by
/// normal typing and do not overlap the plain function-key triggers that the
/// encoder automation listens for, so they are safe global triggers.
enum CodexTriggerPool {
    static let hyperModifier = "cmd-ctrl-opt-shift"

    /// One candidate per letter, in a stable order.
    static let candidates: [String] = "abcdefghijklmnopqrstuvwxyz".map { "\(hyperModifier)-\($0)" }

    /// Device macros already used by any tap or hold slot in the profile.
    static func usedTriggers(in profile: MacropadProfile) -> Set<String> {
        var used: Set<String> = []
        for binding in profile.controls {
            if let macro = binding.action.deviceMacro?.lowercased() { used.insert(macro) }
            if let macro = binding.holdAction?.deviceMacro?.lowercased() { used.insert(macro) }
        }
        return used
    }

    /// The first candidate not already bound elsewhere. `keeping` lets a control
    /// that is being re-edited hold on to its own current trigger.
    static func nextFreeTrigger(in profile: MacropadProfile, keeping current: String? = nil) -> String? {
        var used = usedTriggers(in: profile)
        if let current = current?.lowercased() { used.remove(current) }
        return candidates.first { !used.contains($0) }
    }

    /// A different free trigger than the one given, for a "try another" action.
    static func alternativeTrigger(to trigger: String, in profile: MacropadProfile) -> String? {
        let used = usedTriggers(in: profile).subtracting([trigger.lowercased()])
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
