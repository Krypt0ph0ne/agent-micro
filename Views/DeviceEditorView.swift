import SwiftUI

struct DeviceEditorView: View {
    private enum EditorMode: String, CaseIterable, Identifiable {
        case actions = "Belegung"
        case lighting = "Licht"
        var id: String { rawValue }
    }

    let appState: AppState
    @State private var selectedControl: HardwareControl = .key1
    @State private var mode: EditorMode = .actions

    var body: some View {
        VStack(spacing: 12) {
            DeviceCanvasView(
                profile: appState.profiles.selectedProfile,
                selectedControl: $selectedControl,
                agentTitleForControl: {
                    appState.activeAgentThreads.assignment(for: $0)?.threadTitle
                }
            )

            EditorModeSwitch(
                selection: $mode,
                options: [
                    .init(.actions, title: "Belegung", systemImage: "rectangle.grid.2x2"),
                    .init(.lighting, title: "Licht", systemImage: "lightbulb.led.fill")
                ],
                accessibilityLabel: "Editor"
            )

            Group {
                if mode == .actions {
                    ControlAssignmentPanel(appState: appState, control: $selectedControl)
                } else {
                    LEDControlPanel(appState: appState, control: $selectedControl)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { selectedControl = .key1 }
        .onChange(of: mode) { _, newMode in
            if newMode == .lighting, !HardwareControl.buttons.contains(selectedControl) {
                selectedControl = .key1
            }
        }
    }
}
