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

@MainActor
@Observable
final class DiagnosticsStore {
    private(set) var entries: [DiagnosticEntry] = []
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
