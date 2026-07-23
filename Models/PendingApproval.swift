import Foundation

/// A JSON-RPC request id, preserved in its original wire type (string or
/// integer) so it can be echoed back byte-correct in a response — the id is
/// opaque to the sender, and Codex matches it structurally, not by string
/// comparison.
enum JSONRPCID: Hashable {
    case string(String)
    case number(Int)

    init?(_ raw: Any?) {
        if let string = raw as? String {
            self = .string(string)
        } else if let number = raw as? NSNumber {
            self = .number(number.intValue)
        } else {
            return nil
        }
    }

    var jsonValue: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        }
    }
}

enum ApprovalKind: Hashable {
    case command
    case fileChange
}

enum ApprovalDecision {
    case accept
    case decline
}

enum ApprovalSource: Hashable {
    /// `method` is the exact JSON-RPC method the request arrived as (Codex
    /// exposes both a legacy and a v2 naming scheme for the same two
    /// decisions), needed to shape the response correctly.
    case codex(threadID: String, requestID: JSONRPCID, method: String)
}

/// A single outstanding yes/no decision an agent is waiting on. Any key(s)
/// the user assigns "Genehmigen"/"Ablehnen" to (an ordinary catalog action,
/// see `Resources/CodexActions.json`) can answer it.
struct PendingApproval: Identifiable, Hashable {
    let id: String
    let source: ApprovalSource
    let kind: ApprovalKind
    let summary: String
    let receivedAt: Date
}
