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
                ContextInfoButton(
                    title: AppLanguage.text("Drehrad-Gesten", "Dial gestures"),
                    message: infoMessage
                )
                Spacer()
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            row(
                icon: "slider.horizontal.3",
                gesture: AppLanguage.text("Normal drücken / drehen", "Normal press / turn"),
                value: AppLanguage.text(
                    "Aufwand ± · Modellwahl öffnen/schließen",
                    "Effort ± · open/close model selection"
                )
            )
            row(
                icon: "cube",
                gesture: AppLanguage.text(
                    "Halten (>\(ClaudeReasoningAutomationService.modelListHoldThresholdMilliseconds) ms) + drehen",
                    "Hold (>\(ClaudeReasoningAutomationService.modelListHoldThresholdMilliseconds) ms) + turn"
                ),
                value: AppLanguage.text(
                    "Modell wechseln, Loslassen übernimmt",
                    "Switch model, release applies it"
                )
            )

            HStack(spacing: 8) {
                if !automation.usesPhysicalEncoderEvents {
                    PermissionStatus(
                        title: "Input Monitoring",
                        isGranted: automation.hasInputMonitoringPermission
                    )
                }
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

            if !automation.hasAccessibilityPermission || (!automation.usesPhysicalEncoderEvents && !automation.hasInputMonitoringPermission) {
                Button("Berechtigungen anfordern") { automation.requestPermissions() }
                    .controlSize(.small)
            }

            if !automation.hasAccessibilityPermission {
                Text(AppLanguage.text(
                    "Ist Agent Micro unter Bedienungshilfen bereits sichtbar und eingeschaltet, aber wirkungslos? Nach einem ad-hoc-signierten Update den Schalter einmal Aus → Ein schalten.",
                    "If Agent Micro is already visible and enabled under Accessibility but does not respond, toggle it Off → On once after an ad-hoc-signed update."
                ))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(automation.status)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !automation.usesPhysicalEncoderEvents {
                Label(
                    AppLanguage.text(
                        "Legacy-Keyboard-HID · Input Monitoring nötig",
                        "Legacy keyboard HID · Input Monitoring required"
                    ),
                    systemImage: "cable.connector"
                )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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
        let transport = automation.usesPhysicalEncoderEvents
            ? AppLanguage.text(
                "Das direkte Pad-Protokoll liefert diese Ereignisse direkt.",
                "The direct pad protocol delivers these events directly."
            )
            : AppLanguage.text(
                "Legacy-CH57x-Geräte liefern F22/F23/F24 über Keyboard-HID und benötigen dafür Input Monitoring.",
                "Legacy CH57x devices deliver F22/F23/F24 over keyboard HID and require Input Monitoring."
            )
        return AppLanguage.text(
            "Alle drei Encoder-Elemente (links drehen, drücken, rechts drehen) gehören zusammen und werden hier als eine Gruppe bearbeitet. Ein kurzer Dreh oder Druck ändert den Reasoning-Aufwand bzw. schaltet die Modellwahl um; wird das Rad gehalten und dabei gedreht, navigiert das stattdessen die Modellliste. \(transport) Nach einer Änderung einmal „Übertragen“ klicken.",
            "All three encoder controls (turn left, press, turn right) belong together and are edited as a group. A short turn or press changes reasoning effort or toggles model selection; holding the dial while turning navigates the model list instead. \(transport) After a change, click Transfer once."
        )
    }
}

struct PermissionStatus: View {
    let title: String
    let isGranted: Bool
    var grantedTitle = AppLanguage.text("Erteilt", "Granted")

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(isGranted ? grantedTitle : AppLanguage.text("Fehlt", "Missing"))
                .foregroundStyle(isGranted ? Color.green : Color.orange)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}
