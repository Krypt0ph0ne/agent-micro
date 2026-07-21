import Observation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` so CodexPad can optionally
/// launch at login — the background/menu-bar mode is only actually useful
/// for hold-to-assign if the app is already running.
@MainActor
@Observable
final class LoginItemService {
    private(set) var isEnabled: Bool

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration can fail (e.g. outside a signed .app bundle during
            // `swift run`); reflect the actual resulting state either way.
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
