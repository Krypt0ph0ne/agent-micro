import SwiftUI

struct DeviceCanvasView: View {
    let profile: MacropadProfile
    @Binding var selectedControl: HardwareControl

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 7) {
                            ForEach(0..<3, id: \.self) { column in
                                if let control = HardwareControl.buttons.first(where: { $0.keyPosition?.row == row && $0.keyPosition?.column == column }) {
                                    KeyControlView(
                                        control: control,
                                        action: profile.action(for: control),
                                        led: profile.led.setting(for: control),
                                        isSelected: selectedControl == control
                                    ) { selectedControl = control }
                                }
                            }
                        }
                    }
                }

                EncoderControlView(
                    profile: profile,
                    selectedControl: $selectedControl
                )
        }
        .padding(12)
        .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.88), Color(nsColor: .darkGray).opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 5)
        }
        .overlay(alignment: .bottomTrailing) {
                Text("CODEXPAD")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Virtuelles CodexPad mit sechs Tasten und drei Drehrad-Aktionen")
    }
}

struct KeyControlView: View {
    let control: HardwareControl
    let action: KeyboardAction
    let led: KeyLEDConfiguration
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(control.title.replacingOccurrences(of: "Taste ", with: ""))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                    Spacer(minLength: 0)
                    Image(systemName: action.icon)
                        .font(.system(size: 9, weight: .medium))
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(led.previewColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: led.previewColor.opacity(0.9), radius: led.effect == .off ? 0 : 4)
                    Text(led.effect.title)
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(action.label)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.white.opacity(0.9))
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .topLeading)
            .background(keyMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
        .accessibilityLabel("\(control.title): \(action.label)")
        .accessibilityHint("Auswählen und rechts neu belegen")
        .frame(maxWidth: .infinity)
    }

    private var keyMaterial: some ShapeStyle {
        isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(Color.white.opacity(0.10))
    }
}

extension KeyLEDConfiguration {
    var previewColor: Color {
        guard effect != .off else { return Color.white.opacity(0.16) }
        return Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        ).opacity(max(0.18, Double(brightness) / 255))
    }
}

struct EncoderControlView: View {
    let profile: MacropadProfile
    @Binding var selectedControl: HardwareControl

    var body: some View {
        // All three encoder controls are edited as a single group (they share
        // one tap-vs-hold behaviour), so any of the three highlights and
        // selects the whole trio.
        let isSelected = HardwareControl.encoderActions.contains(selectedControl)

        VStack(spacing: 6) {
            HStack(spacing: 4) {
                EncoderGestureButton(control: .encoderLeft, selected: isSelected) { selectedControl = .encoderLeft }
                EncoderGestureButton(control: .encoderRight, selected: isSelected) { selectedControl = .encoderRight }
            }

            Button { selectedControl = .encoderPress } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.26), .black.opacity(0.38)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Circle()
                        .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.26), lineWidth: isSelected ? 2.5 : 1)
                    VStack(spacing: 2) {
                        Image(systemName: "dial.medium")
                            .font(.system(size: 16))
                        Text("Drehrad")
                            .font(.system(size: 8, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 56)
                }
                .frame(width: 70, height: 70)
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.28), radius: 3, y: 3)
            .accessibilityLabel("Drehrad: Aufwand & Modellwahl")
        }
        .frame(width: 86)
    }
}

private struct EncoderGestureButton: View {
    let control: HardwareControl
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Image(systemName: control == .encoderLeft ? "arrow.counterclockwise" : "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : .white.opacity(0.75))
                .frame(width: 34, height: 30)
                .background(selected ? Color.accentColor.opacity(0.20) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.8) : .white.opacity(0.08))
                }
        }
        .buttonStyle(.plain)
        .help(control.title)
        .accessibilityLabel(control.title)
    }
}
