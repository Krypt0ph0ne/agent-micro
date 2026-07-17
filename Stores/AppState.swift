import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    let catalog: CodexActionCatalog
    let diagnostics: DiagnosticsStore
    let profiles: ProfileStore
    let device: DeviceService
    let inputMonitor: HIDInputMonitor
    let reasoningAutomation: CodexReasoningAutomationService

    init() {
        let catalog = CodexActionCatalog()
        let diagnostics = DiagnosticsStore()
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.profiles = ProfileStore(catalog: catalog)
        self.device = DeviceService(diagnostics: diagnostics)
        self.inputMonitor = HIDInputMonitor()
        self.reasoningAutomation = CodexReasoningAutomationService()
    }

    func refreshDevice() {
        device.refresh()
    }
}
