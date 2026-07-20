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
            Section("Import & Export") {
                HStack {
                    Button("Aktuelles Profil exportieren") {
                        do { resultText = "Exportiert: \(try appState.profiles.exportSelectedProfile().path)" }
                        catch is CancellationError { }
                        catch { resultText = "Export fehlgeschlagen: \(error.localizedDescription)" }
                    }
                    Button("Profil importieren") {
                        do { try appState.profiles.importProfile(); resultText = "Profil importiert." }
                        catch is CancellationError { }
                        catch { resultText = "Import fehlgeschlagen: \(error.localizedDescription)" }
                    }
                }
                if let resultText { Text(resultText).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Sicherheitsmodell") {
                Text("CodexPad speichert Profile und Agent-Zuordnungen ausschließlich unter Application Support/CodexPad. Der Event-Bridge-Service startet den lokalen Codex App Server über stdio, beobachtet Thread-, Turn-, Approval- und Nutzereingabe-Ereignisse und beantwortet Approval-Anfragen niemals. Tastendrücke öffnen ausschließlich den offiziellen Codex-Thread-Link; Mausautomation wird nicht verwendet.")
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
            ? "LED-Pattern \(mode) wurde auf dem Pad gesetzt."
            : "LED-Pattern \(mode) konnte nicht gesetzt werden – Details stehen in Diagnose."
    }
}
