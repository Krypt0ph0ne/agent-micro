import SwiftUI

/// Editor for a key's optional action on hold. The regular action is already
/// shown by the parent editor, so this surface only configures the hold side.
/// Only the six buttons support it; the encoder keeps its dedicated reasoning
/// semantics.
struct TapHoldSection: View {
    let appState: AppState
    let control: HardwareControl
    @State private var isPresentingHoldActionSheet = false

    private var binding: ControlBinding {
        appState.profiles.selectedProfile.binding(for: control)
    }

    /// The regular action must either be an app-synthesizable keyboard action,
    /// or one of the host-dispatched app actions (`.layerSwitch`/`.profileSwitch`)
    /// — both slots then resolve through `CodexPadTapHoldService.onAppAction`
    /// instead of keystroke synthesis. Media, mouse and agent bindings cannot
    /// be re-emitted by the app, so a hold action stays unavailable for those.
    private var tapSupportsHold: Bool {
        KeystrokeSynthesizer.canSynthesize(binding.action.deviceMacro)
            || binding.action.kind == .layerSwitch
            || binding.action.kind == .profileSwitch
    }

    private var assignableActions: [CodexActionDefinition] {
        appState.activeCatalog.actions.filter { $0.isDirectlyAssignable && KeystrokeSynthesizer.canSynthesize($0.deviceMacro) }
    }

    var body: some View {
        Group {
            if binding.action.kind.isAgent {
                agentGestureSummary
            } else {
                configurableTapHoldEditor
            }
        }
        .onChange(of: control) { _, _ in
            isPresentingHoldActionSheet = false
        }
        .sheet(isPresented: $isPresentingHoldActionSheet) {
            ActionSelectionSheet(appState: appState, control: control, context: .hold)
        }
    }

    private var configurableTapHoldEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.tint)
                Text("Halten")
                    .font(.subheadline.weight(.semibold))
                ContextInfoButton(
                    title: AppLanguage.text("Aktion beim Halten", "Action on hold"),
                    message: infoMessage
                )
                Spacer()
                Toggle("", isOn: tapHoldEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!tapSupportsHold && !binding.isTapHold)
            }

            if !tapSupportsHold && !binding.isTapHold {
                Text("Nur für Tastatur-/Codex-Shortcuts verfügbar. Die aktuelle Belegung kann die App nicht zusammen mit einer Halte-Aktion ausführen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if binding.isTapHold {
                activeEditor
            } else {
                Text("Aktiviere den Schalter, um beim Halten eine zusätzliche Aktion zu senden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentGestureSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(.tint)
                Text("Tippen / Halten")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Fest für Agenten")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            row(
                icon: "arrow.up.forward.app",
                title: AppLanguage.text("Tippen", "Tap"),
                value: AppLanguage.text("Zugewiesenen Chat öffnen", "Open the assigned chat"),
                macro: ""
            )
            row(
                icon: "arrow.triangle.2.circlepath",
                title: AppLanguage.text("Halten", "Hold"),
                value: AppLanguage.text("Chat neu zuweisen", "Reassign the chat"),
                macro: "\(CodexQuickAssignService.holdThresholdMilliseconds) ms"
            )

            Text("Beim Halten nimmt Agent Micro zuerst eine kopierte Sitzungs-ID. Ist keine passende ID in der Zwischenablage, wird der zuletzt aktive, noch freie Chat verwendet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var activeEditor: some View {
        // Hold action, editable
        Button {
            isPresentingHoldActionSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: binding.holdAction?.icon ?? "hand.raised")
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Halten").font(.caption2).foregroundStyle(.secondary)
                    Text(binding.holdAction?.displayLabel ?? AppLanguage.text("Aktion wählen", "Choose action"))
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let macro = binding.holdAction?.displayShortcut {
                    Text(macro).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)

        thresholdSlider

        if !appState.tapHold.hasAccessibilityPermission {
            permissionHint
        }
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
                Text("Die Halte-Aktion wird von Agent Micro ausgelöst. Erlaube die Bedienungshilfen, sonst bleibt sie wirkungslos.")
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
                Text(value)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
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
                    isPresentingHoldActionSheet = fallback == nil
                } else {
                    appState.profiles.setHoldAction(nil, for: control)
                    isPresentingHoldActionSheet = false
                }
            }
        )
    }

    /// A useful starting hold action. Pairs `.layerSwitch`/`.profileSwitch`
    /// taps with their natural counterpart (the two are usually assigned
    /// together on one key); otherwise falls back to the first synthesizable
    /// Codex shortcut that differs from the current tap action.
    private func defaultHoldAction() -> KeyboardAction? {
        switch binding.action.kind {
        case .layerSwitch: return .profileSwitch
        case .profileSwitch: return .layerSwitch(mode: .cycle)
        default: break
        }
        let tapID = binding.action.codexActionID
        let choice = assignableActions.first { $0.id != tapID } ?? assignableActions.first
        return choice.flatMap { appState.activeCatalog.keyboardAction(id: $0.id) }
    }

    private var infoMessage: String {
        AppLanguage.text(
            "Halten löst zusätzlich zur normalen Tastenaktion eine eigene Aktion aus. Agent Micro misst die Druckdauer und sendet die passende Tastenkombination selbst. Das benötigt die eigene CH552-Firmware (sie meldet die Druckflanken) und die Bedienungshilfen-Berechtigung. Nach dem Ändern einmal „Übertragen“ klicken.",
            "Holding triggers its own action in addition to the regular key action. Agent Micro measures the press duration and sends the matching shortcut itself. This requires the custom CH552 firmware (it reports the press edges) and Accessibility permission. After a change, click Transfer once."
        )
    }
}
