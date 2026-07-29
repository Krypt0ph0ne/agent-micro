import Foundation
import OSLog

/// Native pulses are handed to the firmware, which renders them smoothly
/// without continuous USB traffic. Only pulses with a non-zero brightness
/// floor need host frames because the firmware cannot represent that range.
/// Those exceptional animations are generation-protected so a stale idle
/// frame can never overwrite a newer agent state.
@MainActor
final class CodexPadLEDFeedbackService {
    private enum DictationSource { case rawEvent, statusMask, keyboardReport }

    /// Raised-cosine breathing is smooth at roughly 30 Hz while leaving
    /// substantially more bandwidth for status polling and physical events.
    private static let rangePulseTickMilliseconds = 33

    private let logger = Logger(subsystem: "com.codexpad.app", category: "led-feedback")
    private let encoder = CodexPadPacketEncoder()
    private let send: ([[UInt8]]) -> Void
    private var animationTask: Task<Void, Never>?
    private var pulseAnimationTask: Task<Void, Never>?
    /// Invalidates an already-cancelled task before it can emit a late frame.
    /// Task cancellation alone is cooperative, so the generation check is the
    /// hard guarantee that only the newest render may write pulse packets.
    private var pulseGeneration: UInt64 = 0
    private var rawEventHeld = false
    private var statusMaskHeld = false
    private var keyboardReportHeld = false
    private var pickerSelectionActive = false
    private var agentStatuses: [HardwareControl: CodexAgentStatus] = [:]
    private var activeProfile: MacropadProfile?

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

    func showThreadAssignedReaction(profile: MacropadProfile) {
        showMomentaryReaction(.threadAssigned, profile: profile)
    }

    /// The picker owns the whole pad until the held agent key is released.
    /// It reuses the configurable assignment colour while forcing the
    /// interaction-specific pulse requested by the hardware gesture.
    func beginThreadPickerSelection(profile: MacropadProfile) {
        activeProfile = profile
        pickerSelectionActive = true
        beginExclusiveTimeline()
        let reaction = profile.reaction(for: .threadAssigned)
        sendWholePad { control in
            KeyLEDConfiguration(
                control: control,
                effect: .pulse,
                red: reaction.red,
                green: reaction.green,
                blue: reaction.blue,
                brightness: reaction.brightness,
                periodMilliseconds: max(200, reaction.periodMilliseconds),
                minBrightness: reaction.minBrightness
            )
        }
    }

    func finishThreadPickerSelection(profile: MacropadProfile, confirmed: Bool) {
        activeProfile = profile
        pickerSelectionActive = false
        beginExclusiveTimeline()
        guard confirmed else {
            showIdleLighting()
            return
        }
        let reaction = profile.reaction(for: .threadAssigned)
        let duration = max(120, reaction.periodMilliseconds)
        sendWholePad { control in
            KeyLEDConfiguration(
                control: control,
                effect: .steady,
                red: reaction.red,
                green: reaction.green,
                blue: reaction.blue,
                brightness: reaction.brightness,
                periodMilliseconds: duration
            )
        }
        animationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(duration)) } catch { return }
            self?.finishExclusiveTimeline()
        }
    }

    /// One-shot green/red reaction fired the moment an approval is answered.
    func showApprovalResolvedReaction(decision: ApprovalDecision, profile: MacropadProfile) {
        showMomentaryReaction(decision == .accept ? .approvalAccepted : .approvalDeclined, profile: profile)
    }

    /// Plays an event's current configuration across the pad, then restores
    /// the regular lighting. This is intentionally independent of the live
    /// event sources so testing a reaction never changes an agent's status.
    func previewReaction(_ event: LEDReactionEvent, profile: MacropadProfile) {
        showMomentaryReaction(event, profile: profile)
    }

    func showIdleLighting() {
        animationTask?.cancel()
        animationTask = nil
        renderAgentLighting()
    }

    /// A brief all-keys white flash confirming the layer-switch hold gesture
    /// fired — not a per-profile configurable reaction, just a system blip.
    func flashLayerSwitchConfirmation(profile: MacropadProfile) {
        activeProfile = profile
        beginExclusiveTimeline()
        logger.info("Layer switch confirmation flash")
        let flashDurationMilliseconds = 350
        sendWholePad { control in
            KeyLEDConfiguration(control: control, effect: .steady, red: 255, green: 255, blue: 255, brightness: 255, periodMilliseconds: flashDurationMilliseconds)
        }
        animationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(flashDurationMilliseconds))
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

    /// Confirms which layer just became active after a `.layerSwitch` action
    /// fires: the whole pad blinks `count` times in the layer's own color,
    /// then restores whatever was showing before. Distinct from
    /// `flashLayerSwitchConfirmation` (the fixed white blip for the Codex⇄
    /// Claude hold gesture) since each layer picks its own color/count.
    ///
    /// Runs as one exclusive host-owned timeline.  Nothing else writes LEDs
    /// between flashes; the pad is dark in each gap and is restored exactly
    /// once after the final frame.
    func flashLayerConfirmation(profile: MacropadProfile, layer: ProfileLayer) {
        activeProfile = profile
        beginExclusiveTimeline()
        let configuration = layer.confirmation
        guard configuration.effect != .off else {
            showIdleLighting()
            return
        }
        let blinkCount = max(1, layer.confirmationRepeatCount)
        logger.info("Layer confirmation flash ×\(blinkCount, privacy: .public)")
        let onMilliseconds = max(80, configuration.periodMilliseconds)
        let gapMilliseconds = max(100, min(220, onMilliseconds / 2))
        animationTask = Task { [weak self] in
            guard let self else { return }

            if configuration.effect == .pulse {
                self.sendWholePad { control in
                    KeyLEDConfiguration(
                        control: control,
                        effect: .pulse,
                        red: configuration.red,
                        green: configuration.green,
                        blue: configuration.blue,
                        brightness: configuration.brightness,
                        periodMilliseconds: onMilliseconds
                    )
                }
                do { try await Task.sleep(for: .milliseconds(onMilliseconds * blinkCount)) } catch { return }
                self.finishExclusiveTimeline()
                return
            }

            let repetitions = configuration.effect == .steady ? 1 : blinkCount
            for index in 0..<repetitions {
                self.sendWholePad { control in
                    KeyLEDConfiguration(
                        control: control,
                        effect: .steady,
                        red: configuration.red,
                        green: configuration.green,
                        blue: configuration.blue,
                        brightness: configuration.brightness,
                        periodMilliseconds: onMilliseconds
                    )
                }
                do { try await Task.sleep(for: .milliseconds(onMilliseconds)) } catch { return }
                guard index < repetitions - 1 else { continue }
                self.send([self.encoder.allOffPacket()])
                do { try await Task.sleep(for: .milliseconds(gapMilliseconds)) } catch { return }
            }
            self.finishExclusiveTimeline()
        }
    }

    func showAgentStatuses(_ statuses: [HardwareControl: CodexAgentStatus], profile: MacropadProfile) {
        agentStatuses = statuses
        activeProfile = profile
        guard !isDictationHeld, !pickerSelectionActive else { return }
        renderAgentLighting()
    }

    /// Terminal states remain the active status layer until the thread starts
    /// again or completion is acknowledged. This immediate write makes the
    /// transition responsive; `showAgentStatuses` then keeps the same
    /// user-configured effect alive.
    func showStatusTransition(_ status: CodexAgentStatus, for control: HardwareControl, profile: MacropadProfile) {
        // Dictation owns the complete pad while the key is held. In particular,
        // a range-limited dictation pulse is host-driven, so starting even a
        // one-key terminal reaction here would cancel its timer and leave the
        // agent key's firmware effect visible until the next dictation frame.
        // The status is still retained in `agentStatuses`; releasing dictation
        // reconciles the latest agent lighting in `showIdleLighting()`.
        guard !isDictationHeld, !pickerSelectionActive else { return }
        guard let event = LEDReactionEvent.event(for: status) else { return }
        let reaction = profile.reaction(for: event)
        guard reaction.effect != .off else { return }
        activeProfile = profile
        agentStatuses[control] = status
        beginExclusiveTimeline()
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
        isDictationHeld ? showDictationReaction() : showIdleLighting()
    }

    private func showDictationReaction() {
        guard let profile = activeProfile else { return }
        let reaction = profile.reaction(for: .dictation)
        guard reaction.effect != .off else {
            renderAgentLighting()
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

    private func renderAgentLighting() {
        // Several independent callers reach this (status updates, flash
        // restores) and none of them own the LEDs while a momentary
        // animation is mid-flight — sending here too would race the
        // animation's own ticks and read as wild flicker. Deferring is safe:
        // every animation ends by calling back into
        // showIdleLighting()/showDictationReaction(), which re-renders from
        // whatever the latest state turned out to be.
        guard animationTask == nil, !pickerSelectionActive else { return }
        guard let profile = activeProfile else { return }
        let settings = HardwareControl.buttons.map { control -> KeyLEDConfiguration in
            let status = agentStatuses[control] ?? .unassigned
            // Suppression only applies to this key's own idle color — a
            // different key's active agent animation must not blank an
            // unrelated key's resting light.
            let suppressThisKey: Bool = {
                guard let event = LEDReactionEvent.event(for: status) else { return false }
                let reaction = profile.reaction(for: event)
                // A one-shot flash is no longer active after its timer fires. It
                // must restore idle even while the thread remains completed.
                return reaction.effect != .off && reaction.effect != .flash && reaction.disablesIdle
            }()
            let idleSetting = baseSetting(for: control, profile: profile, suppressed: suppressThisKey)
            guard let event = LEDReactionEvent.event(for: status) else {
                return idleSetting
            }
            let reaction = profile.reaction(for: event)
            guard reaction.effect != .off else { return idleSetting }
            return reaction.keyConfiguration(for: control)
        }
        sendMixed(settings)
    }

    /// Sends the same configuration to all six keys, routing only unsupported
    /// brightness-range pulses through the host animator.
    private func sendWholePad(_ keyConfiguration: (HardwareControl) -> KeyLEDConfiguration) {
        sendMixed(HardwareControl.buttons.map(keyConfiguration))
    }

    /// Splits firmware-supported settings from range pulses. Every new render
    /// invalidates the previous host generation before writing either group,
    /// while normal pulses remain fire-and-forget firmware commands.
    private func sendMixed(_ settings: [KeyLEDConfiguration]) {
        invalidatePulseAnimation()
        let generation = pulseGeneration
        let staticSettings = settings.filter { !$0.isRangePulse }
        let animatedSettings = settings.filter(\.isRangePulse)
        if !staticSettings.isEmpty {
            send(staticSettings.map(encoder.ledPacket))
        }
        startPulseAnimation(animatedSettings, generation: generation)
    }

    private func beginExclusiveTimeline() {
        animationTask?.cancel()
        animationTask = nil
        invalidatePulseAnimation()
    }

    private func finishExclusiveTimeline() {
        animationTask = nil
        if isDictationHeld {
            showDictationReaction()
        } else {
            showIdleLighting()
        }
    }

    private func invalidatePulseAnimation() {
        pulseGeneration &+= 1
        pulseAnimationTask?.cancel()
        pulseAnimationTask = nil
    }

    /// Starts one animation generation for every currently pulsing key. The
    /// first frame is synchronous; later frames verify both cancellation and
    /// the generation immediately before sending.
    private func startPulseAnimation(
        _ settings: [KeyLEDConfiguration],
        generation: UInt64
    ) {
        guard !settings.isEmpty else { return }
        logger.info("Starting range-pulse generation \(generation, privacy: .public) for \(settings.count, privacy: .public) key(s)")
        let startNanoseconds = DispatchTime.now().uptimeNanoseconds
        let initialFrames = settings.map { breathingFrame(of: $0, elapsedMilliseconds: 0) }
        send(initialFrames.map(encoder.ledPacket))
        pulseAnimationTask = Task { [weak self] in
            // Track true elapsed time rather than accumulating fixed tick
            // steps: a scheduling hiccup would otherwise desync the phase
            // from wall-clock time and read as a stutter on every later tick.
            while true {
                do {
                    try await Task.sleep(for: .milliseconds(Self.rangePulseTickMilliseconds))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, self.pulseGeneration == generation else { return }
                let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startNanoseconds) / 1_000_000
                let frames = settings.map { self.breathingFrame(of: $0, elapsedMilliseconds: elapsedMilliseconds) }
                guard !Task.isCancelled, self.pulseGeneration == generation else { return }
                self.send(frames.map(self.encoder.ledPacket))
            }
        }
    }

    /// Computes one animation frame for a pulse key: a raised-cosine
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

}
