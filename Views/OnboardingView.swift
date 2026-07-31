import SwiftUI

/// First-run flow, gated by `AgentMicro.hasCompletedOnboarding` in `AgentMicroApp`.
/// Offers a one-tap "Schnellstart" (today's permission-only walkthrough) or a
/// guided, step-by-step setup that also configures the agent selection and
/// the dictation source — everything that used to only be discoverable
/// buried in Settings after the fact.
struct OnboardingView: View {
    let appState: AppState
    let onFinished: () -> Void

    private enum Mode: Equatable { case quick, guided }

    /// Every screen the guided path can show, in the fixed order they'd
    /// appear if all were included. `steps` filters this down to what's
    /// actually relevant.
    private enum Step: CaseIterable, Equatable {
        case permissions, agents, claudeStatus, layers, basics, microphone, summary
    }

    static let size = CGSize(width: 560, height: 590)

    @AppStorage(AppLanguage.defaultsKey) private var languageRawValue = AppLanguage.systemDefault.rawValue
    @State private var hasChosenRegionalSetup = false
    @State private var mode: Mode?
    @State private var stepIndex = 0

    // Guided-path choices, applied to `appState.profiles` as they're made.
    @State private var selectedAgents: Set<AutomationApp> = [.codex, .claude]
    @State private var basicsPage = 0
    @State private var micSource: DictationSource = .codex

    private var monitor: PermissionMonitor { appState.permissionMonitor }
    private var language: AppLanguage {
        AppLanguage(rawValue: languageRawValue) ?? .systemDefault
    }
    private var bothPermissionsGranted: Bool {
        monitor.hasAccessibilityPermission
            && (usesPhysicalInputProtocol || monitor.hasInputMonitoringPermission)
    }
    private var usesPhysicalInputProtocol: Bool {
        appState.device.currentDevice?.isCodexPadFirmware == true
    }

    /// A representative profile purely for the illustrative pad diagrams —
    /// showing real key labels/positions is the point, not which app is
    /// ultimately selected.
    private var illustrativeProfile: MacropadProfile {
        appState.profiles.profiles.first(where: { $0.name == "Codex" }) ?? appState.profiles.selectedProfile
    }

    private var steps: [Step] {
        guard mode == .guided else { return mode == .quick ? [.permissions] : [] }
        var steps: [Step] = [.permissions, .agents]
        // Only worth asking if Claude is actually in play — the hooks bridge
        // has no effect on the Codex profile.
        if selectedAgents.contains(.claude) { steps.append(.claudeStatus) }
        steps.append(contentsOf: [.layers, .basics, .microphone, .summary])
        return steps
    }

    var body: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 0) {
                if hasChosenRegionalSetup, mode != nil, !steps.isEmpty {
                    progressBar
                        .padding(.horizontal, 26)
                        .padding(.top, 26)
                        .padding(.bottom, 10)
                }
                ZStack {
                    if !hasChosenRegionalSetup {
                        regionalSetupScreen
                    } else if mode == nil {
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

    // MARK: - Language and keyboard

    private var regionalSetupScreen: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            VStack(spacing: 7) {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(OnboardingPalette.accent)
                Text(language.text("Sprache & Tastatur", "Language & keyboard"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                Text(language.text(
                    "Wähle zuerst die Sprache der App und das Layout deiner Mac-Tastatur.",
                    "First choose the app language and your Mac keyboard layout."
                ))
                .font(.system(size: 12))
                .foregroundStyle(OnboardingPalette.textSecondary)
                .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                languageCard(.german, icon: "textformat.abc")
                languageCard(.english, icon: "character.book.closed")
            }
            .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 7) {
                Text(language.text("Tastaturlayout", "Keyboard layout"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                Picker(
                    language.text("Tastaturlayout", "Keyboard layout"),
                    selection: Binding(
                        get: { appState.profiles.keyboardLayout },
                        set: { appState.profiles.keyboardLayout = $0 }
                    )
                ) {
                    ForEach(KeyboardLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(appState.profiles.keyboardLayout.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(OnboardingPalette.textSecondary)
            }
            .frame(maxWidth: 420)

            Label(
                language.text(
                    "Deine Sprache fehlt? Lass einen Coding-Agenten die zentralen Sprachtexte ergänzen – Beiträge sind willkommen.",
                    "Missing your language? Ask a coding agent to add it through the centralized language strings — contributions are welcome."
                ),
                systemImage: "chevron.left.forwardslash.chevron.right"
            )
            .font(.system(size: 11))
            .foregroundStyle(OnboardingPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)

            HStack {
                Spacer()
                Button(language.text("Weiter", "Continue")) {
                    AppLanguage.current = language
                    hasChosenRegionalSetup = true
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
            }
            .frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
        .padding(30)
    }

    private func languageCard(_ candidate: AppLanguage, icon: String) -> some View {
        OnboardingChoiceCard(
            icon: icon,
            title: candidate.nativeTitle,
            subtitle: candidate == .german ? "Deutsch" : "English",
            isSelected: language == candidate
        ) {
            languageRawValue = candidate.rawValue
            AppLanguage.current = candidate
        }
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
                Text(language.text("Willkommen bei Agent Micro", "Welcome to Agent Micro"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                Text(language.text(
                    "Agent Micro verbindet ein physisches Macropad mit Codex und Claude: Tasten senden Shortcuts, das Drehrad steuert Reasoning-Aufwand und Modellwahl, und die LEDs zeigen den Live-Status deiner Agenten.",
                    "Agent Micro connects a physical macropad to Codex and Claude: keys send shortcuts, the dial controls reasoning effort and model selection, and the LEDs show your agents' live status."
                ))
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            VStack(spacing: 12) {
                OnboardingChoiceCard(
                    icon: "bolt.fill",
                    title: language.text("Schnellstart", "Quick setup"),
                    subtitle: language.text("Nur Berechtigungen einrichten, Rest später in den Einstellungen.", "Set up permissions only; configure everything else later in Settings."),
                    isSelected: false
                ) { goTo(mode: .quick) }

                OnboardingChoiceCard(
                    icon: "list.bullet.rectangle.portrait",
                    title: language.text("Geführte Einrichtung", "Guided setup"),
                    subtitle: language.text("Agents wählen, Layer, Mikrofon und die Bedienung Schritt für Schritt erklärt.", "Choose agents, layers, microphone behavior, and learn the controls step by step."),
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
                usesPhysicalInputProtocol: usesPhysicalInputProtocol,
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
        case .claudeStatus:
            OnboardingClaudeStatusStep(
                isEnabled: appState.claudeAgentBridge.isHooksStatusEnabled,
                errorMessage: appState.claudeAgentBridge.hooksStatusError,
                onToggle: { appState.claudeAgentBridge.setHooksStatusEnabled($0) },
                onBack: goBack,
                onContinue: advance
            )
        case .layers:
            OnboardingLayersStep(
                profile: illustrativeProfile,
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
                micSource: micSource,
                claudeLiveStatus: selectedAgents.contains(.claude)
                    ? appState.claudeAgentBridge.liveStatusAvailability.title
                    : nil,
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
        continueTitle: String = AppLanguage.text("Weiter", "Continue"),
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
                Button(AppLanguage.text("Zurück", "Back"), action: onBack)
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
