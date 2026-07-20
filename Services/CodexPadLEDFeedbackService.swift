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
    private var activeProfile: MacropadProfile?
    private var statusFlashTasks: [HardwareControl: Task<Void, Never>] = [:]
    /// When set (persistent layer mode), the whole-pad idle base uses this
    /// layer colour so the active harness stays visible behind agent statuses.
    private var persistentLayerColor: (color: RGBColor, brightness: UInt8)?

    init(send: @escaping ([[UInt8]]) -> Void) {
        self.send = send
    }

    func handle(_ event: CodexPadPhysicalEvent, profile: MacropadProfile) {
        activeProfile = profile
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
            showMomentaryReaction(.messageSent, profile: profile)
        default:
            break
        }
    }

    /// Compatibility fallback for firmware builds that expose a useful
    /// pressed mask. The keyboard report remains the semantic source of truth.
    func handle(pressedMask: UInt16, profile: MacropadProfile) {
        activeProfile = profile
        let isHeld = HardwareControl.buttons.contains { control in
            profile.action(for: control).codexActionID == "dictation"
                && pressedMask & (UInt16(1) << control.reportedControlIndex) != 0
        }
        setDictationHeld(isHeld, source: .statusMask)
    }

    func handleDictationKeyboardReport(isHeld: Bool, profile: MacropadProfile) {
        activeProfile = profile
        setDictationHeld(isHeld, source: .keyboardReport)
    }

    func showIdleLighting() {
        animationTask?.cancel()
        animationTask = nil
        renderAgentLighting(previousStatuses: agentStatuses)
    }

    /// Whole-pad cue after a harness layer switch. Pulses all six LEDs in the
    /// configured layer colour and brightness once and then either restores idle
    /// (pulseOnce) or keeps the colour as the idle base (persistent).
    func indicateLayerSwitch(color: RGBColor, brightness: UInt8, mode: LayerSwitchLightMode, profile: MacropadProfile) {
        activeProfile = profile
        animationTask?.cancel()
        let period = 700
        send(encoder.allLEDs(effect: .pulse, red: color.red, green: color.green, blue: color.blue, brightness: brightness, periodMilliseconds: period))
        persistentLayerColor = mode == .persistent ? (color, brightness) : nil
        animationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(period))
            } catch {
                return
            }
            guard let self else { return }
            if self.isDictationHeld {
                self.showDictationReaction()
            } else {
                self.renderAgentLighting(previousStatuses: self.agentStatuses)
            }
        }
    }

    /// The idle appearance for a control, honouring a persistent layer colour.
    private func idleConfiguration(for control: HardwareControl, profile: MacropadProfile) -> KeyLEDConfiguration {
        if let layer = persistentLayerColor {
            return KeyLEDConfiguration(control: control, effect: .steady, red: layer.color.red, green: layer.color.green, blue: layer.color.blue, brightness: layer.brightness, periodMilliseconds: 1_000)
        }
        return profile.idleLighting.keyConfiguration(for: control)
    }

    func showAgentStatuses(_ statuses: [HardwareControl: CodexAgentStatus], profile: MacropadProfile) {
        let previous = agentStatuses
        agentStatuses = statuses
        activeProfile = profile
        guard !isDictationHeld else { return }
        renderAgentLighting(previousStatuses: previous)
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
        isDictationHeld ? showDictationReaction() : showIdleLighting()
    }

    private func showDictationReaction() {
        guard let profile = activeProfile else { return }
        let reaction = profile.reaction(for: .dictation)
        guard reaction.effect != .off else {
            renderAgentLighting(previousStatuses: agentStatuses)
            return
        }
        animationTask?.cancel()
        logger.info("Starting configured dictation reaction")
        send(encoder.allLEDs(
            effect: reaction.effect.firmwareEffect,
            red: reaction.red,
            green: reaction.green,
            blue: reaction.blue,
            brightness: reaction.brightness,
            periodMilliseconds: reaction.periodMilliseconds
        ))
    }

    private func showMomentaryReaction(_ event: LEDReactionEvent, profile: MacropadProfile) {
        activeProfile = profile
        let reaction = profile.reaction(for: event)
        guard reaction.effect != .off else { return }
        animationTask?.cancel()
        logger.info("Starting momentary reaction: \(event.rawValue, privacy: .public)")
        send(encoder.allLEDs(
            effect: reaction.effect.firmwareEffect,
            red: reaction.red,
            green: reaction.green,
            blue: reaction.blue,
            brightness: reaction.brightness,
            periodMilliseconds: reaction.periodMilliseconds
        ))
        animationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(max(200, reaction.periodMilliseconds)))
            } catch {
                return
            }
            if self.isDictationHeld {
                self.showDictationReaction()
            } else {
                self.showIdleLighting()
            }
        }
    }

    private func renderAgentLighting(previousStatuses: [HardwareControl: CodexAgentStatus] = [:]) {
        guard let profile = activeProfile else { return }
        let suppressIdle = agentStatuses.values.contains { status in
            guard let event = LEDReactionEvent.event(for: status) else { return false }
            let reaction = profile.reaction(for: event)
            // A one-shot flash is no longer active after its timer fires. It
            // must restore idle even while the thread remains completed.
            return reaction.effect != .off && reaction.effect != .flash && reaction.disablesIdle
        }
        let settings = HardwareControl.buttons.map { control -> KeyLEDConfiguration in
            let status = agentStatuses[control] ?? .unassigned
            let idleSetting = suppressIdle
                ? KeyLEDConfiguration(control: control, effect: .off, red: 0, green: 0, blue: 0, brightness: 0, periodMilliseconds: 1_000)
                : idleConfiguration(for: control, profile: profile)
            guard let event = LEDReactionEvent.event(for: status) else {
                statusFlashTasks[control]?.cancel()
                statusFlashTasks[control] = nil
                return idleSetting
            }
            let reaction = profile.reaction(for: event)
            guard reaction.effect != .off else { return idleSetting }
            guard reaction.effect == .flash else {
                statusFlashTasks[control]?.cancel()
                statusFlashTasks[control] = nil
                return reaction.keyConfiguration(for: control)
            }
            guard previousStatuses[control] != status else {
                return idleSetting
            }
            scheduleStatusFlashRestore(control: control, status: status, delay: reaction.periodMilliseconds)
            return reaction.keyConfiguration(for: control)
        }
        send(settings.map(encoder.ledPacket))
    }

    private func scheduleStatusFlashRestore(
        control: HardwareControl,
        status: CodexAgentStatus,
        delay: Int
    ) {
        statusFlashTasks[control]?.cancel()
        statusFlashTasks[control] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(max(200, delay)))
            } catch {
                return
            }
            guard let self, !self.isDictationHeld, self.agentStatuses[control] == status else { return }
            self.statusFlashTasks[control] = nil
            self.renderAgentLighting(previousStatuses: self.agentStatuses)
        }
    }

}
