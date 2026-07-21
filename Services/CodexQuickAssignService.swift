import Foundation
import Observation

/// Assigns a Codex thread to an unbound button just by holding it — the
/// "no need to keep the CodexPad window open" path for Belegung. Deliberately
/// separate from `CodexPadTapHoldService`: that service only fires for
/// controls with an explicitly configured hold action, whereas an unassigned
/// button has none, and the two must never fight over the same press.
@MainActor
@Observable
final class CodexQuickAssignService {
    /// `UserDefaults` key shared with the Settings toggle.
    static let enabledDefaultsKey = "quickAssignEnabled"

    /// Deliberately longer than the normal tap/hold default
    /// (`ControlBinding.defaultHoldThresholdMilliseconds`, 320ms) since this
    /// assigns state rather than firing a one-off keystroke — an accidental
    /// trigger is more disruptive here.
    static let holdThresholdMilliseconds = 900

    private var pressStartTimes: [HardwareControl: Date] = [:]

    private let isEnabled: () -> Bool
    private let isAlreadyAssigned: (HardwareControl) -> Bool
    private let isTapHoldConfigured: (HardwareControl) -> Bool
    private let candidateThread: () -> CodexThreadDescriptor?
    private let now: () -> Date

    /// Set after `init` (rather than passed in) so callers don't need `self`
    /// to be fully initialized yet — matches `CodexPadEventService.onPhysicalEvent`
    /// and friends elsewhere in this codebase.
    var onAssign: ((CodexThreadDescriptor, HardwareControl) -> Void)?

    init(
        isEnabled: @escaping () -> Bool,
        isAlreadyAssigned: @escaping (HardwareControl) -> Bool,
        isTapHoldConfigured: @escaping (HardwareControl) -> Bool,
        candidateThread: @escaping () -> CodexThreadDescriptor?,
        now: @escaping () -> Date = Date.init
    ) {
        self.isEnabled = isEnabled
        self.isAlreadyAssigned = isAlreadyAssigned
        self.isTapHoldConfigured = isTapHoldConfigured
        self.candidateThread = candidateThread
        self.now = now
    }

    func handle(_ event: CodexPadPhysicalEvent) {
        guard
            let control = HardwareControl(reportedControlIndex: event.control),
            HardwareControl.buttons.contains(control)
        else { return }

        switch event.phase {
        case .pressed:
            guard isEnabled(), !isAlreadyAssigned(control), !isTapHoldConfigured(control) else { return }
            pressStartTimes[control] = now()
        case .released:
            guard let start = pressStartTimes.removeValue(forKey: control) else { return }
            guard isEnabled(), !isAlreadyAssigned(control), !isTapHoldConfigured(control) else { return }
            let heldMilliseconds = now().timeIntervalSince(start) * 1_000
            guard heldMilliseconds >= Double(Self.holdThresholdMilliseconds) else { return }
            guard let thread = candidateThread() else { return }
            onAssign?(thread, control)
        case .triggered:
            break
        }
    }
}
