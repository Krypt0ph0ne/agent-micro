import Foundation
import IOKit.hid
import Observation

struct HIDInputEvent: Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var usagePage: Int
    var usage: Int
    var value: Int

    var label: String {
        if usagePage == 0x07, let functionKey = Self.functionKeyName(usage) { return functionKey }
        return String(format: "Usage Page 0x%02X · Usage 0x%02X", usagePage, usage)
    }

    static func functionKeyName(_ usage: Int) -> String? {
        switch usage {
        case 0x3A...0x45: return "F\(usage - 0x3A + 1)"
        case 0x68...0x73: return "F\(usage - 0x68 + 13)"
        default: return nil
        }
    }

    /// Boot-keyboard reports store ordinary keys in an array element whose
    /// element usage is undefined (usually 0xFFFF). The actual key usage is
    /// then the element value. Variable elements keep usage and value separate.
    static func normalizedKeyboardValue(elementUsage: Int, value: Int) -> (usage: Int, value: Int)? {
        if (0...0xFF).contains(elementUsage) {
            return (elementUsage, value)
        }
        if (1...0xFF).contains(value) {
            return (value, 1)
        }
        return nil
    }
}

struct HIDInputDebouncer {
    private var lastAcceptedTime: [Int: TimeInterval] = [:]

    mutating func accepts(usage: Int, at time: TimeInterval, duplicateWindow: TimeInterval = 0.035) -> Bool {
        if let previous = lastAcceptedTime[usage], time - previous < duplicateWindow { return false }
        lastAcceptedTime[usage] = time
        return true
    }
}

/// Read-only HID monitor for the selected CH57x keyboard collection.  It never
/// intercepts, changes, or synthesizes input. macOS may require Input
/// Monitoring permission before the OS delivers events to this process.
@MainActor
@Observable
final class HIDInputMonitor {
    private var manager: IOHIDManager?
    private let permissionMonitor: PermissionMonitor
    private(set) var isMonitoring = false
    private(set) var status = AppLanguage.text("Nicht gestartet", "Not started")
    private(set) var events: [HIDInputEvent] = []

    var hasInputMonitoringPermission: Bool { permissionMonitor.hasInputMonitoringPermission }

    init(permissionMonitor: PermissionMonitor) {
        self.permissionMonitor = permissionMonitor
    }

    func start(vendorID: Int = 0x1189, productID: Int = 0x8890) {
        stop()
        events.removeAll()

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
            kIOHIDPrimaryUsagePageKey as String: 0x01,
            kIOHIDPrimaryUsageKey as String: 0x06
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, Self.inputCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            status = AppLanguage.text(
                "HID-Monitor konnte nicht geöffnet werden (IOReturn \(result)). Aktiviere bei Bedarf Input Monitoring für Agent Micro.",
                "Could not open the HID monitor (IOReturn \(result)). Enable Input Monitoring for Agent Micro if needed."
            )
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return
        }

        self.manager = manager
        isMonitoring = true
        status = hasInputMonitoringPermission
            ? AppLanguage.text(
                "Lauscht auf physische Tastendrücke des CH57x-Keyboards.",
                "Listening for physical key presses from the CH57x keyboard."
            )
            : AppLanguage.text(
                "Lauscht auf physische Tastendrücke. Falls keine Ereignisse eintreffen, Input Monitoring für Agent Micro erlauben.",
                "Listening for physical key presses. If no events arrive, allow Input Monitoring for Agent Micro."
            )
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        isMonitoring = false
        status = AppLanguage.text("Gestoppt", "Stopped")
    }

    func clear() { events.removeAll() }

    private func record(usagePage: Int, usage: Int, value: Int) {
        guard value != 0, usagePage == 0x07, (0...0xFF).contains(usage) else { return }
        events.insert(HIDInputEvent(usagePage: usagePage, usage: usage, value: value), at: 0)
        if events.count > 80 { events.removeLast(events.count - 80) }
    }

    nonisolated private static let inputCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let elementUsage = Int(IOHIDElementGetUsage(element))
        let integerValue = Int(IOHIDValueGetIntegerValue(value))
        let monitor = Unmanaged<HIDInputMonitor>.fromOpaque(context).takeUnretainedValue()
        guard let normalized = HIDInputEvent.normalizedKeyboardValue(elementUsage: elementUsage, value: integerValue) else { return }
        DispatchQueue.main.async {
            monitor.record(usagePage: usagePage, usage: normalized.usage, value: normalized.value)
        }
    }
}
