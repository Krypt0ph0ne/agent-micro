import SwiftUI

/// One beat of an `OnboardingPadDemo` loop: which control is highlighted on
/// the illustrative pad, the caption shown underneath, an optional gesture
/// to act out on that control, and an optional confirmation badge (e.g.
/// "Thread zugewiesen") that fades in near the end of the beat.
struct PadDemoBeat {
    var highlighted: HardwareControl?
    var caption: String
    var badge: String?
    var keyGesture: OnboardingKeyGesture?
    var encoderGesture: EncoderControlView.Gesture?

    init(
        highlighted: HardwareControl? = nil,
        caption: String,
        badge: String? = nil,
        keyGesture: OnboardingKeyGesture? = nil,
        encoderGesture: EncoderControlView.Gesture? = nil
    ) {
        self.highlighted = highlighted
        self.caption = caption
        self.badge = badge
        self.keyGesture = keyGesture
        self.encoderGesture = encoderGesture
    }
}

/// Drives an `OnboardingDemoPad` through a short scripted sequence (e.g.
/// "halten" → a confirmation badge) instead of only ever describing
/// behavior in prose, with a caption underneath.
struct OnboardingPadDemo: View {
    let profile: MacropadProfile
    let beats: [PadDemoBeat]

    @State private var beatIndex = 0
    @State private var showBadge = false

    private var beat: PadDemoBeat { beats[beatIndex] }

    var body: some View {
        VStack(spacing: 14) {
            OnboardingDemoPad(
                highlighted: beat.highlighted,
                keyGesture: beat.keyGesture,
                encoderGesture: beat.encoderGesture,
                scale: 0.85,
                badgeText: beat.badge,
                showBadge: showBadge,
                profile: profile
            )

            Text(beat.caption)
                .font(.system(size: 12))
                .foregroundStyle(OnboardingPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 28)
                .id(beatIndex)
                .transition(.opacity)
        }
        .padding(.top, 6)
        .task { await runLoop() }
    }

    /// Choreographed phases (display → badge-out → pause → beat switch →
    /// pause → badge-in), not a fixed-interval timer tick — the pauses
    /// around the beat switch are what make it read as a deliberate
    /// sequence instead of something just blinking on a clock.
    @MainActor
    private func runLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.9))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { showBadge = false }
            try? await Task.sleep(for: .seconds(0.22))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                beatIndex = (beatIndex + 1) % beats.count
            }
            try? await Task.sleep(for: .seconds(0.45))
            guard !Task.isCancelled else { return }
            if beats[beatIndex].badge != nil {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { showBadge = true }
            }
        }
    }
}
