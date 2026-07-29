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
        case .unassigned: AppLanguage.text("Nicht zugeordnet", "Unassigned")
        case .idle: AppLanguage.text("Bereit", "Ready")
        case .running: AppLanguage.text("Läuft", "Running")
        case .needsAttention: AppLanguage.text("Eingabe erforderlich", "Needs input")
        case .completed: AppLanguage.text("Erfolgreich abgeschlossen", "Completed")
        case .failed: AppLanguage.text("Fehlgeschlagen", "Failed")
        case .interrupted: AppLanguage.text("Unterbrochen", "Interrupted")
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
    /// Alternate identity for the same visible session. Claude Desktop uses a
    /// `local_…` route ID while older assignments and hooks use the CLI UUID.
    var alternateID: String? = nil
    /// Identifier accepted by the target application's navigation surface.
    /// Claude Desktop's local metadata ID is not routable; the supported
    /// Resume flow uses the underlying CLI UUID.
    var navigationID: String? = nil

    var isSubagent: Bool { parentThreadID != nil }

    var displayTitle: String {
        if let agentNickname, !agentNickname.isEmpty { return agentNickname }
        if !title.isEmpty { return title }
        if !preview.isEmpty { return preview }
        let shortID = String(id.prefix(8))
        return isSubagent ? "Subagent · \(shortID)" : "Sitzung · \(shortID)"
    }

    var projectName: String? {
        guard !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

struct AgentKeyAssignment: Identifiable, Codable, Hashable, Sendable {
    var control: HardwareControl
    var threadID: String
    var threadTitle: String
    var isSubagent: Bool
    var threadProject: String?
    var navigationID: String?

    var id: HardwareControl { control }

    init(control: HardwareControl, threadID: String, threadTitle: String, isSubagent: Bool, threadProject: String? = nil, navigationID: String? = nil) {
        self.control = control
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.isSubagent = isSubagent
        self.threadProject = threadProject
        self.navigationID = navigationID
    }

    private enum CodingKeys: String, CodingKey { case control, threadID, threadTitle, isSubagent, threadProject, navigationID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        control = try container.decode(HardwareControl.self, forKey: .control)
        threadID = try container.decode(String.self, forKey: .threadID)
        threadTitle = try container.decode(String.self, forKey: .threadTitle)
        isSubagent = try container.decode(Bool.self, forKey: .isSubagent)
        threadProject = try container.decodeIfPresent(String.self, forKey: .threadProject)
        navigationID = try container.decodeIfPresent(String.self, forKey: .navigationID)
    }
}

enum CodexBridgeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(serverVersion: String)
    case reconnecting(attempt: Int)
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: AppLanguage.text("Nicht verbunden", "Disconnected")
        case .connecting: AppLanguage.text("Verbindung wird hergestellt …", "Connecting…")
        case .connected(let version): AppLanguage.text("Verbunden · \(version)", "Connected · \(version)")
        case .reconnecting(let attempt): AppLanguage.text("Neu verbinden · Versuch \(attempt)", "Reconnecting · attempt \(attempt)")
        case .failed: AppLanguage.text("Verbindungsfehler", "Connection failed")
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
