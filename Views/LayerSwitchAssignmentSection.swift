import SwiftUI

/// The one key reserved for holding to flip between the Codex and Claude
/// profiles. Unlike the other five, it carries no assignable action — the
/// firmware binds it app-only (no macro) so the hold gesture never also
/// fires a leftover shortcut. Shown in place of the normal action picker
/// whenever the selected control is the reserved one. Can also be turned
/// off entirely, so switching only ever happens through the app.
struct LayerSwitchAssignmentSection: View {
    let appState: AppState

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { appState.profiles.layerSwitchControl != nil },
            set: { appState.profiles.layerSwitchControl = $0 ? (appState.profiles.layerSwitchControl ?? ProfileStore.defaultLayerSwitchControl) : nil }
        )
    }

    private var control: Binding<HardwareControl> {
        Binding(
            get: { appState.profiles.layerSwitchControl ?? ProfileStore.defaultLayerSwitchControl },
            set: { appState.profiles.layerSwitchControl = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right.circle")
                    .foregroundStyle(.tint)
                Text("Layer-Wechsel")
                    .font(.headline)
                ContextInfoButton(
                    title: "Layer-Wechsel-Taste",
                    message: "Diese Taste ist fest für den Profilwechsel reserviert und trägt keine eigene Aktion. Halten (>\(Int(AppState.layerSwitchHoldThresholdSeconds * 1000)) ms) wechselt zwischen dem Codex- und dem Claude-Profil; kurzes Drücken tut nichts. Die Firmware bindet die Taste app-only (ohne Makro), damit dabei nie zusätzlich eine alte Aktion mitfeuert."
                )
                Spacer()
            }

            Toggle("Per Taste wechseln", isOn: isEnabled)

            if isEnabled.wrappedValue {
                Picker("Reservierte Taste", selection: control) {
                    ForEach(HardwareControl.buttons) { item in
                        Text(item.shortTitle).tag(item)
                    }
                }
                .labelsHidden()

                Text("Halten wechselt zwischen Codex und Claude, unabhängig davon, welches Profil gerade aktiv ist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Der Wechsel funktioniert nur über die Menüleiste bzw. das Hauptfenster, keine Taste ist dafür reserviert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 9))
    }
}
