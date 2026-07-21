import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.hid
import Observation
import OSLog

/// Claude Desktop exposes reasoning-effort and model switching through two
/// separate menus, each with its own opening shortcut: ⌘⇧E opens the Effort
/// menu, ⌘⇧I opens the Model menu; both are then navigated with ↑/↓ and
/// confirmed with Enter. Unlike the Codex profile, there is no bare global
/// shortcut for either. So a plain dial turn opens the Effort menu just long
/// enough to step through it and then auto-closes it again, while holding the
/// dial and turning instead opens the Model menu and walks it, confirming on
/// release — the same tap-vs-hold shape as Codex's encoder, retargeted to
/// what Claude actually has.
@MainActor
@Observable
final class ClaudeReasoningAutomationService: EncoderAutomationService {
    private let logger = Logger(subsystem: "com.codexpad.app", category: "claude-encoder")
    private static let preferenceKey = "CodexPad.claudeEncoderAutomationEnabled"
    private static let modelListHoldThresholdSeconds: TimeInterval = 0.35
    static var modelListHoldThresholdMilliseconds: Int { Int(modelListHoldThresholdSeconds * 1000) }
    /// How long the Effort menu stays open after the last plain-rotate step
    /// before CodexPad closes it again on its own.
    private static let autoCloseIdleSeconds: TimeInterval = 1.6

    /// True while the Claude profile is selected; both this service and
    /// `CodexReasoningAutomationService` listen to the same private F22–F24
    /// HID triggers, so only the one matching the active profile may act.
    private let isActiveProfile: () -> Bool
    private var hidManager: IOHIDManager?
    private var inputDebouncer = HIDInputDebouncer()
    /// True whenever CodexPad has sent ⌘⇧E and not yet closed the Effort menu
    /// again (plain-rotate gesture).
    private var isEffortMenuOpen = false
    /// True whenever CodexPad has sent ⌘⇧I and not yet closed the Model menu
    /// again (hold+rotate gesture).
    private var isModelMenuOpen = false
    private var autoCloseTimer: Timer?
    private var encoderHoldTimer: Timer?
    private var encoderHoldFired = false

    private(set) var status = "Deaktiviert"
    private(set) var lastInput = "Noch kein Drehrad-Signal empfangen"
    private(set) var hasAccessibilityPermission: Bool
    private(set) var hasInputMonitoringPermission: Bool
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey)
            updateMonitoring()
        }
    }

    init(isActiveProfile: @escaping () -> Bool) {
        self.isActiveProfile = isActiveProfile
        self.hasAccessibilityPermission = AXIsProcessTrusted()
        self.hasInputMonitoringPermission = CGPreflightListenEventAccess()
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        updateMonitoring()
    }

    func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = CGRequestListenEventAccess()
        refreshPermissions()
        if !hasInputMonitoringPermission || !hasAccessibilityPermission {
            status = "Berechtigungen fehlen noch. In den Systemeinstellungen CodexPad aktivieren und danach zur App zurückkehren."
        }
    }

    func refreshPermissions() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasInputMonitoringPermission = CGPreflightListenEventAccess()
        updateMonitoring()
    }

    /// Model-list-navigation entry point fed by CodexPad's own firmware
    /// protocol, mirroring `CodexReasoningAutomationService.handlePhysicalEvent`
    /// — the only channel that reliably reports the encoder press's release
    /// edge on the confirmed hardware.
    func handlePhysicalEvent(_ event: CodexPadPhysicalEvent) {
        guard isActiveProfile(), let control = HardwareControl(reportedControlIndex: event.control) else { return }
        switch control {
        case .encoderPress:
            switch event.phase {
            case .pressed: beginEncoderHold()
            case .released: endEncoderHold()
            case .triggered: break
            }
        case .encoderLeft:
            guard event.phase == .triggered else { return }
            driveModelMenuHighlight(.previous)
        case .encoderRight:
            guard event.phase == .triggered else { return }
            driveModelMenuHighlight(.next)
        case .key1, .key2, .key3, .key4, .key5, .key6:
            break
        }
    }

    private func beginEncoderHold() {
        autoCloseTimer?.invalidate()
        encoderHoldTimer?.invalidate()
        encoderHoldFired = false
        encoderHoldTimer = Timer.scheduledTimer(withTimeInterval: Self.modelListHoldThresholdSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireEncoderHold() }
        }
    }

    /// Fires the instant the hold threshold is crossed: opens the Model menu
    /// (⌘⇧I) if it isn't already open, so the following rotate ticks can walk
    /// it with ↑/↓.
    private func fireEncoderHold() {
        encoderHoldFired = true
        guard !isModelMenuOpen else { return }
        guard let claude = readyClaudeApplication() else { return }
        claude.activate(options: [.activateAllWindows])
        isModelMenuOpen = true
        status = "Modellmenü offen: drehen wählt, loslassen übernimmt."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Self.postKey(UInt16(kVK_ANSI_I), flags: [.maskCommand, .maskShift])
        }
    }

    /// Releasing after a short press (below the hold threshold) is the plain
    /// tap gesture: toggle the Effort menu open/closed. Releasing after the
    /// dial was actually held confirms the highlighted model and closes the
    /// Model menu instead.
    private func endEncoderHold() {
        encoderHoldTimer?.invalidate()
        encoderHoldTimer = nil
        let wasHeld = encoderHoldFired
        encoderHoldFired = false
        guard wasHeld else {
            toggleEffortMenu()
            return
        }
        guard isModelMenuOpen else { return }
        isModelMenuOpen = false
        guard let claude = readyClaudeApplication() else { return }
        claude.activate(options: [.activateAllWindows])
        status = "Modell übernehmen …"
        Self.postKey(UInt16(kVK_Return))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            Self.postKey(UInt16(kVK_Escape))
            self?.status = "Übernommen."
        }
    }

    /// Only acts while the dial is held past the threshold and the Model menu
    /// is already driven open; a plain (unheld) rotate is handled separately
    /// by `stepEffort` in `handleHIDValue`.
    private func driveModelMenuHighlight(_ step: CodexModelListStep) {
        guard encoderHoldFired, isModelMenuOpen else { return }
        guard readyClaudeApplication() != nil else { return }
        let keyCode = step == .next ? UInt16(kVK_DownArrow) : UInt16(kVK_UpArrow)
        status = step == .next ? "Nächstes Modell" : "Vorheriges Modell"
        Self.postKey(keyCode)
    }

    /// Testing hooks for the assignment panel: skip the hold-timer wait so a
    /// button click can exercise the same state machine as a real long press.
    func testBeginHold() {
        encoderHoldTimer?.invalidate()
        fireEncoderHold()
    }

    func testRotate(_ step: CodexModelListStep) {
        driveModelMenuHighlight(step)
    }

    func testEndHold() {
        encoderHoldFired = true
        endEncoderHold()
    }

    private func resetState() {
        encoderHoldTimer?.invalidate()
        encoderHoldTimer = nil
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        encoderHoldFired = false
        isModelMenuOpen = false
        isEffortMenuOpen = false
    }

    /// Plain (unheld) rotation: Claude only exposes effort stepping while the
    /// Effort menu (⌘⇧E) is open, so this opens it on demand, steps through it
    /// with ↑/↓, and schedules an auto-close a moment after the dial goes
    /// quiet again.
    private func stepEffort(_ direction: CodexModelListStep) {
        guard let claude = readyClaudeApplication() else { return }
        claude.activate(options: [.activateAllWindows])
        let keyCode = direction == .next ? UInt16(kVK_DownArrow) : UInt16(kVK_UpArrow)
        status = direction == .next ? "Aufwand erhöhen" : "Aufwand verringern"
        if isEffortMenuOpen {
            Self.postKey(keyCode)
        } else {
            isEffortMenuOpen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                Self.postKey(UInt16(kVK_ANSI_E), flags: [.maskCommand, .maskShift])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    Self.postKey(keyCode)
                }
            }
        }
        scheduleAutoClose()
    }

    private func scheduleAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: Self.autoCloseIdleSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.autoCloseEffortMenu() }
        }
    }

    private func autoCloseEffortMenu() {
        guard isEffortMenuOpen, !isModelMenuOpen else { return }
        isEffortMenuOpen = false
        Self.postKey(UInt16(kVK_Escape))
        status = "Denkaufwand-Menü geschlossen."
    }

    func toggleEffortMenu() {
        guard let claude = readyClaudeApplication() else { return }
        claude.activate(options: [.activateAllWindows])
        autoCloseTimer?.invalidate()
        if isEffortMenuOpen {
            isEffortMenuOpen = false
            status = "Schließen: Denkaufwand-Menü"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                Self.postKey(UInt16(kVK_Escape))
                self?.status = "Denkaufwand-Menü geschlossen."
            }
            return
        }
        isEffortMenuOpen = true
        status = "Öffnen: Denkaufwand-Menü"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            Self.postKey(UInt16(kVK_ANSI_E), flags: [.maskCommand, .maskShift])
            self?.status = "Denkaufwand-Menü offen: erneut drücken zum Schließen."
        }
    }

    private var claudeApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: AutomationApp.claude.bundleIdentifier)
            .first(where: { $0.bundleURL?.lastPathComponent == "Claude.app" })
    }

    private func readyClaudeApplication() -> NSRunningApplication? {
        guard isEnabled else {
            status = "Encoder-Steuerung ist deaktiviert."
            return nil
        }
        guard hasAccessibilityPermission else {
            status = "Bedienungshilfen fehlen. Bitte unten Berechtigungen anfordern."
            return nil
        }
        guard let claude = claudeApplication else {
            status = "Claude läuft nicht."
            return nil
        }
        return claude
    }

    private func updateMonitoring() {
        stopMonitoring()
        resetState()
        guard isEnabled else {
            status = "Deaktiviert"
            return
        }

        guard hasInputMonitoringPermission else {
            status = "Input Monitoring fehlt – macOS blockiert das Drehrad. Bitte CodexPad unten freigeben."
            return
        }

        status = "Bereit: Drehen = Reasoning-Aufwand (⌘⇧E) · Halten (>\(Int(Self.modelListHoldThresholdSeconds * 1000)) ms) + drehen = Modell wechseln (⌘⇧I)."

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboardIdentity: (Int, Int) -> [String: Any] = { vendorID, productID in
            [
                kIOHIDVendorIDKey as String: vendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDPrimaryUsagePageKey as String: 0x01,
                kIOHIDPrimaryUsageKey as String: 0x06
            ]
        }
        let matching = [keyboardIdentity(0x1189, 0x8890), keyboardIdentity(0x4249, 0x4287)]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, Self.inputCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            status = "Drehrad konnte nicht geöffnet werden (\(result))."
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return
        }
        hidManager = manager
    }

    private func stopMonitoring() {
        guard let hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = nil
    }

    private func handleHIDValue(usagePage: Int, usage: Int, value: Int) {
        guard isActiveProfile(), usagePage == 0x07, [0x71, 0x73].contains(usage) else { return }
        guard value != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard inputDebouncer.accepts(usage: usage, at: now) else { return }
        recordInput(usage: usage, value: value)

        switch usage {
        case 0x71: // F22: rotate left — suppressed mid-hold, see driveModelMenuHighlight.
            guard !encoderHoldFired else { break }
            stepEffort(.previous)
        case 0x73: // F24: rotate right, same guard as above.
            guard !encoderHoldFired else { break }
            stepEffort(.next)
        default:
            break
        }
    }

    private func recordInput(usage: Int, value: Int) {
        lastInput = HIDInputEvent.functionKeyName(usage).map { "Empfangen: \($0)" } ?? String(format: "Empfangen: 0x%02X", usage)
        logger.info("HID input usage=\(usage, privacy: .public) value=\(value, privacy: .public)")
    }

    nonisolated private static let inputCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let element = IOHIDValueGetElement(value)
        let service = Unmanaged<ClaudeReasoningAutomationService>.fromOpaque(context).takeUnretainedValue()
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let elementUsage = Int(IOHIDElementGetUsage(element))
        let integerValue = Int(IOHIDValueGetIntegerValue(value))
        guard let normalized = HIDInputEvent.normalizedKeyboardValue(elementUsage: elementUsage, value: integerValue) else { return }
        DispatchQueue.main.async {
            service.handleHIDValue(usagePage: usagePage, usage: normalized.usage, value: normalized.value)
        }
    }

    private nonisolated static func postKey(_ keyCode: UInt16, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}
