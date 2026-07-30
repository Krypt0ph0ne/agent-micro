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
    private let logger = Logger(subsystem: "io.github.krypt0ph0ne.agentmicro", category: "pad-events")
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
    /// Rate-limits `reconnectDevice()`: a genuinely absent device (mid USB
    /// replug) would otherwise retrigger a full manager/device teardown and
    /// reopen on every single failed LED write.
    private var lastReconnectAttempt = Date.distantPast
    private static let reconnectCooldownSeconds: TimeInterval = 2

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
        // Physical key edges arrive as their own unsolicited reports, so this
        // poll only refreshes the firmware/pressed-mask fallback. 150 ms keeps
        // the synchronous SetReport off the main thread's hot path.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
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
        firmwareStatus = nil
        lastLoggedPressedMask = nil
        status = "Noch nicht verbunden"
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

        // A failing write on the long-lived connection means more than this
        // one LED batch is broken: `device` also carries every encoder
        // press/release and rotation input report via
        // `IOHIDDeviceRegisterInputReportCallback`, so a silently-dead write
        // path silently kills physical encoder input too. Previously this
        // just fell back to a one-off Raw HID connection for the write,
        // which kept the LEDs animating (masking the problem) while the
        // primary connection stayed dead forever — the Drehrad press/hold
        // gestures then stop working with no visible symptom. Reconnect the
        // primary connection instead so reads recover, not just this write.
        reconnectDeviceIfNeeded()

        if let device, sendLEDs(validPackets, to: device) {
            return
        }

        // Still down right after a reconnect attempt (or cooling down from a
        // recent one): reopen Raw HID for just this batch instead of
        // dropping the visual state transition.
        let fallbackResult = CodexPadHIDClient().send(validPackets)
        if !fallbackResult.succeeded {
            logger.error("LED fallback failed: \(fallbackResult.failureDescription, privacy: .public)")
        } else {
            logger.info("LED batch recovered through a fresh Raw HID connection")
        }
    }

    /// Tears down and reopens the primary manager/device, restoring both the
    /// LED output path and the encoder input-report callback. Rate-limited
    /// so a genuinely absent device doesn't thrash open/close on every write.
    private func reconnectDeviceIfNeeded() {
        guard manager != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReconnectAttempt) > Self.reconnectCooldownSeconds else { return }
        lastReconnectAttempt = now
        logger.error("Primary HID connection unhealthy; reconnecting")
        refresh(enabled: true)
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
            let newStatus = CodexPadFirmwareStatus(
                version: "\(bytes[4]).\(bytes[5]).\(bytes[6])",
                capabilities: bytes[7],
                pressedMask: UInt16(bytes[10]) | UInt16(bytes[11]) << 8
            )
            // The firmware streams status faster than we poll. Identical reports
            // must be dropped here: otherwise the LED pipeline (and every failed
            // LED write, which reopens Raw HID) runs on every frame and pegs the
            // CPU. Only a real change is propagated.
            guard newStatus != firmwareStatus else { return }
            firmwareStatus = newStatus
            status = "Firmware \(newStatus.version) · Protokoll v\(bytes[2])"
            if lastLoggedPressedMask != newStatus.pressedMask {
                lastLoggedPressedMask = newStatus.pressedMask
                logger.info("Pressed mask changed: 0x\(String(newStatus.pressedMask, radix: 16), privacy: .public)")
            }
            onFirmwareStatus?(newStatus)
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
