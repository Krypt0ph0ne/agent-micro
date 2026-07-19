import AppKit
import SwiftUI

@main
struct CodexPadApp: App {
    @NSApplicationDelegateAdaptor(CodexPadAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("CodexPad", id: "main") {
            MainWindowView(appState: appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 820, height: 520)
        .windowResizability(.contentMinSize)
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

final class CodexPadAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
