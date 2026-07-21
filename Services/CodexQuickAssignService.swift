import Foundation
import Observation

/// Assigns a Codex thread to a button just by holding it — the "no need to
/// keep the CodexPad window open" path for Belegung. Works the same whether
/// the button is currently unassigned or already holds a different thread:
/// `CodexThreadStore.assign` replaces any existing assignment for that
/// control outright, so a hold on an assigned key is a one-step reassignment
/// rather than an unassign-then-assign dance.
///
/// Fires right when the hold threshold elapses — not on release — so the
/// confirmation LED lands while the button is still held down and the
/// release simply ends the press. Only ever acts on a control the user has
/// already turned into a Codex agent key at least once (`kind == .codexAgent`);
/// every other control's hold is left alone, e.g. a dictation key's own
/// hold-to-record must never be reinterpreted as a reassignment.
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

    private struct PendingPress {
        let cancel: () -> Void
    }

    private var pendingPresses: [HardwareControl: PendingPress] = [:]

    private let isEnabled: () -> Bool
    private let isDesignatedAgentControl: (HardwareControl) -> Bool
    private let isTapHoldConfigured: (HardwareControl) -> Bool
    /// A thread explicitly identified via a copied session ID, if the
    /// clipboard currently holds one — takes priority over `fallbackThread`
    /// since it's a deliberate choice made in Codex itself, not a guess.
    private let clipboardThread: () -> CodexThreadDescriptor?
    /// The best guess absent a clipboard hint: the most recently active
    /// thread not already bound to another key.
    private let fallbackThread: () -> CodexThreadDescriptor?
    /// Schedules `fire` after `interval` seconds and returns a closure that
    /// cancels it. Real presses use a `Timer`; tests inject a fake so they
    /// can trigger or cancel the fire deterministically without sleeping.
    private let schedule: @MainActor (TimeInterval, @escaping () -> Void) -> () -> Void

    /// Set after `init` (rather than passed in) so callers don't need `self`
    /// to be fully initialized yet — matches `CodexPadEventService.onPhysicalEvent`
    /// and friends elsewhere in this codebase.
    var onAssign: ((CodexThreadDescriptor, HardwareControl) -> Void)?

    init(
        isEnabled: @escaping () -> Bool,
        isDesignatedAgentControl: @escaping (HardwareControl) -> Bool,
        isTapHoldConfigured: @escaping (HardwareControl) -> Bool,
        clipboardThread: @escaping () -> CodexThreadDescriptor? = { nil },
        fallbackThread: @escaping () -> CodexThreadDescriptor?,
        schedule: @escaping @MainActor (TimeInterval, @escaping () -> Void) -> () -> Void = CodexQuickAssignService.timerSchedule
    ) {
        self.isEnabled = isEnabled
        self.isDesignatedAgentControl = isDesignatedAgentControl
        self.isTapHoldConfigured = isTapHoldConfigured
        self.clipboardThread = clipboardThread
        self.fallbackThread = fallbackThread
        self.schedule = schedule
    }

    private static func timerSchedule(interval: TimeInterval, fire: @escaping () -> Void) -> () -> Void {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            fire()
        }
        return { timer.invalidate() }
    }

    /// Codex lets you copy a session's UUID (e.g. from its own UI); this
    /// pulls one back out of arbitrary clipboard text so a hold can act on
    /// "whatever chat I just copied the ID of", not just guess by recency.
    nonisolated static func extractThreadID(from clipboardText: String) -> String? {
        let pattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        guard let range = clipboardText.range(of: pattern, options: .regularExpression) else { return nil }
        return String(clipboardText[range])
    }

    func handle(_ event: CodexPadPhysicalEvent) {
        guard
            let control = HardwareControl(reportedControlIndex: event.control),
            HardwareControl.buttons.contains(control)
        else { return }

        switch event.phase {
        case .pressed:
            cancelPending(control)
            guard isEnabled(), isDesignatedAgentControl(control), !isTapHoldConfigured(control) else { return }
            let cancel = schedule(Double(Self.holdThresholdMilliseconds) / 1_000) { [weak self] in
                self?.fireAssign(control)
            }
            pendingPresses[control] = PendingPress(cancel: cancel)
        case .released:
            // Releasing before the threshold elapses is the "just a tap"
            // case: cancel the pending fire so nothing gets assigned. If the
            // threshold already fired, `fireAssign` has already cleared the
            // entry, so this is a no-op — the release doesn't undo it.
            cancelPending(control)
        case .triggered:
            break
        }
    }

    private func cancelPending(_ control: HardwareControl) {
        pendingPresses.removeValue(forKey: control)?.cancel()
    }

    private func fireAssign(_ control: HardwareControl) {
        pendingPresses.removeValue(forKey: control)
        guard let thread = clipboardThread() ?? fallbackThread() else { return }
        onAssign?(thread, control)
    }
}
