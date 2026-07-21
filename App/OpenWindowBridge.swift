import SwiftUI

/// Lets the AppKit-side status item reopen the SwiftUI `WindowGroup` window
/// after the user closes it. SwiftUI only exposes `openWindow` as an
/// environment action inside a View, so `WindowBridgeView` captures it once
/// on appear and stores it here for the menu bar controller to call.
@MainActor
final class OpenWindowBridge {
    static let shared = OpenWindowBridge()
    var openMainWindow: (() -> Void)?
}

struct WindowBridgeView<Content: View>: View {
    let id: String
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onAppear { OpenWindowBridge.shared.openMainWindow = { openWindow(id: id) } }
    }
}
