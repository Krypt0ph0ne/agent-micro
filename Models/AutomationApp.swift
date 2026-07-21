import Foundation

/// Which external app a profile's shortcuts, encoder automation and agent
/// bridge target. Profiles without an assigned app (macOS, Sichere
/// F13–F21-Belegung, Factory-like C mapping) leave this `nil`.
enum AutomationApp: String, CaseIterable, Codable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .codex: "com.openai.codex"
        case .claude: "com.anthropic.claudefordesktop"
        }
    }

    /// Scheme+host used to reopen a specific agent thread/session, e.g.
    /// `codex://threads/{id}` or `claude://resume`.
    var deepLinkScheme: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        }
    }
}
