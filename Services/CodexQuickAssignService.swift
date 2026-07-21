import Foundation
import Observation

/// Assigns a Codex thread to a button just by holding it — the "no need to
/// keep the CodexPad window open" path for Belegung. Works the same whether
/// the button is currently unassigned or already holds a different thread:
/// `CodexThreadStore.assign` replaces any existing assignment for that
/// control outright, so a hold on an assigned key is a one-step reassignment
/// rather than an unassign-then-assign dance. Deliberately separate from
/// `CodexPadTapHoldService`: that service only fires for controls with an
/// explicitly configured hold action, whereas Belegung has none, and the two
/// must never fight over the same press.
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
    private let isTapHoldConfigured: (HardwareControl) -> Bool
    /// A thread explicitly identified via a copied session ID, if the
    /// clipboard currently holds one — takes priority over `fallbackThread`
    /// since it's a deliberate choice made in Codex itself, not a guess.
    private let clipboardThread: () -> CodexThreadDescriptor?
    /// The best guess absent a clipboard hint: the most recently active
    /// thread not already bound to another key.
    private let fallbackThread: () -> CodexThreadDescriptor?
    private let now: () -> Date

    /// Set after `init` (rather than passed in) so callers don't need `self`
    /// to be fully initialized yet — matches `CodexPadEventService.onPhysicalEvent`
    /// and friends elsewhere in this codebase.
    var onAssign: ((CodexThreadDescriptor, HardwareControl) -> Void)?

    init(
        isEnabled: @escaping () -> Bool,
        isTapHoldConfigured: @escaping (HardwareControl) -> Bool,
        clipboardThread: @escaping () -> CodexThreadDescriptor? = { nil },
        fallbackThread: @escaping () -> CodexThreadDescriptor?,
        now: @escaping () -> Date = Date.init
    ) {
        self.isEnabled = isEnabled
        self.isTapHoldConfigured = isTapHoldConfigured
        self.clipboardThread = clipboardThread
        self.fallbackThread = fallbackThread
        self.now = now
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
            guard isEnabled(), !isTapHoldConfigured(control) else { return }
            pressStartTimes[control] = now()
        case .released:
            guard let start = pressStartTimes.removeValue(forKey: control) else { return }
            guard isEnabled(), !isTapHoldConfigured(control) else { return }
            let heldMilliseconds = now().timeIntervalSince(start) * 1_000
            guard heldMilliseconds >= Double(Self.holdThresholdMilliseconds) else { return }
            guard let thread = clipboardThread() ?? fallbackThread() else { return }
            onAssign?(thread, control)
        case .triggered:
            break
        }
    }
}
