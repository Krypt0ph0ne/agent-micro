import Foundation
import IOKit.hid

struct CodexPadHIDClient {
    static let vendorID = 0x4249
    static let productID = 0x4287

    func send(_ packets: [[UInt8]]) -> ProcessResult {
        guard packets.allSatisfy({ $0.count == CodexPadPacketEncoder.packetSize }) else {
            return failure("Interner Fehler: HID-Paket ist nicht 32 Byte lang.")
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: 0xFF60,
            kIOHIDPrimaryUsageKey as String: 0x61
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard managerResult == kIOReturnSuccess else {
            return failure(String(format: "Raw-HID-Manager konnte nicht geöffnet werden: 0x%08X", managerResult))
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
            return failure("Agent Micro Raw-HID-Interface FF60:0061 wurde nicht gefunden.")
        }
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            return failure(String(format: "Agent Micro Raw-HID konnte nicht geöffnet werden: 0x%08X", openResult))
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        for source in packets {
            var packet = source
            let result = packet.withUnsafeMutableBufferPointer { buffer in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, buffer.baseAddress!, buffer.count)
            }
            guard result == kIOReturnSuccess else {
                return failure(String(format: "HID-Ausgabereport fehlgeschlagen: 0x%08X", result))
            }
        }
        return ProcessResult(
            exitCode: 0,
            stdout: "\(packets.count) Agent-Micro-HID-Paket(e) erfolgreich übertragen.",
            stderr: "",
            timedOut: false,
            launchError: nil
        )
    }

    private func failure(_ message: String) -> ProcessResult {
        ProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: message)
    }
}
