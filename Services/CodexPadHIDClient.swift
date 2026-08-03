import Foundation
import IOKit.hid

struct CodexPadHIDClient {
    static let vendorID = 0x4249
    static let productID = 0x4287

    func send(_ packets: [[UInt8]]) -> ProcessResult {
        guard packets.allSatisfy({ $0.count == CodexPadPacketEncoder.packetSize }) else {
            return failure(AppLanguage.text(
                "Interner Fehler: HID-Paket ist nicht 32 Byte lang.",
                "Internal error: the HID packet is not 32 bytes long."
            ))
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
            return failure(String(
                format: AppLanguage.text(
                    "Raw-HID-Manager konnte nicht geöffnet werden: 0x%08X",
                    "Could not open the raw HID manager: 0x%08X"
                ),
                managerResult
            ))
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
            return failure(AppLanguage.text(
                "Agent Micro Raw-HID-Interface FF60:0061 wurde nicht gefunden.",
                "The Agent Micro raw HID interface FF60:0061 was not found."
            ))
        }
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            return failure(String(
                format: AppLanguage.text(
                    "Agent Micro Raw-HID konnte nicht geöffnet werden: 0x%08X",
                    "Could not open Agent Micro raw HID: 0x%08X"
                ),
                openResult
            ))
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        for source in packets {
            var packet = source
            let result = packet.withUnsafeMutableBufferPointer { buffer in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, buffer.baseAddress!, buffer.count)
            }
            guard result == kIOReturnSuccess else {
                return failure(String(
                    format: AppLanguage.text(
                        "HID-Ausgabereport fehlgeschlagen: 0x%08X",
                        "HID output report failed: 0x%08X"
                    ),
                    result
                ))
            }
        }
        return ProcessResult(
            exitCode: 0,
            stdout: AppLanguage.text(
                "\(packets.count) Agent-Micro-HID-Paket(e) erfolgreich übertragen.",
                "\(packets.count) Agent Micro HID packet(s) transferred successfully."
            ),
            stderr: "",
            timedOut: false,
            launchError: nil
        )
    }

    private func failure(_ message: String) -> ProcessResult {
        ProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: message)
    }
}
