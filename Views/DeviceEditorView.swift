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
                selectedControl: $selectedControl
            )
            .frame(height: 146)

            Picker("Editor", selection: $mode) {
                ForEach(EditorMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
