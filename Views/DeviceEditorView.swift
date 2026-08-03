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
        VStack(spacing: 10) {
            // The physical Agent Micro rendering keeps its established
            // full-size geometry at the top of the single-column editor.
            DeviceCanvasView(
                profile: appState.profiles.selectedProfile,
                selectedControl: $selectedControl,
                agentTitleForControl: {
                    appState.activeAgentThreads.assignment(for: $0)?.threadTitle
                }
            )

            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.click")
                    .foregroundStyle(.tint)
                Text("Bedienelement am Pad auswählen")
                Spacer(minLength: 4)
                ContextInfoButton(
                    title: AppLanguage.text("Direkt am Pad bearbeiten", "Edit directly on the pad"),
                    message: AppLanguage.text(
                        "Klicke eine Taste oder einen Bereich des Drehrads an. Die passende Belegung oder Lichteinstellung erscheint darunter.",
                        "Click a key or a zone of the dial. Its assignment or lighting settings appear below."
                    )
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            EditorModeSwitch(
                selection: $mode,
                options: [
                    .init(.actions, title: "Belegung", systemImage: "rectangle.grid.2x2"),
                    .init(.lighting, title: "Licht", systemImage: "lightbulb.led.fill")
                ],
                density: .compact,
                accessibilityLabel: "Editor"
            )

            ScrollView {
                Group {
                    if mode == .actions {
                        ControlAssignmentPanel(appState: appState, control: $selectedControl)
                    } else {
                        LEDControlPanel(appState: appState, control: $selectedControl)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 2)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { selectedControl = .key1 }
        .onChange(of: mode) { _, newMode in
            if newMode == .lighting, !HardwareControl.buttons.contains(selectedControl) {
                selectedControl = .key1
            }
        }
    }
}
