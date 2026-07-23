import SwiftUI

/// The switch-button step needs to show *which physical key* is about to be
/// reserved, not what it currently does — so unlike `DeviceCanvasView`, this
/// intentionally shows generic "Taste 1"–"6" labels, no action icons, no LED
/// status, and a dimmed, static, unlabeled encoder shown only for scale/
/// context. A schematic stand-in, not the real pad.
struct OnboardingSwitchKeyPad: View {
    @Binding var selected: HardwareControl

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { column in
                            if let control = HardwareControl.buttons.first(where: { $0.keyPosition?.row == row && $0.keyPosition?.column == column }) {
                                keyCell(control)
                            }
                        }
                    }
                }
            }
            .frame(width: 210, height: 100)

            encoderPreview
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0x34 / 255, green: 0x36 / 255, blue: 0x3b / 255),
                            Color(red: 0x19 / 255, green: 0x1a / 255, blue: 0x1d / 255),
                            Color(red: 0x0f / 255, green: 0x10 / 255, blue: 0x12 / 255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        )
    }

    private func keyCell(_ control: HardwareControl) -> some View {
        let isSelected = control == selected
        return Button {
            selected = control
        } label: {
            Text(control.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0x46 / 255, green: 0x49 / 255, blue: 0x4f / 255),
                            Color(red: 0x28 / 255, green: 0x29 / 255, blue: 0x2e / 255),
                            Color(red: 0x1e / 255, green: 0x1f / 255, blue: 0x22 / 255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? OnboardingPalette.accent : .white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                }
                .shadow(color: isSelected ? OnboardingPalette.accent.opacity(0.55) : .black.opacity(0.35), radius: isSelected ? 8 : 3)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: isSelected)
    }

    /// Static and dimmed — this screen is about picking a key, not the
    /// encoder, so it's shown only for scale/context and isn't interactive.
    private var encoderPreview: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.51), Color(white: 0.29), Color(white: 0.13)],
                        center: UnitPoint(x: 0.32, y: 0.26),
                        startRadius: 0,
                        endRadius: 36
                    )
                )
            Circle()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.9))
                .frame(width: 2, height: 11)
                .offset(y: -18)
        }
        .frame(width: 58, height: 58)
        .frame(width: 74)
        .opacity(0.5)
    }
}
