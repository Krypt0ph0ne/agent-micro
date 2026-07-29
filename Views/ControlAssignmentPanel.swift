import SwiftUI

struct ControlAssignmentPanel: View {
    let appState: AppState
    @Binding var control: HardwareControl
    @State private var isPresentingActionSheet = false
    @State private var setupAction: CodexActionDefinition?

    private var action: KeyboardAction {
        appState.profiles.selectedProfile.action(for: control)
    }

    private var definition: CodexActionDefinition? {
        guard let id = action.codexActionID else { return nil }
        return appState.activeCatalog.action(id: id)
    }

    var body: some View {
        if HardwareControl.encoderActions.contains(control) {
            EncoderAssignmentSection(appState: appState)
        } else {
            keyAssignmentBody
        }
    }

    private var keyAssignmentBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: control.icon)
                    .foregroundStyle(.tint)
                Text(control.shortTitle)
                    .font(.headline)
                ContextInfoButton(title: "Bedienelement belegen", message: infoMessage)
                Spacer()
                Menu {
                    ForEach(HardwareControl.allCases) { item in
                        Button(item.shortTitle) { withoutAnimation { control = item } }
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
                    Text(action.displayLabel)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(action.displayShortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let definition {
                    ContextInfoButton(
                        title: definition.title,
                        message: definition.description
                    )
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                isPresentingActionSheet = true
            } label: {
                HStack {
                    Text("Belegung ändern")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            if definition == nil, !action.kind.isAgent {
                Text(action.kind == .disabled ? "Dieses Bedienelement löst nichts aus." : "Eigene oder profilinterne Belegung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            configurableReminder

            if action.kind.isAgent {
                CodexAgentAssignmentView(appState: appState, control: control)
            } else {
                TapHoldSection(appState: appState, control: control)
            }

            Text("Auswahl am Pad oben · Bearbeitung hier darunter")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $isPresentingActionSheet) {
            ActionSelectionSheet(appState: appState, control: control, context: .tap)
        }
        .sheet(item: $setupAction) { definition in
            CodexAssignmentWizardView(
                appState: appState,
                control: control,
                initialAction: definition
            )
        }
    }

    /// When a wizard-configured Codex action is bound, remind the user that the
    /// trigger still has to be assigned inside Codex once.
    @ViewBuilder
    private var configurableReminder: some View {
        if let definition, definition.execution == .configurableShortcut,
           let macro = action.deviceMacro, !macro.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("In Codex zuweisen: \(CodexTriggerPool.displayLabel(for: macro))")
                        .font(.caption.weight(.semibold))
                    Text("Codex › Settings › Keyboard Shortcuts › „\(definition.title)“. Danach übertragen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Anleitung") { setupAction = definition }
                    .controlSize(.small)
            }
            .padding(10)
            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var infoMessage: String {
        "Wähle oben eine Taste und danach eine Aktion. Agent-Tasten werden direkt am Pad zugewiesen: Taste halten, mit dem Drehrad einen Chat wählen und loslassen. Der Live-Status steuert die LED. Änderungen müssen einmal auf das Pad übertragen werden."
    }

}

struct TextSubmissionSheet: View {
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

/// Picks how a "Layer wechseln" action assigned to this key resolves its
/// target layer — see `LayerSwitchMode`.
struct LayerSwitchModePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode: LayerSwitchMode = .cycle

    let save: (LayerSwitchMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Layer wechseln")
                .font(.title2.weight(.semibold))
            Text("Wechselt zwischen den Layern des aktuell aktiven Profils. Die Layer selbst legst du im Licht-/Belegungsbereich neben der Profilauswahl an.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(LayerSwitchMode.allCases) { candidate in
                    Button {
                        mode = candidate
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: mode == candidate ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(mode == candidate ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title).font(.body.weight(.medium))
                                Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Zuweisen") {
                    save(mode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
