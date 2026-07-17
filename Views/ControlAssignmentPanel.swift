import SwiftUI

struct ControlAssignmentPanel: View {
    let appState: AppState
    @Binding var control: HardwareControl

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

    private var usesReasoningTriggers: Bool {
        let profile = appState.profiles.selectedProfile
        return profile.action(for: .encoderLeft).deviceMacro == "f22"
            && profile.action(for: .encoderPress).deviceMacro == "f23"
            && profile.action(for: .encoderRight).deviceMacro == "f24"
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
                Button("Deaktivieren") {
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
            } else {
                Text(action.kind == .disabled ? "Dieses Bedienelement löst nichts aus." : "Eigene oder profilinterne Belegung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if HardwareControl.encoderActions.contains(control), usesReasoningTriggers {
                encoderControls
            } else if HardwareControl.encoderActions.contains(control) {
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
    }

    private var encoderControls: some View {
        @Bindable var automation = appState.reasoningAutomation
        return VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack {
                Text("Codex-Direktsteuerung")
                    .font(.caption.weight(.semibold))
                Spacer()
                Toggle("Aktiv", isOn: $automation.isEnabled)
                    .labelsHidden()
                    .controlSize(.mini)
            }

            HStack(spacing: 5) {
                permissionDot(granted: automation.hasInputMonitoringPermission, label: "Input")
                permissionDot(granted: automation.hasAccessibilityPermission, label: "Zugriff")
                Spacer()
                Button("Testen") { testSelectedEncoder() }
                    .controlSize(.mini)
                    .disabled(!automation.isEnabled)
            }

            if !automation.hasInputMonitoringPermission || !automation.hasAccessibilityPermission {
                Button("Freigeben …") { automation.requestPermissions() }
                    .buttonStyle(.link)
                    .controlSize(.mini)
            }
        }
    }

    private func permissionDot(granted: Bool, label: String) -> some View {
        Label(label, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(granted ? .green : .orange)
    }

    private var infoMessage: String {
        if HardwareControl.encoderActions.contains(control) {
            if usesReasoningTriggers {
                return "Links-Drehen, Drücken und Rechts-Drehen sind eigenständige Belegungen. In diesem Profil dienen F22/F23/F24 als interne Trigger für Reasoning und Modellwahl. Eine andere Zuweisung ersetzt den jeweiligen Trigger."
            }
            return "Diese Drehrad-Geste wird wie eine Taste direkt vom Pad gesendet. Über „Codex-Drehradsteuerung“ im Auswahlmenü kannst du den internen Trigger wiederherstellen."
        }
        return "Wähle links eine Taste und danach hier eine Codex-Aktion. Die Änderung wird sofort im Profil gespeichert, aber erst mit „Übertragen“ auf das Pad geschrieben."
    }

    private func testSelectedEncoder() {
        switch control {
        case .encoderLeft:
            appState.reasoningAutomation.perform(.decreaseEffort)
        case .encoderPress:
            appState.reasoningAutomation.toggleModelPicker()
        case .encoderRight:
            appState.reasoningAutomation.perform(.increaseEffort)
        case .key1, .key2, .key3, .key4, .key5, .key6:
            break
        }
    }
}

private extension HardwareControl {
    var shortTitle: String {
        switch self {
        case .encoderLeft: "Links drehen"
        case .encoderPress: "Drehrad drücken"
        case .encoderRight: "Rechts drehen"
        default: title
        }
    }
}
