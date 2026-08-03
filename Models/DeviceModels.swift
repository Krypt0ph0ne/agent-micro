import Foundation

struct DeviceCapabilities: Codable, Hashable {
    var keyCount: Int
    var encoderCount: Int
    var encoderActionsPerEncoder: Int
    var supportsDirectKeyboard: Bool
    var supportsSequences: Bool
    var supportsMedia: Bool
    var supportsMouse: Bool
    var supportsGlobalLEDMode: Bool
    var supportedLEDModes: [Int]
    var supportsPerKeyLED: Bool

    static let unsupported = DeviceCapabilities(
        keyCount: 0, encoderCount: 0, encoderActionsPerEncoder: 0,
        supportsDirectKeyboard: false, supportsSequences: false, supportsMedia: false, supportsMouse: false,
        supportsGlobalLEDMode: false, supportedLEDModes: [], supportsPerKeyLED: false
    )

    /// The native configurator and the WebHID reference implementation both
    /// confirm these three global patterns for 1189:8890. Their colors are
    /// firmware-defined and must be identified on the physical pad.
    static let ch57x8890 = DeviceCapabilities(
        keyCount: 6, encoderCount: 1, encoderActionsPerEncoder: 3,
        supportsDirectKeyboard: true, supportsSequences: true, supportsMedia: true, supportsMouse: true,
        supportsGlobalLEDMode: true, supportedLEDModes: [0, 1, 2], supportsPerKeyLED: false
    )

    static let codexPadCH552 = DeviceCapabilities(
        keyCount: 6, encoderCount: 1, encoderActionsPerEncoder: 3,
        supportsDirectKeyboard: true, supportsSequences: true, supportsMedia: true, supportsMouse: false,
        supportsGlobalLEDMode: false, supportedLEDModes: [], supportsPerKeyLED: true
    )
}

struct ConnectedDevice: Identifiable, Hashable {
    enum Support: String, Hashable {
        case supported, related, unsupported
    }

    var id: String { "\(vendorID)-\(productID)-\(locationID)" }
    var name: String
    var vendorID: Int
    var productID: Int
    var locationID: String
    var manufacturer: String?
    var productName: String?
    var serialNumber: String?
    var interfaces: [USBInterface]
    var hidCollections: [HIDCollection]
    var support: Support
    var capabilities: DeviceCapabilities
    var diagnosticSummary: String

    var vendorIDHex: String { String(format: "0x%04X", vendorID) }
    var productIDHex: String { String(format: "0x%04X", productID) }
    var isCodexPadFirmware: Bool { vendorID == 0x4249 && productID == 0x4287 }
}

struct USBInterface: Codable, Hashable, Identifiable {
    var id: String { "\(number)-\(interfaceClass)-\(subclass)-\(protocolCode)" }
    var number: Int
    var interfaceClass: Int
    var subclass: Int
    var protocolCode: Int
    var endpoints: Int

    var summary: String {
        AppLanguage.text(
            "Interface \(number) · Klasse \(interfaceClass)/\(subclass)/\(protocolCode) · \(endpoints) Endpoint\(endpoints == 1 ? "" : "s")",
            "Interface \(number) · class \(interfaceClass)/\(subclass)/\(protocolCode) · \(endpoints) endpoint\(endpoints == 1 ? "" : "s")"
        )
    }
}

struct HIDCollection: Codable, Hashable, Identifiable {
    var id: String { "\(usagePage)-\(usage)-\(ordinal)" }
    var usagePage: Int
    var usage: Int
    var ordinal: Int

    var summary: String {
        let label: String
        switch (usagePage, usage) {
        case (1, 6): label = "Keyboard"
        case (1, 2): label = "Mouse"
        default: label = "HID"
        }
        return "\(label) · Usage Page \(usagePage) · Usage \(usage)"
    }
}

enum DeviceConnectionState: Equatable {
    case scanning
    case disconnected
    case connected(ConnectedDevice)
    case unsupported(ConnectedDevice)
    case error(String)

    var isSupportedConnection: Bool {
        if case .connected = self { return true }
        return false
    }
}
