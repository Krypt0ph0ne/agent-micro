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
    /// Every state — running, needs-input, completed, failed — is reported.
    case available
    /// Only `running` and `idle` are known, derived from the periodic session
    /// list. Attention and terminal states require the opt-in hooks bridge.
    /// This is *not* "no live status": the shown colour is real, just coarse.
    case sessionListOnly

    var title: String {
        switch self {
        case .available: AppLanguage.text("Live-Status aktiv", "Live status active")
        case .sessionListOnly: AppLanguage.text("Live-Status: Sitzungsliste", "Live status: session list")
        }
    }

    /// Long form for settings and tooltips, where the distinction matters.
    var detail: String {
        switch self {
        case .available:
            AppLanguage.text(
                "Läuft, Eingabe erforderlich und Abschluss werden gemeldet.",
                "Running, needs-input and completion are all reported."
            )
        case .sessionListOnly:
            AppLanguage.text(
                "Läuft und Bereit kommen aus der Sitzungsliste. Eingabe erforderlich und Abschluss brauchen die Hooks.",
                "Running and ready come from the session list. Needs-input and completion require the hooks."
            )
        }
    }
}

/// How much authority a bridge's periodic list snapshot carries relative to
/// its own event stream. This is what keeps the two agent backends from
/// needing the same status semantics.
enum AgentSnapshotAuthority: Equatable, Sendable {
    /// The bridge has a real event stream (Codex's app-server). A snapshot
    /// reporting `idle` is a reconciliation read and never evidence that a
    /// known running or terminal state has ended.
    case reconciliationOnly
    /// The bridge derives liveness purely from polling a session list
    /// (Claude, whose `agents --json` has no event stream). Here the snapshot
    /// *is* the liveness source, so it must be allowed to end a `running`
    /// state — otherwise nothing ever can. Terminal and attention states
    /// still come from events and stay protected.
    case authoritativeForRunning
}

/// Common surface `CodexEventBridge` and `ClaudeAgentBridge` both expose, so
/// `CodexThreadStore` can drive either one without knowing which app it is.
@MainActor
protocol AgentBridge: AnyObject {
    var connectionState: CodexBridgeConnectionState { get }
    var lastError: String? { get }
    var liveStatusAvailability: AgentLiveStatusAvailability { get }
    var snapshotAuthority: AgentSnapshotAuthority { get }
    var onThreads: (([CodexThreadDescriptor]) -> Void)? { get set }
    var onStatus: ((String, CodexAgentStatus, AgentStatusSource) -> Void)? { get set }

    func start()
    func track(threadIDs: Set<String>)
    func refreshThreads()
    func refreshRecentThreads()
    func reconnectNow()
    /// Stops whatever recurring work the bridge does while its profile is not
    /// selected. Only bridges that *poll* have anything to gain here; one with
    /// a persistent push connection would lose live events by disconnecting,
    /// so the default is deliberately to do nothing.
    func suspend()
}

extension AgentBridge {
    func suspend() {}
}
