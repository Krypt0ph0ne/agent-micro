import AppKit
import SwiftUI

/// Menu bar presence so CodexPad stays reachable after the main window is
/// closed. The app no longer quits when its last window closes (see
/// `CodexPadAppDelegate`), so this is the only way back into the UI without
/// relaunching — which matters because the Codex event bridge, HID listening
/// and hold-to-assign quick assign all keep running in the background.
///
/// Clicking the status item shows a popover with a simplified version of the
/// app (current switch assignments, quick reassign) instead of a plain
/// dropdown menu, so the day-to-day "which key does what" check doesn't
/// require opening the main window.
@MainActor
final class CodexPadStatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func install(appState: AppState) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.3x2.fill", accessibilityDescription: "CodexPad")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        let hostingController = NSHostingController(
            rootView: MenuBarPopoverView(
                appState: appState,
                onOpenMainApp: { [weak self] in self?.openMainWindow() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openMainWindow() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        OpenWindowBridge.shared.openMainWindow?()
    }
}
