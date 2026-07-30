import SwiftUI

/// A key's illustrative one-shot gesture in the "Kurz erklärt" demo — visual
/// flavor only, not a real input recognizer.
enum OnboardingKeyGesture { case tap, hold }

/// The schematic, non-interactive pad used by the "Kurz erklärt" carousel.
/// Deliberately not `DeviceCanvasView`: the demo isn't about the user's real
/// key assignments, so cells show only a number and a status dot — no
/// action label, icon, or effect caption — matching the Claude Design
/// handoff's own stripped-down illustration exactly.
struct OnboardingDemoPad: View {
    /// Broader than the real, persisted `LEDEffect` (which has no "flash")
    /// since this demo also needs to illustrate one-shot event reactions
    /// like "Fertig", not just the four steady per-key lighting modes.
    enum DotEffect: Equatable { case off, steady, pulse, blink, flash }

    /// One key's dot: `nil` color means the plain dim "off" dot.
    struct KeyDot {
        var color: Color?
        var effect: DotEffect = .off
        var size: CGFloat = 7
    }

    var highlighted: HardwareControl? = nil
    var keyGesture: OnboardingKeyGesture? = nil
    var encoderGesture: EncoderControlView.Gesture? = nil
    /// Per-control dot override; a control absent from this map gets the
    /// plain dim "off" dot.
    var dots: [HardwareControl: KeyDot] = [:]
    var scale: CGFloat = 0.85
    var badgeText: String? = nil
    var showBadge: Bool = false

    /// `EncoderControlView` needs a real profile to read action labels from,
    /// even though this demo hides them (`compact` has no effect on labels,
    /// only this pad's own cells actually suppress them) — any profile works
    /// since nothing derived from it is shown.
    let profile: MacropadProfile

    private var encoderHighlightBinding: Binding<HardwareControl> {
        Binding(get: { highlighted ?? .key1 }, set: { _ in })
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { column in
                            if let control = HardwareControl.buttons.first(where: { $0.keyPosition?.row == row && $0.keyPosition?.column == column }) {
                                DemoKeyCell(
                                    control: control,
                                    isHighlighted: control == highlighted,
                                    dot: dots[control] ?? KeyDot(color: nil),
                                    gesture: control == highlighted ? keyGesture : nil
                                )
                            }
                        }
                    }
                }
            }
            .frame(width: 250, height: 152)

            EncoderControlView(
                profile: profile,
                selectedControl: encoderHighlightBinding,
                gesture: HardwareControl.encoderActions.contains(highlighted ?? .key1) && highlighted != nil ? encoderGesture : nil
            )
        }
        .padding(16)
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
        .scaleEffect(scale)
        .overlay(alignment: .top) {
            if let badgeText, showBadge {
                Label(badgeText, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255).opacity(0.95), in: Capsule())
                    .foregroundStyle(.white)
                    .offset(y: -6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

private struct DemoKeyCell: View {
    let control: HardwareControl
    let isHighlighted: Bool
    let dot: OnboardingDemoPad.KeyDot
    let gesture: OnboardingKeyGesture?

    @State private var dotOpacity: Double = 1
    @State private var pressScale: CGFloat = 1
    @State private var tapBrightness: Double = 0

    private var gestureTaskKey: String { "\(control.rawValue)-\(String(describing: gesture))" }

    var body: some View {
        VStack(spacing: 6) {
            // Just the number: stripping the literal "Taste " left the English
            // titles as "Key 1", which no longer fits the cell.
            Text(control.title.split(separator: " ").last.map(String.init) ?? control.title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
            Circle()
                .fill(dot.color ?? .white.opacity(0.18))
                .frame(width: dot.size, height: dot.size)
                .opacity(dot.color == nil ? 1 : dotOpacity)
                .shadow(color: dot.color?.opacity(0.85) ?? .clear, radius: dot.color == nil ? 0 : 6)
        }
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
                .strokeBorder(isHighlighted ? OnboardingPalette.accent : .white.opacity(0.1), lineWidth: isHighlighted ? 2 : 1)
        }
        .shadow(color: isHighlighted ? OnboardingPalette.accent.opacity(0.55) : .black.opacity(0.35), radius: isHighlighted ? 8 : 3)
        .animation(.easeInOut(duration: 0.25), value: isHighlighted)
        .scaleEffect(pressScale)
        .brightness(tapBrightness)
        .task(id: dot.effect) {
            dotOpacity = 1
            switch dot.effect {
            case .pulse: await LEDOrganicCurve.run(LEDOrganicCurve.pulse, totalDuration: 1.8, opacity: $dotOpacity)
            case .blink: await LEDOrganicCurve.run(LEDOrganicCurve.blink, totalDuration: 1.05, opacity: $dotOpacity)
            case .flash: await LEDOrganicCurve.run(LEDOrganicCurve.flash, totalDuration: 2.6, opacity: $dotOpacity)
            case .off, .steady: break
            }
        }
        .task(id: gestureTaskKey) { await runGesture() }
    }

    @MainActor
    private func runGesture() async {
        pressScale = 1
        tapBrightness = 0
        switch gesture {
        case .tap:
            withAnimation(.easeOut(duration: 0.12)) { tapBrightness = 0.35 }
            try? await Task.sleep(for: .seconds(0.12))
            withAnimation(.easeOut(duration: 0.25)) { tapBrightness = 0 }
        case .hold:
            withAnimation(.easeOut(duration: 0.18)) { pressScale = 0.93 }
        case nil:
            break
        }
    }
}
