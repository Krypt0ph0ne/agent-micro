import SwiftUI

/// First-run screen: explains what the pad does and walks through granting
/// both permissions the automation needs before handing off to the main
/// window. Gated by `CodexPad.hasCompletedOnboarding` in `CodexPadApp`.
struct OnboardingView: View {
    let appState: AppState
    let onFinished: () -> Void

    private var monitor: PermissionMonitor { appState.permissionMonitor }
    private var bothGranted: Bool {
        monitor.hasAccessibilityPermission && monitor.hasInputMonitoringPermission
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "square.grid.3x2.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("Willkommen bei CodexPad")
                    .font(.title2.weight(.semibold))
                Text("CodexPad verbindet ein physisches Macropad mit Codex und Claude: Tasten senden Shortcuts, das Drehrad steuert Reasoning-Aufwand und Modellwahl, und die LEDs zeigen den Live-Status deiner Agenten. Dafür braucht macOS zwei Freigaben.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                permissionRow(
                    title: "Bedienungshilfen",
                    detail: "Damit CodexPad Tastenkombinationen an Codex/Claude senden kann.",
                    isGranted: monitor.hasAccessibilityPermission
                )
                permissionRow(
                    title: "Input Monitoring",
                    detail: "Damit CodexPad die Tasten und das Drehrad überhaupt empfängt.",
                    isGranted: monitor.hasInputMonitoringPermission
                )
            }

            if !bothGranted {
                Button("Berechtigungen anfordern") { monitor.requestPermissions() }
                    .buttonStyle(.borderedProminent)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if bothGranted {
                    Button("Los geht's") { onFinished() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Später einrichten") { onFinished() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(24)
        .frame(width: 440, height: 420)
        .task { monitor.requestNotificationAuthorizationIfNeeded() }
    }

    private func permissionRow(title: String, detail: String, isGranted: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
    }
}
