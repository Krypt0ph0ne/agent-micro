import Foundation

enum StatusMapper {
    static func threadStatus(type: String?, activeFlags: [String] = []) -> CodexAgentStatus {
        switch type {
        case "active":
            return activeFlags.contains("waitingOnApproval") || activeFlags.contains("waitingOnUserInput")
                ? .needsAttention : .running
        case "systemError": return .failed
        case "idle", "notLoaded": return .idle
        default: return .idle
        }
    }

    static func turnStatus(_ value: String?) -> CodexAgentStatus? {
        switch value {
        case "inProgress": .running
        case "completed": .completed
        case "failed": .failed
        case "interrupted": .interrupted
        default: nil
        }
    }

    /// Maps a state snapshot returned by a separate app-server process.
    ///
    /// Codex persists an externally-owned, still-running turn as `interrupted`
    /// until its owning process writes the completion timestamp. Live
    /// `turn/completed` events remain authoritative; this special case only
    /// applies to snapshots and prevents active desktop turns from appearing
    /// purple after a reconnect.
    static func synchronizedStatus(
        threadType: String?,
        activeFlags: [String] = [],
        latestTurnStatus: String?,
        latestTurnHasCompletionTimestamp: Bool
    ) -> CodexAgentStatus {
        if threadType == "active" {
            return threadStatus(type: threadType, activeFlags: activeFlags)
        }

        if latestTurnStatus == "interrupted", !latestTurnHasCompletionTimestamp {
            return .running
        }

        return turnStatus(latestTurnStatus) ?? .idle
    }

    static func ledConfiguration(for status: CodexAgentStatus, control: HardwareControl) -> KeyLEDConfiguration {
        switch status {
        case .unassigned:
            KeyLEDConfiguration(control: control, effect: .off, red: 0, green: 0, blue: 0, brightness: 0, periodMilliseconds: 1_000)
        case .idle:
            KeyLEDConfiguration(control: control, effect: .steady, red: 255, green: 255, blue: 255, brightness: 56, periodMilliseconds: 1_000)
        case .running:
            KeyLEDConfiguration(control: control, effect: .pulse, red: 20, green: 110, blue: 255, brightness: 255, periodMilliseconds: 1_000)
        case .needsAttention:
            KeyLEDConfiguration(control: control, effect: .pulse, red: 255, green: 105, blue: 0, brightness: 255, periodMilliseconds: 800)
        case .completed:
            KeyLEDConfiguration(control: control, effect: .steady, red: 0, green: 220, blue: 70, brightness: 220, periodMilliseconds: 1_000)
        case .failed:
            KeyLEDConfiguration(control: control, effect: .blink, red: 255, green: 0, blue: 0, brightness: 255, periodMilliseconds: 500)
        case .interrupted:
            KeyLEDConfiguration(control: control, effect: .steady, red: 160, green: 70, blue: 255, brightness: 220, periodMilliseconds: 1_000)
        }
    }
}
