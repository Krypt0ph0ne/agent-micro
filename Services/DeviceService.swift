import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class DeviceService {
    private let logger = Logger(subsystem: "io.github.krypt0ph0ne.agentmicro", category: "device")
    private let detector: DeviceDetector
    private let processClient: CH57xProcessClient
    private let codexPadClient: CodexPadHIDClient
    private let codexPadEncoder = CodexPadPacketEncoder()
    private let encoder = CH57xConfigurationEncoder()
    private let diagnostics: DiagnosticsStore

    private(set) var state: DeviceConnectionState = .scanning
    private(set) var isBusy = false
    private(set) var lastSuccessfulUpload: Date?
    private(set) var lastGeneratedConfiguration = ""
    private(set) var detectedDevices: [ConnectedDevice] = []
    var selectedDiagnosticDeviceID: String?

    init(diagnostics: DiagnosticsStore, detector: DeviceDetector = DeviceDetector(), processClient: CH57xProcessClient = CH57xProcessClient(), codexPadClient: CodexPadHIDClient = CodexPadHIDClient()) {
        self.diagnostics = diagnostics
        self.detector = detector
        self.processClient = processClient
        self.codexPadClient = codexPadClient
    }

    var currentDevice: ConnectedDevice? {
        switch state {
        case .connected(let device), .unsupported(let device): device
        default: nil
        }
    }

    /// Re-checks the USB inventory. Background checks deliberately retain the
    /// last visible connection state while `ioreg` runs: switching through
    /// `.scanning` every time makes the Pad indicator (and the upload button)
    /// flicker despite an unchanged, healthy device.
    func refresh(reportDiagnostics: Bool = true, showsScanningState: Bool = true) {
        if showsScanningState {
            state = .scanning
        }
        let report = detector.detect()
        diagnostics.setRawIORegistry(report.rawIORegistry)
        detectedDevices = report.candidates
        if selectedDiagnosticDeviceID == nil || !report.candidates.contains(where: { $0.id == selectedDiagnosticDeviceID }) {
            selectedDiagnosticDeviceID = report.device?.id
        }
        if let device = report.device {
            if device.support == .supported {
                state = .connected(device)
                if reportDiagnostics {
                    diagnostics.append(.success, AppLanguage.text("Unterstütztes Gerät erkannt", "Supported device detected"), detail: "\(device.name) · \(device.vendorIDHex):\(device.productIDHex)")
                }
            } else {
                state = .unsupported(device)
                if reportDiagnostics {
                    diagnostics.append(
                        .warning,
                        device.support == .related
                            ? AppLanguage.text("CH57x-HID erkannt, aber nicht konfigurierbar", "CH57x HID detected, but not configurable")
                            : AppLanguage.text("Nicht unterstütztes USB-Gerät", "Unsupported USB device"),
                        detail: device.diagnosticSummary
                    )
                }
            }
        } else {
            state = .disconnected
            if reportDiagnostics {
                diagnostics.append(
                    .warning,
                    AppLanguage.text("Kein unterstütztes Gerät", "No supported device"),
                    detail: report.error ?? AppLanguage.text("Unbekannter Erkennungsfehler", "Unknown detection error")
                )
            }
        }
    }

    var selectedDiagnosticDevice: ConnectedDevice? {
        guard let selectedDiagnosticDeviceID else { return currentDevice }
        return detectedDevices.first(where: { $0.id == selectedDiagnosticDeviceID }) ?? currentDevice
    }

    @discardableResult
    func validate(profile: MacropadProfile, keyboardLayout: KeyboardLayout = .usANSI) -> ProcessResult? {
        if currentDevice?.isCodexPadFirmware == true {
            do {
                let packets = try codexPadEncoder.uploadPackets(profile: profile, layout: keyboardLayout)
                let result = ProcessResult(
                    exitCode: 0,
                    stdout: AppLanguage.text(
                        "\(packets.count) lokale HID-Pakete sind gültig.",
                        "\(packets.count) local HID packets are valid."
                    ),
                    stderr: "",
                    timedOut: false,
                    launchError: nil
                )
                diagnostics.record(result, title: AppLanguage.text("CH552-Profil validieren", "Validate CH552 profile"))
                return result
            } catch {
                diagnostics.append(.error, AppLanguage.text("Lokale CH552-Validierung fehlgeschlagen", "Local CH552 validation failed"), detail: error.localizedDescription)
                return nil
            }
        }
        do {
            let configuration = try encoder.encode(profile: profile)
            lastGeneratedConfiguration = configuration
            let result = processClient.validate(configuration: configuration)
            diagnostics.record(result, title: AppLanguage.text("Konfiguration validieren", "Validate configuration"))
            logger.info("Validated profile \(profile.name, privacy: .public): \(result.succeeded, privacy: .public)")
            return result
        } catch {
            diagnostics.append(.error, AppLanguage.text("Lokale Validierung fehlgeschlagen", "Local validation failed"), detail: error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func upload(profile: MacropadProfile, keyboardLayout: KeyboardLayout = .usANSI) -> ProcessResult? {
        guard state.isSupportedConnection else {
            diagnostics.append(
                .error,
                AppLanguage.text("Upload blockiert", "Transfer blocked"),
                detail: AppLanguage.text("Kein unterstütztes CH57x-Gerät verbunden.", "No supported CH57x device connected.")
            )
            return nil
        }
        guard !isBusy else {
            diagnostics.append(.warning, AppLanguage.text("Upload läuft bereits", "A transfer is already running"))
            return nil
        }
        isBusy = true
        defer { isBusy = false }

        let validation = validate(profile: profile, keyboardLayout: keyboardLayout)
        guard validation?.succeeded == true else {
            diagnostics.append(
                .error,
                AppLanguage.text("Upload nicht ausgeführt", "Transfer not performed"),
                detail: AppLanguage.text("Die Konfiguration muss zuerst erfolgreich validieren.", "The configuration has to validate successfully first.")
            )
            return validation
        }

        if currentDevice?.isCodexPadFirmware == true {
            do {
                let packets = try codexPadEncoder.uploadPackets(profile: profile, layout: keyboardLayout)
                let result = codexPadClient.send(packets)
                diagnostics.record(result, title: AppLanguage.text("Profil und RGB live an CH552 übertragen", "Transfer profile and RGB live to the CH552"))
                if result.succeeded {
                    lastSuccessfulUpload = .now
                    diagnostics.append(
                        .success,
                        AppLanguage.text("CH552-Profil aktiv", "CH552 profile active"),
                        detail: AppLanguage.text(
                            "Neun Eingabebelegungen und die konfigurierte Idle-Beleuchtung wurden übertragen.",
                            "Nine input mappings and the configured idle lighting were transferred."
                        )
                    )
                }
                return result
            } catch {
                diagnostics.append(.error, AppLanguage.text("CH552-Upload fehlgeschlagen", "CH552 transfer failed"), detail: error.localizedDescription)
                return nil
            }
        }

        let target = CH57xDeviceTarget.ch57x8890
        guard target.matches(currentDevice) else {
            diagnostics.append(
                .error,
                AppLanguage.text("Upload blockiert", "Transfer blocked"),
                detail: AppLanguage.text(
                    "Das erkannte Gerät stimmt nicht mit dem sicheren Ziel \(String(format: "%04X:%04X", target.vendorID, target.productID)) überein.",
                    "The detected device does not match the safe target \(String(format: "%04X:%04X", target.vendorID, target.productID))."
                )
            )
            return nil
        }

        let result = processClient.upload(configuration: lastGeneratedConfiguration, target: target)
        diagnostics.record(result, title: AppLanguage.text("Konfiguration auf Gerät übertragen", "Transfer configuration to the device"))
        if result.succeeded {
            lastSuccessfulUpload = .now
            diagnostics.append(
                .success,
                AppLanguage.text("Transport erfolgreich", "Transport succeeded"),
                detail: AppLanguage.text(
                    "Helper: Exit 0, stderr leer, Ziel \(String(format: "%04X:%04X", target.vendorID, target.productID)), vorherige Validierung erfolgreich. Die physische Eingabe muss im Eingabe-Test bestätigt werden.",
                    "Helper: exit 0, stderr empty, target \(String(format: "%04X:%04X", target.vendorID, target.productID)), prior validation successful. Physical input still has to be confirmed in the input test."
                )
            )
        } else {
            diagnostics.append(.error, AppLanguage.text("Upload nicht bestätigt", "Transfer not confirmed"), detail: result.failureDescription)
        }
        return result
    }

    @discardableResult
    func setLEDMode(_ mode: Int) -> ProcessResult? {
        guard state.isSupportedConnection,
              currentDevice?.capabilities.supportedLEDModes.contains(mode) == true else {
            diagnostics.append(
                .error,
                AppLanguage.text("LED-Modus nicht gesetzt", "LED mode not set"),
                detail: AppLanguage.text(
                    "Kein unterstütztes Gerät verbunden oder LED-Modus \(mode) nicht verfügbar.",
                    "No supported device connected, or LED mode \(mode) is unavailable."
                )
            )
            return nil
        }
        let result = processClient.setConfirmedLEDMode(mode, target: .ch57x8890)
        diagnostics.record(result, title: AppLanguage.text("LED-Modus \(mode) setzen", "Set LED mode \(mode)"))
        return result
    }

    @discardableResult
    func applyLED(_ setting: KeyLEDConfiguration) -> ProcessResult? {
        applyLEDs([setting])
    }

    @discardableResult
    func applyLEDs(_ settings: [KeyLEDConfiguration]) -> ProcessResult? {
        guard !settings.isEmpty else { return nil }
        guard currentDevice?.isCodexPadFirmware == true else {
            diagnostics.append(
                .error,
                AppLanguage.text("RGB nicht übertragen", "RGB not transferred"),
                detail: AppLanguage.text("Keine eigene CH552-Agent-Micro-Firmware verbunden.", "No custom CH552 Agent Micro firmware connected.")
            )
            return nil
        }
        let result = codexPadClient.send(settings.map(codexPadEncoder.ledPacket))
        let title = settings.count == 1
            ? AppLanguage.text("\(settings[0].control.title) RGB anwenden", "Apply RGB for \(settings[0].control.title)")
            : AppLanguage.text("Alle RGB-Einstellungen anwenden", "Apply all RGB settings")
        diagnostics.record(result, title: title)
        return result
    }

    @discardableResult
    func turnOffCustomLEDs() -> ProcessResult? {
        guard currentDevice?.isCodexPadFirmware == true else { return nil }
        let result = codexPadClient.send([codexPadEncoder.allOffPacket()])
        diagnostics.record(result, title: AppLanguage.text("Alle CH552-LEDs ausschalten", "Turn off all CH552 LEDs"))
        return result
    }
}
