import Foundation
import IOKit.hid
import Observation

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

@Observable
final class CodexPadEventService {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private(set) var firmwareStatus: CodexPadFirmwareStatus?
    private(set) var events: [CodexPadPhysicalEvent] = []
    private(set) var status = "Noch nicht verbunden"

    deinit { reportBuffer?.deallocate() }

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
    }

    func stop() {
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

    fileprivate func consume(_ bytes: [UInt8]) {
        guard bytes.count == 32, bytes[0] == 0x43, bytes[1] == 0x50,
              bytes[0..<31].reduce(0, ^) == bytes[31] else { return }
        if bytes[3] == 0x80 {
            firmwareStatus = .init(version: "\(bytes[4]).\(bytes[5]).\(bytes[6])", capabilities: bytes[7], pressedMask: UInt16(bytes[10]) | UInt16(bytes[11]) << 8)
            status = "Firmware \(firmwareStatus!.version) · Protokoll v\(bytes[2])"
        } else if bytes[3] == 0x81, let phase = CodexPadPhysicalEvent.Phase(rawValue: bytes[6]) {
            events.insert(.init(sequence: bytes[4], control: bytes[5], phase: phase), at: 0)
            if events.count > 100 { events.removeLast(events.count - 100) }
        }
    }
}

private let codexPadInputCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
    guard let context else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    Unmanaged<CodexPadEventService>.fromOpaque(context).takeUnretainedValue().consume(bytes)
}
