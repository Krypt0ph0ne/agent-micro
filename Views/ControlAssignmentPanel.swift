import SwiftUI

struct ControlAssignmentPanel: View {
    let appState: AppState
    @Binding var control: HardwareControl
    @State private var isPresentingTextSubmission = false
    @State private var isPresentingWizard = false
    @State private var isShowingActionPicker = false
    @State private var actionSearch = ""

    private var action: KeyboardAction {
        appState.profiles.selectedProfile.action(for: control)
    }

    private var definition: CodexActionDefinition? {
        guard let id = action.codexActionID else { return nil }
        return appState.activeCatalog.action(id: id)
    }

    private var assignableActions: [CodexActionDefinition] {
        appState.activeCatalog.actions.filter(\.isDirectlyAssignable)
    }

    private var filteredActions: [CodexActionDefinition] {
        let query = actionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return assignableActions }
        return assignableActions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.category.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
                || ($0.shortcut?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        if HardwareControl.encoderActions.contains(control) {
            EncoderAssignmentSection(appState: appState)
        } else if control == appState.profiles.layerSwitchControl {
            LayerSwitchAssignmentSection(appState: appState)
        } else {
            keyAssignmentBody
        }
    }

    private var keyAssignmentBody: some View {
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

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isShowingActionPicker.toggle()
                    actionSearch = ""
                }
            } label: {
                HStack {
                    Text(isShowingActionPicker ? "Auswahl schließen" : "Belegung ändern")
                    Spacer()
                    Image(systemName: isShowingActionPicker ? "chevron.up" : "chevron.down")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            if isShowingActionPicker {
                actionPicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let definition {
                Text(definition.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if !action.kind.isAgent {
                Text(action.kind == .disabled ? "Dieses Bedienelement löst nichts aus." : "Eigene oder profilinterne Belegung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            configurableReminder

            if action.kind.isAgent && !isShowingActionPicker {
                CodexAgentAssignmentView(appState: appState, control: control)
            }

            if !isShowingActionPicker {
                TapHoldSection(appState: appState, control: control)
            }

            Label("Klick links, Auswahl rechts.", systemImage: "cursorarrow.click")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $isPresentingTextSubmission) {
            TextSubmissionSheet { text in
                guard let textAction = KeyboardAction.textSubmission(text) else { return }
                appState.removeActiveAgentAssignment(for: control)
                appState.profiles.updateAction(textAction, for: control)
            }
        }
        .sheet(isPresented: $isPresentingWizard) {
            CodexAssignmentWizardView(appState: appState, control: control)
        }
        .onChange(of: control) { _, _ in
            isShowingActionPicker = false
            actionSearch = ""
        }
    }

    private var actionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("Agent", systemImage: "terminal.fill") { chooseAgent() }
                Button("Text", systemImage: "paperplane.fill") {
                    isPresentingTextSubmission = true
                    isShowingActionPicker = false
                }
                Button("Assistent", systemImage: "wand.and.stars") {
                    isPresentingWizard = true
                    isShowingActionPicker = false
                }
                .help("Konfigurierbare Codex-Aktion mit Trigger einrichten")
                Button("Aus", systemImage: "minus.circle") { chooseDisabled() }
            }
            .controlSize(.small)

            TextField("Aktion durchsuchen", text: $actionSearch)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 3) {
                    if filteredActions.isEmpty {
                        ContentUnavailableView("Keine Aktion gefunden", systemImage: "magnifyingglass")
                            .frame(height: 90)
                    } else {
                        ForEach(filteredActions) { item in
                            actionRow(item)
                        }
                    }
                }
            }
            .frame(height: 174)
        }
        .padding(9)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 9))
    }

    private func actionRow(_ item: CodexActionDefinition) -> some View {
        Button {
            appState.removeActiveAgentAssignment(for: control)
            appState.profiles.assignAction(id: item.id, from: appState.activeCatalog, to: control)
            isShowingActionPicker = false
            actionSearch = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(item.category)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if item.id == action.codexActionID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(item.id == action.codexActionID ? 0.65 : 0.22), in: RoundedRectangle(cornerRadius: 7))
    }

    private func chooseAgent() {
        appState.removeActiveAgentAssignment(for: control)
        appState.assignAgentPlaceholder(to: control)
        isShowingActionPicker = false
    }

    private func chooseDisabled() {
        appState.removeActiveAgentAssignment(for: control)
        appState.profiles.updateAction(.disabled, for: control)
        isShowingActionPicker = false
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
                Button("Anleitung") { isPresentingWizard = true }
                    .controlSize(.small)
            }
            .padding(10)
            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var infoMessage: String {
        "Wähle links eine Taste und danach eine Aktion. Ein Codex Agent wird lokal einem Thread oder Subagenten zugeordnet; dessen Live-Status steuert die LED. Die app-only Belegung muss einmal auf das Pad übertragen werden."
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
