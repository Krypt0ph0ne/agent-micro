import AppKit
import SwiftUI

@main
struct CodexPadApp: App {
    @NSApplicationDelegateAdaptor(CodexPadAppDelegate.self) private var appDelegate
    private var appState: AppState { appDelegate.appState }

    var body: some Scene {
        WindowGroup("Agent Micro", id: "main") {
            WindowBridgeView(id: "main") {
                LanguageAwareView {
                    RootView(appState: appState)
                }
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Gerät erneut suchen") { appState.refreshDevice() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            LanguageAwareView {
                SettingsView(appState: appState)
            }
        }

        Window(AppLanguage.text("Diagnose", "Diagnostics"), id: "diagnostics") {
            LanguageAwareView {
                DiagnosticsView(appState: appState)
                    .frame(width: 460, height: 600)
            }
        }
        .windowResizability(.contentSize)
    }
}

private struct LanguageAwareView<Content: View>: View {
    @AppStorage(AppLanguage.defaultsKey) private var languageRawValue = AppLanguage.systemDefault.rawValue
    @ViewBuilder let content: Content

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRawValue) ?? .systemDefault
    }

    var body: some View {
        content
            .environment(\.locale, language.locale)
            .id(language)
    }
}

/// Gates `MainWindowView` behind `OnboardingView` until the user has been
/// through the first-run permission walkthrough at least once.
private struct RootView: View {
    let appState: AppState
    @AppStorage("CodexPad.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            MainWindowView(appState: appState)
                .frame(width: 410, height: 620)
        } else {
            OnboardingView(appState: appState) { hasCompletedOnboarding = true }
        }
    }
}

@MainActor
final class CodexPadAppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private let statusItemController = CodexPadStatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        statusItemController.install(appState: appState)
        appState.startHardwareServices()
        appState.startAgentBridges()
    }

    /// Closing the main window used to quit Agent Micro, which meant the Codex
    /// bridge connection, HID listening and hold-to-assign all stopped with
    /// it. The menu bar item is now the way back in, so the app stays alive
    /// in the background instead.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
