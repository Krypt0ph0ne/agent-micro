import Foundation
import Observation

struct ThreadPickerPresentation: Equatable {
    let control: HardwareControl
    let appName: String
    var threads: [CodexThreadDescriptor]
    var selectedIndex: Int?
    let assignedThreadID: String?

    var selectedThread: CodexThreadDescriptor? {
        guard let selectedIndex, threads.indices.contains(selectedIndex) else { return nil }
        return threads[selectedIndex]
    }
}

/// Owns the exclusive agent-key gesture:
/// - release before 900 ms opens the assigned thread;
/// - crossing the threshold opens a hardware-driven recent-thread picker;
/// - encoder rotation changes its highlight;
/// - releasing the same agent key confirms the highlight.
@MainActor
@Observable
final class CodexQuickAssignService {
    static let holdThresholdMilliseconds = 900
    static let maximumPickerThreads = 10
    private static let selectionSafetyTimeoutSeconds: TimeInterval = 20

    private struct PendingPress {
        let cancel: () -> Void
    }

    private var pendingPresses: [HardwareControl: PendingPress] = [:]
    private var selectionTimeoutTask: Task<Void, Never>?

    private let isEnabled: () -> Bool
    private let isDesignatedAgentControl: (HardwareControl) -> Bool
    private let isTapHoldConfigured: (HardwareControl) -> Bool
    private let candidateThreads: (HardwareControl) -> [CodexThreadDescriptor]
    private let assignedThreadID: (HardwareControl) -> String?
    private let appName: () -> String
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> () -> Void

    private(set) var picker: ThreadPickerPresentation?
    var isSelecting: Bool { picker != nil }

    var onAssign: ((CodexThreadDescriptor, HardwareControl) -> Void)?
    var onTap: ((HardwareControl) -> Void)?
    var onPickerWillOpen: (() -> Void)?
    var onPickerChanged: ((ThreadPickerPresentation?) -> Void)?
    var onSelectionStarted: (() -> Void)?
    /// `true` means a different/new thread was assigned; `false` is a safe
    /// no-op or cancellation and must restore lighting without a flash.
    var onSelectionFinished: ((Bool) -> Void)?

    init(
        isEnabled: @escaping () -> Bool,
        isDesignatedAgentControl: @escaping (HardwareControl) -> Bool,
        isTapHoldConfigured: @escaping (HardwareControl) -> Bool,
        candidateThreads: @escaping (HardwareControl) -> [CodexThreadDescriptor],
        assignedThreadID: @escaping (HardwareControl) -> String?,
        appName: @escaping () -> String,
        schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> () -> Void = CodexQuickAssignService.timerSchedule
    ) {
        self.isEnabled = isEnabled
        self.isDesignatedAgentControl = isDesignatedAgentControl
        self.isTapHoldConfigured = isTapHoldConfigured
        self.candidateThreads = candidateThreads
        self.assignedThreadID = assignedThreadID
        self.appName = appName
        self.schedule = schedule
    }

    private static func timerSchedule(interval: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in fire() }
        }
        return { timer.invalidate() }
    }

    nonisolated static func recentCandidates(
        from threads: [CodexThreadDescriptor],
        assignedThreadID: String?,
        limit: Int = 10
    ) -> [CodexThreadDescriptor] {
        guard limit > 0 else { return [] }
        let sorted = threads.sorted { $0.updatedAt > $1.updatedAt }
        var result = Array(sorted.prefix(limit))
        guard
            let assignedThreadID,
            !result.contains(where: { $0.id == assignedThreadID }),
            let assigned = sorted.first(where: { $0.id == assignedThreadID })
        else { return result }
        if result.count == limit { result.removeLast() }
        result.append(assigned)
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func handle(_ event: CodexPadPhysicalEvent) {
        guard let control = HardwareControl(reportedControlIndex: event.control) else { return }

        if control == .encoderLeft || control == .encoderRight {
            guard event.phase == .triggered, isSelecting else { return }
            rotate(towardOlder: control == .encoderRight)
            return
        }

        guard HardwareControl.buttons.contains(control) else { return }
        switch event.phase {
        case .pressed:
            beginPendingPress(control)
        case .released:
            if picker?.control == control {
                commitSelection()
            } else if cancelPending(control) {
                onTap?(control)
            }
        case .triggered:
            guard isEnabled(), isDesignatedAgentControl(control), !isTapHoldConfigured(control) else { return }
            onTap?(control)
        }
    }

    func refreshCandidates() {
        guard let current = picker else { return }
        let previouslySelectedID = current.selectedThread?.id
        let threads = candidateThreads(current.control)
        let selectedIndex = selectedIndex(
            in: threads,
            preferredID: previouslySelectedID ?? current.assignedThreadID
        )
        picker = ThreadPickerPresentation(
            control: current.control,
            appName: current.appName,
            threads: threads,
            selectedIndex: selectedIndex,
            assignedThreadID: current.assignedThreadID
        )
        onPickerChanged?(picker)
    }

    func cancelSelection() {
        pendingPresses.values.forEach { $0.cancel() }
        pendingPresses.removeAll()
        guard picker != nil else { return }
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        picker = nil
        onPickerChanged?(nil)
        onSelectionFinished?(false)
    }

    private func beginPendingPress(_ control: HardwareControl) {
        cancelPending(control)
        guard
            picker == nil,
            isEnabled(),
            isDesignatedAgentControl(control),
            !isTapHoldConfigured(control)
        else { return }
        let cancel = schedule(Double(Self.holdThresholdMilliseconds) / 1_000) { [weak self] in
            self?.beginSelection(control)
        }
        pendingPresses[control] = PendingPress(cancel: cancel)
    }

    private func beginSelection(_ control: HardwareControl) {
        pendingPresses.removeValue(forKey: control)
        guard isEnabled(), isDesignatedAgentControl(control) else { return }
        onPickerWillOpen?()
        let assignedID = assignedThreadID(control)
        let threads = candidateThreads(control)
        picker = ThreadPickerPresentation(
            control: control,
            appName: appName(),
            threads: threads,
            selectedIndex: selectedIndex(in: threads, preferredID: assignedID),
            assignedThreadID: assignedID
        )
        onSelectionStarted?()
        onPickerChanged?(picker)
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.selectionSafetyTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.cancelSelection()
        }
    }

    private func selectedIndex(in threads: [CodexThreadDescriptor], preferredID: String?) -> Int? {
        guard !threads.isEmpty else { return nil }
        if let preferredID {
            return threads.firstIndex(where: { $0.id == preferredID })
        }
        return 0
    }

    private func rotate(towardOlder: Bool) {
        guard var picker, !picker.threads.isEmpty else { return }
        if let current = picker.selectedIndex {
            picker.selectedIndex = towardOlder
                ? (current + 1) % picker.threads.count
                : (current - 1 + picker.threads.count) % picker.threads.count
        } else {
            picker.selectedIndex = towardOlder ? 0 : picker.threads.count - 1
        }
        self.picker = picker
        onPickerChanged?(picker)
    }

    private func commitSelection() {
        guard let picker else { return }
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        self.picker = nil
        onPickerChanged?(nil)
        guard
            let selected = picker.selectedThread,
            selected.id != picker.assignedThreadID
        else {
            onSelectionFinished?(false)
            return
        }
        onAssign?(selected, picker.control)
        onSelectionFinished?(true)
    }

    @discardableResult
    private func cancelPending(_ control: HardwareControl) -> Bool {
        guard let pending = pendingPresses.removeValue(forKey: control) else { return false }
        pending.cancel()
        return true
    }
}
