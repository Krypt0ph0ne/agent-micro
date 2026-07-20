import Foundation
import IOKit.hid
import OSLog

private final class CodexPadKeyboardReportBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<UInt8>
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.pointer = .allocate(capacity: capacity)
    }

    deinit { pointer.deallocate() }
}

/// Watches the custom pad's real boot-keyboard reports. Dictation is a held
/// Command+F17 chord, so F17 presence is a stable semantic signal even when
/// the separate vendor-defined event protocol omits or renumbers the key.
@MainActor
final class CodexPadKeyboardStateService: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.codexpad.app", category: "keyboard-state")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer: CodexPadKeyboardReportBuffer?
    private var isF17Held = false
    var onDictationHoldChanged: ((Bool) -> Void)?

    func refresh(enabled: Bool) {
        stop()
        guard enabled else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: CodexPadHIDClient.vendorID,
            kIOHIDProductIDKey as String: CodexPadHIDClient.productID,
            kIOHIDPrimaryUsagePageKey as String: 0x01,
            kIOHIDPrimaryUsageKey as String: 0x06
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            logger.error("Could not open CodexPad keyboard HID")
            return
        }

        let buffer = CodexPadKeyboardReportBuffer(capacity: 16)
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer.pointer,
            buffer.capacity,
            codexPadKeyboardInputCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        self.device = device
        self.reportBuffer = buffer
        logger.info("CodexPad keyboard report monitor connected")
    }

    func stop() {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        reportBuffer = nil
        device = nil
        manager = nil
        isF17Held = false
    }

    fileprivate func consume(reportID: UInt32, bytes: [UInt8]) {
        guard reportID == 1 || bytes.first == 1 else { return }
        let keyStart = bytes.first == 1 ? 3 : 2
        guard bytes.count > keyStart else { return }
        let held = bytes[keyStart...].contains(0x6C)
        guard held != isF17Held else { return }
        isF17Held = held
        logger.info("F17 hold changed: \(held, privacy: .public)")
        onDictationHoldChanged?(held)
    }
}

private let codexPadKeyboardInputCallback: IOHIDReportCallback = { context, _, _, _, reportID, report, length in
    guard let context else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    let service = Unmanaged<CodexPadKeyboardStateService>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        service.consume(reportID: reportID, bytes: bytes)
    }
}
