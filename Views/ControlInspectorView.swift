import SwiftUI

struct ControlInspectorView: View {
    let appState: AppState
    @Binding var control: HardwareControl
    @State private var testMessage: String?

    var body: some View {
        @Bindable var profileStore = appState.profiles
        let action = profileStore.actionBinding(for: control)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 9) {
                    Image(systemName: control.icon)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(control.title).font(.headline)
                        Text("Hardwareaktion").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                GroupBox("Darstellung") {
                    VStack(alignment: .leading, spacing: 9) {
                        TextField("Label", text: action.label)
                        TextField("SF Symbol", text: action.icon)
                    }
                    .textFieldStyle(.roundedBorder)
                }

                GroupBox("Aktion") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Typ", selection: action.kind) {
                            ForEach(ActionKind.allCases) { kind in Text(kind.title).tag(kind) }
                        }
                        .labelsHidden()

                        if action.wrappedValue.kind.isAppShortcut {
                            Picker("Aktion", selection: codexActionIDBinding(for: action)) {
                                Text("Auswählen").tag("")
                                ForEach(appState.activeCatalog.actions.filter(\.isDirectlyAssignable)) { entry in
                                    Text(entry.title).tag(entry.id)
                                }
                            }
                        }

                        if action.wrappedValue.kind != .disabled {
                            TextField("Geräteausdruck", text: macroBinding(for: action))
                                .textFieldStyle(.roundedBorder)
                            Text("Beispiele: `cmd-shift-p`, `f13`, `ctrl-a,ctrl-c`, `volumeup`, `wheel(-1)`.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if action.wrappedValue.kind.isAppDeepLink {
                            TextField("Deep Link", text: deepLinkBinding(for: action))
                                .textFieldStyle(.roundedBorder)
                            Text("Deep Links benötigen künftig einen bewusst aktivierten lokalen F13–F21-Listener; der direkte Geräteupload wird hierfür blockiert.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if action.wrappedValue.kind == .localCommand {
                            TextField("Lokaler Befehl", text: commandBinding(for: action))
                                .textFieldStyle(.roundedBorder)
                            Text("Nicht automatisch ausführbar. Eine sichtbare Bestätigung und ein lokaler Listener wären erforderlich.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                GroupBox("LED") {
                    Text(appState.device.currentDevice?.capabilities.supportsPerKeyLED == true ? "Individuelle LED verfügbar" : "Dieses Modell bestätigt keine individuelle Tastenfarbe. Globaler Modus steht im Gerätebereich.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Test") { testAction() }
                    Button("Zurücksetzen", role: .destructive) {
                        profileStore.updateAction(.disabled, for: control)
                    }
                }
                if let testMessage {
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
    }

    private func macroBinding(for action: Binding<KeyboardAction>) -> Binding<String> {
        Binding(get: { action.wrappedValue.deviceMacro ?? "" }, set: { action.wrappedValue.deviceMacro = $0.isEmpty ? nil : $0 })
    }

    private func deepLinkBinding(for action: Binding<KeyboardAction>) -> Binding<String> {
        Binding(get: { action.wrappedValue.deepLink ?? "" }, set: { action.wrappedValue.deepLink = $0.isEmpty ? nil : $0 })
    }

    private func commandBinding(for action: Binding<KeyboardAction>) -> Binding<String> {
        Binding(get: { action.wrappedValue.command ?? "" }, set: { action.wrappedValue.command = $0.isEmpty ? nil : $0 })
    }

    private func codexActionIDBinding(for action: Binding<KeyboardAction>) -> Binding<String> {
        Binding(
            get: { action.wrappedValue.codexActionID ?? "" },
            set: { id in
                guard !id.isEmpty, let definition = appState.activeCatalog.action(id: id) else { return }
                guard let mapped = appState.activeCatalog.keyboardAction(id: definition.id) else { return }
                action.wrappedValue = mapped
            }
        )
    }

    private func testAction() {
        let result = appState.device.validate(
            profile: appState.profiles.selectedProfile,
            keyboardLayout: appState.profiles.keyboardLayout
        )
        testMessage = result?.succeeded == true ? "Geräteausdruck ist valide." : "Validierung fehlgeschlagen – Details in Diagnose."
    }
}
