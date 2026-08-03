import SwiftUI

struct GeneralView: View {
    let appState: AppState
    @State private var resultText: String?
    @State private var ledTestMessage: String?

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: Binding(
                    get: { appState.profiles.selectedProfile.name },
                    set: { appState.profiles.renameSelected(to: $0) }
                ))
                HStack {
                    Button("Neues Profil") { appState.profiles.newProfile() }
                    Button("Duplizieren") { appState.profiles.duplicateSelected() }
                    Button("Löschen", role: .destructive) { appState.profiles.deleteSelected() }
                }
            }
            Section("Diktat") {
                Picker("Diktierquelle", selection: Binding(
                    get: { appState.profiles.dictationSource },
                    set: { appState.profiles.dictationSource = $0 }
                )) {
                    ForEach(DictationSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                Text(appState.profiles.dictationSource.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Import & Export") {
                HStack {
                    Button("Aktuelles Profil exportieren") {
                        do { resultText = AppLanguage.text("Exportiert", "Exported") + ": \(try appState.profiles.exportSelectedProfile().path)" }
                        catch is CancellationError { }
                        catch { resultText = AppLanguage.text("Export fehlgeschlagen", "Export failed") + ": \(error.localizedDescription)" }
                    }
                    Button("Profil importieren") {
                        do { try appState.profiles.importProfile(); resultText = AppLanguage.text("Profil importiert.", "Profile imported.") }
                        catch is CancellationError { }
                        catch { resultText = AppLanguage.text("Import fehlgeschlagen", "Import failed") + ": \(error.localizedDescription)" }
                    }
                }
                if let resultText { Text(resultText).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Claude Live-Status") {
                Toggle("Live-Status für Claude-Agenten", isOn: Binding(
                    get: { appState.claudeAgentBridge.isHooksStatusEnabled },
                    set: { appState.claudeAgentBridge.setHooksStatusEnabled($0) }
                ))
                Text("Standardmäßig aus. Ohne Hooks liefert `claude agents --json` bereits Läuft und Bereit – aber weder „Eingabe erforderlich“ noch Abschluss oder Fehler. Aktivieren trägt fünf Hook-Einträge (Notification, Stop, SubagentStop, UserPromptSubmit, PreToolUse) in dein globales ~/.claude/settings.json ein, die nur eine Statuszeile pro Ereignis protokollieren – sie greifen nie in eine laufende Session ein und beeinflussen kein Ergebnis. Diese Hooks gelten für jede Claude-Code-Session auf diesem Rechner, nicht nur für am Pad zugewiesene Agenten. Vorhandene eigene Hooks für diese Ereignisse bleiben unverändert; Deaktivieren entfernt ausschließlich die von Agent Micro eingetragenen Einträge wieder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hooksStatusError = appState.claudeAgentBridge.hooksStatusError {
                    Text(hooksStatusError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Sicherheitsmodell") {
                Text("Agent Micro speichert Profile und Agent-Zuordnungen ausschließlich unter Application Support/Agent Micro. Der Event-Bridge-Service startet den lokalen Codex App Server über stdio und beobachtet Thread-, Turn-, Approval- und Nutzereingabe-Ereignisse. Approval-Antworten werden nur nach einem ausdrücklich zugewiesenen physischen Tastendruck gesendet, niemals automatisch. Codex- und Claude-Tasten öffnen ausschließlich vorhandene Desktop-Sitzungen; Mausautomation wird nicht verwendet.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("LED") {
                Text("Das 0x8890 bietet drei globale, dauerhaft gespeicherte LED-Patterns. Ihre Farben und Effekte sind von der Firmware des Pads vorgegeben; einzelne Tasten und freie RGB-Farben werden nicht unterstützt.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Aus") { setLEDMode(0) }
                    Button("Pattern 1 testen") { setLEDMode(1) }
                    Button("Pattern 2 testen") { setLEDMode(2) }
                }
                .disabled(!appState.device.state.isSupportedConnection || appState.device.isBusy)
                if let ledTestMessage {
                    Text(ledTestMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
    }

    private func setLEDMode(_ mode: Int) {
        let result = appState.device.setLEDMode(mode)
        ledTestMessage = result?.succeeded == true
            ? AppLanguage.text(
                "LED-Pattern \(mode) wurde auf dem Pad gesetzt.",
                "LED pattern \(mode) was set on the pad."
            )
            : AppLanguage.text(
                "LED-Pattern \(mode) konnte nicht gesetzt werden – Details stehen in Diagnose.",
                "LED pattern \(mode) could not be set — see Diagnostics for details."
            )
    }
}
