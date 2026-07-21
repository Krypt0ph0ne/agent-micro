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
    private var pendingStatuses: [String: CodexAgentStatus] = [:]

    init(bridge: any AgentBridge, automationApp: AutomationApp = .codex, persistenceURL: URL? = nil) {
        self.bridge = bridge
        self.automationApp = automationApp
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexPad", isDirectory: true)
        let defaultFilename = automationApp == .claude ? "ClaudeAgentKeyAssignments.json" : "AgentKeyAssignments.json"
        self.persistenceURL = persistenceURL ?? base.appendingPathComponent(defaultFilename)
        self.assignments = Self.load(from: self.persistenceURL)

        bridge.onThreads = { [weak self] incoming in self?.merge(incoming) }
        bridge.onStatus = { [weak self] threadID, status in
            if self?.updateStatus(status, threadID: threadID) == true {
                self?.onStatusChange?()
            }
        }
    }

    var connectionState: CodexBridgeConnectionState { bridge.connectionState }
    var connectionError: String? { bridge.lastError }

    func start() {
        bridge.track(threadIDs: Set(assignments.map(\.threadID)))
        bridge.start()
    }

    func refresh() { bridge.refreshThreads() }
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

    func assign(_ thread: CodexThreadDescriptor, to control: HardwareControl) {
        guard HardwareControl.buttons.contains(control) else { return }
        assignments.removeAll(where: { $0.control == control })
        assignments.append(AgentKeyAssignment(
            control: control,
            threadID: thread.id,
            threadTitle: thread.displayTitle,
            isSubagent: thread.isSubagent
        ))
        assignments.sort { $0.control.reportedControlIndex < $1.control.reportedControlIndex }
        persist()
        bridge.track(threadIDs: Set(assignments.map(\.threadID)))
    }

    func removeAssignment(for control: HardwareControl) {
        assignments.removeAll(where: { $0.control == control })
        persist()
        bridge.track(threadIDs: Set(assignments.map(\.threadID)))
    }

    @discardableResult
    func openAssignedThread(for control: HardwareControl) -> Bool {
        guard let threadID = assignment(for: control)?.threadID else { return false }
        let urlString = automationApp == .claude ? "claude://resume?sessionId=\(threadID)" : "codex://threads/\(threadID)"
        guard let url = URL(string: urlString) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func merge(_ incoming: [CodexThreadDescriptor]) {
        let previousAssignedStatuses = assignedStatusSnapshot()
        var byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        for var thread in incoming {
            if let pending = pendingStatuses.removeValue(forKey: thread.id) {
                thread.status = pending
            } else if let current = byID[thread.id], current.status != .idle, thread.status == .idle {
                thread.status = current.status
            }
            byID[thread.id] = thread
        }
        threads = byID.values.sorted { $0.updatedAt > $1.updatedAt }
        if assignedStatusSnapshot() != previousAssignedStatuses {
            onStatusChange?()
        }
    }

    private func updateStatus(_ status: CodexAgentStatus, threadID: String) -> Bool {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
            pendingStatuses[threadID] = status
            return false
        }
        guard threads[index].status != status else { return false }
        threads[index].status = status
        return true
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
