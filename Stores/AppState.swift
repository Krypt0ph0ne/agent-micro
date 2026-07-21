import AppKit
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
    let claudeReasoningAutomation: ClaudeReasoningAutomationService
    let padEvents: CodexPadEventService
    let keyboardState: CodexPadKeyboardStateService
    let tapHold: CodexPadTapHoldService
    let quickAssign: CodexQuickAssignService
    let ledFeedback: CodexPadLEDFeedbackService
    let codexBridge: CodexEventBridge
    let codexThreads: CodexThreadStore
    let claudeAgentBridge: ClaudeAgentBridge
    let claudeThreads: CodexThreadStore
    let claudeQuickAssign: CodexQuickAssignService
    let loginItem: LoginItemService

    init() {
        UserDefaults.standard.register(defaults: [CodexQuickAssignService.enabledDefaultsKey: true])
        let catalog = CodexActionCatalog()
        let claudeCatalog = CodexActionCatalog(resourceName: "ClaudeActions", app: .claude)
        let diagnostics = DiagnosticsStore()
        self.catalog = catalog
        self.claudeCatalog = claudeCatalog
        self.diagnostics = diagnostics
        self.profiles = ProfileStore(catalog: catalog, claudeCatalog: claudeCatalog)
        let profiles = self.profiles
        self.device = DeviceService(diagnostics: diagnostics)
        self.inputMonitor = HIDInputMonitor()
        self.reasoningAutomation = CodexReasoningAutomationService(isActiveProfile: { profiles.selectedProfile.automationApp != .claude })
        self.claudeReasoningAutomation = ClaudeReasoningAutomationService(isActiveProfile: { profiles.selectedProfile.automationApp == .claude })
        self.padEvents = CodexPadEventService()
        self.keyboardState = CodexPadKeyboardStateService()
        self.tapHold = CodexPadTapHoldService { profiles.selectedProfile }
        let codexBridge = CodexEventBridge()
        self.codexBridge = codexBridge
        self.codexThreads = CodexThreadStore(bridge: codexBridge)
        let claudeAgentBridge = ClaudeAgentBridge()
        self.claudeAgentBridge = claudeAgentBridge
        self.claudeThreads = CodexThreadStore(bridge: claudeAgentBridge, automationApp: .claude)
        self.loginItem = LoginItemService()
        self.ledFeedback = CodexPadLEDFeedbackService { [padEvents] packets in
            padEvents.sendLEDs(packets)
        }
        let codexThreads = self.codexThreads
        let claudeThreads = self.claudeThreads
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
        self.claudeQuickAssign = CodexQuickAssignService(
            isEnabled: { UserDefaults.standard.bool(forKey: CodexQuickAssignService.enabledDefaultsKey) },
            isDesignatedAgentControl: { profiles.selectedProfile.action(for: $0).kind == .claudeAgent },
            isTapHoldConfigured: { profiles.selectedProfile.binding(for: $0).isTapHold },
            clipboardThread: {
                guard let clipboardText = NSPasteboard.general.string(forType: .string),
                      let id = CodexQuickAssignService.extractThreadID(from: clipboardText)
                else { return nil }
                return claudeThreads.threads.first { $0.id == id }
            },
            fallbackThread: {
                let assignedThreadIDs = Set(claudeThreads.assignments.map(\.threadID))
                return claudeThreads.threads.first { !assignedThreadIDs.contains($0.id) }
            }
        )
        quickAssign.onAssign = { [weak self] thread, control in
            guard let self else { return }
            self.assignAgentThread(thread, to: control)
            self.ledFeedback.showThreadAssignedReaction(profile: self.profiles.selectedProfile)
        }
        claudeQuickAssign.onAssign = { [weak self] thread, control in
            guard let self else { return }
            self.assignAgentThread(thread, to: control)
            self.ledFeedback.showThreadAssignedReaction(profile: self.profiles.selectedProfile)
        }
        padEvents.onPhysicalEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ledFeedback.handle(event, profile: self.profiles.selectedProfile)
                self.tapHold.handle(event)
                self.quickAssign.handle(event)
                self.claudeQuickAssign.handle(event)
                self.reasoningAutomation.handlePhysicalEvent(event)
                self.claudeReasoningAutomation.handlePhysicalEvent(event)
                if event.phase == .pressed || event.phase == .triggered,
                   let control = HardwareControl(reportedControlIndex: event.control) {
                    let kind = self.profiles.selectedProfile.action(for: control).kind
                    if kind == .codexAgent {
                        _ = self.codexThreads.openAssignedThread(for: control)
                    } else if kind == .claudeAgent {
                        _ = self.claudeThreads.openAssignedThread(for: control)
                    }
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
        claudeThreads.onStatusChange = { [weak self] in self?.refreshAgentLEDs() }
    }

    /// The action catalog matching whichever app the selected profile targets;
    /// falls back to the Codex catalog for app-agnostic profiles (macOS, Safe).
    var activeCatalog: CodexActionCatalog {
        profiles.selectedProfile.automationApp == .claude ? claudeCatalog : catalog
    }

    /// The encoder automation service matching the selected profile's app,
    /// for UI that shows/tests the dial without caring which app it is.
    var activeReasoningAutomation: any EncoderAutomationService {
        profiles.selectedProfile.automationApp == .claude ? claudeReasoningAutomation : reasoningAutomation
    }

    /// The agent-thread store matching the selected profile's app.
    var activeAgentThreads: CodexThreadStore {
        profiles.selectedProfile.automationApp == .claude ? claudeThreads : codexThreads
    }

    /// Turns `control` into an (as yet unassigned) agent-thread control for
    /// whichever app the selected profile targets, ready for
    /// `CodexAgentAssignmentView` to fill in with a real thread.
    func assignAgentPlaceholder(to control: HardwareControl) {
        let appName = profiles.selectedProfile.automationApp?.displayName ?? "Codex"
        profiles.updateAction(
            KeyboardAction(kind: activeAgentKind, label: "\(appName) Agent auswählen", icon: "terminal.fill"),
            for: control
        )
    }

    private var activeAgentKind: ActionKind {
        profiles.selectedProfile.automationApp == .claude ? .claudeAgent : .codexAgent
    }

    /// Clears any live agent-thread assignment for `control` in whichever
    /// store matches the selected profile, so binding a plain shortcut on top
    /// of a previous quick-assign doesn't leave a stale thread reference.
    func removeActiveAgentAssignment(for control: HardwareControl) {
        activeAgentThreads.removeAssignment(for: control)
    }

    func refreshDevice() {
        device.refresh()
        padEvents.refresh(enabled: device.currentDevice?.isCodexPadFirmware == true)
        keyboardState.refresh(enabled: device.currentDevice?.isCodexPadFirmware == true)
        if device.currentDevice?.isCodexPadFirmware == true {
            refreshAgentLEDs()
        }
    }

    func startAgentBridges() {
        codexThreads.start()
        claudeThreads.start()
        refreshAgentLEDs()
    }

    func assignAgentThread(_ thread: CodexThreadDescriptor, to control: HardwareControl) {
        activeAgentThreads.assign(thread, to: control)
        profiles.updateAction(
            KeyboardAction(kind: activeAgentKind, label: thread.displayTitle, icon: thread.isSubagent ? "person.2.fill" : "terminal.fill"),
            for: control
        )
        refreshAgentLEDs()
    }

    func removeAgentAssignment(for control: HardwareControl) {
        let kind = activeAgentKind
        activeAgentThreads.removeAssignment(for: control)
        if profiles.selectedProfile.action(for: control).kind == kind {
            profiles.updateAction(.disabled, for: control)
        }
        refreshAgentLEDs()
    }

    func refreshAgentLEDs() {
        let statuses = Dictionary(uniqueKeysWithValues: HardwareControl.buttons.map { control in
            (control, activeAgentThreads.status(for: control))
        })
        ledFeedback.showAgentStatuses(statuses, profile: profiles.selectedProfile)
    }
}
