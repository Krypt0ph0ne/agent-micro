import AppKit
import SwiftUI

@main
struct CodexPadApp: App {
    @NSApplicationDelegateAdaptor(CodexPadAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("CodexPad", id: "main") {
            MainWindowView(appState: appState)
                .frame(width: 620, height: 405)
        }
        .defaultSize(width: 620, height: 405)
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

final class CodexPadAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
