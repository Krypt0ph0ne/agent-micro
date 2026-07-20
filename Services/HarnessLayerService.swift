import Foundation
import Observation

/// Detects the "hold both switch keys" chord and toggles the active harness
/// layer (Codex ⇄ Claude). To keep the chord clean, the two switch keys are
/// uploaded in app-only mode when their action is synthesizable; this service
/// then re-emits a single-key tap itself and suppresses it while the chord is
/// completing, so switching never leaves a stray keystroke behind.
@MainActor
@Observable
final class HarnessLayerService {
    /// How long both keys must be held together before the layer switches.
    static let chordHoldMilliseconds = 450

    private let store: ProfileStore
    /// Called with the layer to activate. Assigned by AppState after init.
    var onSwitch: (HarnessLayer) -> Void = { _ in }

    private var pressedKeys: Set<HardwareControl> = []
    /// Keys whose current press must NOT emit a tap on release, because the two
    /// switch keys were held together at some point during that press (a chord
    /// attempt) — whether or not it completed, and no matter how long it is held.
    private var suppressedKeys: Set<HardwareControl> = []
    private var chordTimer: Timer?

    private(set) var lastSwitchDescription = "Noch kein Layer-Wechsel"

    init(store: ProfileStore) {
        self.store = store
    }

    func handle(_ event: CodexPadPhysicalEvent) {
        guard store.layerSwitchEnabled,
              let control = HardwareControl(reportedControlIndex: event.control),
              store.layerSwitchKeys.contains(control) else { return }
        switch event.phase {
        case .pressed:
            press(control)
        case .released:
            release(control)
        case .triggered:
            break
        }
    }

    private func press(_ control: HardwareControl) {
        pressedKeys.insert(control)
        // Both switch keys are down together: this is a chord attempt. Neither
        // key may tap on release from now on, and arm the switch timer.
        if Set(store.layerSwitchKeys).isSubset(of: pressedKeys) {
            suppressedKeys.formUnion(store.layerSwitchKeys)
            chordTimer?.invalidate()
            chordTimer = Timer.scheduledTimer(withTimeInterval: Double(Self.chordHoldMilliseconds) / 1_000, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.fireSwitch() }
            }
        }
    }

    private func fireSwitch() {
        chordTimer = nil
        // Only switch while both keys are still physically held.
        guard Set(store.layerSwitchKeys).isSubset(of: pressedKeys) else { return }
        let target = (store.activeLayer ?? .codex).other
        lastSwitchDescription = "Gewechselt zu \(target.title)"
        onSwitch(target)
    }

    private func release(_ control: HardwareControl) {
        // Releasing either key ends any pending switch. Holding longer than the
        // threshold simply fired once already; a later release does nothing.
        chordTimer?.invalidate()
        chordTimer = nil
        pressedKeys.remove(control)
        let wasChordAttempt = suppressedKeys.contains(control)
        suppressedKeys.remove(control)
        guard !wasChordAttempt else { return }
        // A genuine solo tap: re-emit the key's own action ourselves, since the
        // switch keys are uploaded in app-only mode and send nothing themselves.
        let action = store.selectedProfile.action(for: control)
        guard action.isEnabled else { return }
        KeystrokeSynthesizer.post(macro: action.deviceMacro)
    }
}
