import SwiftUI

/// Acts out the whole hold-to-assign gesture instead of describing it: hold the
/// agent key, the thread list opens, the dial moves the selection, releasing
/// assigns and the whole pad flashes green once.
///
/// The rows are illustrative sample data on purpose — the real panel
/// (`ThreadPickerPanel`) is centred on screen and only exists while a key is
/// physically held, so it can never be shown here for real. The layout,
/// status dots and the "Drehen · Loslassen" hint mirror that panel so the real
/// thing is recognisable when it appears.
struct OnboardingAssignmentDemo: View {
    let profile: MacropadProfile

    private enum Phase: CaseIterable, Equatable {
        case hold, turnFirst, turnSecond, release

        /// Main-actor isolated because it quotes the real hold threshold from
        /// `CodexQuickAssignService` rather than restating it as a literal.
        @MainActor
        var caption: String {
            switch self {
            case .hold:
                AppLanguage.text(
                    "Agent-Taste ca. \(CodexQuickAssignService.holdThresholdMilliseconds) ms halten → die Liste der letzten Threads öffnet sich, der bereits zugewiesene ist vorausgewählt",
                    "Hold the agent key for about \(CodexQuickAssignService.holdThresholdMilliseconds) ms → the list of recent threads opens, preselecting the one already assigned"
                )
            case .turnFirst, .turnSecond:
                AppLanguage.text(
                    "Weiter gedrückt halten und am Drehrad drehen → die Auswahl wandert durch die Liste",
                    "Keep the key held and turn the dial → the selection moves through the list"
                )
            case .release:
                AppLanguage.text(
                    "Taste loslassen → der markierte Thread liegt auf der Taste, das ganze Pad blinkt einmal grün",
                    "Release the key → the highlighted thread is now on that key and the whole pad flashes green once"
                )
            }
        }

        /// Which sample row is highlighted. The release keeps the last one so
        /// the confirmation visibly belongs to the row that was chosen.
        var selectedRow: Int {
            switch self {
            case .hold: 0
            case .turnFirst: 1
            case .turnSecond, .release: 2
            }
        }

        var isPickerVisible: Bool { self != .release }

        var seconds: Double {
            switch self {
            case .hold: 1.7
            case .turnFirst, .turnSecond: 0.95
            case .release: 2.0
            }
        }
    }

    private struct SampleThread {
        let title: String
        let detail: String
        let color: Color
    }

    private static let sampleThreads: [SampleThread] = [
        SampleThread(
            title: AppLanguage.text("Login-Flow refactoren", "Refactor login flow"),
            detail: AppLanguage.text("Web App · Läuft", "Web App · Running"),
            color: Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
        ),
        SampleThread(
            title: AppLanguage.text("LED-Timing korrigieren", "Fix LED timing"),
            detail: AppLanguage.text("Agent Micro · Bereit", "Agent Micro · Ready"),
            color: .white
        ),
        SampleThread(
            title: AppLanguage.text("Review offener PRs", "Review open PRs"),
            detail: AppLanguage.text("Agent Micro · Eingabe erforderlich", "Agent Micro · Needs input"),
            color: Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
        ),
        SampleThread(
            title: AppLanguage.text("Doku aktualisieren", "Update the docs"),
            detail: AppLanguage.text("Website · Erfolgreich", "Website · Completed"),
            color: Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
        )
    ]

    /// The default `threadAssigned` reaction colour, so the demo flash matches
    /// what the hardware actually does on a confirmed assignment.
    private static let confirmationGreen = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)

    @State private var phase: Phase = .hold
    /// Lets the single selection highlight travel from row to row instead of
    /// cross-fading two independent highlights, which briefly rendered two rows
    /// as selected at once.
    @Namespace private var selectionHighlight

    private var padDots: [HardwareControl: OnboardingDemoPad.KeyDot] {
        guard phase == .release else {
            return [.key1: .init(color: Self.confirmationGreen.opacity(0.001), effect: .off, size: 7)]
        }
        // The confirmation is a whole-pad reaction, not a single key.
        return Dictionary(uniqueKeysWithValues: HardwareControl.buttons.map { control in
            (control, OnboardingDemoPad.KeyDot(color: Self.confirmationGreen, effect: .flash, size: 10))
        })
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                OnboardingDemoPad(
                    highlighted: .key1,
                    keyGesture: phase == .release ? nil : .hold,
                    encoderGesture: phase == .turnFirst || phase == .turnSecond ? .rotateRight : nil,
                    dots: padDots,
                    scale: 1,
                    badgeText: AppLanguage.text("Thread zugewiesen", "Thread assigned"),
                    showBadge: phase == .release,
                    profile: profile
                )
                .frame(width: 378, height: 184)
                .scaleEffect(0.6, anchor: .center)
                .frame(width: 227, height: 111)

                pickerMock
                    .frame(width: 197)
                    .opacity(phase.isPickerVisible ? 1 : 0)
                    .scaleEffect(phase.isPickerVisible ? 1 : 0.94, anchor: .center)
            }
            // Fixed so the row never re-centres when the picker fades out.
            .frame(width: 436, height: 152)

            // All captions are laid out at once and switched by opacity. A
            // `.transition` on a single `Text` keyed by phase briefly rendered
            // the outgoing and incoming strings on top of each other, and its
            // changing width re-centred everything above it. The switch is
            // deliberately unanimated: cross-fading two different sentences in
            // the same spot reads as smeared text, not as a transition.
            ZStack {
                ForEach(Array(Phase.allCases.enumerated()), id: \.offset) { _, candidate in
                    Text(candidate.caption)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(candidate == phase ? 1 : 0)
                        .animation(nil, value: phase)
                }
            }
            .frame(width: 436, height: 46)

            // Static, phase-independent: these are the preconditions people
            // otherwise discover by holding a key and having nothing happen.
            VStack(alignment: .leading, spacing: 3) {
                note(
                    icon: "person.crop.circle",
                    text: AppLanguage.text(
                        "Nur auf **Agent-Tasten** – also Tasten, denen du die Aktion „Codex-Agent“ bzw. „Claude-Agent“ gegeben hast. Andere Tasten reagieren aufs Halten mit ihrer eigenen Halten-Aktion.",
                        "Only on **agent keys** — keys you gave the Codex agent or Claude agent action. Any other key responds to a hold with its own hold action."
                    )
                )
                note(
                    icon: "hand.tap",
                    text: AppLanguage.text(
                        "Kurz tippen öffnet den zugewiesenen Thread. Hat die Taste eine eigene Tippen/Halten-Belegung, ist das Zuweisen per Halten deaktiviert.",
                        "A quick tap opens the assigned thread. If the key has its own tap/hold pair configured, hold-to-assign is switched off for it."
                    )
                )
            }
            .frame(width: 436, alignment: .leading)
        }
        .padding(.top, 4)
        .task { await runLoop() }
    }

    private func note(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(OnboardingPalette.accent)
                .frame(width: 12)
            Text(.init(text))
                .font(.system(size: 10.5))
                .foregroundStyle(OnboardingPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }

    /// Mirrors `ThreadPickerPanel`'s own header, status dots and row selection,
    /// scaled down — the point is that the real panel is recognisable.
    private var pickerMock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(AppLanguage.text("Thread auswählen", "Choose thread"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                Spacer(minLength: 2)
                Image(systemName: "dial.medium")
                    .font(.system(size: 8))
                    .foregroundStyle(OnboardingPalette.textSecondary)
            }

            ForEach(Array(Self.sampleThreads.enumerated()), id: \.offset) { index, thread in
                row(thread, isSelected: index == phase.selectedRow)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    private func row(_ thread: SampleThread, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(thread.color)
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text(thread.title)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                    .lineLimit(1)
                Text(thread.detail)
                    .font(.system(size: 7.5))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(OnboardingPalette.accent)
                .opacity(isSelected ? 1 : 0)
                // Snaps with the highlight instead of fading, so no second row
                // ever shows a checkmark mid-transition.
                .animation(nil, value: isSelected)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(OnboardingPalette.accent.opacity(0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(OnboardingPalette.accent.opacity(0.75), lineWidth: 1)
                    }
                    .matchedGeometryEffect(id: "selection", in: selectionHighlight)
            }
        }
    }

    @MainActor
    private func runLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(phase.seconds))
            guard !Task.isCancelled else { return }
            let next = Phase.allCases[(Phase.allCases.firstIndex(of: phase)! + 1) % Phase.allCases.count]
            // A spring on the release beat makes the panel pop out and the
            // badge pop in together, which reads as one confirmation.
            withAnimation(next == .release
                ? .spring(response: 0.34, dampingFraction: 0.68)
                : .easeInOut(duration: 0.28)) {
                phase = next
            }
        }
    }
}
