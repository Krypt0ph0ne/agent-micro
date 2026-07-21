import Foundation
import Carbon.HIToolbox
import XCTest
@testable import CodexPad

final class CodexPadTests: XCTestCase {
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
        UserDefaults.standard.removeObject(forKey: "CodexPad.dictationSource")
        let store = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog, persistenceURL: url)
        defer { UserDefaults.standard.removeObject(forKey: "CodexPad.dictationSource") }

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
        guard ProcessInfo.processInfo.environment["CODEXPAD_HARDWARE_TEST"] == "1" else {
            throw XCTSkip("Set CODEXPAD_HARDWARE_TEST=1 only on the Mac with the attached test pad.")
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

    func testAgentIdleReactionDefaultsToARangePulseAndCanFallBackToBaseLighting() {
        let profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        let idleReaction = profile.reaction(for: .agentIdle)
        XCTAssertEqual(idleReaction.effect, .pulse)
        XCTAssertTrue(idleReaction.disablesIdle)
        XCTAssertGreaterThan(idleReaction.minBrightness, 0, "Should breathe within a range rather than the firmware's native 0-sweep")

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
        private(set) var pendingFires: [() -> Void] = []
        private(set) var cancelCount = 0

        func schedule(interval: TimeInterval, fire: @escaping () -> Void) -> () -> Void {
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
    func testQuickAssignFiresAtTheThresholdAndReassignsAnAlreadyBoundAgentButton() {
        func thread(_ id: String) -> CodexThreadDescriptor {
            CodexThreadDescriptor(
                id: id, title: id, preview: "", cwd: "/tmp",
                parentThreadID: nil, agentNickname: nil, agentRole: nil, updatedAt: .now, status: .idle
            )
        }
        var nextCandidate = thread("thread-recent")
        var assignedThread: CodexThreadDescriptor?
        var assignedControl: HardwareControl?
        let scheduler = FakeScheduler()

        let service = CodexQuickAssignService(
            isEnabled: { true },
            isDesignatedAgentControl: { _ in true },
            isTapHoldConfigured: { _ in false },
            fallbackThread: { nextCandidate },
            schedule: scheduler.schedule
        )
        service.onAssign = { thread, control in
            assignedThread = thread
            assignedControl = control
        }

        func event(_ phase: CodexPadPhysicalEvent.Phase) -> CodexPadPhysicalEvent {
            CodexPadPhysicalEvent(sequence: 0, control: HardwareControl.key1.reportedControlIndex, phase: phase)
        }

        // Releasing before the threshold fires must cancel the pending hold.
        service.handle(event(.pressed))
        service.handle(event(.released))
        XCTAssertEqual(scheduler.cancelCount, 1)
        XCTAssertNil(assignedThread)

        // The assignment happens as soon as the threshold elapses — while
        // still held — not only once the button is released.
        service.handle(event(.pressed))
        scheduler.fireLatest()
        XCTAssertEqual(assignedThread?.id, "thread-recent")
        XCTAssertEqual(assignedControl, .key1)

        // The later release must not undo or repeat the assignment.
        assignedThread = nil
        service.handle(event(.released))
        XCTAssertNil(assignedThread)

        // Holding the same, already-assigned button again reassigns it in one
        // step rather than requiring an unassign first.
        nextCandidate = thread("thread-newer")
        service.handle(event(.pressed))
        scheduler.fireLatest()
        XCTAssertEqual(assignedThread?.id, "thread-newer")
        XCTAssertEqual(assignedControl, .key1)
    }

    @MainActor
    func testQuickAssignIgnoresControlsNeverDesignatedAsAgentKeys() {
        var assignedThread: CodexThreadDescriptor?
        let scheduler = FakeScheduler()
        let service = CodexQuickAssignService(
            isEnabled: { true },
            isDesignatedAgentControl: { _ in false },
            isTapHoldConfigured: { _ in false },
            fallbackThread: { CodexThreadDescriptor(
                id: "thread-recent", title: "Recent", preview: "", cwd: "/tmp",
                parentThreadID: nil, agentNickname: nil, agentRole: nil, updatedAt: .now, status: .idle
            ) },
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

    func testExtractThreadIDFindsAUUIDInArbitraryClipboardText() {
        XCTAssertEqual(
            CodexQuickAssignService.extractThreadID(from: "019f5a19-e864-7543-bbca-c6ffdca652ac"),
            "019f5a19-e864-7543-bbca-c6ffdca652ac"
        )
        XCTAssertEqual(
            CodexQuickAssignService.extractThreadID(from: "Session: 019F5A19-E864-7543-BBCA-C6FFDCA652AC (copied)"),
            "019F5A19-E864-7543-BBCA-C6FFDCA652AC"
        )
        XCTAssertNil(CodexQuickAssignService.extractThreadID(from: "not a session id"))
        XCTAssertNil(CodexQuickAssignService.extractThreadID(from: ""))
    }

    @MainActor
    func testQuickAssignPrefersAClipboardThreadOverTheRecencyFallback() {
        let clipboardPick = CodexThreadDescriptor(
            id: "thread-from-clipboard", title: "Copied", preview: "", cwd: "/tmp",
            parentThreadID: nil, agentNickname: nil, agentRole: nil, updatedAt: .now, status: .idle
        )
        let recencyPick = CodexThreadDescriptor(
            id: "thread-recent", title: "Recent", preview: "", cwd: "/tmp",
            parentThreadID: nil, agentNickname: nil, agentRole: nil, updatedAt: .now, status: .idle
        )
        var assignedThread: CodexThreadDescriptor?
        let scheduler = FakeScheduler()

        let service = CodexQuickAssignService(
            isEnabled: { true },
            isDesignatedAgentControl: { _ in true },
            isTapHoldConfigured: { _ in false },
            clipboardThread: { clipboardPick },
            fallbackThread: { recencyPick },
            schedule: scheduler.schedule
        )
        service.onAssign = { thread, _ in assignedThread = thread }

        let control = HardwareControl.key2
        service.handle(CodexPadPhysicalEvent(sequence: 0, control: control.reportedControlIndex, phase: .pressed))
        scheduler.fireLatest()

        XCTAssertEqual(assignedThread?.id, "thread-from-clipboard")
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

        bridge.onStatus?(thread.id, .running)
        bridge.onThreads?([thread])

        XCTAssertEqual(store.status(for: .key1), .running)
        XCTAssertEqual(changeCount, 1)
    }

    @MainActor
    func testCompletedFlashRestoresIdleInsteadOfTurningBoardDark() {
        var batches: [[[UInt8]]] = []
        let feedback = CodexPadLEDFeedbackService { batches.append($0) }
        let profile = ProfileFactory.safe()
        let statuses: [HardwareControl: CodexAgentStatus] = [.key1: .completed]

        feedback.showAgentStatuses(statuses, profile: profile)
        feedback.showAgentStatuses(statuses, profile: profile)

        let restored = batches.last ?? []
        XCTAssertEqual(restored.count, HardwareControl.buttons.count)
        XCTAssertTrue(restored.allSatisfy {
            $0[3] == 0x10
                && $0[5] == profile.idleLighting.effect.rawValue
                && $0[10] == profile.idleLighting.brightness
        })
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
