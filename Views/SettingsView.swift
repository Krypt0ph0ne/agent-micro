import SwiftUI

struct SettingsView: View {
    let appState: AppState
    @State private var resultText: String?
    @State private var ledTestMessage: String?
    @State private var showDiagnostics = false

    var body: some View {
        @Bindable var profiles = appState.profiles
        @Bindable var automation = appState.reasoningAutomation

        Form {
            Section("Profil") {
                TextField(
                    "Name",
                    text: Binding(
                        get: { profiles.selectedProfile.name },
                        set: { profiles.renameSelected(to: $0) }
                    )
                )

                HStack {
                    Button("Neu") { profiles.newProfile() }
                        .frame(maxWidth: .infinity)
                    Button("Duplizieren") { profiles.duplicateSelected() }
                        .frame(maxWidth: .infinity)
                    Button("Löschen", role: .destructive) { profiles.deleteSelected() }
                        .frame(maxWidth: .infinity)
                }
            }

            Section("Tastaturlayout") {
                Picker("Tastaturlayout", selection: $profiles.keyboardLayout) {
                    ForEach(KeyboardLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(profiles.keyboardLayout.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Codex Reasoning · Drehrad") {
                Toggle(isOn: $automation.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drehradsteuerung aktiv")
                        Text("Drehen sendet F18/F19, Druck schaltet die Modellwahl")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    PermissionStatus(
                        title: "Input Monitoring",
                        isGranted: automation.hasInputMonitoringPermission
                    )
                    PermissionStatus(
                        title: "Accessibility",
                        isGranted: automation.hasAccessibilityPermission
                    )
                }

                HStack {
                    Button("− testen") { automation.perform(.decreaseEffort) }
                        .frame(maxWidth: .infinity)
                    Button("Picker") { automation.toggleModelPicker() }
                        .frame(maxWidth: .infinity)
                    Button("+ testen") { automation.perform(.increaseEffort) }
                        .frame(maxWidth: .infinity)
                }
                .disabled(!automation.isEnabled)

                if !automation.hasInputMonitoringPermission || !automation.hasAccessibilityPermission {
                    Button("Berechtigungen anfordern") { automation.requestPermissions() }
                }

                Text(automation.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gerät") {
                Text("Der Helper öffnet nur ein bestätigtes USB-HID-Gerät. Für die Entwicklung läuft die App absichtlich unsandboxed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Gerät erneut suchen") { appState.refreshDevice() }
                    Spacer()
                    Button("Diagnose öffnen") { showDiagnostics = true }
                }
            }

            Section("Hersteller-LED") {
                Text("Beim 0x1189:0x8890 stehen drei firmwareseitige, globale LED-Muster zur Verfügung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Aus") { setLEDMode(0) }
                    Button("Pattern 1") { setLEDMode(1) }
                    Button("Pattern 2") { setLEDMode(2) }
                }
                .disabled(!appState.device.state.isSupportedConnection || appState.device.isBusy)

                if let ledTestMessage {
                    Text(ledTestMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sicherheit") {
                Text("Profile und Agent-Zuordnungen bleiben lokal unter Application Support. Der Event-Bridge-Service beobachtet Ereignisse, beantwortet Approvals aber nie automatisch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Import & Export") {
                HStack {
                    Button("Exportieren") { exportProfile() }
                        .frame(maxWidth: .infinity)
                    Button("Importieren") { importProfile() }
                        .frame(maxWidth: .infinity)
                }

                if let resultText {
                    Text(resultText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .frame(width: 460, height: 560)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(appState: appState)
                .frame(minWidth: 720, minHeight: 520)
        }
    }

    private func exportProfile() {
        do {
            resultText = "Exportiert: \(try appState.profiles.exportSelectedProfile().path)"
        } catch is CancellationError {
        } catch {
            resultText = "Export fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func importProfile() {
        do {
            try appState.profiles.importProfile()
            resultText = "Profil importiert."
        } catch is CancellationError {
        } catch {
            resultText = "Import fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func setLEDMode(_ mode: Int) {
        let result = appState.device.setLEDMode(mode)
        ledTestMessage = result?.succeeded == true
            ? "LED-Pattern \(mode) wurde auf dem Pad gesetzt."
            : "LED-Pattern \(mode) konnte nicht gesetzt werden – Details stehen in Diagnose."
    }
}

private struct PermissionStatus: View {
    let title: String
    let isGranted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(isGranted ? "Erteilt" : "Fehlt")
                .foregroundStyle(isGranted ? Color.green : Color.orange)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}
