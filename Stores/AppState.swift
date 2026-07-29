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
    private let threadPickerPanel: ThreadPickerPanelController
    /// Debounces `autoSync()` so a config change is pushed to the hardware
    /// without the user having to press "Übertragen" — see `scheduleAutoSync()`.
    private var autoSyncTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?
    private var observedDeviceID: String?
    private static let autoSyncDelaySeconds: TimeInterval = 0.4
    /// Per-control rapid-tap counters for a `.tapCount`-mode `.layerSwitch`
    /// action — see `handleLayerSwitchAction`.
    private var layerTapCounts: [HardwareControl: Int] = [:]
    private var layerTapTimers: [HardwareControl: Task<Void, Never>] = [:]
    private var completedAcknowledgementTasks: [String: Task<Void, Never>] = [:]
    private static let layerMultiTapWindowSeconds: TimeInterval = 0.6
    /// A completed agent remains visibly acknowledged after its key opens the
    /// chat. This is deliberately longer than the completion reaction's own
    /// period: the configured pulse/blink is the status layer until this
    /// acknowledgement expires, not just a three-second flash.
    private static let completedAcknowledgementDelaySeconds: TimeInterval = 30
    private(set) var lastTransferResult: TransferResult?

    struct TransferResult: Identifiable {
        let id = UUID()
        let profileName: String
        let layerName: String
        let succeeded: Bool
        let detail: String
    }

    init() {
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
        self.threadPickerPanel = ThreadPickerPanelController()
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
            isEnabled: { true },
            isDesignatedAgentControl: { profiles.selectedProfile.action(for: $0).kind == .codexAgent },
            isTapHoldConfigured: { profiles.selectedProfile.binding(for: $0).isTapHold },
            candidateThreads: { control in
                CodexQuickAssignService.recentCandidates(
                    from: codexThreads.threads,
                    assignedThreadID: codexThreads.assignment(for: control)?.threadID
                )
            },
            assignedThreadID: { codexThreads.assignment(for: $0)?.threadID },
            appName: { AutomationApp.codex.displayName }
        )
        self.claudeQuickAssign = CodexQuickAssignService(
            isEnabled: { true },
            isDesignatedAgentControl: { profiles.selectedProfile.action(for: $0).kind == .claudeAgent },
            isTapHoldConfigured: { profiles.selectedProfile.binding(for: $0).isTapHold },
            candidateThreads: { control in
                CodexQuickAssignService.recentCandidates(
                    from: claudeThreads.threads,
                    assignedThreadID: claudeThreads.assignment(for: control)?.threadID
                )
            },
            assignedThreadID: { claudeThreads.assignment(for: $0)?.threadID },
            appName: { AutomationApp.claude.displayName }
        )
        quickAssign.onAssign = { [weak self] thread, control in
            guard let self else { return }
            self.assignAgentThread(thread, to: control)
        }
        claudeQuickAssign.onAssign = { [weak self] thread, control in
            guard let self else { return }
            self.assignAgentThread(thread, to: control)
        }
        quickAssign.onTap = { [weak self] control in
            self?.openAgentThread(app: .codex, store: codexThreads, control: control)
        }
        claudeQuickAssign.onTap = { [weak self] control in
            self?.openAgentThread(app: .claude, store: claudeThreads, control: control)
        }
        configureThreadPicker(self.quickAssign, store: codexThreads)
        configureThreadPicker(self.claudeQuickAssign, store: claudeThreads)
        reasoningAutomation.isExternallySuspended = { [weak self] in
            self?.quickAssign.isSelecting == true || self?.claudeQuickAssign.isSelecting == true
        }
        claudeReasoningAutomation.isExternallySuspended = { [weak self] in
            self?.quickAssign.isSelecting == true || self?.claudeQuickAssign.isSelecting == true
        }
        tapHold.onAppAction = { [weak self] action, control in
            self?.dispatchAction(action, for: control)
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
                guard event.phase == .pressed || event.phase == .triggered else { return }
                let binding = self.profiles.selectedProfile.binding(for: control)
                // Agent controls own both gestures: release-before-threshold
                // opens the assignment, while a completed hold reassigns it.
                guard !binding.action.kind.isAgent else { return }
                // Tap-hold controls resolve tap-vs-hold themselves (above, via
                // `tapHold.handle`/`onAppAction`) — dispatching the plain tap
                // action here too would fire it immediately on every press,
                // defeating the wait-for-hold timing.
                guard !binding.isTapHold else { return }
                self.dispatchAction(binding.action, for: control)
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
        codexThreads.onThreadsChange = { [weak self] in self?.quickAssign.refreshCandidates() }
        claudeThreads.onThreadsChange = { [weak self] in self?.claudeQuickAssign.refreshCandidates() }
        codexThreads.onStatusUpdate = { [weak self] control, status, source in
            self?.handleAgentStatusUpdate(app: .codex, control: control, status: status, source: source)
        }
        claudeThreads.onStatusUpdate = { [weak self] control, status, source in
            self?.handleAgentStatusUpdate(app: .claude, control: control, status: status, source: source)
        }
        profiles.onChange = { [weak self] in
            guard let self else { return }
            self.scheduleAutoSync()
        }
        profiles.onSelectedProfileChange = { [weak self] in
            self?.quickAssign.cancelSelection()
            self?.claudeQuickAssign.cancelSelection()
        }
    }

    private func configureThreadPicker(
        _ service: CodexQuickAssignService,
        store: CodexThreadStore
    ) {
        service.onPickerWillOpen = { [weak store] in
            store?.refreshRecentThreads()
        }
        service.onPickerChanged = { [weak self] presentation in
            self?.threadPickerPanel.update(presentation)
        }
        service.onSelectionStarted = { [weak self] in
            guard let self else { return }
            self.ledFeedback.beginThreadPickerSelection(profile: self.profiles.selectedProfile)
        }
        service.onSelectionFinished = { [weak self] confirmed in
            guard let self else { return }
            self.ledFeedback.finishThreadPickerSelection(
                profile: self.profiles.selectedProfile,
                confirmed: confirmed
            )
        }
    }

    private func openAgentThread(
        app: AutomationApp,
        store: CodexThreadStore,
        control: HardwareControl
    ) {
        guard store.openAssignedThread(for: control) else { return }
        guard
            store.status(for: control) == .completed,
            let expectedThreadID = store.assignment(for: control)?.threadID
        else { return }
        let key = acknowledgementKey(app: app, control: control)
        completedAcknowledgementTasks[key]?.cancel()
        completedAcknowledgementTasks[key] = Task { [weak self, weak store] in
            try? await Task.sleep(for: .seconds(Self.completedAcknowledgementDelaySeconds))
            guard !Task.isCancelled, let self, let store else { return }
            defer { self.completedAcknowledgementTasks[key] = nil }
            guard store.assignment(for: control)?.threadID == expectedThreadID else { return }
            _ = store.acknowledgeCompleted(for: control)
        }
    }

    private func acknowledgementKey(app: AutomationApp, control: HardwareControl) -> String {
        "\(app.rawValue)-\(control.rawValue)"
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
        guard profiles.hasUnsyncedChanges else { return }
        _ = transferCurrentConfiguration()
    }

    /// Single transfer path shared by the main window, the menu extra and the
    /// debounce.  The selected profile/layer is captured before uploading;
    /// only that exact confirmed snapshot is allowed to clear the dirty flag.
    @discardableResult
    func transferCurrentConfiguration() -> TransferResult? {
        autoSyncTask?.cancel()
        guard device.state.isSupportedConnection, !device.isBusy else { return nil }
        let snapshot = profiles.selectedProfile
        let layer = snapshot.layers.first(where: { $0.id == snapshot.activeLayerID })
        let result = device.upload(profile: snapshot, keyboardLayout: profiles.keyboardLayout)
        let succeeded = result?.succeeded == true
        if succeeded {
            profiles.markSynchronized(profileID: snapshot.id, layerID: snapshot.activeLayerID)
            refreshAgentLEDs()
        }
        let detail = [result?.launchError, result?.stderr, result?.stdout]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        let transfer = TransferResult(
            profileName: snapshot.name,
            layerName: layer?.name ?? "Standard",
            succeeded: succeeded,
            detail: detail
        )
        lastTransferResult = transfer
        return transfer
    }

    /// Dispatch for a control's resolved action on a normal key press.
    private func dispatchAction(_ action: KeyboardAction, for control: HardwareControl) {
        switch action.codexActionID {
        case "approval-accept" where approvals.armed != nil:
            approvals.decide(.accept)
        case "approval-decline" where approvals.armed != nil:
            approvals.decide(.decline)
        default:
            if action.kind == .codexAgent {
                _ = codexThreads.openAssignedThread(for: control)
            } else if action.kind == .claudeAgent {
                _ = claudeThreads.openAssignedThread(for: control)
            } else if action.kind == .layerSwitch {
                handleLayerSwitchAction(action, control: control)
            } else if action.kind == .profileSwitch {
                profiles.switchToOtherBuiltInProfile()
                activeAgentThreads.activateApp()
                ledFeedback.flashLayerSwitchConfirmation(profile: profiles.selectedProfile)
            }
        }
    }

    /// Advances or jumps the *currently selected profile's* active layer
    /// according to the assigned action's mode, then confirms with that
    /// layer's own blink color/count.
    private func handleLayerSwitchAction(_ action: KeyboardAction, control: HardwareControl) {
        switch action.layerSwitchMode ?? .cycle {
        case .cycle:
            profiles.advanceToNextLayer()
            flashActiveLayer()
        case .tapCount:
            let count = (layerTapCounts[control] ?? 0) + 1
            layerTapCounts[control] = count
            layerTapTimers[control]?.cancel()
            layerTapTimers[control] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.layerMultiTapWindowSeconds))
                guard !Task.isCancelled, let self else { return }
                let finalCount = self.layerTapCounts[control] ?? 1
                self.layerTapCounts[control] = 0
                self.profiles.selectLayer(atPosition: finalCount)
                self.flashActiveLayer()
            }
        }
    }

    private func flashActiveLayer() {
        let profile = profiles.selectedProfile
        guard let layer = profile.layers.first(where: { $0.id == profile.activeLayerID }) else { return }
        ledFeedback.flashLayerConfirmation(profile: profile, layer: layer)
    }

    func previewLayerConfirmation(_ layerID: UUID) {
        let profile = profiles.selectedProfile
        guard let layer = profile.layers.first(where: { $0.id == layerID }) else { return }
        ledFeedback.flashLayerConfirmation(profile: profile, layer: layer)
    }

    /// Plays the selected profile's configured event reaction without
    /// requiring the corresponding real-world event to occur.
    func previewReaction(_ event: LEDReactionEvent) {
        ledFeedback.previewReaction(event, profile: profiles.selectedProfile)
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

    /// Starts the persistent USB lifecycle independently of the main window.
    /// A reconnect is treated like a small boot: both input-report listeners
    /// are reopened, the complete profile/layer snapshot is uploaded, and the
    /// current agent LEDs are restored without requiring the toolbar refresh.
    func startHardwareServices() {
        guard deviceMonitorTask == nil else { return }
        reconcileDeviceConnection(forceReinitialization: true, reportDiagnostics: true)
        deviceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.reconcileDeviceConnection(
                    forceReinitialization: false,
                    reportDiagnostics: false
                )
            }
        }
    }

    func refreshDevice() {
        reconcileDeviceConnection(forceReinitialization: true, reportDiagnostics: true)
    }

    private func reconcileDeviceConnection(
        forceReinitialization: Bool,
        reportDiagnostics: Bool
    ) {
        let previousID = observedDeviceID
        // The once-per-second presence check is intentionally silent in the
        // UI. It must not make the already-connected pad look disconnected
        // for one frame on every poll.
        device.refresh(
            reportDiagnostics: reportDiagnostics,
            showsScanningState: forceReinitialization
        )
        let connected = device.currentDevice?.support == .supported
            ? device.currentDevice : nil
        let newID = connected?.id

        guard let connected else {
            quickAssign.cancelSelection()
            claudeQuickAssign.cancelSelection()
            if previousID != nil {
                padEvents.refresh(enabled: false)
                keyboardState.refresh(enabled: false)
                diagnostics.append(.warning, "Agent Micro getrennt", detail: "Eingabe- und LED-Dienste wurden angehalten.")
            }
            observedDeviceID = nil
            return
        }

        guard Self.requiresPadReinitialization(
            previousID: previousID,
            newID: newID,
            forced: forceReinitialization
        ) else { return }

        // Record this physical connection *before* attempting its one-time
        // setup upload. An unavailable Raw-HID interface may make that upload
        // fail, but it must never turn the 1-second presence poll into an
        // endless reinitialise-and-upload loop that resets LED effects.
        observedDeviceID = newID
        let customFirmware = connected.isCodexPadFirmware
        padEvents.refresh(enabled: customFirmware)
        keyboardState.refresh(enabled: customFirmware)
        let transfer = transferCurrentConfiguration()
        if transfer?.succeeded == true {
            diagnostics.append(
                .success,
                previousID == nil ? "Agent Micro initialisiert" : "Agent Micro neu initialisiert",
                detail: "\(transfer?.profileName ?? "Profil") · \(transfer?.layerName ?? "Layer") · Eingaben und Live-LEDs aktiv"
            )
        } else if reportDiagnostics {
            diagnostics.append(
                .error,
                "Agent Micro Initialisierung unvollständig",
                detail: "Das Gerät wurde erkannt, aber das aktive Profil konnte nicht bestätigt werden. Mit „Gerät erneut suchen“ oder „Übertragen“ kann der Versuch bewusst wiederholt werden."
            )
        }
    }

    nonisolated static func requiresPadReinitialization(
        previousID: String?,
        newID: String?,
        forced: Bool
    ) -> Bool {
        guard newID != nil else { return false }
        return forced || previousID != newID
    }

    func startAgentBridges() {
        codexThreads.start()
        claudeThreads.start()
        refreshAgentLEDs()
    }

    func assignAgentThread(_ thread: CodexThreadDescriptor, to control: HardwareControl) {
        let app = profiles.selectedProfile.automationApp == .claude ? AutomationApp.claude : .codex
        let acknowledgement = acknowledgementKey(app: app, control: control)
        completedAcknowledgementTasks[acknowledgement]?.cancel()
        completedAcknowledgementTasks[acknowledgement] = nil
        activeAgentThreads.assign(thread, to: control)
        profiles.updateAction(
            KeyboardAction(kind: activeAgentKind, label: thread.displayTitle, icon: thread.isSubagent ? "person.2.fill" : "terminal.fill"),
            for: control
        )
        refreshAgentLEDs()
    }

    /// Transfers an action without a built-in shortcut to the pad. Shortcut
    /// setup stays deliberately manual: the app never attempts to navigate
    /// Codex, because that route is not stable across Codex versions.
    @discardableResult
    func transferConfiguredShortcut(
        _ definition: CodexActionDefinition,
        trigger: String,
        control: HardwareControl,
        slot: ActionSlot
    ) -> TransferResult? {
        if slot == .tap { removeActiveAgentAssignment(for: control) }
        let app = profiles.selectedProfile.automationApp ?? .codex
        let kind: ActionKind = app == .claude ? .claudeShortcut : .codexShortcut
        profiles.assignConfigurableCodexAction(definition, trigger: trigger, to: control, slot: slot, kind: kind)

        let transfer = transferCurrentConfiguration()
        guard transfer?.succeeded == true else { return transfer }

        CodexTriggerRegistry.markConfirmed(
            trigger,
            for: definition.id,
            app: app
        )

        return transfer
    }

    func removeAgentAssignment(for control: HardwareControl) {
        let kind = activeAgentKind
        let app = profiles.selectedProfile.automationApp == .claude ? AutomationApp.claude : .codex
        let acknowledgement = acknowledgementKey(app: app, control: control)
        completedAcknowledgementTasks[acknowledgement]?.cancel()
        completedAcknowledgementTasks[acknowledgement] = nil
        activeAgentThreads.removeAssignment(for: control)
        if profiles.selectedProfile.action(for: control).kind == kind {
            profiles.updateAction(.disabled, for: control)
        }
        refreshAgentLEDs()
    }

    func refreshAgentLEDs() {
        let statuses = Dictionary(uniqueKeysWithValues: HardwareControl.buttons.map { control in
            (control, activeAgentThreads.presentedStatus(for: control))
        })
        ledFeedback.showAgentStatuses(statuses, profile: profiles.selectedProfile)
    }

    private func handleAgentStatusUpdate(
        app: AutomationApp,
        control: HardwareControl,
        status: CodexAgentStatus,
        source: AgentStatusSource
    ) {
        let acknowledgement = acknowledgementKey(app: app, control: control)
        completedAcknowledgementTasks[acknowledgement]?.cancel()
        completedAcknowledgementTasks[acknowledgement] = nil
        let reaction = profiles.selectedProfile.reaction(for: LEDReactionEvent.event(for: status) ?? .agentIdle)
        diagnostics.recordStatus(
            threadID: (app == .codex ? codexThreads : claudeThreads).assignment(for: control)?.threadID ?? "unknown",
            source: source,
            status: status,
            ledReaction: reaction.effect.title
        )
        guard profiles.selectedProfile.automationApp == app else { return }
        if status == .completed || status == .failed || status == .interrupted {
            ledFeedback.showStatusTransition(status, for: control, profile: profiles.selectedProfile)
        }
    }
}
