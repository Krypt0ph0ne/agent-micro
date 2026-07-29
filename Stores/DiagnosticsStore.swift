import Foundation
import Observation

struct DiagnosticEntry: Identifiable, Hashable {
    enum Level: String, Hashable { case info, success, warning, error }

    var id = UUID()
    var date = Date()
    var level: Level
    var title: String
    var detail: String
}

/// A compact, local-only audit row for status handling.  It intentionally
/// stores only a short thread identifier and no prompt/title content.
struct AgentStatusTrace: Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var threadShortID: String
    var source: AgentStatusSource
    var status: CodexAgentStatus
    var ledReaction: String
}

@MainActor
@Observable
final class DiagnosticsStore {
    private(set) var entries: [DiagnosticEntry] = []
    private(set) var statusTraces: [AgentStatusTrace] = []
    private(set) var rawIORegistry: String = "Noch nicht erfasst."

    func append(_ level: DiagnosticEntry.Level, _ title: String, detail: String = "") {
        entries.insert(DiagnosticEntry(level: level, title: title, detail: detail), at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }

    func record(_ result: ProcessResult, title: String) {
        let detail = [result.launchError, result.stdout.nilIfEmpty, result.stderr.nilIfEmpty]
            .compactMap { $0 }
            .joined(separator: "\n")
        append(result.succeeded ? .success : .error, title, detail: detail)
    }

    func setRawIORegistry(_ value: String) {
        rawIORegistry = value
    }

    func recordStatus(threadID: String, source: AgentStatusSource, status: CodexAgentStatus, ledReaction: String) {
        statusTraces.insert(
            AgentStatusTrace(
                threadShortID: String(threadID.prefix(8)),
                source: source,
                status: status,
                ledReaction: ledReaction
            ),
            at: 0
        )
        if statusTraces.count > 100 { statusTraces.removeLast(statusTraces.count - 100) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
