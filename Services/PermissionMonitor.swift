import AppKit
import ApplicationServices
import Foundation
import Observation
import OSLog
import UserNotifications

/// Single source of truth for the two TCC grants CodexPad's automation
/// needs (Accessibility to post keystrokes, Input Monitoring to read the
/// pad's HID reports). Every service that used to call
/// `AXIsProcessTrusted()`/`CGPreflightListenEventAccess()` itself now reads
/// from here instead, so there is exactly one place refreshing state and
/// exactly one place that can notice a revocation.
///
/// Refreshed both when the app becomes active (catches "user just came back
/// from System Settings") and on a background timer, since CodexPad mostly
/// lives in the menu bar with no window open — without the timer, a
/// revocation while headless would never be re-detected.
@MainActor
@Observable
final class PermissionMonitor {
    private let logger = Logger(subsystem: "com.codexpad.app", category: "permissions")
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

    /// Prompts macOS for both grants (each shows its own system dialog the
    /// first time only) and refreshes immediately after.
    func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = CGRequestListenEventAccess()
        refresh()
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
                title: "Bedienungshilfen entzogen",
                body: "CodexPad kann keine Tastenkombinationen mehr senden. Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen wieder erlauben."
            )
        }
        if hasInputMonitoringPermission, !inputMonitoring {
            notifyRevoked(
                title: "Input Monitoring entzogen",
                body: "Drehrad und Tasten werden nicht mehr erkannt. Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Input Monitoring wieder erlauben."
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
