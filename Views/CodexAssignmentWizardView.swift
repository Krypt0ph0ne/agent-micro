import AppKit
import SwiftUI

/// Guided setup for the 26 configurable Codex actions that ship without a
/// default keybinding. The wizard hands the chosen action a unique trigger
/// chord, tells the user how to bind it inside Codex, and writes the binding.
struct CodexAssignmentWizardView: View {
    @Environment(\.dismiss) private var dismiss
    let appState: AppState
    let control: HardwareControl
    let slot: ActionSlot

    @State private var selected: CodexActionDefinition?
    @State private var trigger = ""
    @State private var search = ""
    @State private var setupError: String?

    init(
        appState: AppState,
        control: HardwareControl,
        slot: ActionSlot = .tap,
        initialAction: CodexActionDefinition? = nil
    ) {
        self.appState = appState
        self.control = control
        self.slot = slot
        _selected = State(initialValue: initialAction)
    }

    private var appName: String { appState.profiles.selectedProfile.automationApp?.displayName ?? "Codex" }

    private var configurableActions: [CodexActionDefinition] {
        appState.activeCatalog.actions.filter { $0.execution == .configurableShortcut }
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
        .task {
            if let selected, trigger.isEmpty {
                prepare(selected)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.tint)
                Text(AppLanguage.text("\(appName)-Aktion einrichten", "Set up \(appName) action"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Label(
                    "\(control.shortTitle)\(slot == .hold ? AppLanguage.text(" · Halten", " · Hold") : "")",
                    systemImage: control.icon
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(AppLanguage.text(
                "Diese Aktionen haben in \(appName) keine Standardtaste. Der Assistent vergibt einen eindeutigen Trigger, den das Pad direkt sendet – du weist ihn danach einmalig in \(appName) zu.",
                "These actions have no default shortcut in \(appName). The assistant assigns a unique trigger that the pad sends directly – you then bind it once in \(appName)."
            ))
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
            prepare(action)
            selected = action
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .frame(width: 24)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
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

    private func prepare(_ action: CodexActionDefinition) {
        let app = appState.profiles.selectedProfile.automationApp ?? .codex
        if let configured = CodexTriggerRegistry.trigger(for: action.id, app: app) {
            // This action has already been set up in Codex. Reuse exactly that
            // trigger when it moves to a different pad control.
            trigger = configured
            return
        }
        trigger = CodexTriggerRegistry.reserveNextFreeTrigger(
            in: appState.profiles.profiles,
            keeping: currentTrigger(for: action.id)
        ) ?? ""
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

            if let setupError {
                Label(setupError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                if appName == "Codex" {
                    Button("Nur lokal zuweisen") {
                        assignLocally(action)
                        dismiss()
                    }
                    Button("Übertragen") {
                        let result = appState.transferConfiguredShortcut(
                            action,
                            trigger: trigger,
                            control: control,
                            slot: slot
                        )
                        if result?.succeeded == true {
                            dismiss()
                        } else {
                            let detail = result?.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                            setupError = detail?.isEmpty == false
                                ? AppLanguage.text(
                                    "Die Taste konnte nicht übertragen werden: \(detail!)",
                                    "The key could not be transferred: \(detail!)"
                                )
                                : AppLanguage.text(
                                    "Die Taste konnte nicht auf das Pad übertragen werden. Prüfe die Verbindung und versuche es erneut.",
                                    "The key could not be transferred to the pad. Check the connection and try again."
                                )
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Zuweisen") {
                        assignLocally(action)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(trigger.isEmpty)
        }
        .padding(16)
    }

    private var triggerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zugewiesener Trigger")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(trigger.isEmpty ? "—" : CodexTriggerPool.displayLabel(for: trigger))
                        .font(.title2.monospaced().weight(.semibold))
                }
                Spacer()
                triggerPicker
                Button {
                    chooseNextTrigger()
                } label: {
                    Label("Belegt – nächster", systemImage: "arrow.right.circle")
                }
                .controlSize(.small)
                .disabled(trigger.isEmpty)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(AppLanguage.text(
                    "\(CodexTriggerPool.candidates.count) Kandidaten: A–Z, 0–9 und F1–F12.",
                    "\(CodexTriggerPool.candidates.count) candidates: A–Z, 0–9 and F1–F12."
                ))
                Text("Codex veröffentlicht seine belegten Shortcuts nicht. Ist einer dort schon belegt, markiere ihn hier; Agent Micro schlägt ihn danach nie wieder vor.")
                if !knownTriggers.isEmpty {
                    Text("Für frühere Einrichtungen: Auswählen › Bereits eingerichtet und den bereits in Codex verwendeten Trigger einmal übernehmen.")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var triggerPicker: some View {
        Menu {
            triggerMenu(AppLanguage.text("Buchstaben", "Letters"), candidates: CodexTriggerPool.letterCandidates)
            triggerMenu(AppLanguage.text("Zahlen", "Numbers"), candidates: CodexTriggerPool.numberCandidates)
            triggerMenu(AppLanguage.text("F-Tasten", "Function keys"), candidates: CodexTriggerPool.functionKeyCandidates)
            if !knownTriggers.isEmpty {
                Divider()
                Menu("Bereits eingerichtet") {
                    ForEach(knownTriggers, id: \.self) { candidate in
                        Button(CodexTriggerPool.displayLabel(for: candidate)) {
                            trigger = candidate
                        }
                    }
                }
            }
        } label: {
            Label("Auswählen", systemImage: "chevron.up.chevron.down")
        }
        .controlSize(.small)
        .disabled(availableTriggers.isEmpty && knownTriggers.isEmpty)
    }

    private var availableTriggers: [String] {
        CodexTriggerRegistry.availableTriggers(
            in: appState.profiles.profiles,
            keeping: trigger
        )
    }

    /// Prior versions persisted a reservation but not which action it belonged
    /// to. Let the user recover that known Codex binding once; the subsequent
    /// transfer writes the durable action-to-trigger mapping.
    private var knownTriggers: [String] {
        let fromProfiles = CodexTriggerPool.usedTriggers(in: appState.profiles.profiles)
        let known = fromProfiles.union(CodexTriggerRegistry.reservedTriggers())
        return CodexTriggerPool.candidates.filter { known.contains($0) && $0 != trigger }
    }

    @ViewBuilder
    private func triggerMenu(_ title: String, candidates: [String]) -> some View {
        let available = Set(availableTriggers)
        Menu(title) {
            ForEach(candidates.filter(available.contains), id: \.self) { candidate in
                Button(CodexTriggerPool.displayLabel(for: candidate)) {
                    CodexTriggerRegistry.reserve(candidate)
                    trigger = candidate
                }
            }
        }
        .disabled(candidates.allSatisfy { !available.contains($0) })
    }

    private func chooseNextTrigger() {
        if let alternative = CodexTriggerRegistry.reserveAlternativeTrigger(
            to: trigger,
            in: appState.profiles.profiles
        ) {
            trigger = alternative
        } else {
            trigger = ""
        }
    }

    private func instructions(for action: CodexActionDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appName == "Codex"
                ? AppLanguage.text("Schnelleinrichtung", "Quick setup")
                : AppLanguage.text("So in \(appName) zuweisen", "How to bind it in \(appName)"))
                .font(.caption.weight(.semibold))
            if appName == "Codex" {
                step(
                    1,
                    AppLanguage.text("Klicke unten auf ", "Click "),
                    trailing: AppLanguage.text(
                        "„Übertragen“, damit \(control.shortTitle) den Trigger sendet.",
                        "“Transfer” below so \(control.shortTitle) sends the trigger."
                    )
                )
                step(
                    2,
                    AppLanguage.text("Öffne in Codex ", "In Codex, open "),
                    trailing: AppLanguage.text(
                        "Settings › Keyboard Shortcuts und suche „\(action.title)“.",
                        "Settings › Keyboard Shortcuts and search for “\(action.title)”."
                    )
                )
                step(
                    3,
                    AppLanguage.text("Klicke beim Treffer auf ", "On the matching row, click "),
                    trailing: AppLanguage.text(
                        "„+“ und drücke einmal die physische \(control.shortTitle).",
                        "“+” and press the physical \(control.shortTitle) once."
                    )
                )
                Text(AppLanguage.text(
                    "Verwende dabei \(CodexTriggerPool.displayLabel(for: trigger)). Agent Micro öffnet keine Codex-Ansicht mehr automatisch.",
                    "Use \(CodexTriggerPool.displayLabel(for: trigger)) for this. Agent Micro no longer opens any Codex view automatically."
                ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            } else {
                step(
                    1,
                    AppLanguage.text("Öffne in Claude ", "In Claude, open "),
                    trailing: AppLanguage.text(
                        "die Datei ~/.claude/keybindings.json.",
                        "the file ~/.claude/keybindings.json."
                    )
                )
                step(
                    2,
                    AppLanguage.text("Trage die Aktions-ID ein: ", "Enter the action ID: "),
                    trailing: AppLanguage.text(
                        "„\(action.codexCommandID ?? action.id)“.",
                        "“\(action.codexCommandID ?? action.id)”."
                    )
                )
                step(
                    3,
                    AppLanguage.text("Binde sie an ", "Bind it to "),
                    trailing: CodexTriggerPool.displayLabel(for: trigger) + "."
                )
                step(
                    4,
                    AppLanguage.text("Danach in Agent Micro ", "Then, in Agent Micro, "),
                    trailing: AppLanguage.text("Übertragen klicken.", "click Transfer.")
                )
            }
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
        let binding = appState.profiles.selectedProfile.binding(for: control)
        let action = slot == .tap ? binding.action : binding.holdAction
        return action?.codexActionID == actionID ? action?.deviceMacro : nil
    }

    private func assignLocally(_ action: CodexActionDefinition) {
        if slot == .tap { appState.removeActiveAgentAssignment(for: control) }
        let kind: ActionKind = appState.profiles.selectedProfile.automationApp == .claude ? .claudeShortcut : .codexShortcut
        appState.profiles.assignConfigurableCodexAction(action, trigger: trigger, to: control, slot: slot, kind: kind)
    }
}
