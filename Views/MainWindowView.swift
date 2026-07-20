import SwiftUI

struct MainWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    let appState: AppState
    @State private var showDiagnostics = false
    @State private var showUploadConfirmation = false
    @State private var showResult = false
    @State private var resultTitle = ""
    @State private var resultDetail = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DeviceEditorView(appState: appState)
                .padding(12)
            Divider()
            actionBar
        }
        .background(.background)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(appState: appState)
                .frame(minWidth: 720, minHeight: 520)
        }
        .alert("Konfiguration auf Gerät übertragen?", isPresented: $showUploadConfirmation) {
            Button("Abbrechen", role: .cancel) {}
            Button("Validieren und übertragen") { upload() }
        } message: { Text(uploadSummary) }
        .alert(resultTitle, isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: { Text(resultDetail) }
        .task {
            appState.refreshDevice()
            appState.startCodexBridge()
            appState.reasoningAutomation.refreshPermissions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                appState.reasoningAutomation.refreshPermissions()
            }
        }
    }

    private var header: some View {
        @Bindable var profiles = appState.profiles
        return HStack(spacing: 8) {
            Label("Profil", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
            Picker("Profil", selection: $profiles.selectedProfileID) {
                ForEach(profiles.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .frame(width: 155)
            .controlSize(.small)
            ContextInfoButton(
                title: "Profile",
                message: "Ein Profil enthält alle sechs Tasten und die drei Drehrad-Gesten. Jede Änderung wird sofort lokal gespeichert; erst „Übertragen“ schreibt sie auf das Gerät."
            )

            Picker("Tastaturlayout", selection: $profiles.keyboardLayout) {
                ForEach(KeyboardLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .frame(width: 124)
            .controlSize(.small)
            .help("HID-Zeichenlayout: \(profiles.keyboardLayout.detail)")

            Spacer(minLength: 8)

            Label(
                appState.codexThreads.connectionState.isConnected ? "Codex verbunden" : "Codex getrennt",
                systemImage: appState.codexThreads.connectionState.isConnected ? "bolt.horizontal.circle.fill" : "bolt.slash.circle"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(appState.codexThreads.connectionState.isConnected ? .green : .secondary)
            .help(appState.codexThreads.connectionError ?? appState.codexThreads.connectionState.title)

            DeviceConnectionBadge(appState: appState)
            ContextInfoButton(
                title: "Geräteverbindung",
                message: "CodexPad erkennt sowohl die Herstellerfirmware 0x1189:0x8890 als auch unsere bestätigte CH552-Firmware 0x4249:0x4287. Die Suche verändert keine Belegung."
            )
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
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.bar)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            syncStatus
            ContextInfoButton(
                title: "Prüfen und Übertragen",
                message: "„Prüfen“ validiert nur die lokale Konfiguration. „Übertragen“ validiert erneut, schreibt sie auf das Pad und fragt vorher zur Sicherheit nach."
            )
            Spacer()
            Button("Prüfen") { validate() }
                .disabled(appState.device.isBusy)
                .controlSize(.small)
            Button("Übertragen") { showUploadConfirmation = true }
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

    private var uploadSummary: String {
        let profile = appState.profiles.selectedProfile
        if appState.device.currentDevice?.isCodexPadFirmware == true {
            return "„\(profile.name)“ wird validiert. Danach sendet CodexPad neun Belegungen und sechs individuelle RGB-Einstellungen live an die bestätigte Firmware 0x4249:0x4287. Nach dem Aus- und Einstecken muss das Profil erneut übertragen werden."
        }
        return "„\(profile.name)“ wird vor dem Upload validiert und anschließend ausschließlich auf das bestätigte Herstellergerät 0x1189:0x8890 geschrieben."
    }

    private func validate() {
        let result = appState.device.validate(
            profile: appState.profiles.selectedProfile,
            keyboardLayout: appState.profiles.keyboardLayout
        )
        resultTitle = result?.succeeded == true ? "Konfiguration gültig" : "Validierung fehlgeschlagen"
        resultDetail = detail(for: result)
        showResult = true
    }

    private func upload() {
        let result = appState.device.upload(
            profile: appState.profiles.selectedProfile,
            keyboardLayout: appState.profiles.keyboardLayout
        )
        if result?.succeeded == true { appState.profiles.markSynchronized() }
        resultTitle = result?.succeeded == true ? "Transport erfolgreich – Eingabe noch prüfen" : "Upload fehlgeschlagen"
        resultDetail = detail(for: result)
        showResult = true
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

private struct DeviceConnectionBadge: View {
    let appState: AppState

    var body: some View {
        let connected = appState.device.state.isSupportedConnection
        Label(connected ? "Verbunden" : "Nicht verbunden", systemImage: connected ? "circle.fill" : "circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(connected ? .green : .secondary)
            .lineLimit(1)
    }
}
