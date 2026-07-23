import SwiftUI

/// Fixed dark palette for the onboarding flow, matching the Claude Design
/// handoff 1:1. Deliberately NOT built from adaptive system colors
/// (`.windowBackgroundColor`, `.secondary`, `.accentColor`, `.controlBackgroundColor`)
/// — those follow the user's system appearance and accent-color preference,
/// so the exact same view can render completely differently depending on
/// settings that have nothing to do with this design. Onboarding is meant to
/// always look like the dark, pad-hardware-matching design the handoff
/// specifies, regardless of system light/dark mode or accent color.
enum OnboardingPalette {
    static let background = Color(red: 0x1c / 255, green: 0x1d / 255, blue: 0x1f / 255)
    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    static let cardBackground = Color.white.opacity(0.05)
    static let cardBackgroundSelected = accent.opacity(0.16)
    static let cardBorder = Color.white.opacity(0.14)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.45)
    static let secondaryButtonBackground = Color.white.opacity(0.08)
    static let progressTrack = Color.white.opacity(0.25)
    static let rowBackground = Color.white.opacity(0.05)
}

/// Solid accent pill, matching the handoff's `#0A84FF` "Weiter"/primary
/// buttons — a fixed color rather than the system accent so it can't be
/// thrown off by a customized accent-color preference.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                OnboardingPalette.accent.opacity(isEnabled ? 1 : 0.35),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension Color {
    /// Whether black text reads better on this color than white — used for
    /// e.g. a status chip whose fill color (like the "Idle" white) is too
    /// light for the usual white-on-dark text to stay legible.
    var isLight: Bool {
        guard let components = NSColor(self).usingColorSpace(.deviceRGB) else { return false }
        let luminance = 0.299 * components.redComponent + 0.587 * components.greenComponent + 0.114 * components.blueComponent
        return luminance > 0.6
    }
}

/// Translucent white pill, matching the handoff's "Zurück" buttons.
struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                OnboardingPalette.secondaryButtonBackground,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
