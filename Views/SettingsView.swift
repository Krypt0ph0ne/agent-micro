import SwiftUI

struct SettingsView: View {
    let appState: AppState
    @State private var resultText: String?
    @AppStorage(CodexQuickAssignService.enabledDefaultsKey) private var quickAssignEnabled = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var profiles = appState.profiles

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                block {
                    SettingsGroup(title: "Profil") {
                        SettingsRow(label: "Profil") {
                            Picker("Profil", selection: $profiles.selectedProfileID) {
                                ForEach(profiles.profiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider().padding(.leading, 12)
                        SettingsRow(label: "Name") {
                            TextField(
                                "",
                                text: Binding(
                                    get: { profiles.selectedProfile.name },
                                    set: { profiles.renameSelected(to: $0) }
                                )
                            )
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                        }
                        Divider().padding(.leading, 12)
                        SettingsRow {
                            HStack(spacing: 8) {
                                Spacer()
                                Button("Neu") { profiles.newProfile() }
                                Button("Duplizieren") { profiles.duplicateSelected() }
                                Button("Löschen", role: .destructive) { profiles.deleteSelected() }
                                    .disabled(profiles.profiles.count <= 1)
                            }
                        }
                    }
                }

                block {
                    SettingsGroup(title: "Tastaturlayout") {
                        SettingsRow {
                            Picker("Tastaturlayout", selection: $profiles.keyboardLayout) {
                                ForEach(KeyboardLayout.allCases) { layout in
                                    Text(layout.title).tag(layout)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                    }
                    caption(profiles.keyboardLayout.detail)
                }

                block {
                    SettingsGroup(title: "Gerät") {
                        SettingsRow {
                            Text("Erkanntes USB-HID-Gerät")
                            Spacer()
                            Button("Erneut suchen") { appState.refreshDevice() }
                        }
                        Divider().padding(.leading, 12)
                        SettingsRow {
                            Text("Diagnose")
                            Spacer()
                            Button("Öffnen") { openWindow(id: "diagnostics") }
                        }
                    }
                    caption("Der Helper öffnet nur ein bestätigtes USB-HID-Gerät. Für die Entwicklung läuft die App absichtlich unsandboxed.")
                }

                block {
                    SettingsGroup(title: "Hintergrund") {
                        SettingsRow {
                            Toggle(
                                "Bei Anmeldung starten",
                                isOn: Binding(
                                    get: { appState.loginItem.isEnabled },
                                    set: { appState.loginItem.setEnabled($0) }
                                )
                            )
                        }
                        Divider().padding(.leading, 12)
                        SettingsRow {
                            Toggle("Halten ordnet bereits belegte Agent-Tasten neu zu", isOn: $quickAssignEnabled)
                        }
                    }
                    caption("Gilt nur für Tasten, die schon einmal einem Codex-Thread zugeordnet wurden. Nutzt eine in Codex kopierte Sitzungs-ID aus der Zwischenablage, sonst den zuletzt aktiven Thread. Agent Micro bleibt nach dem Schließen des Fensters im Menüleisten-Symbol aktiv, damit das auch ohne offenes Fenster funktioniert.")
                }

                block {
                    SettingsGroup(title: "Import & Export") {
                        SettingsRow {
                            Spacer()
                            Button("Exportieren") { exportProfile() }
                            Button("Importieren") { importProfile() }
                        }
                    }
                    if let resultText {
                        caption(resultText)
                    }
                }

                caption("Profile und Agent-Zuordnungen bleiben lokal unter Application Support. Codex-Approvals (Befehl ausführen, Datei ändern) können beantwortet werden, indem du „Genehmigen“/„Ablehnen“ wie jede andere Aktion einer Taste zuweist (Belegungs-Panel); alle anderen Ereignisse werden nur beobachtet.")
            }
            .padding(20)
        }
        .frame(width: 460, height: 600)
    }

    private func block(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .textSelection(.enabled)
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

/// A rounded, titled container that mirrors macOS System Settings groups —
/// a small secondary-style header above a card of divided rows.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// A single row inside a `SettingsGroup`, sized like a System Settings list row.
private struct SettingsRow<Content: View>: View {
    var label: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            if let label {
                Text(label)
                Spacer()
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
