import SwiftUI

/// Simplified, at-a-glance version of the app shown from the menu bar status
/// item: the same mini pad rendering as the main window (`DeviceCanvasView`,
/// so the layout is immediately recognizable), plus quick Codex-agent
/// reassignment and a curated shortcut library for the selected key — all
/// inline in the popover itself, no extra window. Everything else (LEDs,
/// profile management, diagnostics) stays in the main window, reachable via
/// the gear button.
struct MenuBarPopoverView: View {
    let appState: AppState
    let onOpenMainApp: () -> Void
    let onQuit: () -> Void

    @State private var selectedControl: HardwareControl = .key1
    @State private var actionFeedback: String?
    @State private var feedbackIsError = false
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 12) {
                DeviceCanvasView(
                    profile: appState.profiles.selectedProfile,
                    selectedControl: $selectedControl,
                    compact: true,
                    agentTitleForControl: {
                        appState.activeAgentThreads.assignment(for: $0)?.threadTitle
                    }
                )

                MenuBarSelectedControlPanel(appState: appState, control: $selectedControl)
            }
            .padding(12)
            Divider()
            footer
        }
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        @Bindable var profiles = appState.profiles
        return HStack(spacing: 10) {
            Picker("Profil", selection: $profiles.selectedProfileID) {
                ForEach(profiles.visibleProfiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            let profile = appState.profiles.selectedProfile
            Picker("Layer", selection: Binding(
                get: { profile.activeLayerID },
                set: { appState.profiles.selectLayer($0) }
            )) {
                ForEach(profile.layers) { layer in
                    Text(layer.name).tag(layer.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            Spacer(minLength: 8)

            ConnectionStatus(
                title: "Codex",
                connected: appState.codexThreads.connectionState.isConnected,
                help: appState.codexThreads.connectionError ?? appState.codexThreads.connectionState.title
            )
            ConnectionStatus(
                title: "Claude",
                connected: appState.claudeThreads.connectionState.isConnected,
                help: appState.claudeThreads.connectionError ?? appState.claudeThreads.connectionState.title
            )
            ConnectionStatus(title: "Pad", connected: appState.device.state.isSupportedConnection)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            syncStatus
            Spacer()
            Button("Übertragen") { upload() }
                .controlSize(.small)
                .disabled(!appState.device.state.isSupportedConnection || appState.device.isBusy)

            Button(action: onOpenMainApp) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Agent Micro öffnen")

            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Beenden")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var syncStatus: some View {
        if appState.device.isBusy {
            ProgressView()
                .controlSize(.small)
        } else if let actionFeedback {
            Label(actionFeedback, systemImage: feedbackIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(feedbackIsError ? .red : .green)
        } else if appState.profiles.hasUnsyncedChanges {
            Label("Nicht übertragen", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Label("Lokal synchron", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private func upload() {
        guard appState.profiles.hasUnsyncedChanges else {
            showFeedback(
                message: AppLanguage.text("Aktuelles Setup bereits übertragen", "Current setup already transferred"),
                succeeded: true
            )
            return
        }

        let result = appState.transferCurrentConfiguration()
        showFeedback(
            message: result?.succeeded == true
                ? AppLanguage.text("Übertragen", "Transferred")
                : AppLanguage.text("Fehlgeschlagen", "Failed"),
            succeeded: result?.succeeded == true
        )
    }

    private func showFeedback(message: String, succeeded: Bool) {
        feedbackTask?.cancel()
        actionFeedback = message
        feedbackIsError = !succeeded
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            actionFeedback = nil
        }
    }
}

/// Detail panel for the key/encoder currently selected on the mini pad
/// above. Buttons bound to a Codex agent get a quick "reassign to another
/// active thread" menu; the tap (and, if enabled, hold) action can be
/// changed inline against a curated library of shortcuts that already work
/// in Codex without extra setup — tapping "Ändern" expands the picker right
/// here, picking an entry collapses it again.
private struct MenuBarSelectedControlPanel: View {
    private enum EditTarget: Equatable { case tap, hold }

    let appState: AppState
    @Binding var control: HardwareControl
    @State private var editing: EditTarget?
    @State private var search = ""
    @State private var isPresentingActionSheet = false
    @State private var isPresentingHoldActionSheet = false

    private static let activeRecencyWindow: TimeInterval = 24 * 60 * 60
    private static let activeCap = 20

    private var profile: MacropadProfile { appState.profiles.selectedProfile }
    private var binding: ControlBinding { profile.binding(for: control) }
    private var action: KeyboardAction { binding.action }

    private var assignment: AgentKeyAssignment? { appState.activeAgentThreads.assignment(for: control) }
    private var status: CodexAgentStatus { appState.activeAgentThreads.status(for: control) }

    private var activeThreads: [CodexThreadDescriptor] {
        let threads = appState.activeAgentThreads.threads
        let cutoff = Date().addingTimeInterval(-Self.activeRecencyWindow)
        let running = threads.filter { $0.status == .running || $0.status == .needsAttention }
        let recent = threads.filter { $0.status != .running && $0.status != .needsAttention && $0.updatedAt >= cutoff }
        return Array((running + recent).prefix(Self.activeCap))
    }

    /// Already-working shortcuts only: a fixed keybinding Codex listens for
    /// out of the box, no extra "bind this trigger in Codex" step required.
    private var readyActions: [CodexActionDefinition] {
        appState.activeCatalog.actions.filter { $0.execution == .keyboardShortcut && $0.deviceMacro != nil }
    }

    private func filteredActions(forHold: Bool) -> [CodexActionDefinition] {
        let base = forHold ? readyActions.filter { KeystrokeSynthesizer.canSynthesize($0.deviceMacro) } : readyActions
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if HardwareControl.encoderActions.contains(control) {
                encoderRow
            } else {
                VStack(spacing: 8) {
                    keyRow
                    if binding.isTapHold {
                        holdRow
                    }
                }
            }
        }
        .onChange(of: control) { _, _ in collapse() }
        .sheet(isPresented: $isPresentingActionSheet) {
            ActionSelectionSheet(appState: appState, control: control, context: .tap)
        }
        .sheet(isPresented: $isPresentingHoldActionSheet) {
            ActionSelectionSheet(appState: appState, control: control, context: .hold)
        }
    }

    private var keyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: control.icon)
                .foregroundStyle(.tint)
                .frame(width: 20)
            if action.kind.isAgent {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
            let keyLabel = action.kind.isAgent
                ? (assignment?.threadTitle ?? AppLanguage.text("Kein Agent zugeordnet", "No agent assigned"))
                : action.displayLabel
            Text(keyLabel)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .help(keyLabel)
            if action.kind.isAgent, assignment != nil,
               appState.activeAgentThreads.liveStatusAvailability == .sessionListOnly {
                Text(appState.activeAgentThreads.liveStatusAvailability.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(appState.activeAgentThreads.liveStatusAvailability.detail)
            }
            Spacer(minLength: 4)
            if action.kind.isAgent {
                reassignMenu
            }
            Button("Belegen") { isPresentingActionSheet = true }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private var holdRow: some View {
        HStack(spacing: 8) {
            Image(systemName: binding.holdAction?.icon ?? "hand.raised")
                .foregroundStyle(.tint)
                .frame(width: 20)
            let holdLabel = binding.holdAction?.displayLabel ?? "–"
            Text(AppLanguage.text("Halten: \(holdLabel)", "Hold: \(holdLabel)"))
                .font(.callout)
                .lineLimit(1)
                .help(AppLanguage.text("Halten: \(holdLabel)", "Hold: \(holdLabel)"))
            Spacer(minLength: 4)
            Button("Belegen") { isPresentingHoldActionSheet = true }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private func actionLibrary(forHold: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !forHold {
                HStack(spacing: 6) {
                    Button("Agent") { chooseAgent(); collapse() }
                    Button("Aus") { chooseDisabled(); collapse() }
                }
                .controlSize(.small)
            }

            TextField("Shortcut durchsuchen", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            let items = filteredActions(forHold: forHold)
            ScrollView {
                LazyVStack(spacing: 3) {
                    if items.isEmpty {
                        Text("Keine Aktion gefunden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: 60)
                    } else {
                        ForEach(items) { item in
                            libraryRow(item, forHold: forHold)
                        }
                    }
                }
            }
            .frame(height: 140)
        }
        .padding(8)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    private func libraryRow(_ item: CodexActionDefinition, forHold: Bool) -> some View {
        let currentID = forHold ? binding.holdAction?.codexActionID : action.codexActionID
        return Button {
            if forHold {
                appState.profiles.setHoldAction(
                    appState.activeCatalog.keyboardAction(id: item.id),
                    thresholdMilliseconds: binding.resolvedHoldThresholdMilliseconds,
                    for: control
                )
            } else {
                appState.removeActiveAgentAssignment(for: control)
                appState.profiles.assignAction(id: item.id, from: appState.activeCatalog, to: control)
            }
            collapse()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon).frame(width: 18).foregroundStyle(.tint)
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .help(item.title)
                Spacer(minLength: 4)
                if let shortcut = item.shortcut {
                    Text(shortcut).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                if item.id == currentID {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(item.id == currentID ? 0.6 : 0.18), in: RoundedRectangle(cornerRadius: 6))
    }

    private func collapse() {
        editing = nil
        search = ""
    }

    private func chooseAgent() {
        appState.removeActiveAgentAssignment(for: control)
        appState.assignAgentPlaceholder(to: control)
    }

    private func chooseDisabled() {
        appState.removeActiveAgentAssignment(for: control)
        appState.profiles.updateAction(.disabled, for: control)
    }

    private var reassignMenu: some View {
        Menu {
            if assignment != nil {
                Button(role: .destructive) {
                    appState.removeAgentAssignment(for: control)
                } label: {
                    Label("Zuordnung entfernen", systemImage: "trash")
                }
                Divider()
            }
            if activeThreads.isEmpty {
                Text("Keine aktiven Threads")
            } else {
                ForEach(activeThreads) { thread in
                    Button {
                        appState.assignAgentThread(thread, to: control)
                    } label: {
                        if assignment?.threadID == thread.id {
                            Label(thread.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(thread.displayTitle)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Anderen Thread zuweisen")
    }

    private var encoderRow: some View {
        let automation = appState.activeReasoningAutomation
        let isEnabled = Binding(get: { automation.isEnabled }, set: { automation.isEnabled = $0 })
        return HStack(spacing: 8) {
            Image(systemName: "dial.medium")
                .foregroundStyle(.tint)
                .frame(width: 20)
            let encoderLabel = automation.isEnabled
                ? AppLanguage.text("Drehrad · Reasoning-Gesten aktiv", "Dial · Reasoning gestures active")
                : AppLanguage.text("Drehrad · Deaktiviert", "Dial · Disabled")
            Text(encoderLabel)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .help(encoderLabel)
            Spacer(minLength: 4)
            Toggle("", isOn: isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Mirrors the LED exactly — see `CodexAgentAssignmentView.statusColor`.
    private var statusColor: Color {
        switch status {
        case .unassigned: return .secondary
        case .idle: return .white
        case .running: return .blue
        case .needsAttention: return .orange
        case .completed: return .green
        case .failed: return .red
        case .interrupted: return .purple
        }
    }
}
