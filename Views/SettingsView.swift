import SwiftUI

struct SettingsView: View {
    let appState: AppState

    var body: some View {
        TabView {
            GeneralView(appState: appState)
            .tabItem { Label("Allgemein", systemImage: "gearshape") }

            VStack(alignment: .leading, spacing: 12) {
                Text("Gerätezugriff")
                    .font(.title2.weight(.semibold))
                Text("Für die Entwicklung ist die App absichtlich unsandboxed. Der Helper öffnet nur das unterstützte USB-HID-Gerät 0x1189:0x8890 und verwendet einen zehn- bzw. zwanzigsekündigen Prozess-Timeout.")
                    .foregroundStyle(.secondary)
                Button("Gerät erneut suchen") { appState.refreshDevice() }
                Spacer()
            }
            .padding(24)
            .tabItem { Label("Gerät", systemImage: "cpu") }

            ReasoningAutomationSettings(appState: appState)
                .tabItem { Label("Codex Reasoning", systemImage: "brain") }
        }
        .frame(width: 540, height: 330)
    }
}

private struct ReasoningAutomationSettings: View {
    let appState: AppState

    var body: some View {
        @Bindable var automation = appState.reasoningAutomation
        VStack(alignment: .leading, spacing: 13) {
            Text("Codex Reasoning")
                .font(.title2.weight(.semibold))
            Text("F22/F23/F24 sind interne Hardware-Trigger. Drehen sendet F18/F19 an Codex und ändert den Reasoning-Aufwand direkt. Drücken öffnet den Model Picker, erneutes Drücken schließt ihn.")
                .foregroundStyle(.secondary)
            Toggle("Drehradsteuerung aktivieren", isOn: $automation.isEnabled)
            LabeledContent("Input Monitoring", value: automation.hasInputMonitoringPermission ? "Erteilt" : "Fehlt")
            LabeledContent("Accessibility", value: automation.hasAccessibilityPermission ? "Erteilt" : "Fehlt")
            Text(automation.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Berechtigungen anfordern") { automation.requestPermissions() }
                Button("− testen") { automation.perform(.decreaseEffort) }.disabled(!automation.isEnabled)
                Button("Picker testen") { automation.toggleModelPicker() }.disabled(!automation.isEnabled)
                Button("+ testen") { automation.perform(.increaseEffort) }.disabled(!automation.isEnabled)
            }
            Spacer()
        }
        .padding(24)
    }
}
