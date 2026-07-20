import Foundation

enum CodexAgentStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case unassigned
    case idle
    case running
    case needsAttention
    case completed
    case failed
    case interrupted

    var title: String {
        switch self {
        case .unassigned: "Nicht zugeordnet"
        case .idle: "Bereit"
        case .running: "Läuft"
        case .needsAttention: "Eingabe erforderlich"
        case .completed: "Erfolgreich abgeschlossen"
        case .failed: "Fehlgeschlagen"
        case .interrupted: "Unterbrochen"
        }
    }
}

struct CodexThreadDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var preview: String
    var cwd: String
    var parentThreadID: String?
    var agentNickname: String?
    var agentRole: String?
    var updatedAt: Date
    var status: CodexAgentStatus

    var isSubagent: Bool { parentThreadID != nil }

    var displayTitle: String {
        if let agentNickname, !agentNickname.isEmpty { return agentNickname }
        if !title.isEmpty { return title }
        if !preview.isEmpty { return preview }
        return isSubagent ? "Subagent" : "Codex-Thread"
    }
}

struct AgentKeyAssignment: Identifiable, Codable, Hashable, Sendable {
    var control: HardwareControl
    var threadID: String
    var threadTitle: String
    var isSubagent: Bool

    var id: HardwareControl { control }
}

enum CodexBridgeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(serverVersion: String)
    case reconnecting(attempt: Int)
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "Nicht verbunden"
        case .connecting: "Verbindung wird hergestellt …"
        case .connected(let version): "Verbunden · \(version)"
        case .reconnecting(let attempt): "Neu verbinden · Versuch \(attempt)"
        case .failed: "Verbindungsfehler"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
