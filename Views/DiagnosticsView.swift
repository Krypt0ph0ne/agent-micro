import SwiftUI

struct DiagnosticsView: View {
    let appState: AppState
    @State private var showingRaw = false
    @State private var logsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Diagnose").font(.largeTitle.weight(.semibold))
                        Text("USB-/HID-Daten, sauber erfasste Helper-Ausgaben und ein passiver Eingabe-Test. Keine Telemetrie, keine Hersteller-Software.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Erneut erfassen") { appState.refreshDevice() }
                }

                DeviceDiagnosticsCard(appState: appState)
                CodexPadProtocolCard(appState: appState)
                InputMonitorCard(appState: appState)
                AgentBridgeDiagnosticsCard(title: "Codex Event Bridge", icon: "bolt.horizontal.circle", store: appState.codexThreads)
                AgentBridgeDiagnosticsCard(title: "Claude Agent Bridge", icon: "bolt.horizontal.circle", store: appState.claudeThreads)

                DisclosureGroup("Prozess- und App-Logs", isExpanded: $logsExpanded) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.diagnostics.entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: symbol(for: entry.level)).foregroundStyle(color(for: entry.level))
                                    Text(entry.title).font(.headline)
                                    Spacer()
                                    Text(entry.date, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                                }
                                if !entry.detail.isEmpty {
                                    Text(entry.detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                DisclosureGroup("Rohe IORegistry-Ausgabe", isExpanded: $showingRaw) {
                    TextEditor(text: .constant(appState.diagnostics.rawIORegistry))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 240)
                        .textSelection(.enabled)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(24)
        }
    }

    private func symbol(for level: DiagnosticEntry.Level) -> String {
        switch level { case .info: "info.circle"; case .success: "checkmark.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.octagon" }
    }

    private func color(for level: DiagnosticEntry.Level) -> Color {
        switch level { case .info: .blue; case .success: .green; case .warning: .orange; case .error: .red }
    }
}

private struct AgentBridgeDiagnosticsCard: View {
    let title: String
    let icon: String
    let store: CodexThreadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                Button("Threads laden") { store.refresh() }
                Button("Neu verbinden") { store.reconnect() }
            }
            LabeledContent("Verbindung", value: store.connectionState.title)
            LabeledContent("Geladene Threads", value: "\(store.threads.count)")
            LabeledContent("Tastenzuordnungen", value: "\(store.assignments.count) / 6")
            Text("Approval- und Nutzereingabe-Requests werden ausschließlich als Status beobachtet und nie beantwortet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = store.connectionError {
                Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct CodexPadProtocolCard: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Agent Micro-Protokoll", systemImage: "externaldrive.connected.to.line.below")
                    .font(.headline)
                Spacer()
                Button("Status abfragen") { appState.padEvents.requestStatus() }
            }
            Text(appState.padEvents.status).font(.caption).foregroundStyle(.secondary)
            if let firmware = appState.padEvents.firmwareStatus {
                LabeledContent("Firmware", value: firmware.version)
                LabeledContent("Fähigkeiten", value: String(format: "0x%02X", firmware.capabilities))
                LabeledContent("Gedrückte Controls", value: String(format: "0x%03X", firmware.pressedMask))
            }
            if let event = appState.padEvents.events.first {
                LabeledContent("Letztes physisches Ereignis", value: "Control \(event.control + 1) · \(String(describing: event.phase)) · #\(event.sequence)")
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DeviceDiagnosticsCard: View {
    let appState: AppState

    var body: some View {
        @Bindable var device = appState.device
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("USB- und HID-Gerät", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                if !device.detectedDevices.isEmpty {
                    Picker("Diagnosegerät", selection: $device.selectedDiagnosticDeviceID) {
                        ForEach(device.detectedDevices) { candidate in
                            Text("\(candidate.vendorIDHex):\(candidate.productIDHex) · \(candidate.name)").tag(Optional(candidate.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 330)
                }
            }
            if let device = device.selectedDiagnosticDevice {
                LabeledContent("Name", value: device.name)
                LabeledContent("Vendor / Product", value: "\(device.vendorIDHex) / \(device.productIDHex)")
                LabeledContent("Location ID", value: device.locationID)
                LabeledContent("Hersteller", value: device.manufacturer ?? "nicht bereitgestellt")
                LabeledContent("Produktstring", value: device.productName ?? "nicht bereitgestellt")
                LabeledContent("Seriennummer", value: device.serialNumber ?? "nicht bereitgestellt")
                LabeledContent("Status", value: device.support == .supported ? "Upload verifiziert" : device.support == .related ? "CH57x erkannt, Upload gesperrt" : "Nicht CH57x")
                if !device.interfaces.isEmpty {
                    Divider()
                    Text("USB-Interfaces").font(.subheadline.weight(.medium))
                    ForEach(device.interfaces) { interface in
                        Text(interface.summary).font(.caption.monospaced())
                    }
                }
                if !device.hidCollections.isEmpty {
                    Text("HID Collections").font(.subheadline.weight(.medium))
                    ForEach(device.hidCollections) { collection in
                        Text(collection.summary).font(.caption.monospaced())
                    }
                }
                Text(device.diagnosticSummary).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Kein USB-Gerät im IORegistry-Scan. Das unterscheidet sich bewusst von „CH57x erkannt, aber nicht unterstützt“.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct InputMonitorCard: View {
    let appState: AppState

    var body: some View {
        @Bindable var monitor = appState.inputMonitor
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Eingabe-Testmonitor", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Button(monitor.isMonitoring ? "Stoppen" : "Starten") {
                    monitor.isMonitoring ? monitor.stop() : monitor.start()
                }
                .disabled(!appState.device.state.isSupportedConnection && !monitor.isMonitoring)
                Button("Leeren") { monitor.clear() }.disabled(monitor.events.isEmpty)
            }
            Text(monitor.status).font(.caption).foregroundStyle(.secondary)
            if !monitor.hasInputMonitoringPermission {
                Text("Input Monitoring ist für vollständige globale Beobachtung wahrscheinlich erforderlich. Agent Micro liest Ereignisse nur passiv und kann sie nicht blockieren.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if monitor.events.isEmpty {
                Text("Für den sicheren Test F13 bis F21 hochladen, Monitor starten und alle sechs Keys sowie Encoder links / Druck / rechts einmal auslösen.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.events.prefix(12)) { event in
                    HStack { Text(event.label).font(.system(.body, design: .monospaced)); Spacer(); Text(event.date, format: .dateTime.hour().minute().second()) }
                        .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
