import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class DeviceService {
    private let logger = Logger(subsystem: "com.codexpad.app", category: "device")
    private let detector: DeviceDetector
    private let processClient: CH57xProcessClient
    private let encoder = CH57xConfigurationEncoder()
    private let diagnostics: DiagnosticsStore

    private(set) var state: DeviceConnectionState = .scanning
    private(set) var isBusy = false
    private(set) var lastSuccessfulUpload: Date?
    private(set) var lastGeneratedConfiguration = ""
    private(set) var detectedDevices: [ConnectedDevice] = []
    var selectedDiagnosticDeviceID: String?

    init(diagnostics: DiagnosticsStore, detector: DeviceDetector = DeviceDetector(), processClient: CH57xProcessClient = CH57xProcessClient()) {
        self.diagnostics = diagnostics
        self.detector = detector
        self.processClient = processClient
    }

    var currentDevice: ConnectedDevice? {
        switch state {
        case .connected(let device), .unsupported(let device): device
        default: nil
        }
    }

    func refresh() {
        state = .scanning
        let report = detector.detect()
        diagnostics.setRawIORegistry(report.rawIORegistry)
        detectedDevices = report.candidates
        if selectedDiagnosticDeviceID == nil || !report.candidates.contains(where: { $0.id == selectedDiagnosticDeviceID }) {
            selectedDiagnosticDeviceID = report.device?.id
        }
        if let device = report.device {
            if device.support == .supported {
                state = .connected(device)
                diagnostics.append(.success, "Unterstütztes Gerät erkannt", detail: "\(device.name) · \(device.vendorIDHex):\(device.productIDHex)")
            } else {
                state = .unsupported(device)
                diagnostics.append(.warning, device.support == .related ? "CH57x-HID erkannt, aber nicht konfigurierbar" : "Nicht unterstütztes USB-Gerät", detail: device.diagnosticSummary)
            }
        } else {
            state = .disconnected
            diagnostics.append(.warning, "Kein unterstütztes Gerät", detail: report.error ?? "Unbekannter Erkennungsfehler")
        }
    }

    var selectedDiagnosticDevice: ConnectedDevice? {
        guard let selectedDiagnosticDeviceID else { return currentDevice }
        return detectedDevices.first(where: { $0.id == selectedDiagnosticDeviceID }) ?? currentDevice
    }

    @discardableResult
    func validate(profile: MacropadProfile) -> ProcessResult? {
        do {
            let configuration = try encoder.encode(profile: profile)
            lastGeneratedConfiguration = configuration
            let result = processClient.validate(configuration: configuration)
            diagnostics.record(result, title: "Konfiguration validieren")
            logger.info("Validated profile \(profile.name, privacy: .public): \(result.succeeded, privacy: .public)")
            return result
        } catch {
            diagnostics.append(.error, "Lokale Validierung fehlgeschlagen", detail: error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func upload(profile: MacropadProfile) -> ProcessResult? {
        guard state.isSupportedConnection else {
            diagnostics.append(.error, "Upload blockiert", detail: "Kein unterstütztes CH57x-Gerät verbunden.")
            return nil
        }
        guard !isBusy else {
            diagnostics.append(.warning, "Upload läuft bereits")
            return nil
        }
        isBusy = true
        defer { isBusy = false }

        let validation = validate(profile: profile)
        guard validation?.succeeded == true else {
            diagnostics.append(.error, "Upload nicht ausgeführt", detail: "Die Konfiguration muss zuerst erfolgreich validieren.")
            return validation
        }

        let target = CH57xDeviceTarget.ch57x8890
        guard target.matches(currentDevice) else {
            diagnostics.append(.error, "Upload blockiert", detail: "Das erkannte Gerät stimmt nicht mit dem sicheren Ziel \(String(format: "%04X:%04X", target.vendorID, target.productID)) überein.")
            return nil
        }

        let result = processClient.upload(configuration: lastGeneratedConfiguration, target: target)
        diagnostics.record(result, title: "Konfiguration auf Gerät übertragen")
        if result.succeeded {
            lastSuccessfulUpload = .now
            diagnostics.append(.success, "Transport erfolgreich", detail: "Helper: Exit 0, stderr leer, Ziel \(String(format: "%04X:%04X", target.vendorID, target.productID)), vorherige Validierung erfolgreich. Die physische Eingabe muss im Eingabe-Test bestätigt werden.")
        } else {
            diagnostics.append(.error, "Upload nicht bestätigt", detail: result.failureDescription)
        }
        return result
    }

    @discardableResult
    func setLEDMode(_ mode: Int) -> ProcessResult? {
        guard state.isSupportedConnection,
              currentDevice?.capabilities.supportedLEDModes.contains(mode) == true else {
            diagnostics.append(.error, "LED-Modus nicht gesetzt", detail: "Kein unterstütztes Gerät verbunden oder LED-Modus \(mode) nicht verfügbar.")
            return nil
        }
        let result = processClient.setConfirmedLEDMode(mode, target: .ch57x8890)
        diagnostics.record(result, title: "LED-Modus \(mode) setzen")
        return result
    }
}
