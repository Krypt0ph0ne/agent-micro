import SwiftUI

struct ControlAssignmentPanel: View {
    let appState: AppState
    @Binding var control: HardwareControl
    @State private var isPresentingTextSubmission = false

    private var action: KeyboardAction {
        appState.profiles.selectedProfile.action(for: control)
    }

    private var definition: CodexActionDefinition? {
        guard let id = action.codexActionID else { return nil }
        return appState.catalog.action(id: id)
    }

    private var categories: [String] {
        Array(Set(assignableActions.map(\.category))).sorted()
    }

    private var assignableActions: [CodexActionDefinition] {
        appState.catalog.actions.filter(\.isDirectlyAssignable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: control.icon)
                    .foregroundStyle(.tint)
                Text(control.shortTitle)
                    .font(.headline)
                ContextInfoButton(title: "Bedienelement belegen", message: infoMessage)
                Spacer()
                Menu {
                    ForEach(HardwareControl.allCases) { item in
                        Button(item.shortTitle) { control = item }
                    }
                } label: {
                    Image(systemName: "square.grid.3x2")
                }
                .menuStyle(.borderlessButton)
                .help("Anderes Bedienelement auswählen")
            }

            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.label)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(action.displayShortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Menu {
                if HardwareControl.buttons.contains(control) {
                    Button("Codex Agent …") {
                        appState.profiles.updateAction(
                            KeyboardAction(kind: .codexAgent, label: "Codex Agent auswählen", icon: "terminal.fill"),
                            for: control
                        )
                    }
                    Divider()
                }
                if HardwareControl.encoderActions.contains(control) {
                    Button("Codex-Drehradsteuerung") {
                        appState.profiles.updateAction(ProfileFactory.reasoningTriggerAction(for: control), for: control)
                    }
                    Divider()
                }
                ForEach(categories, id: \.self) { category in
                    Menu(category) {
                        ForEach(assignableActions.filter { $0.category == category }) { item in
                            Button {
                                appState.codexThreads.removeAssignment(for: control)
                                appState.profiles.assignCodexAction(id: item.id, to: control)
                            } label: {
                                if item.id == action.codexActionID {
                                    Label(item.title, systemImage: "checkmark")
                                } else {
                                    Text(item.title)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Text absenden …") {
                    isPresentingTextSubmission = true
                }
                Button("Deaktivieren") {
                    appState.codexThreads.removeAssignment(for: control)
                    appState.profiles.updateAction(.disabled, for: control)
                }
            } label: {
                HStack {
                    Text("Aktion auswählen")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let definition {
                Text(definition.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if action.kind != .codexAgent {
                Text(action.kind == .disabled ? "Dieses Bedienelement löst nichts aus." : "Eigene oder profilinterne Belegung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if action.kind == .codexAgent {
                CodexAgentAssignmentView(appState: appState, control: control)
            }

            if HardwareControl.encoderActions.contains(control) {
                Spacer(minLength: 0)
                Label("Direkt vom Pad gesendet", systemImage: "cable.connector")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Spacer(minLength: 0)
                Label("Klick links, Auswahl rechts.", systemImage: "cursorarrow.click")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $isPresentingTextSubmission) {
            TextSubmissionSheet { text in
                guard let textAction = KeyboardAction.textSubmission(text) else { return }
                appState.codexThreads.removeAssignment(for: control)
                appState.profiles.updateAction(textAction, for: control)
            }
        }
    }

    private var infoMessage: String {
        if HardwareControl.encoderActions.contains(control) {
            if control == .encoderPress {
                return "Der Encoder-Druck wird von CodexPad als Umschalter verarbeitet: einmal öffnet die Modellwahl, der nächste Druck schließt sie mit Escape. Nur diese Encoder-Aktion benötigt die laufende CodexPad-App."
            }
            return "Diese Drehrad-Geste wird direkt vom Pad gesendet. Links und rechts nutzen F18/F19 für den Reasoning-Aufwand."
        }
        return "Wähle links eine Taste und danach eine Aktion. Ein Codex Agent wird lokal einem Thread oder Subagenten zugeordnet; dessen Live-Status steuert die LED. Die app-only Belegung muss einmal auf das Pad übertragen werden."
    }

}

private struct TextSubmissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Yeet"

    let save: (String) -> Void

    private var isValid: Bool { TextSubmissionMacro.macro(for: text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Text absenden")
                .font(.title2.weight(.semibold))
            Text("Der Text wird als Tasteneingabe gesendet und mit Enter abgeschickt. Das Zielfeld muss dabei bereits aktiv sein.")
                .foregroundStyle(.secondary)
            TextField("Text", text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, value in
                    text = String(value.prefix(TextSubmissionMacro.maximumTextLength))
                }
            Text("Bis zu 4 Buchstaben oder Ziffern; Groß- und Kleinschreibung werden übernommen.")
                .font(.caption)
                .foregroundStyle(isValid ? Color.secondary : Color.red)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Zuweisen") {
                    save(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
