import SwiftUI

struct DeviceEditorView: View {
    let appState: AppState
    @State private var selectedControl: HardwareControl = .key1

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DeviceCanvasView(
                profile: appState.profiles.selectedProfile,
                selectedControl: $selectedControl
            )
            .frame(width: 316)

            ControlAssignmentPanel(
                appState: appState,
                control: $selectedControl
            )
            .frame(maxWidth: .infinity)
        }
        .onAppear { selectedControl = .key1 }
    }
}
