import Foundation

/// Durable record of configurable shortcut triggers the assistant has offered.
/// A trigger remains reserved after the wizard closes so it cannot later be
/// suggested for a different action or profile.
enum CodexTriggerRegistry {
    static let defaultsKey = "AgentMicro.reservedConfigurableShortcutTriggers"
    static let assignmentsDefaultsKey = "AgentMicro.configurableShortcutAssignments"
    static let confirmedAssignmentsDefaultsKey = "AgentMicro.confirmedConfigurableShortcutAssignments"

    static func reservedTriggers(defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.stringArray(forKey: defaultsKey) ?? []).map { $0.lowercased() })
    }

    /// Returns the trigger the user already configured for this exact action.
    /// It is deliberately keyed by target app as Codex and Claude can use the
    /// same action ID while keeping independent shortcut settings.
    static func trigger(for actionID: String, app: AutomationApp, defaults: UserDefaults = .standard) -> String? {
        assignments(defaults: defaults)[assignmentKey(for: actionID, app: app)]?.lowercased()
    }

    /// Stores the one stable shortcut associated with an action. Reassigning
    /// that action to another pad control must reuse this value, not create a
    /// second Codex shortcut for the same command.
    static func remember(_ trigger: String, for actionID: String, app: AutomationApp, defaults: UserDefaults = .standard) {
        let normalized = trigger.lowercased()
        var stored = assignments(defaults: defaults)
        stored[assignmentKey(for: actionID, app: app)] = normalized
        defaults.set(stored, forKey: assignmentsDefaultsKey)
        reserve(normalized, defaults: defaults)
    }

    /// A confirmed assignment has been transferred successfully and no longer
    /// needs the persistent setup reminder in the inspector.
    static func confirmedTrigger(for actionID: String, app: AutomationApp, defaults: UserDefaults = .standard) -> String? {
        confirmedAssignments(defaults: defaults)[assignmentKey(for: actionID, app: app)]?.lowercased()
    }

    static func markConfirmed(_ trigger: String, for actionID: String, app: AutomationApp, defaults: UserDefaults = .standard) {
        var confirmed = confirmedAssignments(defaults: defaults)
        confirmed[assignmentKey(for: actionID, app: app)] = trigger.lowercased()
        defaults.set(confirmed, forKey: confirmedAssignmentsDefaultsKey)
    }

    /// Recreates a usable pad action from the persistent setup record. This is
    /// what lets the action list offer "Auswählen" after an app restart even
    /// when that action is not currently bound to the selected control.
    static func confirmedAction(
        for definition: CodexActionDefinition,
        app: AutomationApp,
        defaults: UserDefaults = .standard
    ) -> KeyboardAction? {
        guard let trigger = confirmedTrigger(for: definition.id, app: app, defaults: defaults) else { return nil }
        return KeyboardAction(
            kind: app == .claude ? .claudeShortcut : .codexShortcut,
            label: definition.title,
            icon: definition.icon,
            deviceMacro: trigger,
            codexActionID: definition.id
        )
    }

    /// Imports bindings saved before the action-to-trigger index existed. All
    /// layers are scanned, so a binding does not disappear when its layer is
    /// currently inactive.
    static func importExistingAssignments(from profiles: [MacropadProfile], defaults: UserDefaults = .standard) {
        var stored = assignments(defaults: defaults)
        var confirmed = confirmedAssignments(defaults: defaults)
        var reserved = reservedTriggers(defaults: defaults)

        for profile in profiles {
            for layer in profile.layers {
                for binding in layer.controls {
                    recordExisting(
                        binding.action,
                        profileApp: profile.automationApp,
                        into: &stored,
                        confirmed: &confirmed,
                        reserved: &reserved
                    )
                    if let holdAction = binding.holdAction {
                        recordExisting(
                            holdAction,
                            profileApp: profile.automationApp,
                            into: &stored,
                            confirmed: &confirmed,
                            reserved: &reserved
                        )
                    }
                }
            }
        }

        defaults.set(stored, forKey: assignmentsDefaultsKey)
        defaults.set(confirmed, forKey: confirmedAssignmentsDefaultsKey)
        defaults.set(reserved.sorted(), forKey: defaultsKey)
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

    private static func assignments(defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: assignmentsDefaultsKey) as? [String: String] ?? [:]
    }

    private static func confirmedAssignments(defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: confirmedAssignmentsDefaultsKey) as? [String: String] ?? [:]
    }

    private static func assignmentKey(for actionID: String, app: AutomationApp) -> String {
        "\(app.rawValue):\(actionID)"
    }

    private static func recordExisting(
        _ action: KeyboardAction,
        profileApp: AutomationApp?,
        into stored: inout [String: String],
        confirmed: inout [String: String],
        reserved: inout Set<String>
    ) {
        guard
            let actionID = action.codexActionID,
            let trigger = action.deviceMacro?.lowercased(),
            CodexTriggerPool.candidates.contains(trigger)
        else { return }

        let app: AutomationApp = action.kind == .claudeShortcut ? .claude : (profileApp ?? .codex)
        let key = assignmentKey(for: actionID, app: app)
        // An explicit, newer registry record wins over a legacy profile copy.
        stored[key] = stored[key] ?? trigger
        // These bindings were saved by an earlier version that had no success
        // marker. Preserve their established setup as completed on migration.
        confirmed[key] = confirmed[key] ?? trigger
        reserved.insert(trigger)
    }
}
