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
    let approvals: ApprovalCoordinator
    let permissionMonitor: PermissionMonitor
    /// Debounces `autoSync()` so a config change is pushed to the hardware
    /// without the user having to press "Übertragen" — see `scheduleAutoSync()`.
    private var autoSyncTask: Task<Void, Never>?
    private static let autoSyncDelaySeconds: TimeInterval = 0.4
    /// Fires the Codex⇄Claude layer switch once `profiles.layerSwitchControl`
    /// has been held past the threshold — see `beginLayerSwitchHold()`.
    private var layerSwitchHoldTask: Task<Void, Never>?
    static let layerSwitchHoldThresholdSeconds: TimeInterval = 0.4

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
        let permissionMonitor = PermissionMonitor()
        self.permissionMonitor = permissionMonitor
        self.inputMonitor = HIDInputMonitor(permissionMonitor: permissionMonitor)
        self.reasoningAutomation = CodexReasoningAutomationService(permissionMonitor: permissionMonitor, isActiveProfile: { profiles.selectedProfile.automationApp != .claude })
        self.claudeReasoningAutomation = ClaudeReasoningAutomationService(permissionMonitor: permissionMonitor, isActiveProfile: { profiles.selectedProfile.automationApp == .claude })
        self.padEvents = CodexPadEventService()
        self.keyboardState = CodexPadKeyboardStateService()
        self.tapHold = CodexPadTapHoldService(permissionMonitor: permissionMonitor) { profiles.selectedProfile }
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
        let ledFeedback = self.ledFeedback
        self.approvals = ApprovalCoordinator(
            codexBridge: codexBridge,
            ledFeedback: ledFeedback,
            currentProfile: { profiles.selectedProfile }
        )
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
                guard let control = HardwareControl(reportedControlIndex: event.control) else { return }
                if control == self.profiles.layerSwitchControl {
                    switch event.phase {
                    case .pressed: self.beginLayerSwitchHold()
                    case .released: self.endLayerSwitchHold()
                    case .triggered: break
                    }
                    return
                }
                guard event.phase == .pressed || event.phase == .triggered else { return }
                let action = self.profiles.selectedProfile.action(for: control)
                switch action.codexActionID {
                case "approval-accept" where self.approvals.armed != nil:
                    self.approvals.decide(.accept)
                case "approval-decline" where self.approvals.armed != nil:
                    self.approvals.decide(.decline)
                default:
                    if action.kind == .codexAgent {
                        _ = self.codexThreads.openAssignedThread(for: control)
                    } else if action.kind == .claudeAgent {
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
        profiles.onChange = { [weak self] in self?.scheduleAutoSync() }
    }

    /// Debounces a hardware sync so rapid successive edits (e.g. dragging a
    /// color slider) collapse into a single upload ~400ms after the user
    /// stops changing things, instead of flooding the HID interface with a
    /// full 18-packet write per keystroke.
    private func scheduleAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoSyncDelaySeconds))
            guard !Task.isCancelled, let self else { return }
            self.autoSync()
        }
    }

    /// Same upload the manual "Übertragen" button performs
    /// (`MainWindowView.upload()`); the button stays available as a manual
    /// "sync now" fallback for when this is still debouncing or a previous
    /// attempt failed, with the existing `hasUnsyncedChanges`/diagnostics
    /// error surfacing as the retry signal.
    private func autoSync() {
        guard profiles.hasUnsyncedChanges, device.state.isSupportedConnection, !device.isBusy else { return }
        let result = device.upload(profile: profiles.selectedProfile, keyboardLayout: profiles.keyboardLayout, layerSwitchControl: profiles.layerSwitchControl)
        if result?.succeeded == true {
            profiles.markSynchronized()
            refreshAgentLEDs()
        }
    }

    /// `profiles.layerSwitchControl` is reserved and app-only (no macro) in
    /// firmware — see `CodexPadPacketEncoder` — so holding it past the
    /// threshold is the only thing it ever does.
    private func beginLayerSwitchHold() {
        layerSwitchHoldTask?.cancel()
        layerSwitchHoldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.layerSwitchHoldThresholdSeconds))
            guard !Task.isCancelled, let self else { return }
            self.profiles.switchToOtherBuiltInProfile()
            self.ledFeedback.flashLayerSwitchConfirmation(profile: self.profiles.selectedProfile)
        }
    }

    private func endLayerSwitchHold() {
        layerSwitchHoldTask?.cancel()
        layerSwitchHoldTask = nil
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
