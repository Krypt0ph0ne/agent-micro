import SwiftUI

struct CodexAgentAssignmentView: View {
    let appState: AppState
    let control: HardwareControl
    @State private var threadSearch = ""

    private var assignment: AgentKeyAssignment? { appState.codexThreads.assignment(for: control) }
    private var status: CodexAgentStatus { appState.codexThreads.status(for: control) }
    private var filteredThreads: [CodexThreadDescriptor] {
        let query = threadSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let threads = appState.codexThreads.threads
        guard !query.isEmpty else { return Array(threads.prefix(75)) }
        return Array(threads.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.preview.localizedCaseInsensitiveContains(query)
                || $0.cwd.localizedCaseInsensitiveContains(query)
                || ($0.agentRole?.localizedCaseInsensitiveContains(query) ?? false)
        }.prefix(75))
    }

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

            TextField("Threads & Subagenten durchsuchen", text: $threadSearch)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 4) {
                    if filteredThreads.isEmpty {
                        ContentUnavailableView(
                            appState.codexThreads.threads.isEmpty ? "Keine Threads geladen" : "Keine Treffer",
                            systemImage: "rectangle.stack.badge.person.crop"
                        )
                        .frame(height: 96)
                    } else {
                        ForEach(filteredThreads) { thread in
                            threadRow(thread)
                        }
                    }
                }
            }
            .frame(height: 166)

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

    private func threadRow(_ thread: CodexThreadDescriptor) -> some View {
        Button {
            appState.assignCodexThread(thread, to: control)
            threadSearch = ""
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: thread.status))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(thread.displayTitle)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        if thread.isSubagent {
                            Text("SUB")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text([thread.preview, thread.status.title].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if assignment?.threadID == thread.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(assignment?.threadID == thread.id ? 0.65 : 0.22), in: RoundedRectangle(cornerRadius: 7))
    }

    private var statusColor: Color {
        color(for: status)
    }

    private func color(for status: CodexAgentStatus) -> Color {
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
