import Foundation

/// Distinguishes an authoritative lifecycle event from the deliberately
/// limited reconciliation read of an assigned thread.  Keeping this metadata
/// through the store makes a missed server event diagnosable without logging
/// prompt contents or other sensitive thread data.
enum AgentStatusSource: String, Codable, Sendable {
    case event
    case snapshot
    case hook

    var title: String {
        switch self {
        case .event: AppLanguage.text("Ereignis", "Event")
        case .snapshot: AppLanguage.text("Abgleich", "Sync")
        case .hook: "Claude-Hook"
        }
    }
}

enum AgentLiveStatusAvailability: Equatable, Sendable {
    case available
    case notActivated

    var title: String {
        switch self {
        case .available: AppLanguage.text("Live-Status aktiv", "Live status active")
        case .notActivated: AppLanguage.text("Live-Status nicht aktiviert", "Live status not enabled")
        }
    }
}

/// Common surface `CodexEventBridge` and `ClaudeAgentBridge` both expose, so
/// `CodexThreadStore` can drive either one without knowing which app it is.
@MainActor
protocol AgentBridge: AnyObject {
    var connectionState: CodexBridgeConnectionState { get }
    var lastError: String? { get }
    var liveStatusAvailability: AgentLiveStatusAvailability { get }
    var onThreads: (([CodexThreadDescriptor]) -> Void)? { get set }
    var onStatus: ((String, CodexAgentStatus, AgentStatusSource) -> Void)? { get set }

    func start()
    func track(threadIDs: Set<String>)
    func refreshThreads()
    func refreshRecentThreads()
    func reconnectNow()
}
