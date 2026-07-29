import SwiftUI

/// Shared action chooser for the main editor and the menu-bar popover.  The
/// context is explicit because a hold cannot safely receive every action that
/// a normal tap can trigger.
struct ActionSelectionSheet: View {
    enum Context { case tap, hold }

    private var contextTitle: String {
        context == .tap ? AppLanguage.text("Tippen", "Tap") : AppLanguage.text("Halten", "Hold")
    }

    let appState: AppState
    let control: HardwareControl
    let context: Context
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showingText = false
    @State private var wizardAction: CodexActionDefinition?
    @State private var showingLayer = false

    private var catalog: CodexActionCatalog { appState.activeCatalog }
    private var actions: [CodexActionDefinition] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.actions.filter {
            needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle)
                || $0.category.localizedCaseInsensitiveContains(needle)
                || $0.description.localizedCaseInsensitiveContains(needle)
        }
    }
    private var categories: [String] { Array(Set(actions.map(\.category))).sorted() }
    private var appName: String {
        appState.profiles.selectedProfile.automationApp?.displayName ?? "Agent Micro"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppLanguage.text("Aktion auswählen · \(contextTitle)", "Select action · \(contextTitle)")).font(.title3.weight(.semibold))
                Text(appName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.14), in: Capsule())
                Spacer()
                Button("Abbrechen") { dismiss() }
            }
            Text(context == .tap
                 ? "Der Katalog gilt für \(appName). Fehlende App-Aktionen kannst du direkt in der jeweiligen Zeile einrichten."
                 : "Der Katalog gilt für \(appName). Halten verwendet einen eigenen, lokal ausgeführten Slot.")
                .font(.caption).foregroundStyle(.secondary)

            specialActions
            TextField("Aktion suchen", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(categories, id: \.self) { category in
                    Section(category) {
                        ForEach(actions.filter { $0.category == category }) { action in
                            actionRow(action)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 610)
        .sheet(isPresented: $showingText) {
            TextSubmissionSheet { text in
                guard let action = KeyboardAction.textSubmission(text) else { return }
                apply(action)
            }
        }
        .sheet(item: $wizardAction) { action in
            CodexAssignmentWizardView(
                appState: appState,
                control: control,
                slot: context == .hold ? .hold : .tap,
                initialAction: action
            )
        }
        .sheet(isPresented: $showingLayer) {
            LayerSwitchModePickerSheet { mode in apply(.layerSwitch(mode: mode)) }
        }
    }

    private var specialActions: some View {
        HStack(spacing: 8) {
            special(AppLanguage.text("Agent", "Agent"), icon: "terminal.fill", unavailableForHold: true) { appState.assignAgentPlaceholder(to: control); dismiss() }
            special(AppLanguage.text("Text", "Text"), icon: "text.cursor", unavailableForHold: true) { showingText = true }
            special(AppLanguage.text("Layer", "Layer"), icon: "square.stack.3d.up", unavailableForHold: true) { showingLayer = true }
            special(AppLanguage.text("Profil", "Profile"), icon: "arrow.left.arrow.right", unavailableForHold: true) { apply(.profileSwitch) }
            special(AppLanguage.text("Deaktivieren", "Disable"), icon: "minus.circle") { apply(.disabled) }
        }
        .controlSize(.small)
    }

    private func special(_ title: String, icon: String, unavailableForHold: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .disabled(context == .hold && unavailableForHold)
    }

    private func isImmediatelyAssignable(_ action: CodexActionDefinition) -> Bool {
        action.isDirectlyAssignable && (context == .tap || KeystrokeSynthesizer.canSynthesize(action.deviceMacro))
    }

    private func actionRow(_ action: CodexActionDefinition) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .frame(width: 20)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(action.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ContextInfoButton(title: action.title, message: action.description)

            if action.execution == .configurableShortcut {
                if let configured = configuredAction(for: action.id) {
                    Text(configured.displayShortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("Auswählen") {
                        apply(configured)
                    }
                    .controlSize(.small)
                } else {
                    Text("Nicht eingerichtet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Einrichten") {
                        wizardAction = action
                    }
                    .controlSize(.small)
                }
            } else if isImmediatelyAssignable(action) {
                if let shortcut = action.shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button("Auswählen") {
                    choose(action)
                }
                .controlSize(.small)
            } else {
                Text("Nicht verfügbar")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(action.availabilityNote ?? action.execution.title)
            }
        }
        .padding(.vertical, 3)
    }

    private func configuredAction(for actionID: String) -> KeyboardAction? {
        appState.profiles.selectedProfile.layers
            .lazy
            .flatMap(\.controls)
            .flatMap { binding in [binding.action, binding.holdAction].compactMap { $0 } }
            .first { $0.codexActionID == actionID && $0.deviceMacro?.isEmpty == false }
    }

    private func choose(_ definition: CodexActionDefinition) {
        guard isImmediatelyAssignable(definition), let action = catalog.keyboardAction(id: definition.id) else { return }
        apply(action)
    }

    private func apply(_ action: KeyboardAction) {
        appState.removeActiveAgentAssignment(for: control)
        switch context {
        case .tap: appState.profiles.updateAction(action, for: control)
        case .hold:
            appState.profiles.setHoldAction(
                action,
                thresholdMilliseconds: appState.profiles.selectedProfile.binding(for: control).resolvedHoldThresholdMilliseconds,
                for: control
            )
        }
        dismiss()
    }
}
