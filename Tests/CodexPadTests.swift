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
    }

    func testReasoningTriggerProfileUsesConfirmedLocalShortcuts() {
        let profile = ProfileFactory.codexReasoningTriggers(catalog: CodexActionCatalog())
        XCTAssertEqual(profile.action(for: .encoderLeft).deviceMacro, "f18")
        XCTAssertEqual(profile.action(for: .encoderPress).deviceMacro, "f23")
        XCTAssertEqual(profile.action(for: .encoderRight).deviceMacro, "f19")
        XCTAssertEqual(profile.action(for: .encoderLeft).codexActionID, "encoder-effort-decrease")
    }

    func testCodexProfileUsesReasoningTriggersByDefault() {
        let profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        XCTAssertEqual(profile.action(for: .encoderLeft).deviceMacro, "f18")
        XCTAssertEqual(profile.action(for: .encoderPress).deviceMacro, "f23")
        XCTAssertEqual(profile.action(for: .encoderRight).deviceMacro, "f19")
        XCTAssertEqual(profile.action(for: .encoderRight).codexActionID, "encoder-effort-increase")
    }

    func testCodexProfileGeneratesReasoningFunctionKeys() throws {
        let profile = ProfileFactory.codex(catalog: CodexActionCatalog())
        let yaml = try CH57xConfigurationEncoder().encode(profile: profile)
        XCTAssertTrue(yaml.contains("ccw: 'f18'"))
        XCTAssertTrue(yaml.contains("press: 'f23'"))
        XCTAssertTrue(yaml.contains("cw: 'f19'"))
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
