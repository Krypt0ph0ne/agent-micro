import SwiftUI

/// First-run flow, gated by `CodexPad.hasCompletedOnboarding` in `CodexPadApp`.
/// Offers a one-tap "Schnellstart" (today's permission-only walkthrough) or a
/// guided, step-by-step setup that also configures the agent selection, the
/// Codex⇄Claude switch key, and the dictation source — everything that used
/// to only be discoverable buried in Settings after the fact.
struct OnboardingView: View {
    let appState: AppState
    let onFinished: () -> Void

    private enum Mode: Equatable { case quick, guided }

    /// Every screen the guided path can show, in the fixed order they'd
    /// appear if all were included. `steps` filters this down to what's
    /// actually relevant (e.g. no switch-button step for a single agent).
    private enum Step: CaseIterable, Equatable {
        case permissions, agents, switchButton, basics, microphone, summary
    }

    static let size = CGSize(width: 560, height: 560)

    @State private var mode: Mode?
    @State private var stepIndex = 0

    // Guided-path choices, applied to `appState.profiles` as they're made.
    @State private var selectedAgents: Set<AutomationApp> = [.codex, .claude]
    @State private var switchChoice: LayerSwitchChoice?
    @State private var basicsPage = 0
    @State private var micSource: DictationSource = .codex

    private var monitor: PermissionMonitor { appState.permissionMonitor }
    private var bothPermissionsGranted: Bool {
        monitor.hasAccessibilityPermission && monitor.hasInputMonitoringPermission
    }

    /// A representative profile purely for the illustrative pad diagrams —
    /// showing real key labels/positions is the point, not which app is
    /// ultimately selected.
    private var illustrativeProfile: MacropadProfile {
        appState.profiles.profiles.first(where: { $0.name == "Codex" }) ?? appState.profiles.selectedProfile
    }

    private var steps: [Step] {
        guard mode == .guided else { return mode == .quick ? [.permissions] : [] }
        var result: [Step] = [.permissions, .agents]
        if selectedAgents.count > 1 { result.append(.switchButton) }
        result.append(contentsOf: [.basics, .microphone, .summary])
        return result
    }

    var body: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 0) {
                if mode != nil, !steps.isEmpty {
                    progressBar
                        .padding(.horizontal, 26)
                        .padding(.top, 26)
                        .padding(.bottom, 10)
                }
                ZStack {
                    if mode == nil {
                        startScreen
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 1.02)),
                                removal: .opacity
                            ))
                    } else {
                        stepPager
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .preferredColorScheme(.dark)
        .task { monitor.requestNotificationAuthorizationIfNeeded() }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: mode)
    }

    /// Every step is laid out side by side in a single row; sliding to the
    /// next/previous one is just an offset animation. This guarantees the
    /// slide direction always matches the navigation direction — unlike a
    /// `.transition()`-per-step approach, where the outgoing view's animation
    /// is fixed at whatever direction was current when *it* last appeared,
    /// which shows the wrong direction the first time "Zurück" is pressed.
    private var stepPager: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(steps.indices, id: \.self) { index in
                    stepView(for: steps[index])
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .offset(x: -CGFloat(stepIndex) * geo.size.width)
            // Critically damped (dampingFraction 1.0): reaches the target
            // as fast as the response time allows with zero overshoot, and
            // — being real spring physics rather than a fixed-duration
            // easing curve — keeps its existing velocity if stepIndex
            // changes again mid-flight (rapid back-to-back clicks) instead
            // of restarting the curve from a standstill each time.
            .animation(.spring(response: 0.45, dampingFraction: 1.0), value: stepIndex)
        }
        .clipped()
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [OnboardingPalette.accent.opacity(0.16), OnboardingPalette.background],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    // MARK: - Navigation

    private func goTo(mode newMode: Mode) {
        mode = newMode
        stepIndex = 0
    }

    private func advance() {
        guard steps.indices.contains(stepIndex) else { return }
        let currentStep = steps[stepIndex]
        if currentStep == .summary || (mode == .quick && currentStep == .permissions) {
            finish()
            return
        }
        stepIndex += 1
    }

    private func goBack() {
        if stepIndex == 0 {
            mode = nil
        } else {
            stepIndex -= 1
        }
    }

    private func finish() {
        if mode == .guided {
            appState.profiles.enabledAutomationApps = selectedAgents
            if let switchChoice {
                switch switchChoice {
                case .key(let control): appState.profiles.layerSwitchControl = control
                case .appOnly: appState.profiles.layerSwitchControl = nil
                }
            }
            appState.profiles.dictationSource = micSource
        }
        onFinished()
    }

    // MARK: - Step 0: mode choice

    private var startScreen: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Image(systemName: "square.grid.3x2.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(OnboardingPalette.accent)
                Text("Willkommen bei CodexPad")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                Text("CodexPad verbindet ein physisches Macropad mit Codex und Claude: Tasten senden Shortcuts, das Drehrad steuert Reasoning-Aufwand und Modellwahl, und die LEDs zeigen den Live-Status deiner Agenten.")
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            VStack(spacing: 12) {
                OnboardingChoiceCard(
                    icon: "bolt.fill",
                    title: "Schnellstart",
                    subtitle: "Nur Berechtigungen einrichten, Rest später in den Einstellungen.",
                    isSelected: false
                ) { goTo(mode: .quick) }

                OnboardingChoiceCard(
                    icon: "list.bullet.rectangle.portrait",
                    title: "Geführte Einrichtung",
                    subtitle: "Agents wählen, Umschalt-Taste, Mikrofon und die Bedienung Schritt für Schritt erklärt.",
                    isSelected: false
                ) { goTo(mode: .guided) }
            }
            .frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
        .padding(30)
    }

    // MARK: - Step router

    @ViewBuilder
    private func stepView(for step: Step) -> some View {
        switch step {
        case .permissions:
            OnboardingPermissionsStep(
                monitor: monitor,
                bothGranted: bothPermissionsGranted,
                isQuickMode: mode == .quick,
                onBack: goBack,
                onContinue: advance
            )
        case .agents:
            OnboardingAgentChoiceStep(
                selected: $selectedAgents,
                onBack: goBack,
                onContinue: advance
            )
        case .switchButton:
            OnboardingSwitchButtonStep(
                choice: $switchChoice,
                onBack: goBack,
                onContinue: advance
            )
        case .basics:
            OnboardingBasicsStep(
                page: $basicsPage,
                profile: illustrativeProfile,
                onBack: goBack,
                onContinue: advance
            )
        case .microphone:
            OnboardingMicrophoneStep(
                source: $micSource,
                onBack: goBack,
                onContinue: advance
            )
        case .summary:
            OnboardingSummaryStep(
                selectedAgents: selectedAgents,
                switchChoice: switchChoice.map { choice in
                    switch choice {
                    case .key(let control): control.shortTitle
                    case .appOnly: "Nur über die App"
                    }
                },
                micSource: micSource,
                onBack: goBack,
                onFinish: finish
            )
        }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= stepIndex ? OnboardingPalette.accent : OnboardingPalette.progressTrack)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stepIndex)
    }
}

/// Shared chrome for a guided-onboarding step: icon, title, subtitle, the
/// step's own content, and a consistent Zurück/Weiter footer.
struct OnboardingStepChrome<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let onBack: () -> Void
    let onContinue: () -> Void
    let continueTitle: String
    let continueDisabled: Bool
    @ViewBuilder var content: Content

    init(
        icon: String,
        title: String,
        subtitle: String,
        continueTitle: String = "Weiter",
        continueDisabled: Bool = false,
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.continueTitle = continueTitle
        self.continueDisabled = continueDisabled
        self.onBack = onBack
        self.onContinue = onContinue
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(OnboardingPalette.accent)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }

            content
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            HStack {
                Button("Zurück", action: onBack)
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                Spacer()
                Button(continueTitle, action: onContinue)
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .disabled(continueDisabled)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 26)
    }
}

/// A large tappable card used for the mode choice and, elsewhere, any
/// single-select option list (agent choice, switch-button choice).
struct OnboardingChoiceCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? OnboardingPalette.accent : Color.white.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .foregroundStyle(isSelected ? .white : Color.white.opacity(0.6))
                        .font(.system(size: 15, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnboardingPalette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(OnboardingPalette.accent)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        // A slight overshoot on the way in (bounces past full
                        // size before settling) reads as a deliberate "pop"
                        // rather than a plain fade/grow.
                        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isSelected)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? OnboardingPalette.cardBackgroundSelected : OnboardingPalette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? OnboardingPalette.accent : OnboardingPalette.cardBorder, lineWidth: isSelected ? 2 : 1)
            )
            // Border/background crossfade is deliberately a plain ease-out,
            // separate from the bouncy checkmark above — the selection state
            // itself should read as a clean, immediate settle.
            .animation(.easeOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(PressableCardButtonStyle())
    }
}

/// Instant scale-down + darken while pressed, matching a physical button's
/// immediate tactile feedback — separate from (and much faster than) the
/// selection-state crossfade above, which only starts once the press ends.
private struct PressableCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
