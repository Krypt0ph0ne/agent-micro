import Foundation

enum HardwareControl: String, CaseIterable, Codable, Identifiable, Hashable {
    case key1, key2, key3, key4, key5, key6
    case encoderLeft, encoderPress, encoderRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .key1: AppLanguage.text("Taste 1", "Key 1")
        case .key2: AppLanguage.text("Taste 2", "Key 2")
        case .key3: AppLanguage.text("Taste 3", "Key 3")
        case .key4: AppLanguage.text("Taste 4", "Key 4")
        case .key5: AppLanguage.text("Taste 5", "Key 5")
        case .key6: AppLanguage.text("Taste 6", "Key 6")
        case .encoderLeft: AppLanguage.text("Encoder links", "Dial left")
        case .encoderPress: AppLanguage.text("Encoder drücken", "Press dial")
        case .encoderRight: AppLanguage.text("Encoder rechts", "Dial right")
        }
    }

    var shortTitle: String {
        switch self {
        case .encoderLeft: AppLanguage.text("Links drehen", "Turn left")
        case .encoderPress: AppLanguage.text("Drehrad drücken", "Press dial")
        case .encoderRight: AppLanguage.text("Rechts drehen", "Turn right")
        default: title
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

    /// Configuration packets use the PCB order, which is mirrored
    /// horizontally from the order shown in the app for the six keys.
    init?(firmwareControlIndex: UInt8) {
        switch firmwareControlIndex {
        case 0: self = .key3
        case 1: self = .key2
        case 2: self = .key1
        case 3: self = .key6
        case 4: self = .key5
        case 5: self = .key4
        case 6: self = .encoderLeft
        case 7: self = .encoderPress
        case 8: self = .encoderRight
        default: return nil
        }
    }

    var firmwareControlIndex: UInt8 {
        switch self {
        case .key1: 2
        case .key2: 1
        case .key3: 0
        case .key4: 5
        case .key5: 4
        case .key6: 3
        case .encoderLeft: 6
        case .encoderPress: 7
        case .encoderRight: 8
        }
    }

    /// Firmware v2 input events and the pressed mask use the visible logical
    /// order (Key 1...6), not the mirrored configuration-packet order.
    init?(reportedControlIndex: UInt8) {
        guard let control = HardwareControl.allCases.first(where: { $0.reportedControlIndex == reportedControlIndex }) else {
            return nil
        }
        self = control
    }

    var reportedControlIndex: UInt8 {
        switch self {
        case .key1: 0
        case .key2: 1
        case .key3: 2
        case .key4: 3
        case .key5: 4
        case .key6: 5
        case .encoderLeft: 6
        case .encoderPress: 7
        case .encoderRight: 8
        }
    }
}
