import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    let catalog: CodexActionCatalog
    let diagnostics: DiagnosticsStore
    let profiles: ProfileStore
    let device: DeviceService
    let inputMonitor: HIDInputMonitor
    let reasoningAutomation: CodexReasoningAutomationService
    let padEvents: CodexPadEventService
    let keyboardState: CodexPadKeyboardStateService
    let ledFeedback: CodexPadLEDFeedbackService
    let codexBridge: CodexEventBridge
    let codexThreads: CodexThreadStore

    init() {
        let catalog = CodexActionCatalog()
        let diagnostics = DiagnosticsStore()
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.profiles = ProfileStore(catalog: catalog)
        self.device = DeviceService(diagnostics: diagnostics)
        self.inputMonitor = HIDInputMonitor()
        self.reasoningAutomation = CodexReasoningAutomationService()
        self.padEvents = CodexPadEventService()
        self.keyboardState = CodexPadKeyboardStateService()
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
            self?.ledFeedback.handleDictationKeyboardReport(isHeld: isHeld)
        }
        codexThreads.onStatusChange = { [weak self] in self?.refreshAgentLEDs() }
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
        ledFeedback.showAgentStatuses(statuses)
    }
}
