import SwiftUI

/// The encoder's three controls (left/press/right) are always edited as one
/// group: unlike the six buttons, they don't carry a freely assignable
/// action each. Instead they mirror the buttons' tap-vs-hold model with a
/// single fixed pair of gestures — a plain rotate/press changes reasoning
/// effort and toggles the Model Picker, holding the dial and rotating
/// switches the model instead — both always active at once.
struct EncoderAssignmentSection: View {
    let appState: AppState

    private var automation: any EncoderAutomationService { appState.activeReasoningAutomation }

    private var isEnabled: Binding<Bool> {
        Binding(get: { automation.isEnabled }, set: { automation.isEnabled = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dial.medium")
                    .foregroundStyle(.tint)
                Text("Drehrad")
                    .font(.headline)
                ContextInfoButton(title: "Drehrad-Gesten", message: infoMessage)
                Spacer()
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            row(
                icon: "slider.horizontal.3",
                gesture: "Normal drücken / drehen",
                value: "Aufwand ± · Modellwahl öffnen/schließen"
            )
            row(
                icon: "cube",
                gesture: "Halten (>\(ClaudeReasoningAutomationService.modelListHoldThresholdMilliseconds) ms) + drehen",
                value: "Modell wechseln, Loslassen übernimmt"
            )

            HStack(spacing: 8) {
                PermissionStatus(title: "Input Monitoring", isGranted: automation.hasInputMonitoringPermission)
                PermissionStatus(title: "Accessibility", isGranted: automation.hasAccessibilityPermission)
            }

            HStack {
                Button("Halten (simulieren)") { automation.testBeginHold() }
                    .frame(maxWidth: .infinity)
                Button("▲") { automation.testRotate(.previous) }
                    .frame(maxWidth: .infinity)
                Button("▼") { automation.testRotate(.next) }
                    .frame(maxWidth: .infinity)
                Button("Loslassen") { automation.testEndHold() }
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(!automation.isEnabled)

            if !automation.hasInputMonitoringPermission || !automation.hasAccessibilityPermission {
                Button("Berechtigungen anfordern") { automation.requestPermissions() }
                    .controlSize(.small)
            }

            Text(automation.status)
                .font(.caption)
                .foregroundStyle(.secondary)

            Label("Direkt vom Pad gesendet", systemImage: "cable.connector")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(icon: String, gesture: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(gesture).font(.caption2).foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    private var infoMessage: String {
        "Alle drei Encoder-Elemente (links drehen, drücken, rechts drehen) gehören zusammen und werden hier als eine Gruppe bearbeitet. Ein kurzer Dreh oder Druck ändert den Reasoning-Aufwand bzw. schaltet die Modellwahl um; wird das Rad gehalten und dabei gedreht, navigiert das stattdessen die Modellliste. Beides ist gleichzeitig aktiv, ähnlich wie Tippen/Halten bei den sechs Tasten. Nach einer Änderung an F22/F23/F24 einmal „Übertragen“ klicken."
    }
}

struct PermissionStatus: View {
    let title: String
    let isGranted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(isGranted ? "Erteilt" : "Fehlt")
                .foregroundStyle(isGranted ? Color.green : Color.orange)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}
