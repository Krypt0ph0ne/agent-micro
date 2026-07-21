import AppKit
import SwiftUI

@main
struct CodexPadApp: App {
    @NSApplicationDelegateAdaptor(CodexPadAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("CodexPad", id: "main") {
            WindowBridgeView(id: "main") {
                MainWindowView(appState: appState)
                    .frame(width: 440)
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
            SettingsView(appState: appState)
        }
    }
}

@MainActor
final class CodexPadAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = CodexPadStatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        statusItemController.install()
    }

    /// Closing the main window used to quit CodexPad, which meant the Codex
    /// bridge connection, HID listening and hold-to-assign all stopped with
    /// it. The menu bar item is now the way back in, so the app stays alive
    /// in the background instead.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
