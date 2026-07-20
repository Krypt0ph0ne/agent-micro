import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CodexThreadStore {
    private let bridge: CodexEventBridge
    private let persistenceURL: URL

    private(set) var threads: [CodexThreadDescriptor] = []
    private(set) var assignments: [AgentKeyAssignment]
    private(set) var lastPersistenceError: String?
    var onStatusChange: (() -> Void)?

    init(bridge: CodexEventBridge, persistenceURL: URL? = nil) {
        self.bridge = bridge
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexPad", isDirectory: true)
        self.persistenceURL = persistenceURL ?? base.appendingPathComponent("AgentKeyAssignments.json")
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
        guard let threadID = assignment(for: control)?.threadID,
              let url = URL(string: "codex://threads/\(threadID)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func merge(_ incoming: [CodexThreadDescriptor]) {
        var byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        for var thread in incoming {
            if let current = byID[thread.id], current.status != .idle, thread.status == .idle {
                thread.status = current.status
            }
            byID[thread.id] = thread
        }
        threads = byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func updateStatus(_ status: CodexAgentStatus, threadID: String) -> Bool {
        guard let index = threads.firstIndex(where: { $0.id == threadID }),
              threads[index].status != status else { return false }
        threads[index].status = status
        return true
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
