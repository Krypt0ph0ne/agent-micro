import Foundation
import Observation
import OSLog

/// Tracks pending yes/no decisions Codex (and, eventually, Claude) is
/// waiting on. Answering one is just another pad action — the user assigns
/// "Genehmigen"/"Ablehnen" to whichever key(s) they like via the normal
/// Control Assignment Panel, the same as any other action. This coordinator
/// only owns the queue of outstanding requests and answers the agent for
/// real when `decide` is called.
@MainActor
@Observable
final class ApprovalCoordinator {
    private let logger = Logger(subsystem: "io.github.krypt0ph0ne.agentmicro", category: "approval-coordinator")

    private let codexBridge: CodexEventBridge
    private let ledFeedback: CodexPadLEDFeedbackService
    private let currentProfile: () -> MacropadProfile

    private(set) var queue: [PendingApproval] = []

    /// The newest outstanding approval — an assigned key always answers this
    /// one. Older, still-unanswered approvals stay queued underneath.
    var armed: PendingApproval? { queue.last }

    init(
        codexBridge: CodexEventBridge,
        ledFeedback: CodexPadLEDFeedbackService,
        currentProfile: @escaping () -> MacropadProfile
    ) {
        self.codexBridge = codexBridge
        self.ledFeedback = ledFeedback
        self.currentProfile = currentProfile

        codexBridge.onApprovalRequested = { [weak self] approval in
            self?.received(approval)
        }
        codexBridge.onApprovalResolved = { [weak self] id in
            self?.resolvedElsewhere(id: id)
        }
    }

    func decide(_ decision: ApprovalDecision) {
        guard let approval = armed else { return }
        queue.removeAll { $0.id == approval.id }
        switch approval.source {
        case .codex:
            codexBridge.respond(to: approval, decision: decision)
        }
        logger.notice("Approval \(approval.id, privacy: .public) answered: \(decision == .accept ? "accept" : "decline", privacy: .public)")
        ledFeedback.showApprovalResolvedReaction(decision: decision, profile: currentProfile())
    }

    private func received(_ approval: PendingApproval) {
        guard !queue.contains(where: { $0.id == approval.id }) else { return }
        logger.notice("Approval queued: \(approval.id, privacy: .public)")
        queue.append(approval)
    }

    private func resolvedElsewhere(id: String) {
        guard queue.contains(where: { $0.id == id }) else { return }
        queue.removeAll { $0.id == id }
        logger.notice("Approval \(id, privacy: .public) resolved elsewhere; dropping from the pad")
    }
}
