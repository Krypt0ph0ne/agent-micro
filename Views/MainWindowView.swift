import SwiftUI

struct MainWindowView: View {
    private struct ActionFeedback: Identifiable {
        let id = UUID()
        let message: String
        let detail: String
        let succeeded: Bool
    }

    @Environment(\.scenePhase) private var scenePhase
    let appState: AppState
    @State private var showDiagnostics = false
    @State private var actionFeedback: ActionFeedback?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DeviceEditorView(appState: appState)
                .padding(14)
            Divider()
            actionBar
        }
        .background(.background)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { appState.refreshDevice() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Gerät erneut suchen")
                .disabled(appState.device.isBusy)

                Button { showDiagnostics = true } label: {
                    Image(systemName: "stethoscope")
                }
                .help("Diagnose öffnen")

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Einstellungen öffnen")
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(appState: appState)
                .frame(minWidth: 720, minHeight: 520)
        }
        .task {
            appState.refreshDevice()
            appState.startAgentBridges()
            appState.reasoningAutomation.refreshPermissions()
            appState.claudeReasoningAutomation.refreshPermissions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                appState.reasoningAutomation.refreshPermissions()
            appState.claudeReasoningAutomation.refreshPermissions()
            }
        }
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
            .frame(maxWidth: 180, alignment: .leading)
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
        .background(.bar)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            syncStatus
            Spacer()
            Button("Prüfen") { validate() }
                .disabled(appState.device.isBusy)
                .controlSize(.small)
            Button("Übertragen") { upload() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!appState.device.state.isSupportedConnection || appState.device.isBusy)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.bar)
    }

    @ViewBuilder
    private var syncStatus: some View {
        if appState.device.isBusy {
            ProgressView()
                .controlSize(.small)
            Text("Bitte warten …")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let actionFeedback {
            Label(
                actionFeedback.message,
                systemImage: actionFeedback.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(actionFeedback.succeeded ? .green : .red)
            .help(actionFeedback.detail)
        } else if appState.profiles.hasUnsyncedChanges {
            Label("Noch nicht übertragen", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Label("Lokal gespeichert", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private func validate() {
        let result = appState.device.validate(
            profile: appState.profiles.selectedProfile,
            keyboardLayout: appState.profiles.keyboardLayout,
            layerSwitchControl: appState.profiles.layerSwitchControl
        )
        showFeedback(
            message: result?.succeeded == true ? "Konfiguration gültig" : "Validierung fehlgeschlagen",
            result: result
        )
    }

    private func upload() {
        let result = appState.device.upload(
            profile: appState.profiles.selectedProfile,
            keyboardLayout: appState.profiles.keyboardLayout,
            layerSwitchControl: appState.profiles.layerSwitchControl
        )
        if result?.succeeded == true {
            appState.profiles.markSynchronized()
            // The upload leaves the configured idle state active. Reapplying
            // here immediately overlays any live agent status on top of it.
            appState.refreshAgentLEDs()
        }
        showFeedback(
            message: result?.succeeded == true ? "Übertragen" : "Upload fehlgeschlagen",
            result: result
        )
    }

    private func showFeedback(message: String, result: ProcessResult?) {
        feedbackTask?.cancel()
        let feedback = ActionFeedback(
            message: message,
            detail: detail(for: result),
            succeeded: result?.succeeded == true
        )
        actionFeedback = feedback
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, actionFeedback?.id == feedback.id else { return }
            actionFeedback = nil
        }
    }

    private func detail(for result: ProcessResult?) -> String {
        guard let result else { return "Die lokale Vorprüfung hat einen Konfigurationsfehler gemeldet. Details stehen in Diagnose." }
        let parts = [result.launchError, result.stdout.nilIfEmpty, result.stderr.nilIfEmpty].compactMap { $0 }
        return parts.isEmpty ? "Befehl ohne zusätzliche Ausgabe beendet." : parts.joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct ConnectionStatus: View {
    let title: String
    let connected: Bool
    var help: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .help(help ?? (connected ? "Verbunden" : "Nicht verbunden"))
    }
}
