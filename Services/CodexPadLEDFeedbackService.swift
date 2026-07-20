import Foundation
import OSLog

/// Whole-pad feedback delegates animation timing to the firmware. The device
/// already renders its native pulse effect smoothly; the host only changes
/// the six LED configurations once and later restores the idle state.
@MainActor
final class CodexPadLEDFeedbackService {
    private enum DictationSource { case rawEvent, statusMask, keyboardReport }

    private let logger = Logger(subsystem: "com.codexpad.app", category: "led-feedback")
    private let encoder = CodexPadPacketEncoder()
    private let send: ([[UInt8]]) -> Void
    private var animationTask: Task<Void, Never>?
    private var rawEventHeld = false
    private var statusMaskHeld = false
    private var keyboardReportHeld = false
    private var agentStatuses: [HardwareControl: CodexAgentStatus] = [:]

    private static let pulseDurationMilliseconds = 900

    init(send: @escaping ([[UInt8]]) -> Void) {
        self.send = send
    }

    func handle(_ event: CodexPadPhysicalEvent, profile: MacropadProfile) {
        guard
            let control = HardwareControl(reportedControlIndex: event.control),
            let actionID = profile.action(for: control).codexActionID
        else { return }

        switch actionID {
        case "dictation":
            if event.phase == .pressed {
                setDictationHeld(true, source: .rawEvent)
            } else if event.phase == .released {
                setDictationHeld(false, source: .rawEvent)
            }
        case "send-message":
            guard event.phase == .pressed || event.phase == .triggered else { return }
            showSendPulse()
        default:
            break
        }
    }

    /// Compatibility fallback for firmware builds that expose a useful
    /// pressed mask. The keyboard report remains the semantic source of truth.
    func handle(pressedMask: UInt16, profile: MacropadProfile) {
        let isHeld = HardwareControl.buttons.contains { control in
            profile.action(for: control).codexActionID == "dictation"
                && pressedMask & (UInt16(1) << control.reportedControlIndex) != 0
        }
        setDictationHeld(isHeld, source: .statusMask)
    }

    func handleDictationKeyboardReport(isHeld: Bool) {
        setDictationHeld(isHeld, source: .keyboardReport)
    }

    func showIdleLighting() {
        animationTask?.cancel()
        animationTask = nil
        renderAgentLighting()
    }

    func showAgentStatuses(_ statuses: [HardwareControl: CodexAgentStatus]) {
        agentStatuses = statuses
        guard !isDictationHeld else { return }
        renderAgentLighting()
    }

    private var isDictationHeld: Bool {
        rawEventHeld || statusMaskHeld || keyboardReportHeld
    }

    private func setDictationHeld(_ isHeld: Bool, source: DictationSource) {
        let wasHeld = isDictationHeld
        switch source {
        case .rawEvent: rawEventHeld = isHeld
        case .statusMask: statusMaskHeld = isHeld
        case .keyboardReport: keyboardReportHeld = isHeld
        }
        guard wasHeld != isDictationHeld else { return }
        logger.info("Dictation LED hold changed: \(self.isDictationHeld, privacy: .public)")
        isDictationHeld ? showDictationPulse() : showIdleLighting()
    }

    private func showDictationPulse() {
        animationTask?.cancel()
        logger.info("Starting continuous white host pulse")
        send(encoder.allLEDs(
            effect: .pulse,
            red: 255,
            green: 255,
            blue: 255,
            brightness: 255,
            periodMilliseconds: Self.pulseDurationMilliseconds
        ))
    }

    private func showSendPulse() {
        animationTask?.cancel()
        logger.info("Starting one complete red host pulse")
        send(encoder.allLEDs(
            effect: .pulse,
            red: 255,
            green: 0,
            blue: 0,
            brightness: 255,
            periodMilliseconds: Self.pulseDurationMilliseconds
        ))
        animationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(Self.pulseDurationMilliseconds))
            } catch {
                return
            }
            if self.isDictationHeld {
                self.showDictationPulse()
            } else {
                self.showIdleLighting()
            }
        }
    }

    private func renderAgentLighting() {
        send(HardwareControl.buttons.map { control in
            encoder.ledPacket(setting: StatusMapper.ledConfiguration(
                for: agentStatuses[control] ?? .unassigned,
                control: control
            ))
        })
    }

}
