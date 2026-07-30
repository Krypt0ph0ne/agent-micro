import Foundation

/// One-time compatibility bridge from the pre-open-source CodexPad identity.
/// The migration copies preferences only when the new key is absent and moves
/// the Application Support directory only when doing so cannot overwrite data.
enum AgentMicroDataMigration {
    private static let migrationKey = "AgentMicro.didMigrateCodexPadDataV1"

    private static let preferenceSuffixes = [
        "hasCompletedOnboarding",
        "appLanguage",
        "selectedProfileID",
        "keyboardLayout",
        "dictationSource",
        "enabledAutomationApps",
        "reservedConfigurableShortcutTriggers",
        "configurableShortcutAssignments",
        "confirmedConfigurableShortcutAssignments",
        "encoderAutomationEnabled",
        "simpleEncoderV5",
        "claudeEncoderAutomationEnabled",
        "claudeHooksStatusEnabled",
    ]

    static func run(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }

        for suffix in preferenceSuffixes {
            let oldKey = "CodexPad.\(suffix)"
            let newKey = "AgentMicro.\(suffix)"
            if defaults.object(forKey: newKey) == nil,
               let value = defaults.object(forKey: oldKey) {
                defaults.set(value, forKey: newKey)
            }
        }

        migrateApplicationSupport(
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )
        defaults.set(true, forKey: migrationKey)
    }

    private static func migrateApplicationSupport(
        fileManager: FileManager,
        applicationSupportDirectory: URL?
    ) {
        guard let applicationSupport = applicationSupportDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }

        let oldDirectory = applicationSupport.appendingPathComponent("CodexPad", isDirectory: true)
        let newDirectory = applicationSupport.appendingPathComponent("Agent Micro", isDirectory: true)
        guard fileManager.fileExists(atPath: oldDirectory.path),
              !fileManager.fileExists(atPath: newDirectory.path) else { return }

        try? fileManager.moveItem(at: oldDirectory, to: newDirectory)
    }
}
