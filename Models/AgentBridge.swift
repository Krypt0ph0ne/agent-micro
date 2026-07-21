import Foundation

/// Common surface `CodexEventBridge` and `ClaudeAgentBridge` both expose, so
/// `CodexThreadStore` can drive either one without knowing which app it is.
@MainActor
protocol AgentBridge: AnyObject {
    var connectionState: CodexBridgeConnectionState { get }
    var lastError: String? { get }
    var onThreads: (([CodexThreadDescriptor]) -> Void)? { get set }
    var onStatus: ((String, CodexAgentStatus) -> Void)? { get set }

    func start()
    func track(threadIDs: Set<String>)
    func refreshThreads()
    func reconnectNow()
}
