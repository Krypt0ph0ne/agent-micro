import Carbon
import Foundation

enum KeyboardLayout: String, CaseIterable, Codable, Identifiable {
    case automatic
    case germanISO
    case usANSI
    case britishISO

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatisch"
        case .germanISO: "Deutsch ISO"
        case .usANSI: "English US"
        case .britishISO: "English UK"
        }
    }

    var resolved: KeyboardLayout {
        self == .automatic ? Self.detected : self
    }

    var detail: String {
        self == .automatic ? "Automatisch · \(resolved.title)" : title
    }

    static var detected: KeyboardLayout {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return .usANSI
        }
        let identifier = unsafeBitCast(property, to: CFString.self) as String
        let normalized = identifier.lowercased()
        if normalized.contains("german") || normalized.hasSuffix(".de") { return .germanISO }
        if normalized.contains("british") || normalized.contains("uk") { return .britishISO }
        return .usANSI
    }
}
