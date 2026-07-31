import Foundation

/// Common surface both `CodexReasoningAutomationService` and
/// `ClaudeReasoningAutomationService` expose, so encoder UI (status row,
/// permission checks, gesture-simulation buttons) can bind to whichever one
/// matches the currently selected profile without knowing which app it is.
@MainActor
protocol EncoderAutomationService: AnyObject {
    var isEnabled: Bool { get set }
    var status: String { get }
    var lastInput: String { get }
    var hasAccessibilityPermission: Bool { get }
    var hasInputMonitoringPermission: Bool { get }
    /// Custom Agent Micro firmware delivers encoder edges through its raw HID
    /// protocol, so it does not need the system-wide Input Monitoring grant.
    var usesPhysicalEncoderEvents: Bool { get }

    func requestPermissions()
    func refreshPermissions()
    func testBeginHold()
    func testRotate(_ step: CodexModelListStep)
    func testEndHold()
}
