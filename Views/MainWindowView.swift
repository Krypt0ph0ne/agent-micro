import SwiftUI

struct MainWindowView: View {
    private struct ActionFeedback: Identifiable {
        let id = UUID()
        let message: String
        let detail: String
        let succeeded: Bool
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    let appState: AppState
    @State private var actionFeedback: ActionFeedback?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var isPresentingLayerManagement = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DeviceEditorView(appState: appState)
                .padding(12)
                .frame(maxHeight: .infinity)
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

                Button { openWindow(id: "diagnostics") } label: {
                    Image(systemName: "stethoscope")
                }
                .help("Diagnose öffnen")

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Einstellungen öffnen")
            }
        }
        .task {
            appState.startHardwareServices()
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
            .frame(maxWidth: 130, alignment: .leading)
            .controlSize(.small)

            layerPicker

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

    /// Sits next to the Codex/Claude profile picker: which layer (alternate
    /// key/encoder assignment set) of the selected profile is active, plus
    /// access to add/rename/delete layers and their blink-confirmation color.
    private var layerPicker: some View {
        let profile = appState.profiles.selectedProfile
        return HStack(spacing: 2) {
            Picker(
                "Layer",
                selection: Binding(
                    get: { profile.activeLayerID },
                    set: { appState.profiles.selectLayer($0) }
                )
            ) {
                ForEach(profile.layers) { layer in
                    Text(layer.name).tag(layer.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 110, alignment: .leading)

            Button {
                isPresentingLayerManagement = true
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .buttonStyle(.borderless)
            .help("Layer verwalten")
        }
        .sheet(isPresented: $isPresentingLayerManagement) {
            LayerManagementView(appState: appState)
        }
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
            keyboardLayout: appState.profiles.keyboardLayout
        )
        showFeedback(
            message: result?.succeeded == true
                ? AppLanguage.text("Konfiguration gültig", "Configuration valid")
                : AppLanguage.text("Validierung fehlgeschlagen", "Validation failed"),
            detail: detail(for: result),
            succeeded: result?.succeeded == true
        )
    }

    private func upload() {
        guard appState.profiles.hasUnsyncedChanges else {
            showFeedback(
                message: AppLanguage.text("Aktuelles Setup bereits übertragen", "Current setup already transferred"),
                detail: AppLanguage.text(
                    "Auf dem Pad ist bereits die ausgewählte Profil- und Layer-Konfiguration aktiv.",
                    "The selected profile and layer configuration is already active on the pad."
                ),
                succeeded: true
            )
            return
        }

        let transfer = appState.transferCurrentConfiguration()
        let profileName = transfer?.profileName ?? AppLanguage.text("Profil", "Profile")
        let layerName = transfer?.layerName ?? AppLanguage.text("Layer", "Layer")
        showFeedback(
            message: transfer?.succeeded == true
                ? AppLanguage.text("\(profileName) · \(layerName) übertragen", "\(profileName) · \(layerName) transferred")
                : AppLanguage.text("Upload fehlgeschlagen", "Upload failed"),
            detail: transfer?.detail ?? AppLanguage.text(
                "Die Übertragung konnte nicht gestartet werden. Prüfe die Pad-Verbindung und versuche es erneut.",
                "The transfer could not be started. Check the pad connection and try again."
            ),
            succeeded: transfer?.succeeded == true
        )
    }

    private func showFeedback(message: String, detail: String, succeeded: Bool) {
        feedbackTask?.cancel()
        let feedback = ActionFeedback(
            message: message,
            detail: detail,
            succeeded: succeeded
        )
        actionFeedback = feedback
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, actionFeedback?.id == feedback.id else { return }
            actionFeedback = nil
        }
    }

    private func detail(for result: ProcessResult?) -> String {
        guard let result else {
            return AppLanguage.text(
                "Die lokale Vorprüfung hat einen Konfigurationsfehler gemeldet. Details stehen in Diagnose.",
                "The local pre-check reported a configuration error. Details are in Diagnostics."
            )
        }
        let parts = [result.launchError, result.stdout.nilIfEmpty, result.stderr.nilIfEmpty].compactMap { $0 }
        return parts.isEmpty
            ? AppLanguage.text("Befehl ohne zusätzliche Ausgabe beendet.", "Command finished without additional output.")
            : parts.joined(separator: "\n")
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
        .help(help ?? (connected
            ? AppLanguage.text("Verbunden", "Connected")
            : AppLanguage.text("Nicht verbunden", "Not connected")))
    }
}
