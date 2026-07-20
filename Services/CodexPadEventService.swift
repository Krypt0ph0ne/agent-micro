import Foundation
import IOKit.hid
import Observation
import OSLog

struct CodexPadFirmwareStatus: Equatable {
    let version: String
    let capabilities: UInt8
    let pressedMask: UInt16
}

struct CodexPadPhysicalEvent: Identifiable, Equatable {
    enum Phase: UInt8 { case released = 0, pressed = 1, triggered = 2 }
    let id = UUID()
    let sequence: UInt8
    let control: UInt8
    let phase: Phase
    let date = Date()
}

/// All callbacks are scheduled on the main run loop. The Sendable marker is
/// limited to satisfying Foundation's Timer callback contract.
@Observable
final class CodexPadEventService: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.codexpad.app", category: "pad-events")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var statusTimer: Timer?
    private var lastLoggedPressedMask: UInt16?
    private(set) var firmwareStatus: CodexPadFirmwareStatus?
    private(set) var events: [CodexPadPhysicalEvent] = []
    private(set) var status = "Noch nicht verbunden"
    var onPhysicalEvent: ((CodexPadPhysicalEvent) -> Void)?
    var onFirmwareStatus: ((CodexPadFirmwareStatus) -> Void)?

    deinit {
        statusTimer?.invalidate()
        reportBuffer?.deallocate()
    }

    func refresh(enabled: Bool) {
        stop()
        guard enabled else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: CodexPadHIDClient.vendorID,
            kIOHIDProductIDKey as String: CodexPadHIDClient.productID,
            kIOHIDPrimaryUsagePageKey as String: 0xFF60,
            kIOHIDPrimaryUsageKey as String: 0x61
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first,
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            status = "Raw HID konnte nicht geöffnet werden"
            return
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: CodexPadPacketEncoder.packetSize)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, CodexPadPacketEncoder.packetSize, codexPadInputCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        self.device = device
        self.reportBuffer = buffer
        status = "Protokoll v2 verbunden"
        requestStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.requestStatus()
        }
    }

    func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        reportBuffer?.deallocate()
        reportBuffer = nil; device = nil; manager = nil
    }

    func requestStatus() {
        guard let device else { return }
        var packet = CodexPadPacketEncoder().statusRequestPacket()
        _ = packet.withUnsafeMutableBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
    }

    func sendLEDs(_ packets: [[UInt8]]) {
        let validPackets = packets.filter { $0.count == CodexPadPacketEncoder.packetSize }
        guard validPackets.count == packets.count else {
            logger.error("LED packet rejected: invalid packet size")
            return
        }
        if let device, sendLEDs(validPackets, to: device) {
            return
        }

        // The long-lived event interface can disappear briefly during USB
        // reconnects. Reopen Raw HID for this batch instead of dropping the
        // visual state transition.
        let fallbackResult = CodexPadHIDClient().send(validPackets)
        if !fallbackResult.succeeded {
            logger.error("LED fallback failed: \(fallbackResult.failureDescription, privacy: .public)")
        } else {
            logger.info("LED batch recovered through a fresh Raw HID connection")
        }
    }

    private func sendLEDs(_ packets: [[UInt8]], to device: IOHIDDevice) -> Bool {
        for var packet in packets {
            let result = packet.withUnsafeMutableBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
            }
            if result != kIOReturnSuccess {
                logger.error("LED output command \(packet[3], privacy: .public) failed: \(result, privacy: .public)")
                return false
            }
        }
        return true
    }

    fileprivate func consume(_ bytes: [UInt8]) {
        guard bytes.count == 32, bytes[0] == 0x43, bytes[1] == 0x50,
              bytes[0..<31].reduce(0, ^) == bytes[31] else { return }
        if bytes[3] == 0x80 {
            let firmwareStatus = CodexPadFirmwareStatus(
                version: "\(bytes[4]).\(bytes[5]).\(bytes[6])",
                capabilities: bytes[7],
                pressedMask: UInt16(bytes[10]) | UInt16(bytes[11]) << 8
            )
            self.firmwareStatus = firmwareStatus
            status = "Firmware \(firmwareStatus.version) · Protokoll v\(bytes[2])"
            if lastLoggedPressedMask != firmwareStatus.pressedMask {
                lastLoggedPressedMask = firmwareStatus.pressedMask
                logger.info("Pressed mask changed: 0x\(String(firmwareStatus.pressedMask, radix: 16), privacy: .public)")
            }
            onFirmwareStatus?(firmwareStatus)
        } else if bytes[3] == 0x81, let phase = CodexPadPhysicalEvent.Phase(rawValue: bytes[6]) {
            let event = CodexPadPhysicalEvent(sequence: bytes[4], control: bytes[5], phase: phase)
            logger.info("Physical event control=\(event.control, privacy: .public) phase=\(event.phase.rawValue, privacy: .public)")
            events.insert(event, at: 0)
            if events.count > 100 { events.removeLast(events.count - 100) }
            onPhysicalEvent?(event)
        }
    }
}

private let codexPadInputCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
    guard let context else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    Unmanaged<CodexPadEventService>.fromOpaque(context).takeUnretainedValue().consume(bytes)
}
