import AppKit
import SwiftUI

struct LEDControlPanel: View {
    let appState: AppState
    @Binding var control: HardwareControl
    @State private var resultMessage: String?

    private var keyControl: HardwareControl {
        HardwareControl.buttons.contains(control) ? control : .key1
    }

    private var setting: KeyLEDConfiguration {
        appState.profiles.selectedProfile.led.setting(for: keyControl)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "lightbulb.led.fill")
                    .foregroundStyle(setting.previewColor)
                Text("Licht · \(keyControl.shortTitle)")
                    .font(.headline)
                ContextInfoButton(
                    title: "Individuelle RGB-Beleuchtung",
                    message: "Farbe, Helligkeit und Animation werden im Profil gespeichert. „Jetzt anwenden“ überträgt nur diese LED; „Übertragen“ sendet später das komplette Profil."
                )
                Spacer()
            }

            Picker("Taste", selection: $control) {
                ForEach(HardwareControl.buttons) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Effekt")
                Spacer()
                Picker("Effekt", selection: valueBinding(\.effect)) {
                    ForEach(LEDEffect.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 138)
            }

            HStack {
                ColorPicker("Farbe", selection: colorBinding, supportsOpacity: false)
                Spacer()
                presetColors
            }

            LabeledContent("Helligkeit") {
                HStack(spacing: 8) {
                    Slider(value: byteBinding(\.brightness), in: 0...255, step: 1)
                    Text("\(Int(setting.brightness) * 100 / 255) %")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }

            if setting.effect == .blink || setting.effect == .pulse {
                LabeledContent(setting.effect == .blink ? "Blinkdauer" : "Pulsdauer") {
                    HStack(spacing: 8) {
                        Slider(value: periodBinding, in: 100...5_000, step: 100)
                        Text(periodLabel)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            Spacer(minLength: 0)

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button("Alle aus") {
                    let result = appState.device.turnOffCustomLEDs()
                    resultMessage = result?.succeeded == true ? "Alle LEDs sind aus." : result?.failureDescription
                }
                .disabled(appState.device.currentDevice?.isCodexPadFirmware != true)
                Spacer()
                Button("Jetzt anwenden") {
                    let result = appState.device.applyLED(setting)
                    resultMessage = result?.succeeded == true ? "\(keyControl.shortTitle) wurde aktualisiert." : result?.failureDescription
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.device.currentDevice?.isCodexPadFirmware != true)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var presetColors: some View {
        HStack(spacing: 5) {
            ForEach(Self.presets, id: \.name) { preset in
                Button {
                    update { value in
                        value.red = preset.rgb.0
                        value.green = preset.rgb.1
                        value.blue = preset.rgb.2
                        if value.effect == .off { value.effect = .steady }
                    }
                } label: {
                    Circle()
                        .fill(preset.color)
                        .frame(width: 17, height: 17)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(red: Double(setting.red) / 255, green: Double(setting.green) / 255, blue: Double(setting.blue) / 255) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                update { value in
                    value.red = UInt8(clamping: Int((rgb.redComponent * 255).rounded()))
                    value.green = UInt8(clamping: Int((rgb.greenComponent * 255).rounded()))
                    value.blue = UInt8(clamping: Int((rgb.blueComponent * 255).rounded()))
                    if value.effect == .off { value.effect = .steady }
                }
            }
        )
    }

    private func valueBinding<Value>(_ keyPath: WritableKeyPath<KeyLEDConfiguration, Value>) -> Binding<Value> {
        Binding(get: { setting[keyPath: keyPath] }, set: { newValue in update { $0[keyPath: keyPath] = newValue } })
    }

    private func byteBinding(_ keyPath: WritableKeyPath<KeyLEDConfiguration, UInt8>) -> Binding<Double> {
        Binding(get: { Double(setting[keyPath: keyPath]) }, set: { newValue in update { $0[keyPath: keyPath] = UInt8(clamping: Int(newValue)) } })
    }

    private var periodBinding: Binding<Double> {
        Binding(get: { Double(setting.periodMilliseconds) }, set: { newValue in update { $0.periodMilliseconds = Int(newValue) } })
    }

    private var periodLabel: String {
        setting.periodMilliseconds >= 1_000
            ? String(format: "%.1f s", Double(setting.periodMilliseconds) / 1_000)
            : "\(setting.periodMilliseconds) ms"
    }

    private func update(_ mutation: (inout KeyLEDConfiguration) -> Void) {
        var next = setting
        mutation(&next)
        appState.profiles.updateLED(next)
        resultMessage = nil
    }

    private static let presets: [(name: String, color: Color, rgb: (UInt8, UInt8, UInt8))] = [
        ("Rot", .red, (255, 0, 0)), ("Orange", .orange, (255, 96, 0)),
        ("Gelb", .yellow, (255, 255, 0)), ("Grün", .green, (0, 255, 0)),
        ("Cyan", .cyan, (0, 255, 255)), ("Blau", .blue, (0, 0, 255)),
        ("Magenta", .purple, (255, 0, 255)), ("Weiß", .white, (255, 255, 255))
    ]
}
