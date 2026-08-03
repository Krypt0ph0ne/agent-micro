import AppKit
import ApplicationServices
import Foundation
import Observation
import OSLog
import UserNotifications

enum SystemPrivacySettingsPane: String, CaseIterable {
    case accessibility = "Privacy_Accessibility"
    case inputMonitoring = "Privacy_ListenEvent"

    var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
    }
}

/// Single source of truth for the TCC grants Agent Micro can use:
/// Accessibility is required to control Codex/Claude; Input Monitoring is
/// only required for legacy keyboard-HID input and the optional passive
/// diagnostics monitor. The direct Agent Micro pad protocol does not need it.
/// Every service that used to call
/// `AXIsProcessTrusted()`/`CGPreflightListenEventAccess()` itself now reads
/// from here instead, so there is exactly one place refreshing state and
/// exactly one place that can notice a revocation.
///
/// Refreshed both when the app becomes active (catches "user just came back
/// from System Settings") and on a background timer, since Agent Micro mostly
/// lives in the menu bar with no window open — without the timer, a
/// revocation while headless would never be re-detected.
@MainActor
@Observable
final class PermissionMonitor {
    private let logger = Logger(subsystem: "io.github.krypt0ph0ne.agentmicro", category: "permissions")
    private static let pollIntervalSeconds: TimeInterval = 7

    private(set) var hasAccessibilityPermission: Bool
    private(set) var hasInputMonitoringPermission: Bool

    private var pollTimer: Timer?
    private var didRequestNotificationAuthorization = false

    /// Lives for the app's entire run (owned once by `AppState`), so there's
    /// no deallocation path that needs to invalidate `pollTimer` or remove
    /// the notification observer.
    init() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasInputMonitoringPermission = CGPreflightListenEventAccess()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Requests both grants for legacy keyboard-HID pads and leaves System
    /// Settings on the first missing pane. Direct-protocol callers use
    /// `requestAccessibilityPermission()` instead.
    func requestPermissions() {
        let targetPane: SystemPrivacySettingsPane = hasAccessibilityPermission
            ? .inputMonitoring
            : .accessibility
        requestAccessibilityPrompt()
        _ = CGRequestListenEventAccess()
        openSettings(targetPane)
        refresh()
    }

    func requestAccessibilityPermission() {
        requestAccessibilityPrompt()
        openSettings(.accessibility)
        refresh()
    }

    private func requestAccessibilityPrompt() {
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
    }

    private func openSettings(_ pane: SystemPrivacySettingsPane) {
        guard NSWorkspace.shared.open(pane.url) else {
            logger.error("Could not open System Settings pane: \(pane.rawValue, privacy: .public)")
            return
        }
        logger.info("Opened System Settings pane: \(pane.rawValue, privacy: .public)")
    }

    /// Local-notification authorization is its own separate, one-time prompt;
    /// call once at first run so a later revocation can actually alert the user.
    func requestNotificationAuthorizationIfNeeded() {
        guard !didRequestNotificationAuthorization else { return }
        didRequestNotificationAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error {
                self?.logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func refresh() {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        if hasAccessibilityPermission, !accessibility {
            notifyRevoked(
                title: AppLanguage.text("Bedienungshilfen entzogen", "Accessibility permission revoked"),
                body: AppLanguage.text(
                    "Agent Micro kann keine Tastenkombinationen mehr senden. Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen wieder erlauben.",
                    "Agent Micro can no longer send keyboard shortcuts. Re-enable it in System Settings → Privacy & Security → Accessibility."
                )
            )
        }
        if hasInputMonitoringPermission, !inputMonitoring {
            notifyRevoked(
                title: AppLanguage.text("Input Monitoring entzogen", "Input Monitoring revoked"),
                body: AppLanguage.text(
                    "Legacy-Keyboard-HID und der passive Diagnosemonitor können keine Eingaben mehr sehen. Das direkte Agent-Micro-Pad-Protokoll bleibt davon unberührt.",
                    "Legacy keyboard HID and the passive diagnostics monitor can no longer see input. The direct Agent Micro pad protocol is unaffected."
                )
            )
        }
        hasAccessibilityPermission = accessibility
        hasInputMonitoringPermission = inputMonitoring
    }

    private func notifyRevoked(title: String, body: String) {
        logger.error("\(title, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to post permission notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
