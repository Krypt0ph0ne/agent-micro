import SwiftUI

/// Editor for a key's optional second function on hold. Only the six buttons
/// support it; the encoder keeps its dedicated reasoning semantics.
struct TapHoldSection: View {
    let appState: AppState
    let control: HardwareControl
    @State private var isChoosingHold = false
    @State private var holdSearch = ""
    @State private var isPresentingHoldTextSubmission = false
    @State private var isPresentingHoldWizard = false

    private var binding: ControlBinding {
        appState.profiles.selectedProfile.binding(for: control)
    }

    /// Both slots must be app-synthesizable keyboard actions. Media, mouse and
    /// agent bindings cannot be re-emitted by the app, so tap-vs-hold is hidden.
    private var tapSupportsHold: Bool {
        KeystrokeSynthesizer.canSynthesize(binding.action.deviceMacro)
    }

    private var assignableActions: [CodexActionDefinition] {
        appState.activeCatalog.actions.filter { $0.isDirectlyAssignable && KeystrokeSynthesizer.canSynthesize($0.deviceMacro) }
    }

    private var filteredHoldActions: [CodexActionDefinition] {
        let query = holdSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return assignableActions }
        return assignableActions.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "hand.tap")
                    .foregroundStyle(.tint)
                Text("Tippen / Halten")
                    .font(.subheadline.weight(.semibold))
                ContextInfoButton(title: "Zweitbelegung beim Halten", message: infoMessage)
                Spacer()
                Toggle("", isOn: tapHoldEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!tapSupportsHold && !binding.isTapHold)
            }

            if !tapSupportsHold && !binding.isTapHold {
                Text("Nur für Tastatur-/Codex-Shortcuts verfügbar. Diese Tippen-Aktion kann die App nicht als Halten-Zweitaktion nachbilden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if binding.isTapHold {
                activeEditor
            } else {
                Text("Kurz tippen löst „\(binding.action.label)“ aus. Aktiviere den Schalter, um beim Halten eine zweite Aktion zu senden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: control) { _, _ in
            isChoosingHold = false
            holdSearch = ""
        }
        .sheet(isPresented: $isPresentingHoldTextSubmission) {
            TextSubmissionSheet { text in
                guard let textAction = KeyboardAction.textSubmission(text) else { return }
                appState.profiles.setHoldAction(textAction, thresholdMilliseconds: binding.resolvedHoldThresholdMilliseconds, for: control)
            }
        }
        .sheet(isPresented: $isPresentingHoldWizard) {
            CodexAssignmentWizardView(appState: appState, control: control, slot: .hold)
        }
    }

    @ViewBuilder
    private var activeEditor: some View {
        // Tap summary
        row(icon: binding.action.icon, title: "Tippen", value: binding.action.label, macro: binding.action.displayShortcut)

        // Hold action, editable
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isChoosingHold.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: binding.holdAction?.icon ?? "hand.raised")
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Halten").font(.caption2).foregroundStyle(.secondary)
                    Text(binding.holdAction?.label ?? "Aktion wählen").font(.body.weight(.medium)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let macro = binding.holdAction?.displayShortcut {
                    Text(macro).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Image(systemName: isChoosingHold ? "chevron.up" : "chevron.down")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)

        if isChoosingHold {
            holdPicker
        }

        thresholdSlider

        if !appState.tapHold.hasAccessibilityPermission {
            permissionHint
        }
    }

    private var holdPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Text", systemImage: "paperplane.fill") {
                    isPresentingHoldTextSubmission = true
                    isChoosingHold = false
                }
                Button("Assistent", systemImage: "wand.and.stars") {
                    isPresentingHoldWizard = true
                    isChoosingHold = false
                }
                .help("Konfigurierbare Codex-Aktion mit eigenem Trigger als Halten-Aktion einrichten")
            }
            .controlSize(.small)

            TextField("Halten-Aktion durchsuchen", text: $holdSearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredHoldActions) { action in
                        Button {
                            appState.profiles.setHoldAction(
                                appState.activeCatalog.keyboardAction(id: action.id),
                                thresholdMilliseconds: binding.resolvedHoldThresholdMilliseconds,
                                for: control
                            )
                            isChoosingHold = false
                            holdSearch = ""
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: action.icon).frame(width: 20).foregroundStyle(.tint)
                                Text(action.title).font(.caption.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                if action.id == binding.holdAction?.codexActionID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary.opacity(action.id == binding.holdAction?.codexActionID ? 0.6 : 0.2), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(height: 150)
        }
        .padding(8)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
    }

    private var thresholdSlider: some View {
        let threshold = Binding<Double>(
            get: { Double(binding.resolvedHoldThresholdMilliseconds) },
            set: { appState.profiles.setHoldAction(binding.holdAction, thresholdMilliseconds: Int($0), for: control) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Halte-Schwelle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(binding.resolvedHoldThresholdMilliseconds) ms").font(.caption.monospaced())
            }
            Slider(
                value: threshold,
                in: Double(ControlBinding.holdThresholdRange.lowerBound)...Double(ControlBinding.holdThresholdRange.upperBound),
                step: 20
            )
            .controlSize(.small)
        }
    }

    private var permissionHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Bedienungshilfen nötig")
                    .font(.caption.weight(.semibold))
                Text("Tippen/Halten sendet die Aktionen selbst. Erlaube CodexPad die Bedienungshilfen, sonst bleibt die Zweitbelegung wirkungslos.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Berechtigung anfordern") { appState.reasoningAutomation.requestPermissions() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private func row(icon: String, title: String, value: String, macro: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(macro).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    private var tapHoldEnabled: Binding<Bool> {
        Binding(
            get: { binding.isTapHold },
            set: { isOn in
                if isOn {
                    let fallback = defaultHoldAction()
                    appState.profiles.setHoldAction(
                        fallback,
                        thresholdMilliseconds: binding.resolvedHoldThresholdMilliseconds,
                        for: control
                    )
                    isChoosingHold = fallback == nil
                } else {
                    appState.profiles.setHoldAction(nil, for: control)
                    isChoosingHold = false
                }
            }
        )
    }

    /// A useful starting hold action: the first synthesizable Codex shortcut
    /// that differs from the current tap action.
    private func defaultHoldAction() -> KeyboardAction? {
        let tapID = binding.action.codexActionID
        let choice = assignableActions.first { $0.id != tapID } ?? assignableActions.first
        return choice.flatMap { appState.activeCatalog.keyboardAction(id: $0.id) }
    }

    private var infoMessage: String {
        "Kurzes Tippen sendet die Haupt-Aktion, längeres Halten die Zweit-Aktion. CodexPad misst die Druckdauer und sendet die passende Tastenkombination selbst. Das benötigt die eigene CH552-Firmware (sie meldet die Druckflanken) und die Bedienungshilfen-Berechtigung. Nach dem Ändern einmal „Übertragen“ klicken."
    }
}
