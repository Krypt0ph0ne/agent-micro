import SwiftUI

struct SettingsView: View {
    let appState: AppState
    @State private var resultText: String?
    @State private var showDiagnostics = false
    @AppStorage(CodexQuickAssignService.enabledDefaultsKey) private var quickAssignEnabled = true

    var body: some View {
        @Bindable var profiles = appState.profiles

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

            Section("Hintergrund") {
                Toggle(
                    "Bei Anmeldung starten",
                    isOn: Binding(
                        get: { appState.loginItem.isEnabled },
                        set: { appState.loginItem.setEnabled($0) }
                    )
                )
                Toggle("Halten ordnet bereits belegte Agent-Tasten neu zu", isOn: $quickAssignEnabled)

                Text("Gilt nur für Tasten, die schon einmal einem Codex-Thread zugeordnet wurden. Nutzt eine in Codex kopierte Sitzungs-ID aus der Zwischenablage, sonst den zuletzt aktiven Thread. CodexPad bleibt nach dem Schließen des Fensters im Menüleisten-Symbol aktiv, damit das auch ohne offenes Fenster funktioniert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

}
