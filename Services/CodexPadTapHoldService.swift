import Foundation
import Observation

/// Drives tap-vs-hold controls. The CH552 firmware reports raw key-down and
/// key-up edges for controls bound in app-only mode; this service measures how
/// long the key stays down and synthesizes either the tap (primary) action or
/// the hold (secondary) action once the threshold is crossed.
///
/// Only the custom Agent Micro firmware reports these edges, so on the plain
/// CH57x-2 path a tap-vs-hold control simply keeps sending its primary macro
/// straight from the device and this service never sees an event.
@MainActor
@Observable
final class CodexPadTapHoldService {
    private struct PressState {
        var timer: Timer?
        var holdFired = false
    }

    private let profileProvider: () -> MacropadProfile
    private let permissionMonitor: PermissionMonitor
    private var pressStates: [HardwareControl: PressState] = [:]

    /// Last resolved action, surfaced in Diagnostics/Settings for confidence.
    private(set) var lastResolvedAction = "Noch keine Tipp-/Halte-Aktion ausgelöst"

    /// Fired instead of keystroke synthesis when the resolved tap or hold
    /// action has no `deviceMacro` to synthesize (agent, layer-switch,
    /// profile-switch, ...) — lets `AppState` run its normal app-side
    /// dispatch for whichever slot just resolved.
    var onAppAction: ((KeyboardAction, HardwareControl) -> Void)?

    /// Synthesizing keystrokes into other apps needs the Accessibility grant.
    var hasAccessibilityPermission: Bool { permissionMonitor.hasAccessibilityPermission }

    init(permissionMonitor: PermissionMonitor, profileProvider: @escaping () -> MacropadProfile) {
        self.permissionMonitor = permissionMonitor
        self.profileProvider = profileProvider
    }

    /// Whether any button in the given profile currently uses tap-vs-hold.
    static func isActive(in profile: MacropadProfile) -> Bool {
        HardwareControl.buttons.contains { profile.binding(for: $0).isTapHold }
    }

    func handle(_ event: CodexPadPhysicalEvent) {
        guard let control = HardwareControl(reportedControlIndex: event.control) else { return }
        let binding = profileProvider().binding(for: control)
        guard binding.isTapHold else {
            // Drop any stale timer if the binding changed mid-press.
            cancel(control)
            return
        }
        switch event.phase {
        case .pressed:
            beginPress(control: control, binding: binding)
        case .released:
            endPress(control: control, binding: binding)
        case .triggered:
            break
        }
    }

    private func beginPress(control: HardwareControl, binding: ControlBinding) {
        cancel(control)
        let threshold = Double(binding.resolvedHoldThresholdMilliseconds) / 1_000
        let timer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireHold(control: control) }
        }
        pressStates[control] = PressState(timer: timer, holdFired: false)
    }

    private func fireHold(control: HardwareControl) {
        guard var state = pressStates[control], !state.holdFired else { return }
        state.holdFired = true
        state.timer = nil
        pressStates[control] = state
        guard let hold = profileProvider().binding(for: control).holdAction else { return }
        if KeystrokeSynthesizer.post(macro: hold.deviceMacro) {
            lastResolvedAction = "Halten: \(hold.displayLabel)"
        } else if hold.isEnabled {
            onAppAction?(hold, control)
            lastResolvedAction = "Halten: \(hold.displayLabel)"
        }
    }

    private func endPress(control: HardwareControl, binding: ControlBinding) {
        guard let state = pressStates[control] else { return }
        state.timer?.invalidate()
        pressStates[control] = nil
        // The hold already fired for this press; the release must not also tap.
        guard !state.holdFired else { return }
        let tap = binding.action
        if KeystrokeSynthesizer.post(macro: tap.deviceMacro) {
            lastResolvedAction = "Tippen: \(tap.displayLabel)"
        } else if tap.isEnabled {
            onAppAction?(tap, control)
            lastResolvedAction = "Tippen: \(tap.displayLabel)"
        }
    }

    private func cancel(_ control: HardwareControl) {
        pressStates[control]?.timer?.invalidate()
        pressStates[control] = nil
    }
}
