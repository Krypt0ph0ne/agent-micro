import Foundation
import IOKit.hid

final class HIDProbe {
    private var manager: IOHIDManager?

    func run(seconds: TimeInterval) -> Int32 {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboardIdentity: (Int, Int) -> [String: Any] = { vendorID, productID in
            [
                kIOHIDVendorIDKey as String: vendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDPrimaryUsagePageKey as String: 0x01,
                kIOHIDPrimaryUsageKey as String: 0x06
            ]
        }
        let matching = [keyboardIdentity(0x1189, 0x8890), keyboardIdentity(0x4249, 0x4287)]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, Self.callback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            fputs("Could not open CH57x HID keyboard (IOReturn \(result)).\n", stderr)
            return 2
        }

        self.manager = manager
        print("Monitoring Agent Micro keyboard HID for \(Int(seconds)) seconds. Press pad keys and turn/press the encoder now.")
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        return 0
    }

    private func record(usagePage: Int, usage: Int, value: Int) {
        guard usagePage == 0x07, (0...0xFF).contains(usage), value != 0 else { return }
        let name: String
        if (0x3A...0x45).contains(usage) {
            name = "F\(usage - 0x3A + 1)"
        } else if (0x68...0x73).contains(usage) {
            name = "F\(usage - 0x68 + 13)"
        } else {
            name = String(format: "Usage 0x%02X", usage)
        }
        print(String(format: "HID key down: %@ (page 0x%02X, usage 0x%02X, value %d)", name, usagePage, usage, value))
        fflush(stdout)
    }

    private static let callback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let element = IOHIDValueGetElement(value)
        let elementUsage = Int(IOHIDElementGetUsage(element))
        let integerValue = Int(IOHIDValueGetIntegerValue(value))
        let normalized: (usage: Int, value: Int)?
        if (0...0xFF).contains(elementUsage) {
            normalized = (elementUsage, integerValue)
        } else if (1...0xFF).contains(integerValue) {
            normalized = (integerValue, 1)
        } else {
            normalized = nil
        }
        guard let normalized else { return }
        let probe = Unmanaged<HIDProbe>.fromOpaque(context).takeUnretainedValue()
        probe.record(
            usagePage: Int(IOHIDElementGetUsagePage(element)),
            usage: normalized.usage,
            value: normalized.value
        )
    }
}

let argument = CommandLine.arguments.dropFirst().first
let seconds = argument.flatMap(TimeInterval.init) ?? 30
exit(HIDProbe().run(seconds: min(max(seconds, 1), 120)))
