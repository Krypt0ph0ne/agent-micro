import AppKit
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
    let tapHold: CodexPadTapHoldService
    let quickAssign: CodexQuickAssignService
    let ledFeedback: CodexPadLEDFeedbackService
    let codexBridge: CodexEventBridge
    let codexThreads: CodexThreadStore
    let loginItem: LoginItemService

    init() {
        UserDefaults.standard.register(defaults: [CodexQuickAssignService.enabledDefaultsKey: true])
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
        let profiles = self.profiles
        self.tapHold = CodexPadTapHoldService { profiles.selectedProfile }
        let codexBridge = CodexEventBridge()
        self.codexBridge = codexBridge
        self.codexThreads = CodexThreadStore(bridge: codexBridge)
        self.loginItem = LoginItemService()
        self.ledFeedback = CodexPadLEDFeedbackService { [padEvents] packets in
            padEvents.sendLEDs(packets)
        }
        let codexThreads = self.codexThreads
        self.quickAssign = CodexQuickAssignService(
            isEnabled: { UserDefaults.standard.bool(forKey: CodexQuickAssignService.enabledDefaultsKey) },
            isDesignatedAgentControl: { profiles.selectedProfile.action(for: $0).kind == .codexAgent },
            isTapHoldConfigured: { profiles.selectedProfile.binding(for: $0).isTapHold },
            clipboardThread: {
                guard let clipboardText = NSPasteboard.general.string(forType: .string),
                      let id = CodexQuickAssignService.extractThreadID(from: clipboardText)
                else { return nil }
                return codexThreads.threads.first { $0.id == id }
            },
            fallbackThread: {
                let assignedThreadIDs = Set(codexThreads.assignments.map(\.threadID))
                return codexThreads.threads.first { !assignedThreadIDs.contains($0.id) }
            }
        )
        quickAssign.onAssign = { [weak self] thread, control in
            guard let self else { return }
            self.assignCodexThread(thread, to: control)
            self.ledFeedback.showThreadAssignedReaction(profile: self.profiles.selectedProfile)
        }
        padEvents.onPhysicalEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ledFeedback.handle(event, profile: self.profiles.selectedProfile)
                self.tapHold.handle(event)
                self.quickAssign.handle(event)
                self.reasoningAutomation.handlePhysicalEvent(event)
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
