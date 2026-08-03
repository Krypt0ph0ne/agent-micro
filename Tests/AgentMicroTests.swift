import Foundation
import Carbon.HIToolbox
import XCTest
@testable import AgentMicro

/// Removes a temporary `UserDefaults` suite completely.
///
/// `removePersistentDomain(forName:)` only empties the domain; `cfprefsd` still
/// leaves an empty `~/Library/Preferences/<suite>.plist` behind. Every test run
/// creates a fresh UUID-named suite, so without this the developer's Preferences
/// directory accumulates one stray file per suite per run, forever.
func removeDefaultsSuite(_ suiteName: String, defaults: UserDefaults) {
    defaults.removePersistentDomain(forName: suiteName)
    defaults.removeSuite(named: suiteName)
    let plist = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suiteName).plist")
    try? FileManager.default.removeItem(at: plist)
}

final class AgentMicroTests: XCTestCase {
    func testPrivacySettingsDeepLinksTargetTheExpectedTCCPanes() {
        XCTAssertEqual(
            SystemPrivacySettingsPane.accessibility.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        XCTAssertEqual(
            SystemPrivacySettingsPane.inputMonitoring.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )
    }

    func testClaudeEffortRankParsesCombinedGermanAndEnglishPopupLabels() {
        XCTAssertEqual(ClaudeReasoningAutomationService.effortRank(in: "Modell: Opus 5 · Niedrig"), 0)
        XCTAssertEqual(ClaudeReasoningAutomationService.effortRank(in: "Model: Sonnet 4.5 · Medium"), 1)
        XCTAssertEqual(ClaudeReasoningAutomationService.effortRank(in: "Modell: Opus 5 · Hoch"), 2)
        XCTAssertEqual(ClaudeReasoningAutomationService.effortRank(in: "Model: Opus 5 · Extra High"), 3)
        XCTAssertEqual(ClaudeReasoningAutomationService.effortRank(in: "Modell: Opus 5 · Maximal Hoch"), 4)
        XCTAssertNil(ClaudeReasoningAutomationService.effortRank(in: "Modell: Opus 5"))
    }

    func testClaudeEffortTargetClampsToSupportedRange() {
        XCTAssertEqual(ClaudeReasoningAutomationService.targetEffortRank(current: 0, delta: -1), 0)
        XCTAssertEqual(ClaudeReasoningAutomationService.targetEffortRank(current: 2, delta: -1), 1)
        XCTAssertEqual(ClaudeReasoningAutomationService.targetEffortRank(current: 2, delta: 1), 3)
        XCTAssertEqual(ClaudeReasoningAutomationService.targetEffortRank(current: 4, delta: 1), 4)
    }

    // Every string below was captured from a live Accessibility dump of Claude
    // Desktop 1.24012.9 (Agent Micro → Diagnose → "Claude-UI untersuchen").

    func testClaudeEffortPopUpRequiresThePopUpRoleAndNotJustMatchingText() {
        XCTAssertTrue(ClaudeAccessibilityControls.isEffortPopUp(
            role: kAXPopUpButtonRole,
            text: "aufwand: hoch"
        ))
        // The regression this pins down: a chat message mentioning the word
        // was matched ahead of the real control, and the automation then typed
        // effort steps into the conversation list while reporting success.
        XCTAssertFalse(ClaudeAccessibilityControls.isEffortPopUp(
            role: kAXStaticTextRole,
            text: "agent micro meldet danach: claude-aufwand angepasst."
        ))
        XCTAssertFalse(ClaudeAccessibilityControls.isEffortPopUp(
            role: kAXButtonRole,
            text: "#8 · gemergt encoder alternative modellauswahl"
        ))
    }

    func testClaudeModelPopUpIgnoresConversationRowsNamedAfterAModel() {
        XCTAssertTrue(ClaudeAccessibilityControls.isModelPopUp(role: kAXPopUpButtonRole, text: "opus 5"))
        XCTAssertTrue(ClaudeAccessibilityControls.isModelPopUp(role: kAXPopUpButtonRole, text: "sonnet 5"))
        // A real AXPopUpButton, but the one belonging to a sidebar row.
        XCTAssertFalse(ClaudeAccessibilityControls.isModelPopUp(
            role: kAXPopUpButtonRole,
            text: "weitere optionen für encoder alternative modellauswahl"
        ))
        XCTAssertFalse(ClaudeAccessibilityControls.isModelPopUp(
            role: kAXStaticTextRole,
            text: "encoder alternative modellauswahl"
        ))
        // "Modell" alone must never select a control: it is a conversation
        // word, not a model name.
        XCTAssertFalse(ClaudeAccessibilityControls.isModelPopUp(
            role: kAXPopUpButtonRole,
            text: "modellauswahl"
        ))
    }

    func testClaudeEffortSliderLabelsMapToRanksInBothAppLanguages() {
        for (label, rank) in [("Niedrig", 0), ("Mittel", 1), ("Hoch", 2), ("Extra", 3), ("Max", 4)] {
            XCTAssertEqual(ClaudeReasoningAutomationService.effortRank(in: label), rank, label)
        }
        for (label, rank) in [("Low", 0), ("Medium", 1), ("High", 2), ("Extra", 3), ("Max", 4)] {
            XCTAssertEqual(ClaudeReasoningAutomationService.effortRank(in: label), rank, label)
        }
    }

    func testDiagnosticPadEventUsesTheSamePublishedEventPathAndIsIdentifiable() throws {
        let service = CodexPadEventService()
        var received: [CodexPadPhysicalEvent] = []
        service.onPhysicalEvent = { received.append($0) }

        service.injectDiagnosticPhysicalEvent(control: .encoderLeft, phase: .triggered)
        service.injectDiagnosticPhysicalEvent(control: .encoderRight, phase: .triggered)

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.map(\.origin), [.diagnostic, .diagnostic])
        XCTAssertEqual(received.map(\.control), [
            HardwareControl.encoderLeft.reportedControlIndex,
            HardwareControl.encoderRight.reportedControlIndex
        ])
        XCTAssertEqual(received.map(\.phase), [.triggered, .triggered])
        XCTAssertEqual(received.map(\.sequence), [1, 2])
        XCTAssertEqual(service.events, received.reversed())
    }

    func testAgentMicroMigratesLegacyPreferencesAndApplicationSupport() throws {
        let suiteName = "AgentMicroTests.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { removeDefaultsSuite(suiteName, defaults: defaults) }
        defaults.set("de", forKey: "CodexPad.appLanguage")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMicroMigration-\(UUID().uuidString)", isDirectory: true)
        let oldDirectory = root.appendingPathComponent("CodexPad", isDirectory: true)
        let legacyFile = oldDirectory.appendingPathComponent("Profiles.json")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyFile)
        defer { try? FileManager.default.removeItem(at: root) }

        AgentMicroDataMigration.run(
            defaults: defaults,
            applicationSupportDirectory: root
        )

        XCTAssertEqual(defaults.string(forKey: "AgentMicro.appLanguage"), "de")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent("Agent Micro", isDirectory: true)
                    .appendingPathComponent("Profiles.json")
                    .path
            )
        )
    }

    func testProfileSerializationRoundTrip() throws {
        let catalog = CodexActionCatalog()
        let profile = ProfileFactory.codex(catalog: catalog)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(MacropadProfile.self, from: data)
        XCTAssertEqual(decoded.name, "Codex")
        XCTAssertEqual(decoded.action(for: .key2).codexActionID, "quick-chat")
        XCTAssertEqual(decoded.controls.count, 9)
        XCTAssertEqual(decoded.ledReactions.count, LEDReactionEvent.allCases.count)
    }

    func testLegacyLayerBlinkSettingsMigrateToFullConfirmationEffect() throws {
        let layer = ProfileLayer(name: "Alt", controls: [], blinkRed: 12, blinkGreen: 34, blinkBlue: 56, blinkCount: 2)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layer)) as! [String: Any]
        json.removeValue(forKey: "confirmationEffect")
        json.removeValue(forKey: "confirmationBrightness")
        json.removeValue(forKey: "confirmationDurationMilliseconds")
        json.removeValue(forKey: "confirmationRepeatCount")
        let migrated = try JSONDecoder().decode(ProfileLayer.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.confirmationEffect, .flash)
        XCTAssertEqual(migrated.confirmationRepeatCount, 2)
        XCTAssertEqual(migrated.confirmation.red, 12)
        XCTAssertEqual(migrated.confirmation.green, 34)
        XCTAssertEqual(migrated.confirmation.blue, 56)
    }

    func testReasoningTriggerProfileUsesConfirmedLocalShortcuts() {
        let profile = ProfileFactory.codexReasoningTriggers(catalog: CodexActionCatalog())
        XCTAssertEqual(profile.action(for: .encoderLeft).deviceMacro, "f22")
        XCTAssertEqual(profile.action(for: .encoderPress).deviceMacro, "f23")
        XCTAssertEqual(profile.action(for: .encoderRight).deviceMacro, "f24")
        XCTAssertEqual(profile.action(for: .encoderLeft).codexActionID, "encoder-effort-decrease")
    }

    func testCodexProfileUsesReasoningTriggersByDefault() {
        let profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        XCTAssertEqual(profile.action(for: .encoderLeft).deviceMacro, "f22")
        XCTAssertEqual(profile.action(for: .encoderPress).deviceMacro, "f23")
        XCTAssertEqual(profile.action(for: .encoderRight).deviceMacro, "f24")
        XCTAssertEqual(profile.action(for: .encoderRight).codexActionID, "encoder-effort-increase")
    }

    func testCodexProfileGeneratesReasoningFunctionKeys() throws {
        let profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        let yaml = try CH57xConfigurationEncoder().encode(profile: profile)
        XCTAssertTrue(yaml.contains("ccw: 'f22'"))
        XCTAssertTrue(yaml.contains("press: 'f23'"))
        XCTAssertTrue(yaml.contains("cw: 'f24'"))
    }

    func testClaudeProfileUsesReasoningTriggersByDefaultAndTargetsClaude() {
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)
        let profile = ProfileFactory.claude(catalog: claudeCatalog)
        XCTAssertEqual(profile.name, "Claude")
        XCTAssertTrue(profile.isBuiltIn)
        XCTAssertEqual(profile.automationApp, .claude)
        XCTAssertEqual(profile.action(for: .encoderLeft).deviceMacro, "f22")
        XCTAssertEqual(profile.action(for: .encoderPress).deviceMacro, "f23")
        XCTAssertEqual(profile.action(for: .encoderRight).deviceMacro, "f24")
        XCTAssertEqual(profile.action(for: .encoderRight).codexActionID, "encoder-effort-increase")
    }

    func testClaudeActionsMapToConfirmedKeybindings() {
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "dictation")?.deviceMacro, "space")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "dictation")?.kind, .claudeShortcut)
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "new-session")?.deviceMacro, "cmd-n")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "close-session")?.deviceMacro, "cmd-w")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "next-session")?.deviceMacro, "cmd-shift-rightbracket")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "previous-session")?.deviceMacro, "cmd-shift-leftbracket")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "stop-response")?.deviceMacro, "esc")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "send-message")?.deviceMacro, "enter")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "send-message")?.kind, .claudeShortcut)
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "toggle-diff")?.deviceMacro, "cmd-shift-d")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "toggle-preview")?.deviceMacro, "cmd-shift-p")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "toggle-terminal")?.deviceMacro, "ctrl-grave")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "close-panel")?.deviceMacro, "cmd-backslash")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "open-side-chat")?.deviceMacro, "cmd-semicolon")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "cycle-mode")?.deviceMacro, "ctrl-o")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "open-permission-mode")?.deviceMacro, "cmd-shift-m")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "open-model-menu")?.deviceMacro, "cmd-shift-i")
        XCTAssertEqual(claudeCatalog.keyboardAction(id: "open-effort-menu")?.deviceMacro, "cmd-shift-e")
        // The numbered menu-item shortcut documents the gesture but has no
        // fixed device macro, since it's only meaningful once a menu is open.
        XCTAssertNil(claudeCatalog.keyboardAction(id: "select-menu-item"))
        XCTAssertEqual(claudeCatalog.action(id: "select-menu-item")?.execution, .configurableShortcut)
    }

    func testClaudeDesktopSessionUsesReadableTitleProjectAndShortID() throws {
        let data = Data("""
        {
          "sessionId": "local_1cdac978-4c4d-452c-87ca-d3769b994e0a",
          "cliSessionId": "8566a8f9-bd20-4f55-bb33-7675859812ed",
          "title": "Agent Micro pre-release adjustments",
          "cwd": "/tmp/worktree",
          "originCwd": "/Users/test/Agent Micro",
          "createdAt": 1780000000000,
          "lastActivityAt": 1780001000000,
          "isArchived": false,
          "bridgeSessionIds": ["session_01XMavBeqfaCXC5dbAMrn6ba"]
        }
        """.utf8)
        let session = try JSONDecoder().decode(ClaudeDesktopSession.self, from: data)
        let thread = session.threadDescriptor
        XCTAssertEqual(thread.id, "local_1cdac978-4c4d-452c-87ca-d3769b994e0a")
        XCTAssertEqual(thread.displayTitle, "Agent Micro pre-release adjustments")
        XCTAssertEqual(thread.projectName, "Agent Micro")
        XCTAssertEqual(thread.preview, "Agent Micro · 1cdac978")
        XCTAssertEqual(thread.alternateID, "8566a8f9-bd20-4f55-bb33-7675859812ed")
        // The CLI UUID identifies the session for hooks and migration, but it
        // is not what Claude's navigation route accepts.
        XCTAssertEqual(thread.navigationID, "session_01XMavBeqfaCXC5dbAMrn6ba")
    }

    func testClaudeNavigationUsesExistingDesktopSessionRoute() {
        XCTAssertEqual(
            CodexThreadStore.navigationURL(for: "session_01XMavBeqfaCXC5dbAMrn6ba", app: .claude)?.absoluteString,
            "claude://code/session_01XMavBeqfaCXC5dbAMrn6ba"
        )
        XCTAssertNil(CodexThreadStore.navigationURL(for: "local_1cdac978-4c4d-452c-87ca-d3769b994e0a", app: .claude))
        // Verified against Claude's own handler: the CLI UUID fails its
        // `/^(cse|session)_/` check, so the deep link is dropped without even
        // focusing the window. Sending it is worse than not sending it.
        XCTAssertNil(
            CodexThreadStore.navigationURL(for: "8566a8f9-bd20-4f55-bb33-7675859812ed", app: .claude)
        )
    }

    func testPetCatalogContainsOneRealToggleAction() {
        let catalog = CodexActionCatalog()
        XCTAssertNotNil(catalog.action(id: "toggle-pet"))
        XCTAssertEqual(catalog.action(id: "toggle-pet")?.codexCommandID, "openPetOverlay")
        XCTAssertNil(catalog.action(id: "wake-pet"))
        XCTAssertNil(catalog.action(id: "tuck-away-pet"))
    }

    @MainActor
    func testDictationSourceRewritesBothProfilesAndDefaultsToCodex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-dictation-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("Profiles.json")
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)
        // `dictationSource` persists through UserDefaults.standard across test
        // runs on the same machine; clear it first so the "default is .codex"
        // assertion below is deterministic rather than depending on whatever a
        // previous run last left behind.
        UserDefaults.standard.removeObject(forKey: "AgentMicro.dictationSource")
        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        defer { UserDefaults.standard.removeObject(forKey: "AgentMicro.dictationSource") }

        func dictationMacro(in profileName: String) -> String? {
            store.profiles.first(where: { $0.name == profileName })?.controls
                .first(where: { $0.action.codexActionID == "dictation" })?.action.deviceMacro
        }

        XCTAssertEqual(store.dictationSource, .codex)
        XCTAssertEqual(dictationMacro(in: "Codex"), "cmd-f17")
        XCTAssertEqual(dictationMacro(in: "Claude"), "cmd-f17", "default source is Codex-global, so the fresh Claude profile is rewritten to match")

        store.dictationSource = .claude
        XCTAssertEqual(dictationMacro(in: "Codex"), "space")
        XCTAssertEqual(dictationMacro(in: "Claude"), "space")

        store.dictationSource = .followProfile
        XCTAssertEqual(dictationMacro(in: "Codex"), "cmd-f17")
        XCTAssertEqual(dictationMacro(in: "Claude"), "space")
    }

    @MainActor
    func testExistingCodexProfilesAreBackfilledWithAnAutomationAppTag() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-tag-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Profiles.json")
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)

        // Simulate a profile persisted before `automationApp` existed.
        var legacy = ProfileFactory.codex(catalog: catalog)
        legacy.automationApp = nil
        try ProfileFileCodec.encode([legacy]).write(to: url)

        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        XCTAssertEqual(store.profiles.first(where: { $0.name == "Codex" })?.automationApp, .codex)
        XCTAssertEqual(store.profiles.first(where: { $0.name == "Claude" })?.automationApp, .claude, "a Claude profile should be auto-added for pre-existing installs")
    }

    @MainActor
    func testLegacyGreenIdleReactionIsMigratedToWhiteButCustomRecolorIsLeftAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-idle-color-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Profiles.json")
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)

        // Codex keeps the original shipped green; Claude simulates a user
        // who already recolored idle themselves (should be left untouched).
        var codexLegacyGreen = ProfileFactory.codex(catalog: catalog)
        codexLegacyGreen.setReaction(.init(event: .agentIdle, effect: .pulse, red: 48, green: 209, blue: 88, brightness: 180, periodMilliseconds: 2_200, disablesIdle: true, minBrightness: 40))
        var claudeCustomized = ProfileFactory.claude(catalog: claudeCatalog)
        claudeCustomized.setReaction(.init(event: .agentIdle, effect: .pulse, red: 10, green: 20, blue: 30, brightness: 180, periodMilliseconds: 2_200, disablesIdle: true, minBrightness: 40))
        try ProfileFileCodec.encode([codexLegacyGreen, claudeCustomized]).write(to: url)

        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)

        let migratedIdle = store.profiles.first(where: { $0.name == "Codex" })!.reaction(for: .agentIdle)
        XCTAssertEqual(migratedIdle.red, 255)
        XCTAssertEqual(migratedIdle.green, 255)
        XCTAssertEqual(migratedIdle.blue, 255)

        let untouchedIdle = store.profiles.first(where: { $0.name == "Claude" })!.reaction(for: .agentIdle)
        XCTAssertEqual(untouchedIdle.red, 10, "a custom recolor away from the original green must not be overwritten")
        XCTAssertEqual(untouchedIdle.green, 20)
        XCTAssertEqual(untouchedIdle.blue, 30)
    }

    @MainActor
    func testLegacyPetActionsCollapseToSingleToggleWithoutChangingTrigger() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-micro-pet-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Profiles.json")
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)
        var profile = ProfileFactory.codex(catalog: catalog)
        profile.setAction(
            KeyboardAction(
                kind: .codexShortcut,
                label: "Wake Pet",
                icon: "pawprint",
                deviceMacro: "cmd-ctrl-opt-shift-p",
                codexActionID: "wake-pet"
            ),
            for: .key2
        )
        try ProfileFileCodec.encode([profile, ProfileFactory.claude(catalog: claudeCatalog)]).write(to: url)

        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        let migrated = store.profiles.first(where: { $0.name == "Codex" })!.action(for: .key2)
        XCTAssertEqual(migrated.codexActionID, "toggle-pet")
        XCTAssertEqual(migrated.label, "Pet anzeigen")
        XCTAssertEqual(migrated.deviceMacro, "cmd-ctrl-opt-shift-p")
    }

    @MainActor
    func testLoadingPrunesEverythingExceptCodexAndClaudeAndBacksUpFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Profiles.json")
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)

        // A cluttered real-world profile list: the two we want, plus the
        // stock extras and a hand-made custom profile.
        var customDuplicate = ProfileFactory.claude(catalog: claudeCatalog)
        customDuplicate.name = "Claude Code"
        customDuplicate.id = UUID()
        let cluttered = [
            ProfileFactory.codex(catalog: catalog),
            customDuplicate,
            ProfileFactory.macOS(),
            ProfileFactory.safe(),
            ProfileFactory.codexReasoningTriggers(catalog: catalog),
            ProfileFactory.claude(catalog: claudeCatalog)
        ]
        try ProfileFileCodec.encode(cluttered).write(to: url)

        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        XCTAssertEqual(Set(store.profiles.map(\.name)), ["Codex", "Claude"])

        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Profiles.before-prune-") }
        XCTAssertEqual(backups.count, 1, "the untouched original list should be backed up exactly once before pruning")
        let backedUp = try ProfileFileCodec.decode(Data(contentsOf: backups[0]))
        XCTAssertEqual(backedUp.count, cluttered.count, "the backup should contain everything, including the dropped custom profile")

        // Re-loading the already-pruned file must not create another backup.
        _ = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        let backupsAfterReload = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Profiles.before-prune-") }
        XCTAssertEqual(backupsAfterReload.count, 1)
    }

    @MainActor
    func testLegacyProfileWithoutKeyboardActionIDDecodesInsteadOfResettingToDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-legacy-action-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Profiles.json")
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)

        // Simulate a `Profiles.json` saved before `KeyboardAction.id` existed:
        // every action object is missing the "id" key entirely.
        var document = try JSONSerialization.jsonObject(
            with: ProfileFileCodec.encode([ProfileFactory.codex(catalog: catalog), ProfileFactory.claude(catalog: claudeCatalog)])
        ) as! [String: Any]
        var profiles = document["profiles"] as! [[String: Any]]
        for profileIndex in profiles.indices {
            var layers = profiles[profileIndex]["layers"] as! [[String: Any]]
            for layerIndex in layers.indices {
                var controls = layers[layerIndex]["controls"] as! [[String: Any]]
                for controlIndex in controls.indices {
                    var action = controls[controlIndex]["action"] as! [String: Any]
                    action.removeValue(forKey: "id")
                    controls[controlIndex]["action"] = action
                }
                layers[layerIndex]["controls"] = controls
            }
            profiles[profileIndex]["layers"] = layers
        }
        document["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        XCTAssertEqual(Set(store.profiles.map(\.name)), ["Codex", "Claude"], "legacy id-less actions must still decode, not fall back to a fresh factory seed")
        XCTAssertEqual(store.profiles.first(where: { $0.name == "Codex" })?.action(for: .key2).codexActionID, "quick-chat")
        XCTAssertNil(store.lastLoadWarning)
    }

    @MainActor
    func testOneCorruptProfileIsSkippedWithoutDiscardingTheRestAndABackupIsWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-partial-corruption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Profiles.json")
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)

        var document = try JSONSerialization.jsonObject(
            with: ProfileFileCodec.encode([ProfileFactory.codex(catalog: catalog), ProfileFactory.claude(catalog: claudeCatalog)])
        ) as! [String: Any]
        var profiles = document["profiles"] as! [[String: Any]]
        // Corrupt only the Codex profile beyond recovery (required "name" key gone).
        profiles[0].removeValue(forKey: "name")
        document["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        XCTAssertTrue(store.profiles.contains(where: { $0.name == "Claude" }), "the undamaged profile must survive")
        XCTAssertNotNil(store.lastLoadWarning)

        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Profiles.corrupt-") }
        XCTAssertEqual(backups.count, 1, "the raw corrupt file should be backed up before recovery")
    }

    func testActionKindAgentAndCatalogHelpersCoverBothApps() {
        XCTAssertTrue(ActionKind.codexAgent.isAgent)
        XCTAssertTrue(ActionKind.claudeAgent.isAgent)
        XCTAssertFalse(ActionKind.disabled.isAgent)
        XCTAssertTrue(ActionKind.codexShortcut.isAppShortcut)
        XCTAssertTrue(ActionKind.claudeShortcut.isAppShortcut)
        XCTAssertTrue(ActionKind.codexDeepLink.isAppDeepLink)
        XCTAssertTrue(ActionKind.claudeDeepLink.isAppDeepLink)
    }

    func testEncoderAutomationUsesDirectCodexShortcuts() {
        XCTAssertEqual(CodexEncoderCommand.decreaseEffort.directShortcutKeyCode, UInt16(kVK_F18))
        XCTAssertEqual(CodexEncoderCommand.increaseEffort.directShortcutKeyCode, UInt16(kVK_F19))
        XCTAssertNil(CodexEncoderCommand.openPicker.directShortcutKeyCode)
        XCTAssertEqual(CodexEncoderCommand.closePicker.directShortcutKeyCode, UInt16(kVK_Escape))
    }

    func testImportExportRoundTrip() throws {
        let profile = ProfileFactory.safe()
        let data = try ProfileFileCodec.encode([profile])
        let decoded = try ProfileFileCodec.decode(data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].action(for: .encoderRight).deviceMacro, "f21")
    }

    func testCodexActionsMapToOfficialShortcuts() {
        let catalog = CodexActionCatalog()
        XCTAssertEqual(catalog.keyboardAction(id: "command-menu")?.deviceMacro, "cmd-shift-p")
        XCTAssertEqual(catalog.keyboardAction(id: "quick-chat")?.deviceMacro, "cmd-opt-n")
        XCTAssertEqual(catalog.keyboardAction(id: "dictation")?.deviceMacro, "cmd-f17")
        XCTAssertEqual(catalog.action(id: "dictation")?.codexCommandID, "globalDictationHold")
        XCTAssertEqual(catalog.keyboardAction(id: "new-chat")?.deepLink, "codex://threads/new")
        XCTAssertEqual(catalog.action(id: "increase-font-size")?.deviceMacro, "cmd-equal")
        XCTAssertEqual(catalog.keyboardAction(id: "send-message")?.deviceMacro, "enter")
        XCTAssertEqual(catalog.action(id: "send-message")?.shortcut, "Enter")

        XCTAssertEqual(catalog.keyboardAction(id: "settings")?.deviceMacro, "f13")
        XCTAssertEqual(catalog.keyboardAction(id: "open-model-picker")?.deviceMacro, "f14")
        XCTAssertEqual(catalog.keyboardAction(id: "open-side-chat")?.deviceMacro, "f15")
        XCTAssertEqual(catalog.action(id: "open-skills")?.execution, .deepLink)
        XCTAssertEqual(catalog.action(id: "reasoning-decrease")?.execution, .configurableShortcut)
        XCTAssertTrue(catalog.categories.contains("Terminal und Panels"))
    }

    func testCH57xConfigurationGeneration() throws {
        let profile = ProfileFactory.safe()
        let output = try CH57xConfigurationEncoder().encode(profile: profile)
        XCTAssertTrue(output.contains("model: ch57x-2"))
        XCTAssertTrue(output.contains("rows: 2"))
        XCTAssertTrue(output.contains("columns: 3"))
        XCTAssertTrue(output.contains("- ['f13', 'f14', 'f15']"))
        XCTAssertTrue(output.contains("ccw: 'f19'"))
        XCTAssertTrue(output.contains("press: 'f20'"))
        XCTAssertTrue(output.contains("cw: 'f21'"))
    }

    func testEscapesSingleQuoteAndSpecialCharacters() throws {
        var profile = ProfileFactory.safe()
        profile.setAction(
            KeyboardAction(kind: .keySequence, label: "Quote", deviceMacro: "ctrl-a,'"),
            for: .key1
        )
        let output = try CH57xConfigurationEncoder().encode(profile: profile)
        XCTAssertTrue(output.contains("'ctrl-a,'''") )
    }

    func testTextSubmissionBuildsASequenceWithEnter() throws {
        let action = try XCTUnwrap(KeyboardAction.textSubmission("Yeet"))
        XCTAssertEqual(action.kind, .textSubmission)
        XCTAssertEqual(action.deviceMacro, "shift-y,e,e,t,enter")
        XCTAssertEqual(action.submittedText, "Yeet")

        var profile = ProfileFactory.safe()
        profile.setAction(action, for: .key1)
        let output = try CH57xConfigurationEncoder().encode(profile: profile)
        XCTAssertTrue(output.contains("- ['shift-y,e,e,t,enter', 'f14', 'f15']"))
    }

    func testTextSubmissionRejectsUnsupportedOrTooLongText() {
        XCTAssertNil(KeyboardAction.textSubmission("Hello"))
        XCTAssertNil(KeyboardAction.textSubmission("Hi!"))
        XCTAssertNil(KeyboardAction.textSubmission(""))
    }

    func testValidationErrorsForUnsafeAndTooLongExpressions() {
        var profile = ProfileFactory.safe()
        profile.setAction(KeyboardAction(kind: .singleKey, label: "Bad", deviceMacro: "a\nb"), for: .key1)
        XCTAssertThrowsError(try CH57xConfigurationEncoder().encode(profile: profile)) { error in
            XCTAssertEqual(error as? CH57xConfigurationError, .invalidExpression(.key1, "a\nb"))
        }

        profile.setAction(KeyboardAction(kind: .keySequence, label: "Long", deviceMacro: "a,b,c,d,e,f"), for: .key1)
        XCTAssertThrowsError(try CH57xConfigurationEncoder().encode(profile: profile)) { error in
            XCTAssertEqual(error as? CH57xConfigurationError, .sequenceTooLong(.key1))
        }
    }

    func testDeferredActionIsNotUploadable() {
        var profile = ProfileFactory.safe()
        profile.setAction(KeyboardAction(kind: .codexDeepLink, label: "Open", deepLink: "codex://settings"), for: .key1)
        XCTAssertThrowsError(try CH57xConfigurationEncoder().encode(profile: profile)) { error in
            XCTAssertEqual(error as? CH57xConfigurationError, .unsupportedDeferredAction(.key1))
        }
    }

    func testConfirmedDeviceCapabilities() {
        let capabilities = DeviceCapabilities.ch57x8890
        XCTAssertEqual(capabilities.keyCount, 6)
        XCTAssertEqual(capabilities.encoderCount, 1)
        XCTAssertEqual(capabilities.encoderActionsPerEncoder, 3)
        XCTAssertTrue(capabilities.supportsGlobalLEDMode)
        XCTAssertEqual(capabilities.supportedLEDModes, [0, 1, 2])
        XCTAssertFalse(capabilities.supportsPerKeyLED)
    }

    func testDeviceDetectorRecognizesActualVendorAndProductID() {
        let ioreg = """
        +-o IOUSBHostDevice@01120000  <class IOUSBHostDevice>
          | { "idProduct" = 34960 "idVendor" = 4489 "locationID" = 17956864 }
        """
        let detector = DeviceDetector(runner: MockRunner(result: ProcessResult(exitCode: 0, stdout: ioreg, stderr: "", timedOut: false, launchError: nil)))
        let report = detector.detect()
        XCTAssertEqual(report.device?.vendorID, 0x1189)
        XCTAssertEqual(report.device?.productID, 0x8890)
        XCTAssertEqual(report.device?.capabilities, .ch57x8890)
    }

    func testLiveCH57xDetectionWhenHardwareTestsAreRequested() throws {
        guard ProcessInfo.processInfo.environment["AGENT_MICRO_HARDWARE_TEST"] == "1" else {
            throw XCTSkip("Set AGENT_MICRO_HARDWARE_TEST=1 only on the Mac with the attached test pad.")
        }
        let report = DeviceDetector().detect()
        XCTAssertEqual(report.device?.vendorID, 0x1189, report.error ?? "Kein Gerät")
        XCTAssertEqual(report.device?.productID, 0x8890, report.rawIORegistry.prefix(2_000).description)
        XCTAssertEqual(report.device?.support, .supported)
    }

    func testHIDFunctionKeyMappingUsesCorrectNonContiguousHIDUsages() {
        XCTAssertEqual(HIDInputEvent.functionKeyName(0x3A), "F1")
        XCTAssertEqual(HIDInputEvent.functionKeyName(0x45), "F12")
        XCTAssertEqual(HIDInputEvent.functionKeyName(0x68), "F13")
        XCTAssertEqual(HIDInputEvent.functionKeyName(0x70), "F21")
        XCTAssertNil(HIDInputEvent.functionKeyName(0x46))
    }

    func testBootKeyboardArrayValueIsDecodedAsTheActualFunctionKey() {
        let normalized = HIDInputEvent.normalizedKeyboardValue(elementUsage: 0xFFFF, value: 0x71)
        XCTAssertEqual(normalized?.usage, 0x71)
        XCTAssertEqual(normalized?.value, 1)

        let variable = HIDInputEvent.normalizedKeyboardValue(elementUsage: 0x71, value: 1)
        XCTAssertEqual(variable?.usage, 0x71)
        XCTAssertEqual(variable?.value, 1)
    }

    func testCH57xDuplicateReportsAreCollapsedWithoutDroppingRealDetents() {
        var debouncer = HIDInputDebouncer()
        XCTAssertTrue(debouncer.accepts(usage: 0x71, at: 10.000))
        XCTAssertFalse(debouncer.accepts(usage: 0x71, at: 10.010))
        XCTAssertTrue(debouncer.accepts(usage: 0x73, at: 10.011))
        XCTAssertTrue(debouncer.accepts(usage: 0x71, at: 10.050))
    }

    func testProcessSuccessRejectsStderrEvenWithExitCodeZero() {
        let result = ProcessResult(exitCode: 0, stdout: "", stderr: "warning", timedOut: false, launchError: nil)
        XCTAssertFalse(result.succeeded)
    }

    func testRunnerDrainsLargeOutputBeforeTimeout() {
        let result = FoundationProcessRunner().run(ProcessInvocation(
            executablePath: "/usr/bin/seq",
            arguments: ["1", "50000"],
            timeout: 3
        ))
        XCTAssertTrue(result.succeeded, result.failureDescription)
        XCTAssertTrue(result.stdout.contains("50000"))
    }

    func testProcessClientUsesMockRunnerForValidation() throws {
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-test-helper-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: helper) }

        let runner = RecordingMockRunner()
        let client = CH57xProcessClient(runner: runner, helperURL: helper)
        let result = client.validate(configuration: "model: ch57x-2")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.arguments.first, "validate")
    }

    func testUploadPinsTheConfirmedVendorAndProductID() throws {
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-test-helper-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: helper) }

        let runner = RecordingMockRunner()
        let client = CH57xProcessClient(runner: runner, helperURL: helper)
        _ = client.upload(configuration: "model: ch57x-2", target: .ch57x8890)
        XCTAssertEqual(Array(runner.invocations[0].arguments.prefix(5)), ["--vendor-id", "0x1189", "--product-id", "0x8890", "upload"])
    }

    func testLEDModePinsTheConfirmedVendorAndProductID() throws {
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-test-helper-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: helper) }

        let runner = RecordingMockRunner()
        let client = CH57xProcessClient(runner: runner, helperURL: helper)
        _ = client.setConfirmedLEDMode(2, target: .ch57x8890)
        XCTAssertEqual(runner.invocations[0].arguments, ["--vendor-id", "0x1189", "--product-id", "0x8890", "led", "2"])
    }

    func testCodexPadLEDPacketUsesConfirmedLogicalIndexAndChecksum() {
        let setting = KeyLEDConfiguration(
            control: .key6,
            effect: .pulse,
            red: 12,
            green: 34,
            blue: 56,
            brightness: 200,
            periodMilliseconds: 1_200
        )
        let packet = CodexPadPacketEncoder().ledPacket(setting: setting)

        XCTAssertEqual(packet.count, 32)
        XCTAssertEqual(Array(packet[0...10]), [0x43, 0x50, 0x01, 0x10, 0x03, 0x03, 12, 34, 56, 60, 200])
        XCTAssertEqual(packet[31], packet[0..<31].reduce(0, ^))
    }

    func testTransientWholePadLEDsCoverAllSixKeys() {
        let packets = CodexPadPacketEncoder().allLEDs(
            effect: .pulse,
            red: 255,
            green: 255,
            blue: 255,
            brightness: 255,
            periodMilliseconds: 900
        )

        XCTAssertEqual(packets.count, 6)
        XCTAssertEqual(packets.map { $0[4] }, [2, 1, 0, 5, 4, 3])
        XCTAssertTrue(packets.allSatisfy { $0[5] == LEDEffect.pulse.rawValue && $0[6...10] == [255, 255, 255, 45, 255] })
    }

    func testNativePulseUsesFirmwarePulseCommands() {
        let packets = CodexPadPacketEncoder().allLEDs(
            effect: .pulse,
            red: 255,
            green: 0,
            blue: 0,
            brightness: 176,
            periodMilliseconds: 900
        )

        XCTAssertEqual(packets.count, 6)
        XCTAssertTrue(packets.allSatisfy { $0[5] == LEDEffect.pulse.rawValue })
        XCTAssertTrue(packets.allSatisfy { $0[6...10] == [255, 0, 0, 45, 176] })
    }

    func testCodexPadAllOffPacketUsesTheGlobalOffCommand() {
        let packet = CodexPadPacketEncoder().allOffPacket()

        XCTAssertEqual(Array(packet[0...3]), [0x43, 0x50, 0x01, 0x12])
        XCTAssertEqual(packet[31], packet[0..<31].reduce(0, ^))
    }

    func testUploadEndsWithConfiguredIdleLightingInsteadOfGlobalOff() throws {
        var profile = ProfileFactory.safe()
        profile.idleLighting = IdleLEDConfiguration(
            enabled: true,
            effect: .pulse,
            red: 11,
            green: 22,
            blue: 33,
            brightness: 144,
            periodMilliseconds: 1_200
        )

        let packets = try CodexPadPacketEncoder().uploadPackets(profile: profile)
        let idlePackets = packets.suffix(HardwareControl.buttons.count)

        XCTAssertEqual(packets.count, 21)
        XCTAssertTrue(packets.allSatisfy { $0[3] != 0x12 })
        XCTAssertTrue(idlePackets.allSatisfy {
            $0[3] == 0x10 && $0[5...10] == [LEDEffect.pulse.rawValue, 11, 22, 33, 60, 144]
        })
    }

    func testFirmwareInputUsesLogicalOrderWhileConfigurationUsesPCBOrder() {
        let dictationControl = HardwareControl.key4
        let mask = UInt16(1) << dictationControl.reportedControlIndex

        XCTAssertEqual(dictationControl.firmwareControlIndex, 5)
        XCTAssertEqual(dictationControl.reportedControlIndex, 3)
        XCTAssertEqual(HardwareControl(firmwareControlIndex: 5), .key4)
        XCTAssertEqual(HardwareControl(reportedControlIndex: 3), .key4)
        XCTAssertNotEqual(mask & (UInt16(1) << dictationControl.reportedControlIndex), 0)
    }

    func testCodexPadKeyboardBindingPacketEncodesShortcut() throws {
        let action = KeyboardAction(kind: .keyboardShortcut, label: "Neu", icon: "command", deviceMacro: "cmd-shift-n")
        let packet = try CodexPadPacketEncoder().bindingPacket(action: action, control: .key2)

        XCTAssertEqual(Array(packet[0...8]), [0x43, 0x50, 0x01, 0x20, 0x01, 0x01, 0x01, 0x0A, 0x11])
        XCTAssertEqual(packet[31], packet[0..<31].reduce(0, ^))
    }

    func testCodexPadStatusRequestUsesProtocolV2() {
        let packet = CodexPadPacketEncoder().statusRequestPacket()
        XCTAssertEqual(Array(packet[0...3]), [0x43, 0x50, 0x02, 0x30])
        XCTAssertEqual(packet[31], packet[0..<31].reduce(0, ^))
    }

    func testHostOnlyActionProducesNoKeyboardMacro() throws {
        let action = KeyboardAction(kind: .hostEvent, label: "Agent starten")
        let packet = try CodexPadPacketEncoder().bindingPacket(action: action, control: .key1)
        XCTAssertEqual(packet[5], 3)
        XCTAssertEqual(packet[6], 0)
    }

    func testCodexAgentActionUsesTheFirmwareAppOnlyEvent() throws {
        let action = KeyboardAction(kind: .codexAgent, label: "Build Agent", icon: "terminal.fill")
        let packet = try CodexPadPacketEncoder().bindingPacket(action: action, control: .key1)

        XCTAssertEqual(packet[4], HardwareControl.key1.firmwareControlIndex)
        XCTAssertEqual(packet[5], 3)
        XCTAssertEqual(packet[6], 0)
        XCTAssertTrue(action.isEnabled)
    }

    func testCodexStatusMapperCoversAllRequiredLiveStates() {
        XCTAssertEqual(StatusMapper.threadStatus(type: "notLoaded"), .idle)
        XCTAssertEqual(StatusMapper.threadStatus(type: "idle"), .idle)
        XCTAssertEqual(StatusMapper.threadStatus(type: "active"), .running)
        XCTAssertEqual(StatusMapper.threadStatus(type: "active", activeFlags: ["waitingOnApproval"]), .needsAttention)
        XCTAssertEqual(StatusMapper.threadStatus(type: "active", activeFlags: ["waitingOnUserInput"]), .needsAttention)
        XCTAssertEqual(StatusMapper.threadStatus(type: "systemError"), .failed)
        XCTAssertEqual(StatusMapper.turnStatus("completed"), .completed)
        XCTAssertEqual(StatusMapper.turnStatus("failed"), .failed)
        XCTAssertEqual(StatusMapper.turnStatus("interrupted"), .interrupted)
    }

    func testSnapshotTreatsExternallyOwnedUnfinishedTurnAsRunning() {
        XCTAssertEqual(StatusMapper.synchronizedStatus(
            threadType: "notLoaded",
            latestTurnStatus: "interrupted",
            latestTurnHasCompletionTimestamp: false
        ), .running)
    }

    func testSnapshotKeepsActuallyCompletedInterruptedTurnPurple() {
        XCTAssertEqual(StatusMapper.synchronizedStatus(
            threadType: "notLoaded",
            latestTurnStatus: "interrupted",
            latestTurnHasCompletionTimestamp: true
        ), .interrupted)
    }

    func testSnapshotMapsCompletedAndFailedTurns() {
        XCTAssertEqual(StatusMapper.synchronizedStatus(
            threadType: "notLoaded",
            latestTurnStatus: "completed",
            latestTurnHasCompletionTimestamp: true
        ), .completed)
        XCTAssertEqual(StatusMapper.synchronizedStatus(
            threadType: "notLoaded",
            latestTurnStatus: "failed",
            latestTurnHasCompletionTimestamp: true
        ), .failed)
    }

    func testCodexStatusLEDMappingMatchesTheProductContract() {
        let idle = StatusMapper.ledConfiguration(for: .idle, control: .key1)
        XCTAssertEqual(idle.effect, .steady)
        XCTAssertEqual([idle.red, idle.green, idle.blue], [255, 255, 255])
        XCTAssertLessThan(idle.brightness, 100)

        let running = StatusMapper.ledConfiguration(for: .running, control: .key2)
        XCTAssertEqual(running.effect, .pulse)
        XCTAssertEqual([running.red, running.green, running.blue], [20, 110, 255])

        let approval = StatusMapper.ledConfiguration(for: .needsAttention, control: .key3)
        XCTAssertEqual(approval.effect, .pulse)
        XCTAssertEqual([approval.red, approval.green, approval.blue], [255, 105, 0])

        let completed = StatusMapper.ledConfiguration(for: .completed, control: .key4)
        XCTAssertEqual(completed.effect, .steady)
        XCTAssertEqual([completed.red, completed.green, completed.blue], [0, 220, 70])

        let failed = StatusMapper.ledConfiguration(for: .failed, control: .key5)
        XCTAssertEqual(failed.effect, .blink)
        XCTAssertEqual([failed.red, failed.green, failed.blue], [255, 0, 0])

        let interrupted = StatusMapper.ledConfiguration(for: .interrupted, control: .key6)
        XCTAssertEqual(interrupted.effect, .steady)
        XCTAssertEqual([interrupted.red, interrupted.green, interrupted.blue], [160, 70, 255])

        let unassigned = StatusMapper.ledConfiguration(for: .unassigned, control: .key1)
        XCTAssertEqual(unassigned.effect, .off)
    }

    func testLEDReactionEventMapsAgentIdleSeparatelyFromUnassigned() {
        XCTAssertEqual(LEDReactionEvent.event(for: .idle), .agentIdle)
        XCTAssertNil(LEDReactionEvent.event(for: .unassigned))
        XCTAssertEqual(LEDReactionEvent.event(for: .running), .agentRunning)
        XCTAssertEqual(LEDReactionEvent.event(for: .needsAttention), .agentNeedsAttention)
        XCTAssertEqual(LEDReactionEvent.event(for: .completed), .agentCompleted)
        XCTAssertEqual(LEDReactionEvent.event(for: .failed), .agentFailed)
        XCTAssertEqual(LEDReactionEvent.event(for: .interrupted), .agentInterrupted)
    }

    func testAgentIdleReactionDefaultsToRangePulseAndCanFallBackToBaseLighting() {
        let profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        let idleReaction = profile.reaction(for: .agentIdle)
        XCTAssertEqual(idleReaction.effect, .pulse)
        XCTAssertTrue(idleReaction.disablesIdle)
        XCTAssertGreaterThan(idleReaction.minBrightness, 0)

        var mutable = profile
        mutable.setReaction(LEDReactionConfiguration(
            event: .agentIdle, effect: .off, red: 0, green: 0, blue: 0, brightness: 0, periodMilliseconds: 1_000
        ))
        XCTAssertEqual(mutable.reaction(for: .agentIdle).effect, .off, "Switching to .off is how a profile opts back into plain idle lighting")
    }

    /// A fake `schedule` that hands the caller manual control over when (or
    /// whether) a pending hold fires, instead of waiting on a real `Timer`.
    @MainActor
    private final class FakeScheduler {
        private(set) var pendingFires: [@MainActor @Sendable () -> Void] = []
        private(set) var cancelCount = 0

        func schedule(interval: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
            pendingFires.append(fire)
            let index = pendingFires.count - 1
            return { [weak self] in
                self?.cancelCount += 1
                self?.pendingFires[index] = {}
            }
        }

        func fireLatest() {
            pendingFires.last?()
        }
    }

    @MainActor
    func testQuickAssignOpensPickerAtThresholdAndCommitsOnlyOnRelease() {
        func thread(_ id: String, age: TimeInterval) -> CodexThreadDescriptor {
            CodexThreadDescriptor(
                id: id, title: id, preview: "", cwd: "/tmp",
                parentThreadID: nil, agentNickname: nil, agentRole: nil,
                updatedAt: Date().addingTimeInterval(age), status: .idle
            )
        }
        let current = thread("thread-current", age: -20)
        let newer = thread("thread-newer", age: 0)
        var currentAssignment = current.id
        var assignedThread: CodexThreadDescriptor?
        var assignedControl: HardwareControl?
        var openedControl: HardwareControl?
        var finished: [Bool] = []
        let scheduler = FakeScheduler()

        let service = CodexQuickAssignService(
            isEnabled: { true },
            isDesignatedAgentControl: { _ in true },
            isTapHoldConfigured: { _ in false },
            candidateThreads: { _ in [newer, current] },
            assignedThreadID: { _ in currentAssignment },
            appName: { "Codex" },
            schedule: scheduler.schedule
        )
        service.onAssign = { thread, control in
            assignedThread = thread
            assignedControl = control
        }
        service.onTap = { openedControl = $0 }
        service.onSelectionFinished = { finished.append($0) }

        func event(_ phase: CodexPadPhysicalEvent.Phase) -> CodexPadPhysicalEvent {
            CodexPadPhysicalEvent(sequence: 0, control: HardwareControl.key1.reportedControlIndex, phase: phase)
        }

        // Releasing before the threshold fires must cancel the pending hold.
        service.handle(event(.pressed))
        service.handle(event(.released))
        XCTAssertEqual(scheduler.cancelCount, 1)
        XCTAssertNil(assignedThread)
        XCTAssertEqual(openedControl, .key1)

        // The threshold opens the picker but keeps the current assignment as
        // the safe selection. Releasing without rotation is a no-op.
        service.handle(event(.pressed))
        scheduler.fireLatest()
        XCTAssertTrue(service.isSelecting)
        XCTAssertEqual(service.picker?.selectedThread?.id, current.id)
        XCTAssertNil(assignedThread)
        service.handle(event(.released))
        XCTAssertNil(assignedThread)
        XCTAssertEqual(finished, [false])

        // A new hold plus one turn toward newer commits only when the agent
        // key is released.
        service.handle(event(.pressed))
        scheduler.fireLatest()
        service.handle(CodexPadPhysicalEvent(
            sequence: 0,
            control: HardwareControl.encoderLeft.reportedControlIndex,
            phase: .triggered
        ))
        XCTAssertEqual(service.picker?.selectedThread?.id, newer.id)
        XCTAssertNil(assignedThread)
        service.handle(event(.released))
        XCTAssertEqual(assignedThread?.id, "thread-newer")
        XCTAssertEqual(assignedControl, .key1)
        XCTAssertEqual(finished, [false, true])
        currentAssignment = newer.id
    }

    func testAgentActionOwnsHoldAndClearsGenericSecondBinding() {
        var profile = ProfileFactory.safe()
        profile.setHoldAction(.profileSwitch, thresholdMilliseconds: 400, for: .key1)
        XCTAssertTrue(profile.binding(for: .key1).isTapHold)

        profile.setAction(
            KeyboardAction(kind: .codexAgent, label: "Codex Agent", icon: "terminal.fill"),
            for: .key1
        )
        XCTAssertNil(profile.holdAction(for: .key1))
        XCTAssertFalse(profile.binding(for: .key1).isTapHold)

        profile.setHoldAction(.profileSwitch, thresholdMilliseconds: 400, for: .key1)
        XCTAssertNil(profile.holdAction(for: .key1), "Agent controls reserve hold for thread reassignment")
    }

    @MainActor
    func testQuickAssignIgnoresControlsNeverDesignatedAsAgentKeys() {
        var assignedThread: CodexThreadDescriptor?
        let scheduler = FakeScheduler()
        let service = CodexQuickAssignService(
            isEnabled: { true },
            isDesignatedAgentControl: { _ in false },
            isTapHoldConfigured: { _ in false },
            candidateThreads: { _ in [] },
            assignedThreadID: { _ in nil },
            appName: { "Codex" },
            schedule: scheduler.schedule
        )
        service.onAssign = { thread, _ in assignedThread = thread }

        // A dictation key (never assigned to a Codex thread) must not be
        // hijacked by its own long hold-to-record gesture.
        service.handle(CodexPadPhysicalEvent(sequence: 0, control: HardwareControl.key4.reportedControlIndex, phase: .pressed))
        XCTAssertTrue(scheduler.pendingFires.isEmpty, "Must never schedule a fire for a non-agent control")
        service.handle(CodexPadPhysicalEvent(sequence: 0, control: HardwareControl.key4.reportedControlIndex, phase: .released))
        XCTAssertNil(assignedThread)
    }

    func testRecentPickerCandidatesKeepOldCurrentAssignmentWithinTenRows() {
        let now = Date()
        let threads = (0..<12).map { index in
            CodexThreadDescriptor(
                id: "thread-\(index)", title: "\(index)", preview: "", cwd: "/tmp",
                parentThreadID: nil, agentNickname: nil, agentRole: nil,
                updatedAt: now.addingTimeInterval(TimeInterval(-index)), status: .idle
            )
        }
        let result = CodexQuickAssignService.recentCandidates(
            from: threads,
            assignedThreadID: "thread-11"
        )
        XCTAssertEqual(result.count, 10)
        XCTAssertTrue(result.contains(where: { $0.id == "thread-11" }))
        XCTAssertFalse(result.contains(where: { $0.id == "thread-9" }))
    }

    @MainActor
    func testAllSixCodexAgentAssignmentsPersistLocally() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-agent-store-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("AgentKeyAssignments.json")
        let store = CodexThreadStore(bridge: CodexEventBridge(), persistenceURL: url)

        for (index, control) in HardwareControl.buttons.enumerated() {
            store.assign(CodexThreadDescriptor(
                id: "thread-\(index)",
                title: "Agent \(index + 1)",
                preview: "",
                cwd: "/tmp",
                parentThreadID: index.isMultiple(of: 2) ? nil : "parent",
                agentNickname: nil,
                agentRole: nil,
                updatedAt: .now,
                status: .idle
            ), to: control)
        }

        XCTAssertEqual(store.assignments.count, 6)
        XCTAssertNil(store.lastPersistenceError)
        let restored = CodexThreadStore(bridge: CodexEventBridge(), persistenceURL: url)
        XCTAssertEqual(restored.assignments.count, 6)
        XCTAssertEqual(restored.assignment(for: .key6)?.threadID, "thread-5")
    }

    @MainActor
    func testLegacyClaudeCLIAssignmentMigratesToReadableDesktopSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-micro-claude-assignment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ClaudeAgentKeyAssignments.json")
        let cliID = "8566a8f9-bd20-4f55-bb33-7675859812ed"
        let desktopID = "local_1cdac978-4c4d-452c-87ca-d3769b994e0a"
        try JSONEncoder().encode([
            AgentKeyAssignment(
                control: .key1,
                threadID: cliID,
                threadTitle: "codex-micro-3c",
                isSubagent: false
            )
        ]).write(to: url)

        let bridge = CodexEventBridge()
        let store = CodexThreadStore(bridge: bridge, automationApp: .claude, persistenceURL: url)
        bridge.onThreads?([
            CodexThreadDescriptor(
                id: desktopID,
                title: "Agent Micro pre-release adjustments",
                preview: "Agent Micro · 1cdac978",
                cwd: "/Users/test/Agent Micro",
                parentThreadID: nil,
                agentNickname: nil,
                agentRole: "Claude Desktop",
                updatedAt: .now,
                status: .idle,
                alternateID: cliID,
                navigationID: cliID
            )
        ])

        let migrated = try XCTUnwrap(store.assignment(for: .key1))
        XCTAssertEqual(migrated.threadID, desktopID)
        XCTAssertEqual(migrated.navigationID, cliID)
        XCTAssertEqual(migrated.threadTitle, "Agent Micro pre-release adjustments")
        XCTAssertEqual(migrated.threadProject, "Agent Micro")

        let restored = CodexThreadStore(bridge: CodexEventBridge(), automationApp: .claude, persistenceURL: url)
        XCTAssertEqual(restored.assignment(for: .key1)?.threadID, desktopID)
        XCTAssertEqual(restored.assignment(for: .key1)?.navigationID, cliID)
    }

    @MainActor
    func testAgentStatusArrivingBeforeThreadListIsNotLost() {
        let bridge = CodexEventBridge()
        let persistenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexpad-early-status-\(UUID().uuidString).json")
        let store = CodexThreadStore(bridge: bridge, persistenceURL: persistenceURL)
        let thread = CodexThreadDescriptor(
            id: "early-agent",
            title: "Early Agent",
            preview: "",
            cwd: "/tmp",
            parentThreadID: nil,
            agentNickname: nil,
            agentRole: nil,
            updatedAt: .now,
            status: .idle
        )
        store.assign(thread, to: .key1)
        var changeCount = 0
        store.onStatusChange = { changeCount += 1 }

        bridge.onStatus?(thread.id, .running, .event)
        bridge.onThreads?([thread])

        XCTAssertEqual(store.status(for: .key1), .running)
        XCTAssertEqual(changeCount, 1)
    }

    @MainActor
    func testCompletedAcknowledgementChangesPresentationOnlyUntilNewWork() {
        let bridge = CodexEventBridge()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexpad-completed-ack-\(UUID().uuidString).json")
        let store = CodexThreadStore(bridge: bridge, persistenceURL: url)
        let thread = CodexThreadDescriptor(
            id: "completed-thread", title: "Done", preview: "", cwd: "/tmp",
            parentThreadID: nil, agentNickname: nil, agentRole: nil,
            updatedAt: .now, status: .completed
        )
        store.assign(thread, to: .key1)
        bridge.onThreads?([thread])

        XCTAssertEqual(store.status(for: .key1), .completed)
        XCTAssertEqual(store.presentedStatus(for: .key1), .completed)
        XCTAssertTrue(store.acknowledgeCompleted(for: .key1))
        XCTAssertEqual(store.status(for: .key1), .completed)
        XCTAssertEqual(store.presentedStatus(for: .key1), .idle)

        bridge.onStatus?(thread.id, .running, .event)
        XCTAssertEqual(store.presentedStatus(for: .key1), .running)
        bridge.onStatus?(thread.id, .completed, .event)
        XCTAssertEqual(store.presentedStatus(for: .key1), .completed)
    }

    @MainActor
    func testEventStatusWinsOverIdleSnapshotUntilInputResolvesAndTerminalTriggersOnce() {
        let bridge = CodexEventBridge()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentmicro-status-flow-\(UUID().uuidString).json")
        let store = CodexThreadStore(bridge: bridge, persistenceURL: url)
        let thread = CodexThreadDescriptor(
            id: "status-flow-thread", title: "Test", preview: "", cwd: "/tmp/project",
            parentThreadID: nil, agentNickname: nil, agentRole: nil, updatedAt: .now, status: .idle
        )
        store.assign(thread, to: .key1)
        bridge.onThreads?([thread])

        var transitions: [(CodexAgentStatus, AgentStatusSource)] = []
        store.onStatusUpdate = { _, status, source in transitions.append((status, source)) }
        bridge.onStatus?(thread.id, .running, .event)
        bridge.onStatus?(thread.id, .needsAttention, .event)
        var staleRunning = thread
        staleRunning.status = .running
        bridge.onThreads?([staleRunning]) // a separate app-server often sees only "running"
        bridge.onThreads?([thread]) // a stale idle reconciliation must not hide input
        XCTAssertEqual(store.status(for: .key1), .needsAttention)

        bridge.onStatus?(thread.id, .running, .event)
        bridge.onStatus?(thread.id, .completed, .event)
        bridge.onStatus?(thread.id, .completed, .event)
        XCTAssertEqual(transitions.filter { $0.0 == .completed }.count, 1)
        XCTAssertEqual(transitions.last?.1, .event)

        bridge.onThreads?([thread])
        XCTAssertEqual(
            store.status(for: .key1),
            .completed,
            "A stale idle list snapshot must not erase the terminal event"
        )
        XCTAssertTrue(store.acknowledgeCompleted(for: .key1))
        XCTAssertEqual(store.presentedStatus(for: .key1), .idle)
    }

    @MainActor
    func testIdleReconciliationCannotOverwriteKnownAgentStates() {
        let bridge = CodexEventBridge()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexpad-stale-idle-\(UUID().uuidString).json")
        let store = CodexThreadStore(bridge: bridge, persistenceURL: url)
        let idleThread = CodexThreadDescriptor(
            id: "stale-idle-thread", title: "Test", preview: "", cwd: "/tmp/project",
            parentThreadID: nil, agentNickname: nil, agentRole: nil,
            updatedAt: .now, status: .idle
        )
        store.assign(idleThread, to: .key1)
        bridge.onThreads?([idleThread])

        for protectedStatus in [
            CodexAgentStatus.running,
            .needsAttention,
            .completed,
            .failed,
            .interrupted
        ] {
            bridge.onStatus?(idleThread.id, protectedStatus, .event)
            XCTAssertEqual(store.status(for: .key1), protectedStatus)

            // Covers the descriptor path used by thread/list and thread/read.
            bridge.onThreads?([idleThread])
            XCTAssertEqual(
                store.status(for: .key1),
                protectedStatus,
                "An idle descriptor snapshot must not overwrite \(protectedStatus)"
            )

            // Covers the explicit synchronized-status callback from thread/read.
            bridge.onStatus?(idleThread.id, .idle, .snapshot)
            XCTAssertEqual(
                store.status(for: .key1),
                protectedStatus,
                "An idle status snapshot must not overwrite \(protectedStatus)"
            )
        }

        // A real event remains authoritative and can intentionally return the
        // thread to idle.
        bridge.onStatus?(idleThread.id, .idle, .event)
        XCTAssertEqual(store.status(for: .key1), .idle)

        XCTAssertEqual(
            bridge.snapshotAuthority,
            .reconciliationOnly,
            "Codex owns its status transitions through events; a poll must never end one"
        )
    }

    /// Claude has no event stream, so the disappearance of a session from
    /// `claude agents --json` is the only end-of-run signal that will ever
    /// arrive. Without this the LED pulsed blue forever after the first run.
    @MainActor
    func testClaudePollSnapshotEndsRunningButNotTerminalOrAttentionStates() {
        let bridge = ClaudeAgentBridge()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-poll-idle-\(UUID().uuidString).json")
        let store = CodexThreadStore(bridge: bridge, automationApp: .claude, persistenceURL: url)
        let idleThread = CodexThreadDescriptor(
            id: "local_poll", title: "Claude", preview: "", cwd: "/tmp/project",
            parentThreadID: nil, agentNickname: nil, agentRole: "Claude Desktop",
            updatedAt: .now, status: .idle,
            alternateID: "cli-uuid", navigationID: "session_01ABC"
        )
        store.assign(idleThread, to: .key1)
        bridge.onThreads?([idleThread])

        var runningThread = idleThread
        runningThread.status = .running
        bridge.onThreads?([runningThread])
        XCTAssertEqual(store.status(for: .key1), .running)

        // The session exits: the poll reports the Desktop descriptor as idle.
        bridge.onThreads?([idleThread])
        XCTAssertEqual(
            store.status(for: .key1),
            .idle,
            "A poll-only bridge must be allowed to end a running state"
        )

        // Hook-driven states are still protected — a vanished process is not
        // evidence that a completed, failed or attention state never happened.
        for protectedStatus in [
            CodexAgentStatus.needsAttention,
            .completed,
            .failed,
            .interrupted
        ] {
            bridge.onStatus?(idleThread.id, protectedStatus, .hook)
            XCTAssertEqual(store.status(for: .key1), protectedStatus)
            bridge.onThreads?([idleThread])
            XCTAssertEqual(
                store.status(for: .key1),
                protectedStatus,
                "An idle poll snapshot must not overwrite \(protectedStatus)"
            )
        }
    }

    /// Without the hooks the poll still yields a real running/idle state, so
    /// the UI must name that state instead of claiming there is none — the LED
    /// is driven from the very same value.
    @MainActor
    func testClaudeStatusTitleMatchesLEDStateWhenOnlySessionListIsAvailable() {
        let bridge = ClaudeAgentBridge()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-status-title-\(UUID().uuidString).json")
        let store = CodexThreadStore(bridge: bridge, automationApp: .claude, persistenceURL: url)
        var thread = CodexThreadDescriptor(
            id: "local_title", title: "Claude", preview: "", cwd: "/tmp/project",
            parentThreadID: nil, agentNickname: nil, agentRole: "Claude Desktop",
            updatedAt: .now, status: .idle,
            alternateID: "cli-uuid", navigationID: "session_01ABC"
        )
        store.assign(thread, to: .key1)
        thread.status = .running
        bridge.onThreads?([thread])

        XCTAssertEqual(store.liveStatusAvailability, .sessionListOnly)
        XCTAssertEqual(store.status(for: .key1), .running)
        XCTAssertEqual(
            store.statusTitle(for: .key1),
            CodexAgentStatus.running.title,
            "The label must report the state the LED is showing"
        )
    }

    /// Claude validates the deep-link identifier with `/^(cse|session)_/` and
    /// silently drops anything else without even focusing its window, which is
    /// why a key press used to do nothing at all.
    func testClaudeNavigationURLAcceptsOnlyBridgeSessionIdentifiers() {
        XCTAssertEqual(
            CodexThreadStore.navigationURL(for: "session_01ABC", app: .claude),
            URL(string: "claude://code/session_01ABC")
        )
        XCTAssertEqual(
            CodexThreadStore.navigationURL(for: "cse_01ABC", app: .claude),
            URL(string: "claude://code/cse_01ABC")
        )
        XCTAssertNil(
            CodexThreadStore.navigationURL(for: "local_c9f6e9e5-ae9a-4f04", app: .claude),
            "The Desktop metadata ID is not routable"
        )
        XCTAssertNil(
            CodexThreadStore.navigationURL(for: "c109ee95-b1d8-4e92-992b", app: .claude),
            "The CLI UUID is rejected by Claude's handler, so it must not be sent"
        )
        XCTAssertEqual(
            CodexThreadStore.navigationURL(for: "0199", app: .codex),
            URL(string: "codex://threads/0199"),
            "Codex deep links stay unconditional"
        )
    }

    /// The bridge ID is the routable identity; a Claude assignment must never
    /// persist the CLI UUID as its navigation target again.
    @MainActor
    func testClaudeAssignmentPersistsBridgeSessionIDAndNeverTheCLIUUID() {
        let bridge = ClaudeAgentBridge()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-navid-\(UUID().uuidString).json")
        let store = CodexThreadStore(bridge: bridge, automationApp: .claude, persistenceURL: url)
        let withBridgeID = CodexThreadDescriptor(
            id: "local_withbridge", title: "Mit Bridge-ID", preview: "", cwd: "/tmp/project",
            parentThreadID: nil, agentNickname: nil, agentRole: "Claude Desktop",
            updatedAt: .now, status: .idle,
            alternateID: "cli-uuid-1", navigationID: "session_01ABC"
        )
        let withoutBridgeID = CodexThreadDescriptor(
            id: "local_nobridge", title: "Ohne Bridge-ID", preview: "", cwd: "/tmp/project",
            parentThreadID: nil, agentNickname: nil, agentRole: "Claude Desktop",
            updatedAt: .now, status: .idle,
            alternateID: "cli-uuid-2", navigationID: nil
        )

        store.assign(withBridgeID, to: .key1)
        XCTAssertEqual(store.assignment(for: .key1)?.navigationID, "session_01ABC")

        store.assign(withoutBridgeID, to: .key2)
        XCTAssertNil(
            store.assignment(for: .key2)?.navigationID,
            "An unroutable CLI UUID must not be substituted"
        )

        // A stale CLI UUID from an older build is cleared once the poll runs.
        store.assign(withoutBridgeID, to: .key3)
        var recorded = withoutBridgeID
        recorded.navigationID = "session_01XYZ"
        bridge.onThreads?([recorded])
        XCTAssertEqual(store.assignment(for: .key3)?.navigationID, "session_01XYZ")
    }

    /// The 2s poll spawns a `claude` process per tick, so it must stay off
    /// while the Codex profile is selected — and a stray refresh from a picker
    /// must not quietly restart it.
    @MainActor
    func testSuspendedClaudeBridgeStopsPollingUntilExplicitlyStarted() {
        let bridge = ClaudeAgentBridge()
        bridge.start()
        XCTAssertNotEqual(bridge.connectionState, .disconnected)

        bridge.suspend()
        XCTAssertEqual(bridge.connectionState, .disconnected)

        bridge.refreshThreads()
        XCTAssertEqual(
            bridge.connectionState,
            .disconnected,
            "A refresh must not resurrect polling while suspended"
        )

        bridge.start()
        XCTAssertNotEqual(bridge.connectionState, .disconnected)
        bridge.suspend()
    }

    /// Codex has a push event stream, so suspending it would only lose events.
    /// The default protocol implementation must keep it running.
    @MainActor
    func testSuspendIsANoOpForTheEventDrivenCodexBridge() {
        let bridge = CodexEventBridge()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-suspend-\(UUID().uuidString).json")
        let store = CodexThreadStore(bridge: bridge, persistenceURL: url)
        let thread = CodexThreadDescriptor(
            id: "codex-live", title: "Turn", preview: "", cwd: "/tmp/project",
            parentThreadID: nil, agentNickname: nil, agentRole: nil,
            updatedAt: .now, status: .idle
        )
        store.assign(thread, to: .key1)
        bridge.onThreads?([thread])
        bridge.onStatus?(thread.id, .running, .event)

        store.suspend()

        XCTAssertEqual(
            store.status(for: .key1),
            .running,
            "Suspending must not disturb the Codex store's live state"
        )
        bridge.onStatus?(thread.id, .completed, .event)
        XCTAssertEqual(store.status(for: .key1), .completed, "Codex events keep flowing")
    }

    /// Regression guard for the field the whole Claude navigation path hangs
    /// on: Claude records it as an array, and only the routable entries count.
    func testClaudeDesktopSessionDecodesBridgeSessionIDForNavigation() throws {
        let json = """
        {
          "sessionId": "local_c9f6e9e5",
          "cliSessionId": "c109ee95-b1d8",
          "title": "Agent-Zustände",
          "originCwd": "/tmp/project",
          "lastActivityAt": 1785366277310,
          "isArchived": false,
          "bridgeSessionIds": ["session_01OLD", "session_01NEW"]
        }
        """
        let session = try JSONDecoder().decode(ClaudeDesktopSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.bridgeSessionID, "session_01NEW")
        XCTAssertEqual(session.threadDescriptor.navigationID, "session_01NEW")
        XCTAssertEqual(session.threadDescriptor.alternateID, "c109ee95-b1d8")

        let legacy = """
        {"sessionId": "local_old", "title": "Alt", "originCwd": "/tmp"}
        """
        let legacySession = try JSONDecoder().decode(ClaudeDesktopSession.self, from: Data(legacy.utf8))
        XCTAssertNil(legacySession.bridgeSessionID)
        XCTAssertNil(legacySession.threadDescriptor.navigationID)
    }

    @MainActor
    func testMissedAttentionEventRecoveredBySnapshotReachesLEDOutput() {
        let bridge = CodexEventBridge()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-attention-led-\(UUID().uuidString).json")
        let store = CodexThreadStore(bridge: bridge, persistenceURL: url)
        var thread = CodexThreadDescriptor(
            id: "attention-snapshot", title: "Test", preview: "", cwd: "/tmp/project",
            parentThreadID: nil, agentNickname: nil, agentRole: nil, updatedAt: .now, status: .idle
        )
        store.assign(thread, to: .key1)
        bridge.onThreads?([thread])

        var batches: [[[UInt8]]] = []
        let feedback = CodexPadLEDFeedbackService { batches.append($0) }
        let profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        store.onStatusChange = {
            feedback.showAgentStatuses([.key1: store.status(for: .key1)], profile: profile)
        }

        // No event callback: this represents reconciliation after a missed
        // thread/status/changed notification.
        thread.status = .needsAttention
        bridge.onThreads?([thread])

        XCTAssertEqual(store.status(for: .key1), .needsAttention)
        let expected = profile.reaction(for: .agentNeedsAttention)
        let keyPacket = batches.last?.first(where: { $0[4] == HardwareControl.key1.firmwareControlIndex })
        XCTAssertEqual(keyPacket?[5], expected.effect.firmwareEffect.rawValue)
        XCTAssertEqual(keyPacket?[6], expected.red)
        XCTAssertEqual(keyPacket?[7], expected.green)
        XCTAssertEqual(keyPacket?[8], expected.blue)
    }

    @MainActor
    func testLayerConfirmationUsesSteadyFramesAndOneGlobalOffGap() async {
        var batches: [[[UInt8]]] = []
        let feedback = CodexPadLEDFeedbackService { batches.append($0) }
        let profile = ProfileFactory.safe()
        var layer = profile.layers[0]
        layer.confirmationEffect = .blink
        layer.confirmationDurationMilliseconds = 80
        layer.confirmationRepeatCount = 2

        feedback.flashLayerConfirmation(profile: profile, layer: layer)
        try? await Task.sleep(for: .milliseconds(320))

        let onBatches = batches.filter { $0.count == HardwareControl.buttons.count && $0.allSatisfy { $0[3] == 0x10 } }
        XCTAssertGreaterThanOrEqual(onBatches.count, 2)
        XCTAssertTrue(onBatches.prefix(2).allSatisfy { $0.allSatisfy { $0[5] == LEDEffect.steady.rawValue } })
        XCTAssertEqual(batches.filter { $0.count == 1 && $0[0][3] == 0x12 }.count, 1)
    }

    @MainActor
    func testCompletedStatusRemainsVisibleUntilItIsAcknowledged() {
        var batches: [[[UInt8]]] = []
        let feedback = CodexPadLEDFeedbackService { batches.append($0) }
        let profile = ProfileFactory.safe()
        let statuses: [HardwareControl: CodexAgentStatus] = [.key1: .completed]

        feedback.showAgentStatuses(statuses, profile: profile)
        feedback.showAgentStatuses(statuses, profile: profile)

        let completed = profile.reaction(for: .agentCompleted)
        let keyPacket = batches.last?.first(where: { $0[4] == HardwareControl.key1.firmwareControlIndex })
        XCTAssertEqual(keyPacket?[5], completed.effect.firmwareEffect.rawValue)
        XCTAssertEqual([keyPacket?[6], keyPacket?[7], keyPacket?[8]], [completed.red, completed.green, completed.blue])
    }

    @MainActor
    func testTerminalTransitionStopsBeforeIdleCanRender() async {
        var batches: [[[UInt8]]] = []
        let feedback = CodexPadLEDFeedbackService { batches.append($0) }
        var profile = ProfileFactory.safe()
        profile.setReaction(.init(
            event: .agentCompleted,
            effect: .pulse,
            red: 0,
            green: 220,
            blue: 70,
            brightness: 255,
            periodMilliseconds: 200,
            disablesIdle: true
        ))
        profile.setReaction(.init(
            event: .agentIdle,
            effect: .steady,
            red: 255,
            green: 255,
            blue: 255,
            brightness: 56,
            periodMilliseconds: 200,
            disablesIdle: true
        ))

        feedback.showAgentStatuses([.key1: .completed], profile: profile)
        feedback.showStatusTransition(.completed, for: .key1, profile: profile)
        feedback.showAgentStatuses([.key1: .idle], profile: profile)
        try? await Task.sleep(for: .milliseconds(260))

        let finalKeyPacket = batches.last?.first(where: { $0[4] == HardwareControl.key1.firmwareControlIndex })
        XCTAssertEqual(finalKeyPacket?[5], LEDEffect.steady.rawValue)
        XCTAssertEqual([finalKeyPacket?[6], finalKeyPacket?[7], finalKeyPacket?[8]], [255, 255, 255])
    }

    @MainActor
    func testThreadPickerPulsesAndConfirmsAcrossAllSixKeys() {
        var batches: [[[UInt8]]] = []
        let feedback = CodexPadLEDFeedbackService { batches.append($0) }
        var profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        profile.setReaction(.init(
            event: .threadAssigned,
            effect: .flash,
            red: 12,
            green: 34,
            blue: 56,
            brightness: 210,
            periodMilliseconds: 180,
            disablesIdle: false
        ))

        feedback.beginThreadPickerSelection(profile: profile)
        let pulse = batches.last ?? []
        XCTAssertEqual(pulse.count, HardwareControl.buttons.count)
        XCTAssertTrue(pulse.allSatisfy {
            $0[5] == LEDEffect.pulse.rawValue
                && $0[6...10] == [12, 34, 56, 10, 210]
        })

        feedback.finishThreadPickerSelection(profile: profile, confirmed: true)
        let flash = batches.last ?? []
        XCTAssertEqual(flash.count, HardwareControl.buttons.count)
        XCTAssertTrue(flash.allSatisfy {
            $0[5] == LEDEffect.steady.rawValue
                && $0[6...10] == [12, 34, 56, 9, 210]
        })
    }

    @MainActor
    func testRunningStatusInvalidatesEveryPendingIdleRangePulseFrame() async {
        var batches: [[[UInt8]]] = []
        let feedback = CodexPadLEDFeedbackService { batches.append($0) }
        var profile = ProfileFactory.safe()
        profile.setReaction(.init(
            event: .agentIdle,
            effect: .pulse,
            red: 255,
            green: 255,
            blue: 255,
            brightness: 180,
            periodMilliseconds: 200,
            disablesIdle: true,
            minBrightness: 40
        ))
        profile.setReaction(.init(
            event: .agentRunning,
            effect: .pulse,
            red: 10,
            green: 132,
            blue: 255,
            brightness: 255,
            periodMilliseconds: 200,
            disablesIdle: true
        ))

        feedback.showAgentStatuses([.key1: .idle], profile: profile)
        // The host animator runs on MainActor. A loaded XCTest runner may
        // delay one or more 20 ms ticks, so wait for the observable condition
        // with a bounded timeout instead of relying on one scheduler slice.
        var idleFrames = batches.flatMap { $0 }.filter {
            $0[4] == HardwareControl.key1.firmwareControlIndex
                && $0[6...8] == [255, 255, 255]
        }
        for _ in 0..<40 {
            if idleFrames.count >= 3 { break }
            try? await Task.sleep(for: .milliseconds(25))
            idleFrames = batches.flatMap { $0 }.filter {
                $0[4] == HardwareControl.key1.firmwareControlIndex
                    && $0[6...8] == [255, 255, 255]
            }
        }
        XCTAssertGreaterThanOrEqual(idleFrames.count, 3)
        XCTAssertTrue(idleFrames.allSatisfy {
            $0[5] == LEDEffect.steady.rawValue && (40...180).contains($0[10])
        })

        let beforeDuplicateIdle = batches.count
        feedback.showAgentStatuses([.key1: .idle], profile: profile)
        XCTAssertEqual(
            batches.count,
            beforeDuplicateIdle,
            "An identical reconciliation must not restart the pulse at its trough"
        )

        let runningStart = batches.count
        feedback.showAgentStatuses([.key1: .running], profile: profile)
        try? await Task.sleep(for: .milliseconds(90))

        let runningPackets = batches.dropFirst(runningStart)
            .flatMap { $0 }
            .filter { $0[4] == HardwareControl.key1.firmwareControlIndex }
        XCTAssertFalse(runningPackets.isEmpty)
        XCTAssertTrue(runningPackets.allSatisfy {
            $0[5] == LEDEffect.pulse.rawValue && $0[6...8] == [10, 132, 255]
        })
        XCTAssertFalse(runningPackets.contains { $0[6...8] == [255, 255, 255] })
    }

    @MainActor
    func testNativeAgentPulseDoesNotContinuouslyWriteOverHID() async {
        var batches: [[[UInt8]]] = []
        let feedback = CodexPadLEDFeedbackService { batches.append($0) }
        var profile = ProfileFactory.safe()
        profile.setReaction(.init(
            event: .agentRunning,
            effect: .pulse,
            red: 10,
            green: 132,
            blue: 255,
            brightness: 255,
            periodMilliseconds: 200,
            disablesIdle: true
        ))

        feedback.showAgentStatuses([.key1: .running], profile: profile)
        let batchesAfterRender = batches.count
        let keyPacket = batches.last?.first {
            $0[4] == HardwareControl.key1.firmwareControlIndex
        }
        XCTAssertEqual(keyPacket?[5], LEDEffect.pulse.rawValue)

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(
            batches.count,
            batchesAfterRender,
            "A firmware-native agent pulse must not generate continuous host HID writes"
        )
    }

    @MainActor
    func testDictationRangePulseSuppressesTerminalAgentReactionUntilRelease() async {
        var batches: [[[UInt8]]] = []
        let feedback = CodexPadLEDFeedbackService { batches.append($0) }
        var profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        profile.setReaction(.init(
            event: .dictation,
            effect: .pulse,
            red: 255,
            green: 255,
            blue: 255,
            brightness: 100,
            periodMilliseconds: 200,
            disablesIdle: false,
            minBrightness: 70
        ))
        profile.setReaction(.init(
            event: .agentCompleted,
            effect: .flash,
            red: 1,
            green: 2,
            blue: 3,
            brightness: 255,
            periodMilliseconds: 200,
            disablesIdle: true
        ))

        feedback.handle(
            CodexPadPhysicalEvent(
                sequence: 0,
                control: HardwareControl.key4.reportedControlIndex,
                phase: .pressed
            ),
            profile: profile
        )
        try? await Task.sleep(for: .milliseconds(45))
        let firstAgentBatch = batches.count

        feedback.showStatusTransition(.completed, for: .key1, profile: profile)
        try? await Task.sleep(for: .milliseconds(70))

        let batchesDuringDictation = batches.dropFirst(firstAgentBatch)
        XCTAssertFalse(batchesDuringDictation.isEmpty)
        XCTAssertFalse(
            batchesDuringDictation.flatMap { $0 }.contains {
                $0[4] == HardwareControl.key1.firmwareControlIndex && $0[6...8] == [1, 2, 3]
            },
            "A terminal agent reaction must not replace the active dictation range pulse."
        )
        XCTAssertTrue(
            batchesDuringDictation.allSatisfy { batch in
                batch.count == HardwareControl.buttons.count
                    && batch.allSatisfy { $0[5] == LEDEffect.steady.rawValue && (70...100).contains($0[10]) }
            }
        )
    }

    func testCodexPadDictationUsesCommandF17HoldBinding() throws {
        let action = try XCTUnwrap(CodexActionCatalog().keyboardAction(id: "dictation"))
        let packet = try CodexPadPacketEncoder().bindingPacket(action: action, control: .key4)

        XCTAssertEqual(packet[4], 5) // visible bottom-left key -> PCB control 5
        XCTAssertEqual(packet[5], 4) // held until the physical key is released
        XCTAssertEqual(packet[6], 1)
        XCTAssertEqual(packet[7], 0x08) // left Command
        XCTAssertEqual(packet[8], 0x6C) // F17
    }

    func testCodexPadMirrorsPhysicalButtonRowsButNotEncoderControls() throws {
        let encoder = CodexPadPacketEncoder()
        let disabled = KeyboardAction.disabled
        let controls: [HardwareControl] = [.key1, .key2, .key3, .key4, .key5, .key6, .encoderLeft, .encoderPress, .encoderRight]
        let expected: [UInt8] = [2, 1, 0, 5, 4, 3, 6, 7, 8]

        let actual = try controls.map { try encoder.bindingPacket(action: disabled, control: $0)[4] }
        XCTAssertEqual(actual, expected)
    }

    func testGermanLayoutSwapsYAndZForSemanticText() throws {
        let encoder = CodexPadPacketEncoder()
        let action = try XCTUnwrap(KeyboardAction.textSubmission("Yeet"))
        let packet = try encoder.bindingPacket(action: action, control: .key3, layout: .germanISO)

        XCTAssertEqual(packet[6], 5)
        XCTAssertEqual(Array(packet[7...16]), [0x02, 0x1D, 0x00, 0x08, 0x00, 0x08, 0x00, 0x17, 0x00, 0x28])
    }

    func testGermanLayoutAddsIntrinsicModifiersForBrackets() throws {
        let action = KeyboardAction(kind: .keyboardShortcut, label: "Zurück", deviceMacro: "cmd-shift-leftbracket")
        let packet = try CodexPadPacketEncoder().bindingPacket(action: action, control: .key1, layout: .germanISO)

        XCTAssertEqual(packet[7], 0x0E)
        XCTAssertEqual(packet[8], 0x22)
    }

    func testLegacyProfileWithoutPerKeyLEDsGetsSafeDefaults() throws {
        let profile = ProfileFactory.safe()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(profile)) as? [String: Any])
        object["led"] = ["enabled": true, "mode": 1]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MacropadProfile.self, from: data)

        XCTAssertEqual(decoded.led.keys.count, 6)
        XCTAssertEqual(decoded.led.setting(for: .key3).effect, .steady)
    }

    func testLegacyProfileWithoutReactionConfigurationGetsDefaults() throws {
        let profile = ProfileFactory.safe()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(profile)) as? [String: Any])
        object.removeValue(forKey: "ledReactions")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MacropadProfile.self, from: data)

        XCTAssertEqual(decoded.ledReactions.count, LEDReactionEvent.allCases.count)
        XCTAssertEqual(decoded.reaction(for: .agentRunning).effect, .pulse)
        XCTAssertEqual(decoded.reaction(for: .messageSent).effect, .flash)
    }

    func testLegacyProfileGetsIdleDefaultsAndAgentIdleOverride() throws {
        let profile = ProfileFactory.safe()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(profile)) as? [String: Any])
        object.removeValue(forKey: "idleLighting")
        var reactions = try XCTUnwrap(object["ledReactions"] as? [[String: Any]])
        let runningIndex = try XCTUnwrap(reactions.firstIndex { $0["event"] as? String == LEDReactionEvent.agentRunning.rawValue })
        reactions[runningIndex].removeValue(forKey: "disablesIdle")
        object["ledReactions"] = reactions
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MacropadProfile.self, from: data)

        XCTAssertEqual(decoded.idleLighting, .default)
        XCTAssertTrue(decoded.reaction(for: .agentRunning).disablesIdle)
    }

    @MainActor
    func testProfileStoreCanUpdateAllSixLEDsTogetherAndPersistReaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-profile-store-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("Profiles.json")
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)
        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        let settings = HardwareControl.buttons.map {
            KeyLEDConfiguration(control: $0, effect: .steady, red: 12, green: 34, blue: 56, brightness: 200, periodMilliseconds: 700)
        }
        store.updateLEDs(settings)
        var reaction = store.selectedProfile.reaction(for: .agentFailed)
        reaction.effect = .flash
        reaction.red = 99
        store.updateReaction(reaction)
        var idle = store.selectedProfile.idleLighting
        idle.effect = .pulse
        idle.brightness = 155
        store.updateIdleLighting(idle)

        XCTAssertTrue(HardwareControl.buttons.allSatisfy {
            store.selectedProfile.led.setting(for: $0).red == 12
        })
        XCTAssertEqual(store.selectedProfile.reaction(for: .agentFailed).effect, .flash)

        let restored = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        restored.selectedProfileID = store.selectedProfileID
        XCTAssertEqual(restored.selectedProfile.led.setting(for: .key6).blue, 56)
        XCTAssertEqual(restored.selectedProfile.reaction(for: .agentFailed).red, 99)
        XCTAssertEqual(restored.selectedProfile.idleLighting.effect, .pulse)
        XCTAssertEqual(restored.selectedProfile.idleLighting.brightness, 155)
    }

    @MainActor
    func testProfileStoreMigratesStaleF18F19EncoderDefaultToPrivateTriggers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-profile-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Profiles.json")
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)

        // Simulate a profile persisted before the F22/F24 fix: the direct
        // F18/F19 shortcuts bypass CodexReasoningAutomationService entirely,
        // so this state must always be migrated forward on load.
        var stale = ProfileFactory.codex(catalog: catalog)
        stale.setAction(
            KeyboardAction(kind: .singleKey, label: "Aufwand −", icon: "minus.circle", deviceMacro: "f18", codexActionID: "encoder-effort-decrease"),
            for: .encoderLeft
        )
        stale.setAction(
            KeyboardAction(kind: .singleKey, label: "Modellwahl umschalten", icon: "cube", deviceMacro: "f23", codexActionID: "encoder-model-modifier"),
            for: .encoderPress
        )
        stale.setAction(
            KeyboardAction(kind: .singleKey, label: "Aufwand +", icon: "plus.circle", deviceMacro: "f19", codexActionID: "encoder-effort-increase"),
            for: .encoderRight
        )
        try ProfileFileCodec.encode([stale]).write(to: url)

        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        XCTAssertEqual(store.selectedProfile.action(for: .encoderLeft).deviceMacro, "f22")
        XCTAssertEqual(store.selectedProfile.action(for: .encoderPress).deviceMacro, "f23")
        XCTAssertEqual(store.selectedProfile.action(for: .encoderRight).deviceMacro, "f24")
    }

    func testFlashReactionUsesSupportedFirmwareEffect() {
        let reaction = LEDReactionConfiguration.defaults.first { $0.event == .messageSent }!
        let setting = reaction.keyConfiguration(for: .key2)
        XCTAssertEqual(reaction.effect, .flash)
        XCTAssertEqual(setting.effect, .steady)
        XCTAssertEqual(setting.control, .key2)
    }

    // MARK: - Tap-vs-hold

    private func bindingPacket(for control: HardwareControl, in packets: [[UInt8]]) -> [UInt8]? {
        packets.first { $0[3] == 0x20 && $0[4] == control.firmwareControlIndex }
    }

    func testTapHoldControlUploadsAppOnlyBinding() throws {
        var profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        let hold = CodexActionCatalog().keyboardAction(id: "new-chat")
        profile.setHoldAction(hold, thresholdMilliseconds: 300, for: .key1)
        XCTAssertTrue(profile.binding(for: .key1).isTapHold)

        let packets = try CodexPadPacketEncoder().packets(profile: profile)
        let key1 = try XCTUnwrap(bindingPacket(for: .key1, in: packets))
        XCTAssertEqual(key1[5], 3, "Tap-hold control must upload the app-only mode")
        // A neighbouring plain control keeps a real keyboard binding.
        let key2 = try XCTUnwrap(bindingPacket(for: .key2, in: packets))
        XCTAssertEqual(key2[5], 1)
    }

    func testControlBindingDecodesWithoutHoldFields() throws {
        let legacy = Data("""
        {"control":"key1","action":{"id":"\(UUID().uuidString)","kind":"singleKey","label":"F13","icon":"keyboard","deviceMacro":"f13"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(ControlBinding.self, from: legacy)
        XCTAssertNil(decoded.holdAction)
        XCTAssertFalse(decoded.isTapHold)
        XCTAssertEqual(decoded.resolvedHoldThresholdMilliseconds, ControlBinding.defaultHoldThresholdMilliseconds)
    }

    func testSetHoldActionClearsThresholdWhenRemoved() {
        var profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        profile.setHoldAction(CodexActionCatalog().keyboardAction(id: "new-chat"), thresholdMilliseconds: 500, for: .key3)
        XCTAssertTrue(profile.binding(for: .key3).isTapHold)
        XCTAssertEqual(profile.binding(for: .key3).holdThresholdMilliseconds, 500)
        profile.setHoldAction(nil, for: .key3)
        XCTAssertFalse(profile.binding(for: .key3).isTapHold)
        XCTAssertNil(profile.binding(for: .key3).holdThresholdMilliseconds)
    }

    // MARK: - Keystroke synthesis

    func testSynthesizerRecognizesKeyboardChordsOnly() {
        XCTAssertTrue(KeystrokeSynthesizer.canSynthesize("cmd-shift-p"))
        XCTAssertTrue(KeystrokeSynthesizer.canSynthesize("cmd-n"))
        XCTAssertTrue(KeystrokeSynthesizer.canSynthesize("f18"))
        XCTAssertTrue(KeystrokeSynthesizer.canSynthesize("cmd-ctrl-opt-shift-a"))
        XCTAssertTrue(KeystrokeSynthesizer.canSynthesize("shift-y,e,e,t,enter"))
        XCTAssertFalse(KeystrokeSynthesizer.canSynthesize("mute"))
        XCTAssertFalse(KeystrokeSynthesizer.canSynthesize("wheel(1)"))
        XCTAssertFalse(KeystrokeSynthesizer.canSynthesize("f24"))
        XCTAssertFalse(KeystrokeSynthesizer.canSynthesize(nil))
        XCTAssertFalse(KeystrokeSynthesizer.canSynthesize(""))
        XCTAssertTrue(KeystrokeSynthesizer.canSynthesize("cmd-slash", layout: .germanISO))
    }

    // MARK: - Codex rollout status fallback

    func testRolloutParserTracksApprovalUntilItsConcreteOutputArrives() {
        var parser = CodexRolloutStatusParser()
        let approval = """
        {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"approval-1","name":"exec","input":"{\\"sandbox_permissions\\":\\"require_escalated\\"}"}}
        """
        let unrelatedOutput = """
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"other"}}
        """
        let approvalOutput = """
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"approval-1"}}
        """

        XCTAssertEqual(parser.consume(line: approval), .needsAttention)
        XCTAssertNil(parser.consume(line: unrelatedOutput))
        XCTAssertEqual(parser.consume(line: approvalOutput), .running)
    }

    func testRolloutParserMapsCompletionFailureAndInterruption() {
        var parser = CodexRolloutStatusParser()
        XCTAssertEqual(parser.consume(line: #"{"type":"event_msg","payload":{"type":"task_complete"}}"#), .completed)
        XCTAssertEqual(parser.consume(line: #"{"type":"event_msg","payload":{"type":"error"}}"#), .failed)
        XCTAssertEqual(
            parser.consume(line: #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#),
            .interrupted
        )
    }

    func testPadReconnectDecisionRequiresARealConnectionAndDetectsReplug() {
        XCTAssertFalse(AppState.requiresPadReinitialization(previousID: "pad-1", newID: nil, forced: true))
        XCTAssertFalse(AppState.requiresPadReinitialization(previousID: "pad-1", newID: "pad-1", forced: false))
        XCTAssertTrue(AppState.requiresPadReinitialization(previousID: nil, newID: "pad-1", forced: false))
        XCTAssertTrue(AppState.requiresPadReinitialization(previousID: "pad-1", newID: "pad-2", forced: false))
        XCTAssertTrue(AppState.requiresPadReinitialization(previousID: "pad-1", newID: "pad-1", forced: true))
    }

    // MARK: - Assignment wizard trigger pool

    func testTriggerPoolPicksFreeHyperChords() {
        var profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        let first = try? XCTUnwrap(CodexTriggerPool.nextFreeTrigger(in: profile))
        XCTAssertEqual(first, "cmd-ctrl-opt-shift-a")

        profile.setAction(
            KeyboardAction(kind: .codexShortcut, label: "X", deviceMacro: "cmd-ctrl-opt-shift-a", codexActionID: "toggle-plan-mode"),
            for: .key1
        )
        XCTAssertEqual(CodexTriggerPool.nextFreeTrigger(in: profile), "cmd-ctrl-opt-shift-b")
        XCTAssertTrue(CodexTriggerPool.usedTriggers(in: profile).contains("cmd-ctrl-opt-shift-a"))
        XCTAssertNotEqual(CodexTriggerPool.alternativeTrigger(to: "cmd-ctrl-opt-shift-b", in: profile), "cmd-ctrl-opt-shift-b")
    }

    func testTriggerPoolIncludesLettersNumbersAndFunctionKeys() {
        XCTAssertEqual(CodexTriggerPool.candidates.count, 48)
        XCTAssertEqual(CodexTriggerPool.letterCandidates.first, "cmd-ctrl-opt-shift-a")
        XCTAssertTrue(CodexTriggerPool.numberCandidates.contains("cmd-ctrl-opt-shift-0"))
        XCTAssertTrue(CodexTriggerPool.functionKeyCandidates.contains("cmd-ctrl-opt-shift-f12"))
    }

    func testTriggerPoolKeepsOwnTriggerWhenReediting() {
        var profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        profile.setAction(
            KeyboardAction(kind: .codexShortcut, label: "Plan", deviceMacro: "cmd-ctrl-opt-shift-a", codexActionID: "toggle-plan-mode"),
            for: .key1
        )
        // Re-running the wizard for the same control keeps its assigned trigger.
        XCTAssertEqual(
            CodexTriggerPool.nextFreeTrigger(in: profile, keeping: "cmd-ctrl-opt-shift-a"),
            "cmd-ctrl-opt-shift-a"
        )
    }

    func testTriggerRegistryPersistsOfferedTriggersAcrossProfiles() {
        let suiteName = "CodexPadTests.triggerRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeDefaultsSuite(suiteName, defaults: defaults) }

        let codex = ProfileFactory.codex(catalog: CodexActionCatalog())
        let claude = ProfileFactory.claude(catalog: CodexActionCatalog(resourceName: "ClaudeActions", app: .claude))
        XCTAssertEqual(
            CodexTriggerRegistry.reserveNextFreeTrigger(in: [codex, claude], defaults: defaults),
            "cmd-ctrl-opt-shift-a"
        )
        XCTAssertEqual(
            CodexTriggerRegistry.reserveNextFreeTrigger(in: [claude, codex], defaults: defaults),
            "cmd-ctrl-opt-shift-b"
        )
        XCTAssertTrue(CodexTriggerRegistry.reservedTriggers(defaults: defaults).contains("cmd-ctrl-opt-shift-a"))
    }

    func testTriggerRegistryAdvancesPastEveryPreviouslyOfferedCandidate() {
        let suiteName = "CodexPadTests.triggerRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeDefaultsSuite(suiteName, defaults: defaults) }

        let profiles = [ProfileFactory.codex(catalog: CodexActionCatalog())]
        CodexTriggerRegistry.reserve("cmd-ctrl-opt-shift-a", defaults: defaults)
        CodexTriggerRegistry.reserve("cmd-ctrl-opt-shift-b", defaults: defaults)

        XCTAssertEqual(
            CodexTriggerRegistry.reserveAlternativeTrigger(
                to: "cmd-ctrl-opt-shift-b",
                in: profiles,
                defaults: defaults
            ),
            "cmd-ctrl-opt-shift-c"
        )
    }

    func testTriggerRegistryRemembersAnActionAcrossPadControls() {
        let suiteName = "CodexPadTests.triggerRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeDefaultsSuite(suiteName, defaults: defaults) }

        CodexTriggerRegistry.remember(
            "cmd-ctrl-opt-shift-f7",
            for: "toggle-pet",
            app: .codex,
            defaults: defaults
        )

        XCTAssertEqual(
            CodexTriggerRegistry.trigger(for: "toggle-pet", app: .codex, defaults: defaults),
            "cmd-ctrl-opt-shift-f7"
        )
        XCTAssertNil(CodexTriggerRegistry.trigger(for: "toggle-pet", app: .claude, defaults: defaults))
        XCTAssertTrue(CodexTriggerRegistry.reservedTriggers(defaults: defaults).contains("cmd-ctrl-opt-shift-f7"))
    }

    func testTriggerRegistryConfirmsOnlyAfterSuccessfulSetup() {
        let suiteName = "CodexPadTests.triggerRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeDefaultsSuite(suiteName, defaults: defaults) }

        CodexTriggerRegistry.remember(
            "cmd-ctrl-opt-shift-f8",
            for: "toggle-pet",
            app: .codex,
            defaults: defaults
        )
        XCTAssertNil(CodexTriggerRegistry.confirmedTrigger(for: "toggle-pet", app: .codex, defaults: defaults))

        CodexTriggerRegistry.markConfirmed(
            "cmd-ctrl-opt-shift-f8",
            for: "toggle-pet",
            app: .codex,
            defaults: defaults
        )
        XCTAssertEqual(
            CodexTriggerRegistry.confirmedTrigger(for: "toggle-pet", app: .codex, defaults: defaults),
            "cmd-ctrl-opt-shift-f8"
        )
    }

    func testTriggerRegistryRestoresConfirmedActionAfterRestart() throws {
        let suiteName = "CodexPadTests.triggerRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeDefaultsSuite(suiteName, defaults: defaults) }

        let definition = try XCTUnwrap(CodexActionCatalog().action(id: "toggle-pet"))
        CodexTriggerRegistry.markConfirmed(
            "cmd-ctrl-opt-shift-f9",
            for: definition.id,
            app: .codex,
            defaults: defaults
        )

        let restored = CodexTriggerRegistry.confirmedAction(for: definition, app: .codex, defaults: defaults)
        XCTAssertEqual(restored?.deviceMacro, "cmd-ctrl-opt-shift-f9")
        XCTAssertEqual(restored?.codexActionID, "toggle-pet")
        XCTAssertEqual(restored?.kind, .codexShortcut)
    }

    func testTriggerRegistryImportsExistingBindingsFromInactiveLayers() {
        let suiteName = "CodexPadTests.triggerRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeDefaultsSuite(suiteName, defaults: defaults) }

        var profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        var inactiveLayer = profile.layers[0]
        inactiveLayer.name = "Eigene Aktionen"
        inactiveLayer.controls[0].action = KeyboardAction(
            kind: .codexShortcut,
            label: "Pad an/aus",
            deviceMacro: "cmd-ctrl-opt-shift-9",
            codexActionID: "toggle-pet"
        )
        profile.layers.append(inactiveLayer)

        CodexTriggerRegistry.importExistingAssignments(from: [profile], defaults: defaults)

        XCTAssertEqual(
            CodexTriggerRegistry.trigger(for: "toggle-pet", app: .codex, defaults: defaults),
            "cmd-ctrl-opt-shift-9"
        )
    }

    func testTriggerRegistrySkipsTriggersUsedInAnotherProfile() {
        let suiteName = "CodexPadTests.triggerRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { removeDefaultsSuite(suiteName, defaults: defaults) }

        let codex = ProfileFactory.codex(catalog: CodexActionCatalog())
        var claude = ProfileFactory.claude(catalog: CodexActionCatalog(resourceName: "ClaudeActions", app: .claude))
        claude.setAction(
            KeyboardAction(kind: .claudeShortcut, label: "Bereits belegt", deviceMacro: "cmd-ctrl-opt-shift-a"),
            for: .key1
        )
        XCTAssertEqual(
            CodexTriggerRegistry.reserveNextFreeTrigger(in: [codex, claude], defaults: defaults),
            "cmd-ctrl-opt-shift-b"
        )
    }

    func testTriggerPoolDisplayLabel() {
        XCTAssertEqual(CodexTriggerPool.displayLabel(for: "cmd-ctrl-opt-shift-a"), "⌘⌃⌥⇧A")
    }
}

private struct MockRunner: ProcessRunning {
    let result: ProcessResult
    func run(_ invocation: ProcessInvocation) -> ProcessResult { result }
}

private final class RecordingMockRunner: ProcessRunning, @unchecked Sendable {
    var invocations: [ProcessInvocation] = []
    func run(_ invocation: ProcessInvocation) -> ProcessResult {
        invocations.append(invocation)
        return ProcessResult(exitCode: 0, stdout: "config is valid", stderr: "", timedOut: false, launchError: nil)
    }
}
