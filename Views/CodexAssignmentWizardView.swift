import AppKit
import SwiftUI

/// Guided setup for the 26 configurable Codex actions that ship without a
/// default keybinding. The wizard hands the chosen action a unique trigger
/// chord, tells the user how to bind it inside Codex, and writes the binding.
struct CodexAssignmentWizardView: View {
    @Environment(\.dismiss) private var dismiss
    let appState: AppState
    let control: HardwareControl

    @State private var selected: CodexActionDefinition?
    @State private var trigger = ""
    @State private var search = ""

    private var configurableActions: [CodexActionDefinition] {
        appState.catalog.actions.filter { $0.execution == .configurableShortcut }
    }

    private var filtered: [CodexActionDefinition] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return configurableActions }
        return configurableActions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.category.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let selected {
                confirmStep(for: selected)
            } else {
                chooseStep
            }
        }
        .frame(width: 460, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.tint)
                Text("Codex-Aktion einrichten")
                    .font(.title3.weight(.semibold))
                Spacer()
                Label(control.shortTitle, systemImage: control.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Diese Aktionen haben in Codex keine Standardtaste. Der Assistent vergibt einen eindeutigen Trigger, den das Pad direkt sendet – du weist ihn danach einmalig in Codex zu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Aktion durchsuchen", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 4) {
                    if filtered.isEmpty {
                        ContentUnavailableView("Keine Aktion gefunden", systemImage: "magnifyingglass")
                            .frame(height: 120)
                    } else {
                        ForEach(filtered) { action in
                            actionRow(action)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func actionRow(_ action: CodexActionDefinition) -> some View {
        Button {
            trigger = CodexTriggerPool.nextFreeTrigger(
                in: appState.profiles.selectedProfile,
                keeping: currentTrigger(for: action.id)
            ) ?? ""
            selected = action
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .frame(width: 24)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(action.category).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func confirmStep(for action: CodexActionDefinition) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                selected = nil
            } label: {
                Label("Andere Aktion", systemImage: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            HStack(spacing: 10) {
                Image(systemName: action.icon).font(.title2).foregroundStyle(.tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.headline)
                    Text(action.description).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            triggerCard

            if trigger.isEmpty {
                Label("Alle Trigger sind belegt. Entferne zuerst eine andere Codex-Aktion.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                instructions(for: action)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Zuweisen") {
                    appState.codexThreads.removeAssignment(for: control)
                    appState.profiles.assignConfigurableCodexAction(action, trigger: trigger, to: control)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trigger.isEmpty)
            }
        }
        .padding(16)
    }

    private var triggerCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Zugewiesener Trigger")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(trigger.isEmpty ? "—" : CodexTriggerPool.displayLabel(for: trigger))
                    .font(.title2.monospaced().weight(.semibold))
            }
            Spacer()
            Button {
                if let alternative = CodexTriggerPool.alternativeTrigger(to: trigger, in: appState.profiles.selectedProfile) {
                    trigger = alternative
                }
            } label: {
                Label("Anderer", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .disabled(trigger.isEmpty)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func instructions(for action: CodexActionDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("So in Codex zuweisen")
                .font(.caption.weight(.semibold))
            step(1, "Öffne in Codex ", trailing: "Settings › Keyboard Shortcuts.")
            step(2, "Suche den Eintrag ", trailing: "„\(action.title)".appending("."))
            step(3, "Klicke ihn an und drücke die Tastenkombination ", trailing: CodexTriggerPool.displayLabel(for: trigger) + ".")
            step(4, "Danach in CodexPad ", trailing: "Übertragen klicken, um den Trigger auf das Pad zu laden.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func step(_ number: Int, _ text: String, trailing: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.bold).monospaced())
                .frame(width: 18, height: 18)
                .background(.tint.opacity(0.2), in: Circle())
            (Text(text) + Text(trailing).font(.caption.weight(.semibold)))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// If this control is already bound to the same action, keep its trigger so
    /// re-running the wizard is idempotent.
    private func currentTrigger(for actionID: String) -> String? {
        let action = appState.profiles.selectedProfile.action(for: control)
        return action.codexActionID == actionID ? action.deviceMacro : nil
    }
}
