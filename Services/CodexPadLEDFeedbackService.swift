import Foundation
import OSLog

/// Whole-pad feedback mostly delegates animation timing to the firmware: the
/// device renders its native pulse effect smoothly, and the host only
/// changes the six LED configurations once and later restores the idle
/// state. The one exception is a range-limited pulse (`isRangePulse`), which
/// the CH552 firmware cannot do on its own — that one is driven by a
/// lightweight host timer in `updateRangePulseAnimation`.
@MainActor
final class CodexPadLEDFeedbackService {
    private enum DictationSource { case rawEvent, statusMask, keyboardReport }

    /// 50 Hz keeps the steps below the eye's flicker threshold for a
    /// breathing effect while staying cheap: at most a few dozen short HID
    /// writes per second (one per animated key), nothing like the busy-loop
    /// CPU issue fixed for app-server output parsing.
    private static let rangePulseTickMilliseconds = 20

    private let logger = Logger(subsystem: "com.codexpad.app", category: "led-feedback")
    private let encoder = CodexPadPacketEncoder()
    private let send: ([[UInt8]]) -> Void
    private var animationTask: Task<Void, Never>?
    private var rangePulseTask: Task<Void, Never>?
    private var rawEventHeld = false
    private var statusMaskHeld = false
    private var keyboardReportHeld = false
    private var agentStatuses: [HardwareControl: CodexAgentStatus] = [:]
    private var activeProfile: MacropadProfile?
    private var statusFlashTasks: [HardwareControl: Task<Void, Never>] = [:]

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
        sendWholePad(reaction.keyConfiguration)
    }

    private func showMomentaryReaction(_ event: LEDReactionEvent, profile: MacropadProfile) {
        activeProfile = profile
        let reaction = profile.reaction(for: event)
        guard reaction.effect != .off else { return }
        animationTask?.cancel()
        logger.info("Starting momentary reaction: \(event.rawValue, privacy: .public)")
        sendWholePad(reaction.keyConfiguration)
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
            let idleSetting = baseSetting(for: control, profile: profile, suppressed: suppressIdle)
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
        sendMixed(settings)
    }

    /// Sends the same configuration to all six keys, routing it through the
    /// range-pulse animator when it needs a host-managed brightness floor.
    private func sendWholePad(_ keyConfiguration: (HardwareControl) -> KeyLEDConfiguration) {
        sendMixed(HardwareControl.buttons.map(keyConfiguration))
    }

    /// Sends a batch of per-key settings, splitting off any that need a
    /// host-animated range pulse so the rest still take the cheap,
    /// fire-and-forget firmware-native path.
    private func sendMixed(_ settings: [KeyLEDConfiguration]) {
        let staticSettings = settings.filter { !$0.isRangePulse }
        let animatedSettings = settings.filter(\.isRangePulse)
        if !staticSettings.isEmpty {
            send(staticSettings.map(encoder.ledPacket))
        }
        updateRangePulseAnimation(animatedSettings)
    }

    /// Starts (or stops) the host-driven breathing loop for keys whose pulse
    /// has a floor above zero. Always cancels any previous animation first,
    /// so this is the single choke point that keeps `rangePulseTask` in sync
    /// with whatever base/reaction layer is currently active.
    private func updateRangePulseAnimation(_ settings: [KeyLEDConfiguration]) {
        rangePulseTask?.cancel()
        guard !settings.isEmpty else {
            rangePulseTask = nil
            return
        }
        logger.info("Starting range-pulse animation for \(settings.count, privacy: .public) key(s)")
        rangePulseTask = Task { [weak self] in
            // Track true elapsed time rather than accumulating fixed tick
            // steps: a scheduling hiccup would otherwise desync the phase
            // from wall-clock time and read as a stutter on every later tick.
            let startNanoseconds = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                guard let self else { return }
                let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startNanoseconds) / 1_000_000
                let frames = settings.map { self.breathingFrame(of: $0, elapsedMilliseconds: elapsedMilliseconds) }
                self.send(frames.map(self.encoder.ledPacket))
                do {
                    try await Task.sleep(for: .milliseconds(Self.rangePulseTickMilliseconds))
                } catch {
                    return
                }
            }
        }
    }

    /// Computes one animation frame for a range-pulse key: a raised-cosine
    /// ("smoothstep") wave between `minBrightness` and `brightness` that
    /// completes one full up-and-down cycle every `periodMilliseconds`, sent
    /// to the firmware as a plain steady colour so no unsupported effect byte
    /// ever reaches it. The cosine easing eases in and out of each peak/
    /// trough instead of moving at a constant linear rate, which is what
    /// reads as a smooth "breathing" motion instead of a visible ramp.
    private func breathingFrame(of setting: KeyLEDConfiguration, elapsedMilliseconds: Double) -> KeyLEDConfiguration {
        let period = Double(max(200, setting.periodMilliseconds))
        let position = elapsedMilliseconds.truncatingRemainder(dividingBy: period) / period
        let eased = (1 - cos(position * 2 * .pi)) / 2
        let low = Double(setting.minBrightness)
        let high = Double(setting.brightness)
        var frame = setting
        frame.effect = .steady
        frame.brightness = UInt8(clamping: Int((low + (high - low) * eased).rounded()))
        return frame
    }

    /// Resolves the resting ("Grundlicht") appearance for a single key,
    /// honouring the per-key vs. single-colour base mode and agent-status
    /// idle suppression.
    private func baseSetting(
        for control: HardwareControl,
        profile: MacropadProfile,
        suppressed: Bool
    ) -> KeyLEDConfiguration {
        guard !suppressed else {
            return KeyLEDConfiguration(control: control, effect: .off, red: 0, green: 0, blue: 0, brightness: 0, periodMilliseconds: 1_000)
        }
        return profile.baseLighting(for: control)
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
