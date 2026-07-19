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
/// dismissible Codex areas; F22–F24 remain reserved for the encoder's
/// reasoning controls. No UI coordinates or picker navigation are used.
@MainActor
@Observable
final class CodexReasoningAutomationService {
    private let logger = Logger(subsystem: "com.codexpad.app", category: "encoder")
    private static let preferenceKey = "CodexPad.encoderAutomationEnabled"
    private static let migrationKey = "CodexPad.simpleEncoderV5"
    private var hidManager: IOHIDManager?
    private var inputDebouncer = HIDInputDebouncer()
    private var openDismissibleArea: CodexDismissibleArea?

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
        guard isEnabled else {
            status = "Deaktiviert"
            return
        }

        guard hasInputMonitoringPermission else {
            status = "Input Monitoring fehlt – macOS blockiert das Drehrad. Bitte CodexPad unten freigeben."
            return
        }

        status = "Bereit: Drehen = Aufwand · Drücken = Model Picker."

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
        guard usagePage == 0x07, [0x68, 0x69, 0x6A, 0x71, 0x72, 0x73].contains(usage) else { return }

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
        case 0x71: // F22: rotate left
            perform(.decreaseEffort)
        case 0x72: // F23: press
            toggleModelPicker()
        case 0x73: // F24: rotate right
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
}
