import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    let catalog: CodexActionCatalog
    let claudeCatalog: CodexActionCatalog
    let diagnostics: DiagnosticsStore
    let profiles: ProfileStore
    let device: DeviceService
    let inputMonitor: HIDInputMonitor
    let reasoningAutomation: CodexReasoningAutomationService
    let padEvents: CodexPadEventService
    let keyboardState: CodexPadKeyboardStateService
    let tapHold: CodexPadTapHoldService
    let harnessLayer: HarnessLayerService
    let ledFeedback: CodexPadLEDFeedbackService
    let codexBridge: CodexEventBridge
    let codexThreads: CodexThreadStore

    /// The action catalog for the currently active harness layer. Claude uses
    /// its own shortcut set; everything else falls back to the Codex catalog.
    var activeCatalog: CodexActionCatalog {
        profiles.activeLayer == .claude ? claudeCatalog : catalog
    }

    init() {
        let catalog = CodexActionCatalog()
        let diagnostics = DiagnosticsStore()
        self.catalog = catalog
        self.claudeCatalog = .claude()
        self.diagnostics = diagnostics
        self.profiles = ProfileStore(catalog: catalog)
        self.device = DeviceService(diagnostics: diagnostics)
        self.inputMonitor = HIDInputMonitor()
        self.reasoningAutomation = CodexReasoningAutomationService()
        self.padEvents = CodexPadEventService()
        self.keyboardState = CodexPadKeyboardStateService()
        let profiles = self.profiles
        self.tapHold = CodexPadTapHoldService { profiles.selectedProfile }
        self.harnessLayer = HarnessLayerService(store: profiles)
        let codexBridge = CodexEventBridge()
        self.codexBridge = codexBridge
        self.codexThreads = CodexThreadStore(bridge: codexBridge)
        self.ledFeedback = CodexPadLEDFeedbackService { [padEvents] packets in
            padEvents.sendLEDs(packets)
        }
        padEvents.onPhysicalEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ledFeedback.handle(event, profile: self.profiles.selectedProfile)
                self.harnessLayer.handle(event)
                self.tapHold.handle(event)
                if event.phase == .pressed || event.phase == .triggered,
                   let control = HardwareControl(reportedControlIndex: event.control),
                   self.profiles.selectedProfile.action(for: control).kind == .codexAgent {
                    _ = self.codexThreads.openAssignedThread(for: control)
                }
            }
        }
        padEvents.onFirmwareStatus = { [weak self] firmwareStatus in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ledFeedback.handle(pressedMask: firmwareStatus.pressedMask, profile: self.profiles.selectedProfile)
            }
        }
        keyboardState.onDictationHoldChanged = { [weak self] isHeld in
            guard let self else { return }
            self.ledFeedback.handleDictationKeyboardReport(isHeld: isHeld, profile: self.profiles.selectedProfile)
        }
        codexThreads.onStatusChange = { [weak self] in self?.refreshAgentLEDs() }
        harnessLayer.onSwitch = { [weak self] layer in self?.switchToLayer(layer) }
    }

    /// Activates a harness layer: selects its profile, uploads it to the pad if
    /// connected, and shows the whole-pad colour cue. Used by both the header
    /// toggle and the physical switch chord.
    func switchToLayer(_ layer: HarnessLayer) {
        guard profiles.activeLayer != layer else { return }
        guard profiles.selectLayer(layer) else { return }
        let profile = profiles.selectedProfile
        if device.state.isSupportedConnection {
            let result = device.upload(
                profile: profile,
                keyboardLayout: profiles.keyboardLayout,
                appOnlyControls: profiles.appOnlySwitchControls(in: profile)
            )
            if result?.succeeded == true {
                profiles.markSynchronized()
            }
        }
        ledFeedback.indicateLayerSwitch(layer: layer, mode: profiles.layerSwitchLightMode, profile: profile)
    }

    func refreshDevice() {
        device.refresh()
        padEvents.refresh(enabled: device.currentDevice?.isCodexPadFirmware == true)
        keyboardState.refresh(enabled: device.currentDevice?.isCodexPadFirmware == true)
        if device.currentDevice?.isCodexPadFirmware == true {
            refreshAgentLEDs()
        }
    }

    func startCodexBridge() {
        codexThreads.start()
        refreshAgentLEDs()
    }

    func assignCodexThread(_ thread: CodexThreadDescriptor, to control: HardwareControl) {
        codexThreads.assign(thread, to: control)
        profiles.updateAction(
            KeyboardAction(kind: .codexAgent, label: thread.displayTitle, icon: thread.isSubagent ? "person.2.fill" : "terminal.fill"),
            for: control
        )
        refreshAgentLEDs()
    }

    func removeCodexAssignment(for control: HardwareControl) {
        codexThreads.removeAssignment(for: control)
        if profiles.selectedProfile.action(for: control).kind == .codexAgent {
            profiles.updateAction(.disabled, for: control)
        }
        refreshAgentLEDs()
    }

    func refreshAgentLEDs() {
        let statuses = Dictionary(uniqueKeysWithValues: HardwareControl.buttons.map { control in
            (control, codexThreads.status(for: control))
        })
        ledFeedback.showAgentStatuses(statuses, profile: profiles.selectedProfile)
    }
}
