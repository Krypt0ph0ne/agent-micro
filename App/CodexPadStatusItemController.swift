import AppKit

/// Menu bar presence so CodexPad stays reachable after the main window is
/// closed. The app no longer quits when its last window closes (see
/// `CodexPadAppDelegate`), so this is the only way back into the UI without
/// relaunching — which matters because the Codex event bridge, HID listening
/// and hold-to-assign quick assign all keep running in the background.
@MainActor
final class CodexPadStatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.3x2.fill", accessibilityDescription: "CodexPad")

        let menu = NSMenu()
        menu.addItem(withTitle: "CodexPad öffnen", action: #selector(showMainWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Beenden", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu

        statusItem = item
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        OpenWindowBridge.shared.openMainWindow?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
