import Foundation

/// Extracts the small lifecycle subset Agent Micro needs from Codex's local
/// JSONL rollout. This complements (rather than replaces) the app-server:
/// another app-server process can reconcile persisted turns, but it does not
/// always receive a pending approval owned by the already-running Desktop app.
struct CodexRolloutStatusParser {
    private(set) var pendingRequests: Set<String> = []

    mutating func consume(line: String) -> CodexAgentStatus? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if object["type"] as? String == "event_msg",
           let payload = object["payload"] as? [String: Any] {
            switch payload["type"] as? String {
            case "task_started":
                pendingRequests.removeAll()
                return .running
            case "task_complete":
                pendingRequests.removeAll()
                return .completed
            case "turn_aborted":
                pendingRequests.removeAll()
                return payload["reason"] as? String == "interrupted" ? .interrupted : .failed
            case "error":
                pendingRequests.removeAll()
                return .failed
            default:
                break
            }
        }

        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String
        else { return nil }

        switch payloadType {
        case "function_call", "custom_tool_call":
            guard let callID = payload["call_id"] as? String,
                  Self.requiresUserAction(payload)
            else { return nil }
            pendingRequests.insert(callID)
            return .needsAttention

        case "function_call_output", "custom_tool_call_output":
            guard let callID = payload["call_id"] as? String,
                  pendingRequests.remove(callID) != nil
            else { return nil }
            return pendingRequests.isEmpty ? .running : .needsAttention

        default:
            return nil
        }
    }

    private static func requiresUserAction(_ payload: [String: Any]) -> Bool {
        let name = (payload["name"] as? String)?.lowercased() ?? ""
        if name.contains("request_user_input") || name.contains("requestuserinput") {
            return true
        }
        for key in ["arguments", "input"] {
            guard let text = payload[key] as? String else { continue }
            if text.contains("\"sandbox_permissions\":\"require_escalated\"")
                || text.contains("\"sandbox_permissions\": \"require_escalated\"") {
                return true
            }
        }
        return false
    }
}

/// Incrementally tails only assigned Codex tasks. The first read establishes a
/// snapshot; later appended lines are emitted as events so LED one-shots keep
/// their exact once-only semantics.
final class CodexRolloutStatusObserver {
    struct Update {
        let threadID: String
        let status: CodexAgentStatus
        let source: AgentStatusSource
    }

    private struct Cursor {
        var url: URL
        var offset: UInt64
        var parser: CodexRolloutStatusParser
        var lastStatus: CodexAgentStatus?
        var initialized: Bool
        var pendingFragment: String
    }

    private let sessionsRoot: URL
    private var cursors: [String: Cursor] = [:]

    init(sessionsRoot: URL? = nil) {
        self.sessionsRoot = sessionsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func retain(threadIDs: Set<String>) {
        cursors = cursors.filter { threadIDs.contains($0.key) }
    }

    func poll(threadIDs: Set<String>) -> [Update] {
        retain(threadIDs: threadIDs)
        var updates: [Update] = []
        for threadID in threadIDs {
            if cursors[threadID] == nil, let url = rolloutURL(for: threadID) {
                cursors[threadID] = Cursor(
                    url: url,
                    offset: 0,
                    parser: CodexRolloutStatusParser(),
                    lastStatus: nil,
                    initialized: false,
                    pendingFragment: ""
                )
            }
            guard var cursor = cursors[threadID] else { continue }
            let source: AgentStatusSource = cursor.initialized ? .event : .snapshot
            let result = readNewLines(cursor)
            cursor = result.cursor
            let effectiveStatuses = source == .snapshot
                ? Array(result.statuses.suffix(1))
                : result.statuses
            for status in effectiveStatuses where status != cursor.lastStatus {
                cursor.lastStatus = status
                updates.append(Update(threadID: threadID, status: status, source: source))
            }
            cursor.initialized = true
            cursors[threadID] = cursor
        }
        return updates
    }

    private func readNewLines(_ input: Cursor) -> (cursor: Cursor, statuses: [CodexAgentStatus]) {
        var cursor = input
        guard let handle = try? FileHandle(forReadingFrom: cursor.url) else {
            return (cursor, [])
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? cursor.offset
        if !cursor.initialized, cursor.offset == 0, size > 1_000_000 {
            cursor.offset = size - 1_000_000
        }
        if size < cursor.offset {
            cursor.offset = 0
            cursor.parser = CodexRolloutStatusParser()
            cursor.pendingFragment = ""
        }
        try? handle.seek(toOffset: cursor.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            cursor.offset = size
            return (cursor, [])
        }
        cursor.offset += UInt64(data.count)

        let text = cursor.pendingFragment + String(decoding: data, as: UTF8.self)
        let hasCompleteLastLine = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        cursor.pendingFragment = hasCompleteLastLine ? "" : (lines.popLast() ?? "")
        var statuses: [CodexAgentStatus] = []
        for line in lines where !line.isEmpty {
            if let status = cursor.parser.consume(line: line) {
                statuses.append(status)
            }
        }
        return (cursor, statuses)
    }

    private func rolloutURL(for threadID: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (URL, Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasSuffix("\(threadID).jsonl")
            else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.1 { best = (url, date) }
        }
        return best?.0
    }
}
