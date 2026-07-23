import AppKit
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
    /// Minimum real gap enforced between any two posted key events. Unlike
    /// Codex's plain rotate (a direct, stateless shortcut), Claude's effort
    /// and model steps depend on a menu actually being open first, so a fast
    /// rotation firing an "open menu" keystroke and an "arrow" keystroke back
    /// to back — each scheduled from its own independent timer — could have
    /// the arrow land before the open shortcut actually took effect. All key
    /// posts now go through `enqueue`, a single serial queue, so ordering and
    /// spacing are guaranteed regardless of how fast the dial is turned.
    private static let keySpacingSeconds: TimeInterval = 0.09

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
    private var pendingKeyActions: [() -> Void] = []
    private var isProcessingKeyActions = false

    private let permissionMonitor: PermissionMonitor
    private(set) var status = "Deaktiviert"
    private(set) var lastInput = "Noch kein Drehrad-Signal empfangen"
    var hasAccessibilityPermission: Bool { permissionMonitor.hasAccessibilityPermission }
    var hasInputMonitoringPermission: Bool { permissionMonitor.hasInputMonitoringPermission }
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey)
            updateMonitoring()
        }
    }

    init(permissionMonitor: PermissionMonitor, isActiveProfile: @escaping () -> Bool) {
        self.permissionMonitor = permissionMonitor
        self.isActiveProfile = isActiveProfile
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        updateMonitoring()
    }

    func requestPermissions() {
        permissionMonitor.requestPermissions()
        updateMonitoring()
        if !hasInputMonitoringPermission || !hasAccessibilityPermission {
            status = "Berechtigungen fehlen noch. In den Systemeinstellungen CodexPad aktivieren und danach zur App zurückkehren."
        }
    }

    func refreshPermissions() {
        permissionMonitor.refresh()
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
            // Swapped vs. the naive left=previous/right=next assumption:
            // confirmed by hand that this hardware reports the physical
            // rotation directions inverted relative to the encoderLeft/Right
            // labels, so left is wired to `.next` here to match reality.
            guard event.phase == .triggered else { return }
            driveModelMenuHighlight(.next)
        case .encoderRight:
            guard event.phase == .triggered else { return }
            driveModelMenuHighlight(.previous)
        case .key1, .key2, .key3, .key4, .key5, .key6:
            break
        }
    }

    private func beginEncoderHold() {
        autoCloseTimer?.invalidate()
        encoderHoldTimer?.invalidate()
        encoderHoldFired = false
        // A fresh press physically implies the previous one was released —
        // the hardware cannot report two `.pressed` events in a row without a
        // `.released` in between. If `isModelMenuOpen` is still true here, a
        // `.released` firmware report was dropped last time, leaving this
        // flag stuck and silently blocking `fireEncoderHold()` from ever
        // reopening the menu again (the actual bug behind "works once, then
        // never again until the automation toggle is switched off and on").
        // Force it closed so every new press starts from a clean slate.
        if isModelMenuOpen {
            isModelMenuOpen = false
            enqueue { Self.postKey(UInt16(kVK_Escape)) }
        }
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
        enqueue {
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
        enqueue { Self.postKey(UInt16(kVK_Return)) }
        enqueue { [weak self] in
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
        enqueue { Self.postKey(keyCode) }
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
        pendingKeyActions.removeAll()
        isProcessingKeyActions = false
    }

    /// Appends a key-posting action to the serial queue instead of firing it
    /// immediately. Every action runs strictly after the previous one, with a
    /// real `keySpacingSeconds` gap in between, so an "open menu" shortcut
    /// enqueued a moment ago is guaranteed to have already landed before a
    /// later arrow-key action from a fast follow-up rotation runs.
    private func enqueue(_ action: @escaping () -> Void) {
        pendingKeyActions.append(action)
        processQueueIfNeeded()
    }

    private func processQueueIfNeeded() {
        guard !isProcessingKeyActions, !pendingKeyActions.isEmpty else { return }
        isProcessingKeyActions = true
        let next = pendingKeyActions.removeFirst()
        next()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keySpacingSeconds) { [weak self] in
            guard let self else { return }
            self.isProcessingKeyActions = false
            self.processQueueIfNeeded()
        }
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
        if !isEffortMenuOpen {
            isEffortMenuOpen = true
            enqueue { Self.postKey(UInt16(kVK_ANSI_E), flags: [.maskCommand, .maskShift]) }
        }
        // Enqueued strictly after the open shortcut above (same serial
        // queue), so this always lands after the menu is actually open, even
        // if the dial is rotated faster than the queue can drain.
        enqueue { Self.postKey(keyCode) }
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
        enqueue { [weak self] in
            Self.postKey(UInt16(kVK_Escape))
            self?.status = "Denkaufwand-Menü geschlossen."
        }
    }

    func toggleEffortMenu() {
        guard let claude = readyClaudeApplication() else { return }
        claude.activate(options: [.activateAllWindows])
        autoCloseTimer?.invalidate()
        if isEffortMenuOpen {
            isEffortMenuOpen = false
            status = "Schließen: Denkaufwand-Menü"
            enqueue { [weak self] in
                Self.postKey(UInt16(kVK_Escape))
                self?.status = "Denkaufwand-Menü geschlossen."
            }
            return
        }
        isEffortMenuOpen = true
        status = "Öffnen: Denkaufwand-Menü"
        enqueue { [weak self] in
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
            // Claude isn't running (or was quit/relaunched since we last
            // opened a menu): whatever we assumed about its UI state no
            // longer holds, so drop it rather than risk sending arrow keys
            // into a menu that isn't there.
            resetState()
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

        // Swapped vs. the naive F22=previous/F24=next assumption, matching
        // the same left/right inversion applied in `handlePhysicalEvent`.
        switch usage {
        case 0x71: // F22: rotate left — suppressed mid-hold, see driveModelMenuHighlight.
            guard !encoderHoldFired else { break }
            stepEffort(.next)
        case 0x73: // F24: rotate right, same guard as above.
            guard !encoderHoldFired else { break }
            stepEffort(.previous)
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
