import SwiftUI

struct SettingsView: View {
    let appState: AppState
    @State private var resultText: String?
    @State private var showDiagnostics = false

    var body: some View {
        @Bindable var profiles = appState.profiles
        @Bindable var automation = appState.reasoningAutomation

        Form {
            Section("Profil") {
                TextField(
                    "Name",
                    text: Binding(
                        get: { profiles.selectedProfile.name },
                        set: { profiles.renameSelected(to: $0) }
                    )
                )

                HStack {
                    Button("Neu") { profiles.newProfile() }
                        .frame(maxWidth: .infinity)
                    Button("Duplizieren") { profiles.duplicateSelected() }
                        .frame(maxWidth: .infinity)
                    Button("Löschen", role: .destructive) { profiles.deleteSelected() }
                        .frame(maxWidth: .infinity)
                }
            }

            Section("Tastaturlayout") {
                Picker("Tastaturlayout", selection: $profiles.keyboardLayout) {
                    ForEach(KeyboardLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(profiles.keyboardLayout.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Codex Reasoning · Drehrad") {
                Toggle(isOn: $automation.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drehradsteuerung aktiv")
                        Text("Drehen sendet F18/F19, Druck schaltet die Modellwahl")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    PermissionStatus(
                        title: "Input Monitoring",
                        isGranted: automation.hasInputMonitoringPermission
                    )
                    PermissionStatus(
                        title: "Accessibility",
                        isGranted: automation.hasAccessibilityPermission
                    )
                }

                HStack {
                    Button("− testen") { automation.perform(.decreaseEffort) }
                        .frame(maxWidth: .infinity)
                    Button("Picker") { automation.toggleModelPicker() }
                        .frame(maxWidth: .infinity)
                    Button("+ testen") { automation.perform(.increaseEffort) }
                        .frame(maxWidth: .infinity)
                }
                .disabled(!automation.isEnabled)

                if !automation.hasInputMonitoringPermission || !automation.hasAccessibilityPermission {
                    Button("Berechtigungen anfordern") { automation.requestPermissions() }
                }

                Text(automation.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Layer · Codex ⇄ Claude Code") {
                Toggle(isOn: $profiles.layerSwitchEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Layer per Tasten-Chord umschalten")
                        Text("Beide Umschalt-Tasten zusammen halten wechselt Codex ⇄ Claude Code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Picker("Taste A", selection: switchKeyBinding(0)) {
                        ForEach(HardwareControl.buttons) { Text($0.title).tag($0) }
                    }
                    Picker("Taste B", selection: switchKeyBinding(1)) {
                        ForEach(HardwareControl.buttons) { Text($0.title).tag($0) }
                    }
                }
                .disabled(!profiles.layerSwitchEnabled)

                Picker("LED beim Wechsel", selection: $profiles.layerSwitchLightMode) {
                    ForEach(LayerSwitchLightMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!profiles.layerSwitchEnabled)

                Text(profiles.layerSwitchLightMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ColorPicker("Codex-Farbe", selection: layerColorBinding(.codex), supportsOpacity: false)
                ColorPicker("Claude-Farbe", selection: layerColorBinding(.claude), supportsOpacity: false)

                HStack {
                    Text("Helligkeit")
                    Slider(
                        value: Binding(
                            get: { Double(profiles.layerSwitchBrightness) },
                            set: { profiles.layerSwitchBrightness = UInt8(clamping: Int($0)) }
                        ),
                        in: 20...255,
                        step: 1
                    )
                    Text("\(Int(Double(profiles.layerSwitchBrightness) / 255 * 100)) %")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!profiles.layerSwitchEnabled)

                Text("Die Umschalt-Tasten senden beim einzelnen Tippen ihre normale Aktion; beim Halten beider schalten sie nur um und lösen selbst nichts aus. Echte Halte-Aktionen wie Diktat funktionieren auf einer Umschalt-Taste nicht. Braucht die CH552-Firmware und Bedienungshilfen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gerät") {
                Text("Der Helper öffnet nur ein bestätigtes USB-HID-Gerät. Für die Entwicklung läuft die App absichtlich unsandboxed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Gerät erneut suchen") { appState.refreshDevice() }
                    Spacer()
                    Button("Diagnose öffnen") { showDiagnostics = true }
                }
            }

            Section("Sicherheit") {
                Text("Profile und Agent-Zuordnungen bleiben lokal unter Application Support. Der Event-Bridge-Service beobachtet Ereignisse, beantwortet Approvals aber nie automatisch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Import & Export") {
                HStack {
                    Button("Exportieren") { exportProfile() }
                        .frame(maxWidth: .infinity)
                    Button("Importieren") { importProfile() }
                        .frame(maxWidth: .infinity)
                }

                if let resultText {
                    Text(resultText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .frame(width: 460, height: 560)
        .onChange(of: profiles.layerSwitchEnabled) { _, _ in appState.applyLayerSwitchConfiguration() }
        .onChange(of: profiles.layerSwitchKeys) { _, _ in appState.applyLayerSwitchConfiguration() }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(appState: appState)
                .frame(minWidth: 720, minHeight: 520)
        }
    }

    /// Binds one of the two switch-key slots, keeping the two keys distinct by
    /// swapping when the user picks the key already used by the other slot.
    private func switchKeyBinding(_ index: Int) -> Binding<HardwareControl> {
        Binding(
            get: {
                let keys = appState.profiles.layerSwitchKeys
                return keys.indices.contains(index) ? keys[index] : .key4
            },
            set: { newValue in
                var keys = appState.profiles.layerSwitchKeys
                guard keys.count == 2 else { return }
                let other = 1 - index
                if keys[other] == newValue { keys[other] = keys[index] }
                keys[index] = newValue
                appState.profiles.layerSwitchKeys = keys
            }
        )
    }

    private func exportProfile() {
        do {
            resultText = "Exportiert: \(try appState.profiles.exportSelectedProfile().path)"
        } catch is CancellationError {
        } catch {
            resultText = "Export fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func importProfile() {
        do {
            try appState.profiles.importProfile()
            resultText = "Profil importiert."
        } catch is CancellationError {
        } catch {
            resultText = "Import fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Bridges a stored layer colour to SwiftUI's ColorPicker.
    private func layerColorBinding(_ layer: HarnessLayer) -> Binding<Color> {
        Binding(
            get: {
                let c = appState.profiles.layerColor(for: layer)
                return Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
            },
            set: { newColor in
                appState.profiles.setLayerColor(Self.rgb(from: newColor), for: layer)
            }
        )
    }

    private static func rgb(from color: Color) -> RGBColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return RGBColor(
            red: UInt8(clamping: Int((ns.redComponent * 255).rounded())),
            green: UInt8(clamping: Int((ns.greenComponent * 255).rounded())),
            blue: UInt8(clamping: Int((ns.blueComponent * 255).rounded()))
        )
    }
}

private struct PermissionStatus: View {
    let title: String
    let isGranted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(isGranted ? "Erteilt" : "Fehlt")
                .foregroundStyle(isGranted ? Color.green : Color.orange)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}
