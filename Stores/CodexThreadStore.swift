import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CodexThreadStore {
    private let bridge: any AgentBridge
    /// Which app's deep-link scheme `openAssignedThread` builds — the store's
    /// merge/assign/persist logic itself doesn't care which app it is.
    private let automationApp: AutomationApp
    private let persistenceURL: URL

    private(set) var threads: [CodexThreadDescriptor] = []
    private(set) var assignments: [AgentKeyAssignment]
    private(set) var lastPersistenceError: String?
    var onStatusChange: (() -> Void)?
    var onThreadsChange: (() -> Void)?
    /// Called for every effective state transition, retaining the source so
    /// the app can drive a one-shot completion reaction independently from
    /// the current/resting LED state.
    var onStatusUpdate: ((HardwareControl, CodexAgentStatus, AgentStatusSource) -> Void)?
    private var pendingStatuses: [String: (CodexAgentStatus, AgentStatusSource)] = [:]
    /// An elicitation is a concrete outstanding request, not merely a colour.
    /// A later idle reconciliation read must never hide it; only an event that
    /// resolves/continues the turn is allowed to clear this guard.
    private var attentionLocks: Set<String> = []
    /// Completion acknowledgement is presentation-only. The underlying
    /// descriptor remains `.completed` until the bridge reports real work.
    private var acknowledgedCompletedThreadIDs: Set<String> = []

    init(bridge: any AgentBridge, automationApp: AutomationApp = .codex, persistenceURL: URL? = nil) {
        self.bridge = bridge
        self.automationApp = automationApp
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexPad", isDirectory: true)
        let defaultFilename = automationApp == .claude ? "ClaudeAgentKeyAssignments.json" : "AgentKeyAssignments.json"
        self.persistenceURL = persistenceURL ?? base.appendingPathComponent(defaultFilename)
        self.assignments = Self.load(from: self.persistenceURL)

        bridge.onThreads = { [weak self] incoming in self?.merge(incoming) }
        bridge.onStatus = { [weak self] threadID, status, source in
            self?.updateStatus(status, threadID: threadID, source: source)
        }
    }

    var connectionState: CodexBridgeConnectionState { bridge.connectionState }
    var connectionError: String? { bridge.lastError }
    var liveStatusAvailability: AgentLiveStatusAvailability { bridge.liveStatusAvailability }
    var sessionNavigationSummary: String {
        automationApp == .claude
            ? "Claude-Sitzungen werden über ihre Bridge-Sitzungs-ID (`session_…`) in der bestehenden Desktop-Unterhaltung geöffnet. Ältere Sitzungen ohne diese ID lassen sich nicht direkt anspringen; ein Tastendruck holt dann nur Claude nach vorn."
            : "Codex öffnet den zugewiesenen Thread per Deep Link."
    }

    func start() {
        bridge.track(threadIDs: Set(assignments.map(\.threadID)))
        bridge.start()
    }

    /// Pauses the bridge while this store's profile is not selected. Nothing
    /// persisted or in-memory is discarded, so `start()` resumes seamlessly.
    func suspend() { bridge.suspend() }

    func refresh() { bridge.refreshThreads() }
    func refreshRecentThreads() { bridge.refreshRecentThreads() }
    func reconnect() { bridge.reconnectNow() }

    func assignment(for control: HardwareControl) -> AgentKeyAssignment? {
        assignments.first(where: { $0.control == control })
    }

    func thread(for control: HardwareControl) -> CodexThreadDescriptor? {
        guard let id = assignment(for: control)?.threadID else { return nil }
        return threads.first(where: { $0.id == id })
    }

    func status(for control: HardwareControl) -> CodexAgentStatus {
        guard let assignment = assignment(for: control) else { return .unassigned }
        return threads.first(where: { $0.id == assignment.threadID })?.status ?? .idle
    }

    func presentedStatus(for control: HardwareControl) -> CodexAgentStatus {
        guard let assignment = assignment(for: control) else { return .unassigned }
        let raw = status(for: control)
        if raw == .completed, acknowledgedCompletedThreadIDs.contains(assignment.threadID) {
            return .idle
        }
        return raw
    }

    /// Always the state the LEDs are actually showing. The availability level
    /// is a separate, secondary caption (`liveStatusAvailability`) — replacing
    /// the status with it made the UI claim there was no live status while the
    /// pad was pulsing blue.
    func statusTitle(for control: HardwareControl) -> String {
        guard assignment(for: control) != nil else { return CodexAgentStatus.unassigned.title }
        return presentedStatus(for: control).title
    }

    @discardableResult
    func acknowledgeCompleted(for control: HardwareControl) -> Bool {
        guard
            let assignment = assignment(for: control),
            status(for: control) == .completed
        else { return false }
        let inserted = acknowledgedCompletedThreadIDs.insert(assignment.threadID).inserted
        if inserted { onStatusChange?() }
        return inserted
    }

    func assign(_ thread: CodexThreadDescriptor, to control: HardwareControl) {
        guard HardwareControl.buttons.contains(control) else { return }
        if let previous = assignment(for: control) {
            acknowledgedCompletedThreadIDs.remove(previous.threadID)
        }
        acknowledgedCompletedThreadIDs.remove(thread.id)
        assignments.removeAll(where: { $0.control == control })
        assignments.append(AgentKeyAssignment(
            control: control,
            threadID: thread.id,
            threadTitle: thread.displayTitle,
            isSubagent: thread.isSubagent,
            threadProject: thread.projectName,
            // For Claude an absent bridge ID must stay absent — the CLI UUID
            // that used to be substituted here is rejected by Claude's route.
            navigationID: automationApp == .claude
                ? thread.navigationID
                : (thread.navigationID ?? thread.id)
        ))
        assignments.sort { $0.control.reportedControlIndex < $1.control.reportedControlIndex }
        persist()
        bridge.track(threadIDs: Set(assignments.map(\.threadID)))
    }

    func removeAssignment(for control: HardwareControl) {
        if let previous = assignment(for: control) {
            acknowledgedCompletedThreadIDs.remove(previous.threadID)
        }
        assignments.removeAll(where: { $0.control == control })
        persist()
        bridge.track(threadIDs: Set(assignments.map(\.threadID)))
    }

    @discardableResult
    func openAssignedThread(for control: HardwareControl) -> Bool {
        guard let assignment = assignment(for: control) else { return false }
        if automationApp == .claude {
            // Fall back to the bridge ID the current thread list reports, so a
            // key assigned before Claude recorded one starts working as soon as
            // the session is resumed, without needing a re-assignment.
            let threadID = assignment.navigationID
                ?? threads.first(where: { $0.id == assignment.threadID })?.navigationID
            // A press must never be a no-op: without a routable ID, or if the
            // scheme handler declines, at least bring Claude to the front.
            guard let threadID, let url = Self.navigationURL(for: threadID, app: .claude) else {
                return activateApp()
            }
            return NSWorkspace.shared.open(url) || activateApp()
        }
        let threadID = assignment.navigationID ?? assignment.threadID
        guard let url = Self.navigationURL(for: threadID, app: .codex) else { return false }
        return NSWorkspace.shared.open(url)
    }

    nonisolated static func navigationURL(for threadID: String, app: AutomationApp) -> URL? {
        switch app {
        case .codex:
            return URL(string: "codex://threads/\(threadID)")
        case .claude:
            // Claude's handler validates the identifier with `/^(cse|session)_/`
            // and bails out silently on anything else — that is why a tap with
            // a CLI UUID or a `local_…` ID did nothing at all, not even focus
            // the window. `claude://resume?session=…` is not a substitute: it
            // *imports* the CLI transcript into a new Desktop session, which is
            // where the duplicated "General coding session" entries came from.
            guard ClaudeAgentBridge.isRoutableBridgeSessionID(threadID) else { return nil }
            return URL(string: "claude://code/\(threadID)")
        }
    }

    /// A physical profile switch changes focus; selecting a profile in the UI
    /// remains configuration-only.
    @discardableResult
    func activateApp() -> Bool {
        if automationApp == .codex {
            if let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.openai.codex"
            ).first {
                return running.activate(options: [.activateAllWindows])
            }
            let path = "/Applications/Codex.app"
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: configuration
            ) { _, _ in }
            return true
        }
        let candidates = ["/Applications/Claude.app", "/Applications/Claude Desktop.app"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, _ in }
        return true
    }

    private func merge(_ incoming: [CodexThreadDescriptor]) {
        migrateAssignments(to: incoming)
        let previousAssignedStatuses = assignedStatusSnapshot()
        var byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        for var thread in incoming {
            if let pending = pendingStatuses.removeValue(forKey: thread.id) {
                thread.status = pending.0
                applyStatusTransition(thread.id, status: pending.0, source: pending.1, oldStatus: byID[thread.id]?.status)
            } else if attentionLocks.contains(thread.id),
                      thread.status == .idle || thread.status == .running {
                thread.status = .needsAttention
            } else if let current = byID[thread.id],
                      current.status != .idle,
                      thread.status == .idle,
                      !snapshotIdleMayEnd(current.status) {
                // `thread/list` and the descriptor half of `thread/read`
                // regularly report an idle shell while a more authoritative
                // turn event/rollout/hook says the assigned agent is active
                // or terminal. Preserve that known state; otherwise the
                // two-second reconciliation poll makes the LED alternate
                // between its real colour and idle forever.
                thread.status = current.status
            } else if let oldStatus = byID[thread.id]?.status, oldStatus != thread.status {
                applyStatusTransition(thread.id, status: thread.status, source: .snapshot, oldStatus: oldStatus)
            }
            byID[thread.id] = thread
        }
        threads = byID.values.sorted { $0.updatedAt > $1.updatedAt }
        onThreadsChange?()
        if assignedStatusSnapshot() != previousAssignedStatuses {
            onStatusChange?()
        }
    }

    /// Re-links assignments saved before Claude Desktop session navigation was
    /// available. Their CLI UUID matches `alternateID`; after migration the
    /// visible Desktop ID, readable title and project are persisted together.
    ///
    /// Codex descriptors carry no `alternateID`, so this stays inert for the
    /// Codex store exactly as before.
    private func migrateAssignments(to incoming: [CodexThreadDescriptor]) {
        var changed = false
        for thread in incoming {
            guard thread.alternateID != nil || automationApp == .claude else { continue }
            let alternateID = thread.alternateID
            for index in assignments.indices
            where assignments[index].threadID == alternateID || assignments[index].threadID == thread.id {
                // A stale CLI UUID in `navigationID` is cleared by this, since
                // Claude's route rejects it; it is replaced as soon as Claude
                // records a bridge ID for the session.
                let navigationID = automationApp == .claude
                    ? thread.navigationID
                    : (thread.navigationID ?? alternateID)
                if assignments[index].threadID != thread.id
                    || assignments[index].threadTitle != thread.displayTitle
                    || assignments[index].threadProject != thread.projectName
                    || assignments[index].navigationID != navigationID {
                    assignments[index].threadID = thread.id
                    assignments[index].threadTitle = thread.displayTitle
                    assignments[index].threadProject = thread.projectName
                    assignments[index].navigationID = navigationID
                    changed = true
                }
            }
        }
        guard changed else { return }
        assignments.sort { $0.control.reportedControlIndex < $1.control.reportedControlIndex }
        persist()
        bridge.track(threadIDs: Set(assignments.map(\.threadID)))
    }

    /// Whether an `idle` arriving from a list snapshot is allowed to end
    /// `current`. For an event-driven bridge the answer is always no — that is
    /// the Codex rule and it stays untouched. For a poll-only bridge the
    /// snapshot is the sole liveness source, so it may end `running`, and only
    /// `running`: attention and terminal states come from hook events, which a
    /// vanished process does not disprove.
    private func snapshotIdleMayEnd(_ current: CodexAgentStatus) -> Bool {
        switch bridge.snapshotAuthority {
        case .reconciliationOnly: false
        case .authoritativeForRunning: current == .running
        }
    }

    private func updateStatus(_ status: CodexAgentStatus, threadID: String, source: AgentStatusSource) {
        if source != .snapshot {
            switch status {
            case .needsAttention:
                attentionLocks.insert(threadID)
            case .running, .completed, .failed, .interrupted:
                attentionLocks.remove(threadID)
            case .idle, .unassigned:
                break
            }
        }
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
            pendingStatuses[threadID] = (status, source)
            return
        }
        let oldStatus = threads[index].status
        if source == .snapshot {
            if attentionLocks.contains(threadID),
               status == .idle || status == .running {
                return
            }
            // The explicit `thread/read` status callback is a second snapshot
            // path in addition to `merge`. It needs the same precedence rule:
            // an idle reconciliation is not evidence that a known running,
            // attention, completed, failed or interrupted state ended.
            if status == .idle, oldStatus != .idle, !snapshotIdleMayEnd(oldStatus) {
                return
            }
        }
        guard oldStatus != status else { return }
        threads[index].status = status
        applyStatusTransition(threadID, status: status, source: source, oldStatus: oldStatus)
        onStatusChange?()
    }

    private func applyStatusTransition(
        _ threadID: String,
        status: CodexAgentStatus,
        source: AgentStatusSource,
        oldStatus: CodexAgentStatus?
    ) {
        guard oldStatus != status else { return }
        acknowledgedCompletedThreadIDs.remove(threadID)
        for assignment in assignments where assignment.threadID == threadID {
            onStatusUpdate?(assignment.control, status, source)
        }
    }

    private func assignedStatusSnapshot() -> [HardwareControl: CodexAgentStatus] {
        Dictionary(uniqueKeysWithValues: assignments.map { assignment in
            (assignment.control, threads.first(where: { $0.id == assignment.threadID })?.status ?? .idle)
        })
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(assignments).write(to: persistenceURL, options: .atomic)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    private static func load(from url: URL) -> [AgentKeyAssignment] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([AgentKeyAssignment].self, from: data) else { return [] }
        return value.filter { HardwareControl.buttons.contains($0.control) }
    }
}
