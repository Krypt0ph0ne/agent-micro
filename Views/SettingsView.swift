import SwiftUI

struct SettingsView: View {
    let appState: AppState
    @AppStorage(AppLanguage.defaultsKey) private var languageRawValue = AppLanguage.systemDefault.rawValue
    @State private var resultText: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var profiles = appState.profiles
        let language = AppLanguage(rawValue: languageRawValue) ?? .systemDefault

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                block {
                    SettingsGroup(title: language.text("Sprache & Region", "Language & region")) {
                        SettingsRow(label: language.text("Sprache", "Language")) {
                            Picker(
                                language.text("Sprache", "Language"),
                                selection: $languageRawValue
                            ) {
                                ForEach(AppLanguage.allCases) { candidate in
                                    Text(candidate.nativeTitle).tag(candidate.rawValue)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    caption(language.text(
                        "Die App-Sprache wird sofort geändert. Deine Sprache fehlt? Ergänze die zentralen Sprachtexte mit Codex oder einem anderen Coding-Agenten – Beiträge sind willkommen.",
                        "The app language changes immediately. Missing your language? Add it through the centralized language strings with Codex or another coding agent — contributions are welcome."
                    ))
                }

                block {
                    SettingsGroup(title: language.text("Profil", "Profile")) {
                        SettingsRow(label: language.text("Profil", "Profile")) {
                            Picker(language.text("Profil", "Profile"), selection: $profiles.selectedProfileID) {
                                ForEach(profiles.profiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider().padding(.leading, 12)
                        SettingsRow(label: language.text("Name", "Name")) {
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
                                Button(language.text("Neu", "New")) { profiles.newProfile() }
                                Button(language.text("Duplizieren", "Duplicate")) { profiles.duplicateSelected() }
                                Button(language.text("Löschen", "Delete"), role: .destructive) { profiles.deleteSelected() }
                                    .disabled(profiles.profiles.count <= 1)
                            }
                        }
                    }
                }

                block {
                    SettingsGroup(title: language.text("Tastaturlayout", "Keyboard layout")) {
                        SettingsRow {
                            Picker(language.text("Tastaturlayout", "Keyboard layout"), selection: $profiles.keyboardLayout) {
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
                    SettingsGroup(title: language.text("Gerät", "Device")) {
                        SettingsRow {
                            Text(language.text("Erkanntes USB-HID-Gerät", "Detected USB HID device"))
                            Spacer()
                            Button(language.text("Erneut suchen", "Scan again")) { appState.refreshDevice() }
                        }
                        Divider().padding(.leading, 12)
                        SettingsRow {
                            Text(language.text("Diagnose", "Diagnostics"))
                            Spacer()
                            Button(language.text("Öffnen", "Open")) { openWindow(id: "diagnostics") }
                        }
                    }
                    caption(language.text(
                        "Der Helper öffnet nur ein bestätigtes USB-HID-Gerät. Für die Entwicklung läuft die App absichtlich unsandboxed.",
                        "The helper opens only a verified USB HID device. The development build intentionally runs without an app sandbox."
                    ))
                }

                block {
                    SettingsGroup(title: language.text("Hintergrund", "Background")) {
                        SettingsRow {
                            Toggle(
                                language.text("Bei Anmeldung starten", "Launch at login"),
                                isOn: Binding(
                                    get: { appState.loginItem.isEnabled },
                                    set: { appState.loginItem.setEnabled($0) }
                                )
                            )
                        }
                    }
                    caption(language.text(
                        "Agent-Tasten verwenden fest Tippen zum Öffnen und Halten zum Neuzuordnen. Agent Micro bleibt nach dem Schließen des Fensters im Menüleisten-Symbol aktiv, damit das auch ohne offenes Fenster funktioniert.",
                        "Agent keys always use tap to open and hold to reassign. Agent Micro remains active in the menu bar after its window closes, so this also works without an open window."
                    ))
                }

                block {
                    SettingsGroup(title: language.text("Import & Export", "Import & export")) {
                        SettingsRow {
                            Spacer()
                            Button(language.text("Exportieren", "Export")) { exportProfile() }
                            Button(language.text("Importieren", "Import")) { importProfile() }
                        }
                    }
                    if let resultText {
                        caption(resultText)
                    }
                }

                caption(language.text(
                    "Profile und Agent-Zuordnungen bleiben lokal unter Application Support. Codex-Approvals (Befehl ausführen, Datei ändern) können beantwortet werden, indem du „Genehmigen“/„Ablehnen“ wie jede andere Aktion einer Taste zuweist (Belegungs-Panel); alle anderen Ereignisse werden nur beobachtet.",
                    "Profiles and agent assignments stay local in Application Support. Codex approvals (run a command, change a file) can be answered by assigning Approve/Decline to a key like any other action; all other events are observed only."
                ))
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
            resultText = AppLanguage.text("Exportiert", "Exported") + ": \(try appState.profiles.exportSelectedProfile().path)"
        } catch is CancellationError {
        } catch {
            resultText = AppLanguage.text("Export fehlgeschlagen", "Export failed") + ": \(error.localizedDescription)"
        }
    }

    private func importProfile() {
        do {
            try appState.profiles.importProfile()
            resultText = AppLanguage.text("Profil importiert.", "Profile imported.")
        } catch is CancellationError {
        } catch {
            resultText = AppLanguage.text("Import fehlgeschlagen", "Import failed") + ": \(error.localizedDescription)"
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
