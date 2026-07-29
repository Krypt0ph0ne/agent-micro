import Foundation

/// Durable record of configurable shortcut triggers the assistant has offered.
/// A trigger remains reserved after the wizard closes so it cannot later be
/// suggested for a different action or profile.
enum CodexTriggerRegistry {
    static let defaultsKey = "CodexPad.reservedConfigurableShortcutTriggers"

    static func reservedTriggers(defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.stringArray(forKey: defaultsKey) ?? []).map { $0.lowercased() })
    }

    static func availableTriggers(
        in profiles: [MacropadProfile],
        keeping current: String? = nil,
        defaults: UserDefaults = .standard
    ) -> [String] {
        var unavailable = CodexTriggerPool.usedTriggers(in: profiles)
        unavailable.formUnion(reservedTriggers(defaults: defaults))
        if let current = current?.lowercased() {
            unavailable.remove(current)
        }
        return CodexTriggerPool.candidates.filter { !unavailable.contains($0) }
    }

    @discardableResult
    static func reserveNextFreeTrigger(
        in profiles: [MacropadProfile],
        keeping current: String? = nil,
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let trigger = CodexTriggerPool.nextFreeTrigger(
            in: profiles,
            keeping: current,
            reserved: reservedTriggers(defaults: defaults)
        ) else { return nil }
        reserve(trigger, defaults: defaults)
        return trigger
    }

    @discardableResult
    static func reserveAlternativeTrigger(
        to trigger: String,
        in profiles: [MacropadProfile],
        defaults: UserDefaults = .standard
    ) -> String? {
        guard let alternative = CodexTriggerPool.alternativeTrigger(
            to: trigger,
            in: profiles,
            reserved: reservedTriggers(defaults: defaults)
        ) else { return nil }
        reserve(alternative, defaults: defaults)
        return alternative
    }

    static func reserve(_ trigger: String, defaults: UserDefaults = .standard) {
        var reserved = reservedTriggers(defaults: defaults)
        reserved.insert(trigger.lowercased())
        defaults.set(reserved.sorted(), forKey: defaultsKey)
    }
}
