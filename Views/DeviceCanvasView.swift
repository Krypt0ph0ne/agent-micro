import SwiftUI

/// Applies a state change with animations forced off, regardless of whatever
/// implicit transaction is ambient at the call site (SwiftUI/AppKit buttons
/// on macOS often carry one). Used for control selection: picking a
/// different key/encoder zone should snap instantly, not replay the
/// selection-dependent content below as an animated insert/remove.
func withoutAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

/// Multi-stop opacity curves for the pad's live LED simulation, lifted from
/// the Claude Design animation spec. A plain `.easeInOut(...).repeatForever
/// (autoreverses: true)` only oscillates symmetrically between two values;
/// these reproduce the designed keyframe shape instead — an asymmetric
/// pulse "breath" and a blink with a brief afterglow before the next pair.
enum LEDOrganicCurve {
    /// Each stop is `(opacity, fraction of the total cycle)`, in order,
    /// starting at fraction 0 and ending at fraction 1 (which loops back to
    /// the first stop's opacity to start the next cycle).
    static let pulse: [(Double, Double)] = [(1.0, 0), (0.55, 0.22), (0.85, 0.45), (0.4, 0.68), (1.0, 1.0)]
    static let blink: [(Double, Double)] = [(1.0, 0), (0.15, 0.15), (0.92, 0.30), (0.18, 0.42), (1.0, 1.0)]
    static let flash: [(Double, Double)] = [(0.35, 0), (1.0, 0.08), (1.0, 0.88), (0.35, 1.0)]

    /// Steps `opacity` through `stops` in an endless loop, animating each
    /// segment over its share of `totalDuration`. Cancelled automatically
    /// when the enclosing `.task` is torn down (e.g. the LED effect changes).
    @MainActor
    static func run(_ stops: [(Double, Double)], totalDuration: Double, opacity: Binding<Double>) async {
        while !Task.isCancelled {
            for index in 1..<stops.count {
                let (_, fromFraction) = stops[index - 1]
                let (toValue, toFraction) = stops[index]
                let segmentDuration = (toFraction - fromFraction) * totalDuration
                withAnimation(.easeInOut(duration: segmentDuration)) { opacity.wrappedValue = toValue }
                try? await Task.sleep(for: .seconds(segmentDuration))
                if Task.isCancelled { return }
            }
        }
    }
}

/// Virtual rendering of the physical CH57x macropad: a 2×3 key grid plus a
/// single rotary-encoder disc, styled to read as real brushed-metal hardware
/// (corner screws, inset-shadow keys, a knob with a rotation tick) rather
/// than a flat card of buttons. Reused at two densities — `compact` drops
/// the per-key LED effect caption and the "DREHRAD" label for the narrower
/// menu-bar popover.
struct DeviceCanvasView: View {
    let profile: MacropadProfile
    @Binding var selectedControl: HardwareControl
    var compact: Bool = false
    var agentTitleForControl: ((HardwareControl) -> String?)? = nil

    private var keyGap: CGFloat { compact ? 6 : 8 }
    private var gridWidth: CGFloat { compact ? 198 : 250 }
    private var keyRowHeight: CGFloat { compact ? 56 : 72 }
    private var padPadding: CGFloat { compact ? 12 : 16 }
    private var screwInset: CGFloat { compact ? 7 : 9 }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 8 : 12) {
            VStack(spacing: keyGap) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: keyGap) {
                        ForEach(0..<3, id: \.self) { column in
                            if let control = HardwareControl.buttons.first(where: { $0.keyPosition?.row == row && $0.keyPosition?.column == column }) {
                                KeyControlView(
                                    control: control,
                                    action: profile.action(for: control),
                                    displayLabel: agentTitleForControl?(control),
                                    led: profile.led.setting(for: control),
                                    isSelected: selectedControl == control,
                                    compact: compact
                                ) { withoutAnimation { selectedControl = control } }
                            }
                        }
                    }
                }
            }
            .frame(width: gridWidth, height: keyRowHeight * 2 + keyGap)

            EncoderControlView(profile: profile, selectedControl: $selectedControl, compact: compact)
        }
        .padding(padPadding)
        .background(padBackground)
        .overlay(alignment: .topLeading) { screw.padding(screwInset) }
        .overlay(alignment: .topTrailing) { screw.padding(screwInset) }
        .overlay(alignment: .bottomLeading) { screw.padding(screwInset) }
        .overlay(alignment: .bottomTrailing) { screw.padding(screwInset) }
        .overlay(alignment: .bottomTrailing) {
            // Too small to coexist with the corner screw in the compact
            // (menu-bar) size, so the wordmark only appears at full size,
            // and is inset well clear of that screw's own position.
            if !compact {
                Text("AGENT MICRO")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.bottom, 9)
                    .padding(.trailing, 18)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Virtuelles Agent Micro mit sechs Tasten und drei Drehrad-Aktionen")
    }

    private var padBackground: some View {
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
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
    }

    /// A tiny brushed-metal corner screw — the detail that reads "real
    /// hardware" instead of "a rounded rectangle with buttons in it".
    private var screw: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(white: 0.56), Color(white: 0.22)],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 0,
                    endRadius: 4
                )
            )
            .frame(width: 5, height: 5)
            .shadow(color: .black.opacity(0.6), radius: 0.5)
    }
}

struct KeyControlView: View {
    let control: HardwareControl
    let action: KeyboardAction
    var displayLabel: String? = nil
    let led: KeyLEDConfiguration
    let isSelected: Bool
    var compact: Bool = false
    let select: () -> Void

    @State private var dotOpacity: Double = 1

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                HStack(spacing: 3) {
                    Text(control.title.replacingOccurrences(of: "Taste ", with: ""))
                        .font(.system(size: compact ? 8 : 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 0)
                    Image(systemName: action.icon)
                        .font(.system(size: compact ? 8 : 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                // Fixed height (not a trailing Spacer) so the two-line label
                // always gets the room it needs to actually wrap instead of
                // being squeezed down to one line with a mid-word "…".
                Text(resolvedLabel)
                    .font(.system(size: compact ? 8 : 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: compact ? 18 : 22, alignment: .top)
                    .help(resolvedLabel)
                Spacer(minLength: 0)
                HStack(spacing: compact ? 4 : 5) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
                        .opacity(dotOpacity)
                        .shadow(color: dotGlowColor, radius: dotGlowRadius)
                    if !compact {
                        Text(led.effect.title)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 6 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(keyBackground, in: RoundedRectangle(cornerRadius: compact ? 9 : 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 9 : 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .shadow(color: isSelected ? Color.accentColor.opacity(0.5) : .black.opacity(0.3), radius: isSelected ? 8 : 2, y: 2)
        // Selection border/glow crossfades instead of snapping when the
        // user taps a different key.
        .animation(.easeInOut(duration: 0.25), value: isSelected)
        .task(id: led.effect) {
            dotOpacity = 1
            switch led.effect {
            case .pulse: await LEDOrganicCurve.run(LEDOrganicCurve.pulse, totalDuration: 1.8, opacity: $dotOpacity)
            case .blink: await LEDOrganicCurve.run(LEDOrganicCurve.blink, totalDuration: 1.05, opacity: $dotOpacity)
            case .off, .steady: break
            }
        }
        .accessibilityLabel("\(control.title): \(resolvedLabel)")
        .accessibilityHint("Auswählen und darunter neu belegen")
    }

    private var resolvedLabel: String {
        guard action.kind.isAgent else { return action.displayLabel }
        return displayLabel ?? "Kein Chat zugeordnet"
    }

    private var keyBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0x46 / 255, green: 0x49 / 255, blue: 0x4f / 255),
                Color(red: 0x28 / 255, green: 0x2a / 255, blue: 0x2e / 255),
                Color(red: 0x1e / 255, green: 0x1f / 255, blue: 0x22 / 255)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var dotColor: Color {
        led.effect == .off ? .white.opacity(0.18) : Color(
            red: Double(led.red) / 255,
            green: Double(led.green) / 255,
            blue: Double(led.blue) / 255
        )
    }

    private var dotGlowColor: Color {
        led.effect == .off ? .clear : dotColor.opacity(0.9)
    }

    /// Glow size still reflects the configured brightness — the redesign's
    /// solid-dot look shouldn't lose that real, functional signal.
    private var dotGlowRadius: CGFloat {
        guard led.effect != .off else { return 0 }
        return 2 + 4 * (CGFloat(led.brightness) / 255)
    }

}

extension KeyLEDConfiguration {
    /// Brightness-blended preview color used by the LED settings swatches
    /// (`LEDControlPanel`) — distinct from `KeyControlView`'s pad-dot
    /// rendering, which keeps the dot fully saturated and expresses
    /// brightness through glow size instead.
    var previewColor: Color {
        guard effect != .off else { return Color.white.opacity(0.16) }
        return Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        ).opacity(max(0.18, Double(brightness) / 255))
    }
}

/// A single brushed-metal disc: rotate left/right are tap zones on the
/// disc's own left/right thirds (no separate arrow buttons), the center is
/// the press, and a rotation "tick" at the top makes it read as a knob
/// rather than a plain circle.
struct EncoderControlView: View {
    /// A one-shot illustrative wiggle — real rotation/press feedback for the
    /// onboarding demo, not a functional gesture recognizer.
    enum Gesture: Equatable { case rotateLeft, rotateRight, press }

    let profile: MacropadProfile
    @Binding var selectedControl: HardwareControl
    var compact: Bool = false
    /// Non-nil only while the onboarding demo wants this exact disc to act
    /// out a gesture; real call sites (main window, menu bar) leave this nil.
    var gesture: Gesture? = nil

    @State private var discRotation: Double = 0
    @State private var discScale: CGFloat = 1

    private var isGroupSelected: Bool { HardwareControl.encoderActions.contains(selectedControl) }
    private var discSize: CGFloat { compact ? 56 : 70 }
    private var chevronZoneWidth: CGFloat { compact ? 18 : 22 }
    private var gestureTaskKey: String { "\(selectedControl.rawValue)-\(String(describing: gesture))" }

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            Button { withoutAnimation { selectedControl = .encoderPress } } label: {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(white: 0.51), Color(white: 0.29), Color(white: 0.13)],
                                center: UnitPoint(x: 0.32, y: 0.26),
                                startRadius: 0,
                                endRadius: discSize * 0.62
                            )
                        )
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.9))
                        .frame(width: 2, height: compact ? 10 : 13)
                        .shadow(color: .white.opacity(0.5), radius: 1)
                        .offset(y: -discSize * 0.32)
                }
                .frame(width: discSize, height: discSize)
                .rotationEffect(.degrees(discRotation))
                .scaleEffect(discScale)
                .overlay {
                    Circle()
                        .strokeBorder(isGroupSelected ? Color.accentColor : .white.opacity(0.08), lineWidth: isGroupSelected ? 2.5 : 1)
                }
                .overlay {
                    Circle()
                        .stroke(Color(white: 0.05), lineWidth: 3)
                        .padding(-3)
                }
            }
            .buttonStyle(.plain)
            .shadow(color: isGroupSelected ? Color.accentColor.opacity(0.55) : .black.opacity(0.35), radius: isGroupSelected ? 10 : 5, y: 3)
            .animation(.easeInOut(duration: 0.25), value: isGroupSelected)
            .task(id: gestureTaskKey) { await runGesture() }
            .overlay {
                HStack(spacing: 0) {
                    chevronButton(.encoderLeft, symbol: "chevron.left")
                        .frame(width: chevronZoneWidth)
                    Spacer(minLength: 0)
                    chevronButton(.encoderRight, symbol: "chevron.right")
                        .frame(width: chevronZoneWidth)
                }
                .frame(width: discSize, height: discSize)
            }
            .accessibilityLabel("Drehrad: Aufwand & Modellwahl")

            if !compact {
                Text("DREHRAD")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: compact ? 68 : 84)
    }

    @MainActor
    private func runGesture() async {
        discRotation = 0
        discScale = 1
        switch gesture {
        case .rotateLeft:
            withAnimation(.easeInOut(duration: 0.3)) { discRotation = -22 }
            try? await Task.sleep(for: .seconds(0.3))
            withAnimation(.easeInOut(duration: 0.3)) { discRotation = 0 }
        case .rotateRight:
            withAnimation(.easeInOut(duration: 0.3)) { discRotation = 22 }
            try? await Task.sleep(for: .seconds(0.3))
            withAnimation(.easeInOut(duration: 0.3)) { discRotation = 0 }
        case .press:
            withAnimation(.easeOut(duration: 0.15)) { discScale = 0.88 }
            try? await Task.sleep(for: .seconds(0.15))
            withAnimation(.easeOut(duration: 0.2)) { discScale = 1 }
        case nil:
            break
        }
    }

    private func chevronButton(_ control: HardwareControl, symbol: String) -> some View {
        let isSelected = selectedControl == control
        return Button { withoutAnimation { selectedControl = control } } label: {
            Image(systemName: symbol)
                .font(.system(size: compact ? 11 : 13, weight: .bold))
                .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.4))
                .shadow(color: isSelected ? Color.accentColor.opacity(0.8) : .clear, radius: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.25), value: isSelected)
        }
        .buttonStyle(.plain)
        .help(control.title)
        .accessibilityLabel(control.title)
    }
}
