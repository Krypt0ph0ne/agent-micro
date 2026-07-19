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
    let padEvents: CodexPadEventService

    init() {
        let catalog = CodexActionCatalog()
        let diagnostics = DiagnosticsStore()
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.profiles = ProfileStore(catalog: catalog)
        self.device = DeviceService(diagnostics: diagnostics)
        self.inputMonitor = HIDInputMonitor()
        self.reasoningAutomation = CodexReasoningAutomationService()
        self.padEvents = CodexPadEventService()
    }

    func refreshDevice() {
        device.refresh()
        padEvents.refresh(enabled: device.currentDevice?.isCodexPadFirmware == true)
    }
}
