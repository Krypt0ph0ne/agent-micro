import AppKit
import SwiftUI

struct CodexCatalogView: View {
    let appState: AppState
    @Binding var selectedControl: HardwareControl
    @State private var query = ""
    @State private var category = "Alle"

    private var filteredActions: [CodexActionDefinition] {
        appState.catalog.actions.filter { action in
            let categoryMatches = category == "Alle" || action.category == category
            let queryMatches = query.isEmpty || [action.title, action.description, action.shortcut ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query)
            return categoryMatches && queryMatches
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Actions")
                    .font(.largeTitle.weight(.semibold))
                Text("Versionierbarer Katalog: \(appState.catalog.document.verifiedAgainst). Direkte Shortcuts werden auf das aktuell gewählte Pad-Control geschrieben; Deep Links bleiben transparent als lokale Listener-Aktionen gekennzeichnet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    TextField("Aktionen durchsuchen", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 330)
                    Picker("Kategorie", selection: $category) {
                        Text("Alle").tag("Alle")
                        ForEach(appState.catalog.categories, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 190)
                    Spacer()
                    Menu {
                        ForEach(HardwareControl.allCases) { control in
                            Button(control.title) { selectedControl = control }
                        }
                    } label: {
                        Label("Ziel: \(selectedControl.title)", systemImage: selectedControl.icon)
                    }
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(filteredActions) { action in
                        ActionCatalogCard(action: action) {
                            assign(action)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func assign(_ action: CodexActionDefinition) {
        switch action.execution {
        case .keyboardShortcut:
            appState.profiles.assignCodexAction(id: action.id, to: selectedControl)
        case .configurableShortcut:
            appState.profiles.assignCodexAction(id: action.id, to: selectedControl)
        case .deepLink:
            guard let deferred = appState.catalog.deferredAction(id: action.id) else { return }
            appState.profiles.updateAction(deferred, for: selectedControl)
        case .unavailable:
            break
        }
    }
}

private struct ActionCatalogCard: View {
    let action: CodexActionDefinition
    let assign: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: action.icon)
                    .font(.title3)
                    .foregroundStyle(action.execution == .unavailable ? Color.secondary : Color.accentColor)
                Spacer()
                Text(action.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(action.title).font(.headline)
            Text(action.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            } else if let link = action.deepLink {
                Text(link)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            if let note = action.availabilityNote {
                Text(note).font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                Text(action.execution.title).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(buttonTitle, action: assign)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(action.execution == .unavailable || !action.isDirectlyAssignable && action.execution != .deepLink)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .help(helpText)
    }

    private var buttonTitle: String {
        switch action.execution {
        case .deepLink: "Zuweisen*"
        case .configurableShortcut: action.isDirectlyAssignable ? "Zuweisen*" : "In Codex belegen"
        default: "Zuweisen"
        }
    }

    private var helpText: String {
        switch action.execution {
        case .deepLink: "*Deep Links benötigen einen lokalen Listener und sind nicht direkt uploadbar."
        case .configurableShortcut:
            action.isDirectlyAssignable
                ? "*Der Pad-Trigger muss in Codex unter Settings > Keyboard Shortcuts einmalig derselben Aktion zugewiesen werden. Der zweite Tastendruck schließt den geöffneten Bereich."
                : "Für diese reale Codex-Aktion ist in 26.715.21425 keine Standardtaste eingebunden. Lege sie zuerst unter Settings > Keyboard Shortcuts fest und verwende anschließend denselben freien Shortcut im Pad."
        default: ""
        }
    }
}
