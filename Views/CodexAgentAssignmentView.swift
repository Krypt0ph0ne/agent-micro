import SwiftUI

struct CodexAgentAssignmentView: View {
    let appState: AppState
    let control: HardwareControl

    private var assignment: AgentKeyAssignment? { appState.codexThreads.assignment(for: control) }
    private var status: CodexAgentStatus { appState.codexThreads.status(for: control) }
    private var regularThreads: [CodexThreadDescriptor] { appState.codexThreads.threads.filter { !$0.isSubagent } }
    private var subagents: [CodexThreadDescriptor] { appState.codexThreads.threads.filter(\.isSubagent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(assignment?.threadTitle ?? "Noch kein Thread zugeordnet")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(status.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let assignment {
                    Button("Öffnen") { _ = appState.codexThreads.openAssignedThread(for: control) }
                        .controlSize(.small)
                    Button(role: .destructive) { appState.removeCodexAssignment(for: control) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Zuordnung entfernen")
                    .accessibilityLabel("Zuordnung \(assignment.threadTitle) entfernen")
                }
            }

            Menu {
                if regularThreads.isEmpty && subagents.isEmpty {
                    Text("Keine Threads gefunden")
                }
                if !regularThreads.isEmpty {
                    Section("Threads") {
                        ForEach(regularThreads.prefix(75)) { thread in threadButton(thread) }
                    }
                }
                if !subagents.isEmpty {
                    Section("Subagenten") {
                        ForEach(subagents.prefix(75)) { thread in threadButton(thread) }
                    }
                }
            } label: {
                HStack {
                    Text(assignment == nil ? "Thread oder Subagent auswählen" : "Zuordnung ändern")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))

            HStack(spacing: 6) {
                Label(appState.codexThreads.connectionState.title, systemImage: connectionIcon)
                    .foregroundStyle(appState.codexThreads.connectionState.isConnected ? Color.green : Color.secondary)
                Spacer()
                Button { appState.codexThreads.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Threads neu laden")
                Button("Neu verbinden") { appState.codexThreads.reconnect() }
                    .buttonStyle(.borderless)
            }
            .font(.caption)

            if let error = appState.codexThreads.connectionError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func threadButton(_ thread: CodexThreadDescriptor) -> some View {
        Button {
            appState.assignCodexThread(thread, to: control)
        } label: {
            if assignment?.threadID == thread.id {
                Label(thread.displayTitle, systemImage: "checkmark")
            } else {
                Text(thread.displayTitle)
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .unassigned: .secondary
        case .idle: .white
        case .running: .blue
        case .needsAttention: .orange
        case .completed: .green
        case .failed: .red
        case .interrupted: .purple
        }
    }

    private var connectionIcon: String {
        appState.codexThreads.connectionState.isConnected ? "bolt.horizontal.circle.fill" : "bolt.slash.circle"
    }
}
