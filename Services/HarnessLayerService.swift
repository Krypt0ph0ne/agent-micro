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
    private var consumedByChord: Set<HardwareControl> = []
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
        consumedByChord.remove(control)
        // Both switch keys are down: arm the chord.
        if Set(store.layerSwitchKeys).isSubset(of: pressedKeys) {
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
        consumedByChord.formUnion(store.layerSwitchKeys)
        let target = (store.activeLayer ?? .codex).other
        lastSwitchDescription = "Gewechselt zu \(target.title)"
        onSwitch(target)
    }

    private func release(_ control: HardwareControl) {
        // A release before the threshold breaks the pending chord.
        chordTimer?.invalidate()
        chordTimer = nil
        pressedKeys.remove(control)
        defer { consumedByChord.remove(control) }
        // The chord already switched on this press, so don't also tap.
        guard !consumedByChord.contains(control) else { return }
        // Only clean (app-only) switch keys are re-emitted by the app; a switch
        // key left on real firmware already sent its own macro.
        guard store.appOnlySwitchControls(in: store.selectedProfile).contains(control) else { return }
        let action = store.selectedProfile.action(for: control)
        guard action.isEnabled else { return }
        KeystrokeSynthesizer.post(macro: action.deviceMacro)
    }
}
