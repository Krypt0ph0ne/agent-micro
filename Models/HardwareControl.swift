import Foundation

enum HardwareControl: String, CaseIterable, Codable, Identifiable, Hashable {
    case key1, key2, key3, key4, key5, key6
    case encoderLeft, encoderPress, encoderRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .key1: "Taste 1"
        case .key2: "Taste 2"
        case .key3: "Taste 3"
        case .key4: "Taste 4"
        case .key5: "Taste 5"
        case .key6: "Taste 6"
        case .encoderLeft: "Encoder links"
        case .encoderPress: "Encoder drücken"
        case .encoderRight: "Encoder rechts"
        }
    }

    var icon: String {
        switch self {
        case .key1, .key2, .key3, .key4, .key5, .key6: "keyboard"
        case .encoderLeft: "rotate.left"
        case .encoderPress: "button.programmable"
        case .encoderRight: "rotate.right"
        }
    }

    var keyPosition: (row: Int, column: Int)? {
        switch self {
        case .key1: (0, 0)
        case .key2: (0, 1)
        case .key3: (0, 2)
        case .key4: (1, 0)
        case .key5: (1, 1)
        case .key6: (1, 2)
        default: nil
        }
    }

    static var buttons: [HardwareControl] { [.key1, .key2, .key3, .key4, .key5, .key6] }
    static var encoderActions: [HardwareControl] { [.encoderLeft, .encoderPress, .encoderRight] }
}
