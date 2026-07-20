import Foundation

struct DeviceDetectionReport: Sendable {
    var device: ConnectedDevice?
    var candidates: [ConnectedDevice]
    var rawIORegistry: String
    var error: String?
}

/// Reads the IORegistry directly rather than treating `system_profiler` as the
/// source of truth.  Some current macOS installations return an empty USB
/// inventory from system_profiler while their HID services remain available.
struct DeviceDetector {
    private let runner: any ProcessRunning

    init(runner: any ProcessRunning = FoundationProcessRunner()) {
        self.runner = runner
    }

    func detect() -> DeviceDetectionReport {
        let result = runner.run(ProcessInvocation(
            executablePath: "/usr/sbin/ioreg",
            arguments: ["-p", "IOUSB", "-l", "-w0"],
            timeout: 8
        ))
        guard result.succeeded else {
            return DeviceDetectionReport(device: nil, candidates: [], rawIORegistry: result.stdout, error: result.failureDescription)
        }

        let candidates = parseDevices(from: result.stdout)
        let supported = candidates.first(where: { $0.support == .supported })
        if let supported {
            return DeviceDetectionReport(device: supported, candidates: candidates, rawIORegistry: result.stdout, error: nil)
        }
        if let related = candidates.first(where: { $0.support == .related }) {
            return DeviceDetectionReport(device: related, candidates: candidates, rawIORegistry: result.stdout, error: nil)
        }

        let summary = candidates.map { "\($0.vendorIDHex):\($0.productIDHex)" }.joined(separator: ", ")
        return DeviceDetectionReport(
            device: nil,
            candidates: candidates,
            rawIORegistry: result.stdout,
            error: "Kein unterstütztes CodexPad gefunden. Sichtbare USB-Kennungen: \(summary.isEmpty ? "keine" : summary)."
        )
    }

    private func parseDevices(from text: String) -> [ConnectedDevice] {
        let sections = deviceSections(in: text)
        var seen = Set<String>()
        return sections.compactMap { section in
            guard let vendorID = integer(named: "idVendor", in: section), let productID = integer(named: "idProduct", in: section) else { return nil }
            let locationID = string(named: "locationID", in: section) ?? "unbekannt"
            let identity = "\(vendorID)-\(productID)-\(locationID)"
            guard seen.insert(identity).inserted else { return nil }
            return makeDevice(vendorID: vendorID, productID: productID, locationID: locationID, section: section)
        }
    }

    /// Each USB-device property dictionary follows a distinct IOUSBHostDevice
    /// line.  Limiting the section at the next device header avoids accidentally
    /// pairing an interface's properties with its parent device.
    private func deviceSections(in text: String) -> [String] {
        let pattern = "(?m)^.*<class IOUSBHostDevice[^\\n]*$"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else { return [text] }
        return matches.enumerated().compactMap { index, match in
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : (text as NSString).length
            guard let swiftRange = Range(NSRange(location: start, length: end - start), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func makeDevice(vendorID: Int, productID: Int, locationID: String, section: String) -> ConnectedDevice {
        let support: ConnectedDevice.Support
        let capabilities: DeviceCapabilities
        let summary: String
        if vendorID == 0x4249 && productID == 0x4287 {
            support = .supported
            capabilities = .codexPadCH552
            summary = "Eigene CH552-CodexPad-Firmware erkannt. Sechs Tasten, Encoder und sechs einzeln steuerbare RGB-LEDs sind firmwarebestätigt."
        } else if vendorID == 0x1189 && productID == 0x8890 {
            support = .supported
            capabilities = .ch57x8890
            summary = "CH57x-2 erkannt. Das Boot-HID-Keyboard und das separate Konfigurationsinterface werden vom MIT-Helper für 0x1189:0x8890 unterstützt."
        } else if vendorID == 0x1189 && [0x8840, 0x8842].contains(productID) {
            support = .related
            capabilities = .unsupported
            summary = "CH57x-Variante erkannt. Der gebündelte Helper kennt diese Kennung, CodexPad verifiziert Uploads jedoch derzeit nur für das getestete 3×2-Modell 0x8890."
        } else if vendorID == 0x1189 {
            support = .related
            capabilities = .unsupported
            summary = "CH57x-verwandtes USB-Gerät erkannt, aber seine Protokollvariante ist nicht verifiziert. Diagnose kann die Kennung auswählen; Upload bleibt gesperrt."
        } else {
            support = .unsupported
            capabilities = .unsupported
            summary = "Nicht als CH57x erkannt."
        }

        return ConnectedDevice(
            name: string(named: "USB Product Name", in: section) ?? string(named: "kUSBProductString", in: section) ?? ([0x1189, 0x4249].contains(vendorID) ? "CodexPad" : "USB-Gerät"),
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            manufacturer: string(named: "USB Vendor Name", in: section) ?? string(named: "kUSBVendorString", in: section),
            productName: string(named: "USB Product Name", in: section) ?? string(named: "kUSBProductString", in: section),
            serialNumber: string(named: "USB Serial Number", in: section) ?? string(named: "kUSBSerialNumberString", in: section),
            interfaces: interfaces(in: section),
            hidCollections: hidCollections(in: section),
            support: support,
            capabilities: capabilities,
            diagnosticSummary: summary
        )
    }

    private func interfaces(in section: String) -> [USBInterface] {
        // Interfaces live under the device entry in the IOUSB plane.  The
        // matching fields may be missing on restricted systems, so an empty
        // array is a diagnostic fact rather than a negative device result.
        let chunks = section.components(separatedBy: "IOUSBHostInterface")
        return chunks.dropFirst().compactMap { chunk in
            guard
                let number = integer(named: "bInterfaceNumber", in: chunk),
                let interfaceClass = integer(named: "bInterfaceClass", in: chunk),
                let subclass = integer(named: "bInterfaceSubClass", in: chunk),
                let protocolCode = integer(named: "bInterfaceProtocol", in: chunk)
            else { return nil }
            return USBInterface(number: number, interfaceClass: interfaceClass, subclass: subclass, protocolCode: protocolCode, endpoints: integer(named: "bNumEndpoints", in: chunk) ?? 0)
        }
    }

    private func hidCollections(in section: String) -> [HIDCollection] {
        let keyboardOccurrences = occurrences(of: "\"PrimaryUsagePage\" = 1", in: section)
        return keyboardOccurrences.enumerated().compactMap { index, offset in
            let suffix = String(section.suffix(from: offset))
            guard let usage = integer(named: "PrimaryUsage", in: suffix) else { return nil }
            return HIDCollection(usagePage: 1, usage: usage, ordinal: index)
        }
    }

    private func occurrences(of needle: String, in text: String) -> [String.Index] {
        var result: [String.Index] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, options: [], range: searchRange) {
            result.append(range.lowerBound)
            searchRange = range.upperBound..<text.endIndex
        }
        return result
    }

    private func integer(named name: String, in text: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\\"\(escaped)\\\"\\s*=\\s*(0x[0-9A-Fa-f]+|[0-9]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range), let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[valueRange])
        return value.lowercased().hasPrefix("0x") ? Int(value.dropFirst(2), radix: 16) : Int(value)
    }

    private func string(named name: String, in text: String) -> String? {
        let pattern = "\\\"\(NSRegularExpression.escapedPattern(for: name))\\\"\\s*=\\s*\\\"([^\\\"]+)\\\""
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range), let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }
}
