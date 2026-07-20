import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.hid
import Observation
import OSLog

enum CodexEncoderCommand {
    case decreaseEffort, openPicker, closePicker, increaseEffort

    var title: String {
        switch self {
        case .decreaseEffort: "Aufwand verringern"
        case .openPicker: "Model Picker öffnen"
        case .closePicker: "Model Picker schließen"
        case .increaseEffort: "Aufwand erhöhen"
        }
    }

    var detail: String {
        switch self {
        case .decreaseEffort: "Direkter Codex-Shortcut F18"
        case .openPicker: "Picker öffnen"
        case .closePicker: "Picker schließen (Esc)"
        case .increaseEffort: "Direkter Codex-Shortcut F19"
        }
    }

    var directShortcutKeyCode: UInt16? {
        switch self {
        case .decreaseEffort: UInt16(kVK_F18)
        case .closePicker: UInt16(kVK_Escape)
        case .increaseEffort: UInt16(kVK_F19)
        case .openPicker: nil
        }
    }

}

enum CodexModelListStep {
    case next, previous
}

private enum CodexDismissibleArea: String {
    case modelPicker
    case settings
    case sideChat

    var title: String {
        switch self {
        case .modelPicker: "Model Picker"
        case .settings: "Settings"
        case .sideChat: "Side Chat"
        }
    }

}

/// The hardware uses private function-key triggers. F13–F15 toggle
/// dismissible Codex areas; F22–F24 are the encoder's private rotate/press
/// triggers. The encoder always has both gestures at once, mirroring the
/// buttons' tap-vs-hold model: a plain rotate/press changes reasoning effort
/// or toggles the Model Picker, while holding the dial and rotating drives
/// the Model Picker's "Modell" submenu with arrow keys instead.
@MainActor
@Observable
final class CodexReasoningAutomationService {
    private let logger = Logger(subsystem: "com.codexpad.app", category: "encoder")
    private static let preferenceKey = "CodexPad.encoderAutomationEnabled"
    private static let migrationKey = "CodexPad.simpleEncoderV5"
    /// The dial must be held this long before a press starts driving the
    /// Model Picker; short presses fall through untouched.
    private static let modelListHoldThresholdSeconds: TimeInterval = 0.35
    static var modelListHoldThresholdMilliseconds: Int { Int(modelListHoldThresholdSeconds * 1000) }
    private var hidManager: IOHIDManager?
    private var inputDebouncer = HIDInputDebouncer()
    private var openDismissibleArea: CodexDismissibleArea?
    /// True once the held press has opened the Model Picker and driven it
    /// straight into the "Modell" submenu.
    private var isModelListOpen = false
    private var encoderHoldTimer: Timer?
    /// Set once the current press has been held past the threshold; rotation
    /// only drives menu navigation while this is true.
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

    init() {
        self.hasAccessibilityPermission = AXIsProcessTrusted()
        self.hasInputMonitoringPermission = CGPreflightListenEventAccess()
        if !UserDefaults.standard.bool(forKey: Self.migrationKey) {
            UserDefaults.standard.set(true, forKey: Self.preferenceKey)
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
        }
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

    /// TCC permissions can change while System Settings is in front. Refresh
    /// them whenever CodexPad becomes active and reopen HID only after access
    /// was actually granted.
    func refreshPermissions() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasInputMonitoringPermission = CGPreflightListenEventAccess()
        updateMonitoring()
    }

    @discardableResult
    func perform(_ command: CodexEncoderCommand) -> Bool {
        guard let codex = readyCodexApplication() else { return false }
        codex.activate(options: [.activateAllWindows])
        status = "Ausführen: \(command.title)"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            if let keyCode = command.directShortcutKeyCode {
                Self.postKey(keyCode)
            } else {
                Self.openModelPickerShortcut()
            }
            switch command {
            case .openPicker:
                self?.status = "Picker offen: erneut drücken zum Schließen."
            case .closePicker:
                self?.status = "Picker geschlossen."
            default:
                self?.status = "Fertig: \(command.title)"
            }
        }
        return true
    }

    func toggleModelPicker() {
        toggle(.modelPicker)
    }

    /// Model-list-navigation entry point fed by CodexPad's own firmware
    /// protocol (`CodexPadEventService`), which is the only channel that
    /// reliably reports the encoder press's release edge: the generic
    /// keyboard-HID interface only ever delivers the key-down for this
    /// control on the confirmed hardware, never the key-up, so hold-duration
    /// timing cannot be driven from `handleHIDValue` alone. Rotation ticks are
    /// read from the same protocol for consistency, since it is unaffected by
    /// whichever macro happens to be flashed for the dial.
    func handlePhysicalEvent(_ event: CodexPadPhysicalEvent) {
        guard let control = HardwareControl(reportedControlIndex: event.control) else { return }
        switch control {
        case .encoderPress:
            switch event.phase {
            case .pressed: beginEncoderHold()
            case .released: endEncoderHold()
            case .triggered: break
            }
        case .encoderLeft:
            guard event.phase == .triggered else { return }
            driveModelListHighlight(.previous)
        case .encoderRight:
            guard event.phase == .triggered else { return }
            driveModelListHighlight(.next)
        case .key1, .key2, .key3, .key4, .key5, .key6:
            break
        }
    }

    private func beginEncoderHold() {
        encoderHoldTimer?.invalidate()
        encoderHoldFired = false
        encoderHoldTimer = Timer.scheduledTimer(withTimeInterval: Self.modelListHoldThresholdSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireEncoderHold() }
        }
    }

    /// Fires the instant the hold threshold is crossed: opens the Model
    /// Picker and drills straight into its "Modell" submenu with no further
    /// press/release cycle needed.
    ///
    /// The menu's starting highlight is not fixed: the first-ever open
    /// starts on "Erweitert", but once the menu has been driven into a
    /// submenu and closed, it re-opens next time already highlighting
    /// wherever it was left — so a fixed "press Up N times" count that
    /// worked once landed one entry off the next time. Confirmed by hand:
    /// Up from "Modell" (the first entry) wraps to "Erweitert" (the last),
    /// but Up pressed again while already on "Erweitert" does nothing
    /// (it's a dead end in that direction) — while Down from "Erweitert"
    /// reliably moves on. That dead end is exploited here as a fixed anchor:
    /// six Up presses are more than enough to land on "Erweitert" and stay
    /// there regardless of the starting position, then one Down reaches
    /// "Modell" and Right expands its model list.
    private func fireEncoderHold() {
        encoderHoldFired = true
        guard !isModelListOpen else { return }
        guard let codex = readyCodexApplication() else { return }
        codex.activate(options: [.activateAllWindows])
        isModelListOpen = true
        status = "Modellliste offen: drehen wählt, loslassen übernimmt."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Self.openModelPickerShortcut()
            let upArrow = UInt16(kVK_UpArrow)
            let sequence = Array(repeating: upArrow, count: 6) + [UInt16(kVK_DownArrow), UInt16(kVK_RightArrow)]
            Self.postKeysSequentially(sequence, startingAfter: 0.08, interval: 0.07)
        }
    }

    /// Releasing after a short press (below the hold threshold) is the plain
    /// tap gesture: toggle the Model Picker open/closed, unchanged from
    /// direct-effort behaviour. Releasing after the dial was actually held
    /// confirms the highlighted model and closes the picker instead.
    private func endEncoderHold() {
        encoderHoldTimer?.invalidate()
        encoderHoldTimer = nil
        let wasHeld = encoderHoldFired
        encoderHoldFired = false
        guard wasHeld else {
            toggleModelPicker()
            return
        }
        guard isModelListOpen else { return }
        isModelListOpen = false
        guard let codex = readyCodexApplication() else { return }
        codex.activate(options: [.activateAllWindows])
        status = "Modell übernehmen …"
        Self.postKey(UInt16(kVK_Return))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            Self.postKey(UInt16(kVK_Escape))
            self?.status = "Übernommen."
        }
    }

    /// Only acts while the dial is held past the threshold and the Model
    /// Picker is already driven open; a plain (unheld) rotate is handled
    /// separately by the direct reasoning-effort shortcuts in
    /// `handleHIDValue`, so this stays silent otherwise to avoid double
    /// handling the same physical tick.
    private func driveModelListHighlight(_ step: CodexModelListStep) {
        guard encoderHoldFired, isModelListOpen else { return }
        guard readyCodexApplication() != nil else { return }
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
        driveModelListHighlight(step)
    }

    func testEndHold() {
        encoderHoldFired = true
        endEncoderHold()
    }

    private func resetModelPickerNavigation() {
        encoderHoldTimer?.invalidate()
        encoderHoldTimer = nil
        encoderHoldFired = false
        isModelListOpen = false
    }

    private func toggle(_ area: CodexDismissibleArea) {
        guard let codex = readyCodexApplication() else { return }
        codex.activate(options: [.activateAllWindows])

        if openDismissibleArea == area {
            openDismissibleArea = nil
            status = "Schließen: \(area.title)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                Self.postKey(UInt16(kVK_Escape))
                self?.status = "\(area.title) geschlossen."
            }
            return
        }

        openDismissibleArea = area
        status = "Öffnen: \(area.title)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            switch area {
            case .modelPicker:
                Self.openModelPickerShortcut()
            case .settings:
                Self.postKey(UInt16(kVK_ANSI_Comma), flags: [.maskCommand])
            case .sideChat:
                break
            }
            self?.status = "\(area.title) offen: erneut drücken zum Schließen."
        }
    }

    private var codexApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .first(where: { $0.bundleURL?.lastPathComponent == "Codex.app" })
    }

    private func readyCodexApplication() -> NSRunningApplication? {
        guard isEnabled else {
            status = "Encoder-Steuerung ist deaktiviert."
            return nil
        }
        guard hasAccessibilityPermission else {
            status = "Bedienungshilfen fehlen. Bitte unten Berechtigungen anfordern."
            return nil
        }
        guard let codex = codexApplication else {
            status = "Codex läuft nicht."
            return nil
        }
        return codex
    }

    private func updateMonitoring() {
        stopMonitoring()
        openDismissibleArea = nil
        resetModelPickerNavigation()
        guard isEnabled else {
            status = "Deaktiviert"
            return
        }

        guard hasInputMonitoringPermission else {
            status = "Input Monitoring fehlt – macOS blockiert das Drehrad. Bitte CodexPad unten freigeben."
            return
        }

        status = "Bereit: Drehen/Drücken = Aufwand & Modellwahl · Halten (>\(Int(Self.modelListHoldThresholdSeconds * 1000)) ms) + drehen = Modell wechseln."

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
        guard usagePage == 0x07, [0x68, 0x69, 0x6A, 0x71, 0x73].contains(usage) else { return }

        // The encoder press (F23) needs both edges to measure hold duration,
        // which this generic keyboard-HID path cannot reliably deliver on the
        // confirmed hardware (only the key-down ever arrives here); it is
        // handled exclusively via `handlePhysicalEvent` instead.

        guard value != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard inputDebouncer.accepts(usage: usage, at: now) else { return }
        recordInput(usage: usage, value: value)

        switch usage {
        case 0x68: // F13: Settings
            toggle(.settings)
        case 0x69: // F14: Model Picker
            toggle(.modelPicker)
        case 0x6A: // F15: Side Chat (configured in Codex)
            toggle(.sideChat)
        case 0x71: // F22: rotate left — suppressed mid-hold so the same tick
                   // doesn't also fire the direct effort shortcut while
                   // `driveModelListHighlight` is navigating the Model Picker.
            guard !encoderHoldFired else { break }
            perform(.decreaseEffort)
        case 0x73: // F24: rotate right, same guard as above.
            guard !encoderHoldFired else { break }
            perform(.increaseEffort)
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
        let service = Unmanaged<CodexReasoningAutomationService>.fromOpaque(context).takeUnretainedValue()
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let elementUsage = Int(IOHIDElementGetUsage(element))
        let integerValue = Int(IOHIDValueGetIntegerValue(value))
        guard let normalized = HIDInputEvent.normalizedKeyboardValue(elementUsage: elementUsage, value: integerValue) else { return }
        DispatchQueue.main.async {
            service.handleHIDValue(usagePage: usagePage, usage: normalized.usage, value: normalized.value)
        }
    }

    private nonisolated static func openModelPickerShortcut() {
        postKey(UInt16(kVK_ANSI_M), flags: [.maskControl, .maskShift])
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

    /// Posts each key with a real gap after the previous one, rather than in
    /// one burst: identical key events fired back-to-back with no spacing
    /// were observed to be coalesced/dropped, silently under-counting menu
    /// navigation presses.
    private nonisolated static func postKeysSequentially(_ keyCodes: [UInt16], startingAfter delay: TimeInterval, interval: TimeInterval) {
        guard let first = keyCodes.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            postKey(first)
            postKeysSequentially(Array(keyCodes.dropFirst()), startingAfter: interval, interval: interval)
        }
    }
}
