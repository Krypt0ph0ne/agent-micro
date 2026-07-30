import SwiftUI

/// Compact status and gesture guidance for an agent-bound key.
///
/// Thread selection deliberately lives on the physical hold gesture. Keeping
/// the complete thread/subagent catalog out of the main editor prevents the
/// window from growing vertically and keeps assignment available without
/// duplicating the hardware picker in a second UI.
struct CodexAgentAssignmentView: View {
    let appState: AppState
    let control: HardwareControl

    private var assignment: AgentKeyAssignment? {
        appState.activeAgentThreads.assignment(for: control)
    }

    private var status: CodexAgentStatus {
        appState.activeAgentThreads.presentedStatus(for: control)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            assignmentRow
            Divider()
            gestureRow

            if let error = appState.activeAgentThreads.connectionError {
                Label {
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption2)
                .foregroundStyle(.red)
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var assignmentRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(assignment?.threadTitle ?? "Noch kein Chat zugeordnet")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(appState.activeAgentThreads.statusTitle(for: control))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if assignment != nil,
                   appState.activeAgentThreads.liveStatusAvailability == .sessionListOnly {
                    Text(appState.activeAgentThreads.liveStatusAvailability.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(appState.activeAgentThreads.liveStatusAvailability.title)
                }
            }

            Spacer(minLength: 6)

            if assignment != nil {
                Button("Öffnen") {
                    _ = appState.activeAgentThreads.openAssignedThread(for: control)
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    appState.removeAgentAssignment(for: control)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Zuordnung entfernen")
                .accessibilityLabel("Agent-Zuordnung entfernen")
            }
        }
    }

    private var gestureRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Label("Tippen: öffnen", systemImage: "hand.tap")
                .help("Kurzes Tippen öffnet den aktuell zugewiesenen Chat.")
            Divider()
                .frame(height: 18)
            Label("Halten: auswählen", systemImage: "hand.raised.fill")
                .foregroundStyle(.tint)
                .help("Taste halten, mit dem Drehrad einen Chat wählen und zum Zuweisen loslassen.")
            Spacer(minLength: 4)
            ContextInfoButton(
                title: "Chat direkt am Pad zuweisen",
                message: "Halte die Agent-Taste etwa \(CodexQuickAssignService.holdThresholdMilliseconds) ms gedrückt. Drehe weiter gedrückt am Drehrad durch die letzten Chats und lasse die Taste beim gewünschten Chat los. Kurzes Tippen öffnet den bereits zugewiesenen Chat."
            )
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    /// Mirrors the LED exactly. Greying this out while the pad showed the real
    /// colour was the inconsistency; the coarser availability level is
    /// communicated as its own caption instead.
    private var statusColor: Color {
        switch status {
        case .unassigned: return .secondary
        case .idle: return .white
        case .running: return .blue
        case .needsAttention: return .orange
        case .completed: return .green
        case .failed: return .red
        case .interrupted: return .purple
        }
    }
}
