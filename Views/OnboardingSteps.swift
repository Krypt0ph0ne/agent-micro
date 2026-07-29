import SwiftUI

// MARK: - Permissions

/// First real step of both the quick and guided path: the same permission
/// walkthrough CodexPad always required, now framed as step 1 of the wizard
/// instead of the sole screen.
struct OnboardingPermissionsStep: View {
    let monitor: PermissionMonitor
    let bothGranted: Bool
    let isQuickMode: Bool
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepChrome(
            icon: "lock.shield",
            title: AppLanguage.text("Zwei Berechtigungen", "Two permissions"),
            subtitle: AppLanguage.text(
                "Damit Agent Micro Tasten und Drehrad empfangen und Shortcuts an Codex/Claude senden kann, braucht macOS diese Freigaben.",
                "Agent Micro needs these macOS permissions to receive keys and dial input and send shortcuts to Codex and Claude."
            ),
            continueTitle: isQuickMode ? AppLanguage.text("Los geht's", "Get started") : AppLanguage.text("Weiter", "Continue"),
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(spacing: 10) {
                permissionRow(
                    title: AppLanguage.text("Bedienungshilfen", "Accessibility"),
                    detail: AppLanguage.text("Damit Agent Micro Tastenkombinationen an Codex/Claude senden kann.", "Allows Agent Micro to send keyboard shortcuts to Codex and Claude."),
                    isGranted: monitor.hasAccessibilityPermission
                )
                permissionRow(
                    title: "Input Monitoring",
                    detail: AppLanguage.text("Damit Agent Micro die Tasten und das Drehrad überhaupt empfängt.", "Allows Agent Micro to receive keys and dial input."),
                    isGranted: monitor.hasInputMonitoringPermission
                )
                if !bothGranted {
                    Button(AppLanguage.text("Berechtigungen anfordern", "Request permissions")) { monitor.requestPermissions() }
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 420)
        }
    }

    private func permissionRow(title: String, detail: String, isGranted: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
                .symbolEffect(.bounce, value: isGranted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(OnboardingPalette.textPrimary)
                Text(detail).font(.system(size: 11)).foregroundStyle(OnboardingPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(OnboardingPalette.rowBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Agent choice

struct OnboardingAgentChoiceStep: View {
    @Binding var selected: Set<AutomationApp>
    let onBack: () -> Void
    let onContinue: () -> Void

    private var isBoth: Bool { selected == Set(AutomationApp.allCases) }

    var body: some View {
        OnboardingStepChrome(
            icon: "person.2.badge.gearshape",
            title: AppLanguage.text("Welche Agents nutzt du?", "Which agents do you use?"),
            subtitle: AppLanguage.text("Das steuert, welche Profile im Menü auftauchen.", "This controls which profiles appear in the menu."),
            continueDisabled: selected.isEmpty,
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(spacing: 12) {
                option(.codex, icon: "terminal.fill", title: AppLanguage.text("Nur Codex", "Codex only"), subtitle: AppLanguage.text("Nur das Codex-Profil ist aktiv.", "Only the Codex profile is active."))
                option(.claude, icon: "sparkles", title: AppLanguage.text("Nur Claude", "Claude only"), subtitle: AppLanguage.text("Nur das Claude-Profil ist aktiv.", "Only the Claude profile is active."))
                OnboardingChoiceCard(
                    icon: "arrow.left.arrow.right",
                    title: AppLanguage.text("Beide", "Both"),
                    subtitle: AppLanguage.text(
                        "Codex- und Claude-Profil sind beide aktiv; weise irgendeiner Taste die Aktion „Profil wechseln“ zu, um zwischen ihnen zu springen.",
                        "Both Codex and Claude profiles are active. Assign Switch profile to any key to move between them."
                    ),
                    isSelected: isBoth
                ) { selected = Set(AutomationApp.allCases) }
            }
            .frame(maxWidth: 420)
        }
    }

    private func option(_ app: AutomationApp, icon: String, title: String, subtitle: String) -> some View {
        OnboardingChoiceCard(
            icon: icon,
            title: title,
            subtitle: subtitle,
            isSelected: selected == [app]
        ) { selected = [app] }
    }
}

// MARK: - Layers

/// Purely explanatory — layers themselves are created/edited later via the
/// layer picker next to the profile picker, not here. Shows the two example
/// layers every built-in profile ships with, so the concept isn't abstract.
struct OnboardingLayersStep: View {
    let profile: MacropadProfile
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepChrome(
            icon: "square.stack.3d.up",
            title: AppLanguage.text("Layer pro Profil", "Layers per profile"),
            subtitle: AppLanguage.text(
                "Jedes Profil kann mehrere Layer mit unterschiedlichen Tastenbelegungen haben. Weise einer Taste die Aktion „Layer wechseln“ zu, um zwischen ihnen zu springen – das Pad blinkt kurz in der Farbe des neuen Layers, damit du auch ohne Blick in die App weißt, welcher aktiv ist.",
                "Each profile can have multiple layers with different key mappings. Assign Switch layer to a key to move between them. The pad briefly flashes the new layer's color so you know which one is active."
            ),
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(spacing: 10) {
                ForEach(profile.layers) { layer in
                    layerCard(layer)
                }
                Text(AppLanguage.text(
                    "Codex und Claude starten schon mit zwei Beispiel-Layern; weitere legst du über das Stapel-Symbol neben der Profilauswahl an. Zwischen Codex und Claude selbst wechselst du genauso einfach über die Aktion „Profil wechseln“.",
                    "Codex and Claude start with two example layers. Add more with the stack icon next to the profile picker. Switch between Codex and Claude with the Switch profile action."
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)
        }
    }

    private func layerCard(_ layer: ProfileLayer) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color(
                    red: Double(layer.blinkRed) / 255,
                    green: Double(layer.blinkGreen) / 255,
                    blue: Double(layer.blinkBlue) / 255
                ))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.textPrimary)
                Text(layer.controls.prefix(3).map(\.action.displayLabel).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(OnboardingPalette.textSecondary)
                    .lineLimit(1)
                    .help(layer.controls.prefix(3).map(\.action.displayLabel).joined(separator: " · "))
            }
            Spacer(minLength: 8)
            Text(AppLanguage.text("blinkt \(layer.blinkCount)×", "flashes \(layer.blinkCount)×"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OnboardingPalette.textSecondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(OnboardingPalette.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OnboardingPalette.cardBorder, lineWidth: 1))
    }
}

// MARK: - Basics carousel

private enum BasicsCard: Int, CaseIterable {
    case ledStatus, tapHold, dial, agentAssignment

    var icon: String {
        switch self {
        case .ledStatus: "circle.hexagongrid.fill"
        case .tapHold: "hand.tap"
        case .dial: "dial.medium.fill"
        case .agentAssignment: "person.crop.circle.badge.plus"
        }
    }

    var title: String {
        switch self {
        case .ledStatus: "Status-LEDs"
        case .tapHold: AppLanguage.text("Tippen vs. Halten", "Tap vs. hold")
        case .dial: AppLanguage.text("Das Drehrad", "The dial")
        case .agentAssignment: AppLanguage.text("Agents zuweisen", "Assign agents")
        }
    }

    var subtitle: String {
        switch self {
        case .ledStatus: AppLanguage.text("Jede Taste zeigt per Farbe und Effekt den Status ihres zugewiesenen Agents.", "Each key shows its assigned agent's status through color and effects.")
        case .tapHold: AppLanguage.text("Eine Taste kann zwei Funktionen tragen – kurz tippen ist etwas anderes als gedrückt halten.", "A key can have two functions: a quick tap differs from holding it.")
        case .dial: AppLanguage.text("Direkt am Pad, ohne die Maus zu benutzen.", "Control it directly on the pad without using the mouse.")
        case .agentAssignment: AppLanguage.text("Threads landen per Halten auf einer Taste, nicht per Konfigurationsmenü.", "Assign threads by holding a key, without digging through a configuration menu.")
        }
    }
}

struct OnboardingBasicsStep: View {
    @Binding var page: Int
    let profile: MacropadProfile
    let onBack: () -> Void
    let onContinue: () -> Void

    /// Only the *entering* card is animated (slide + fade in from the side
    /// matching direction); the outgoing one uses `.identity` — no removal
    /// animation at all. That's deliberate: an asymmetric transition whose
    /// removal edge also depends on this flag would replay whatever
    /// direction was current when the outgoing view was last inserted, not
    /// the direction of the click that's removing it now — the same stale-
    /// direction bug the step pager had. Animating only the entrance sidesteps
    /// it entirely.
    @State private var enterFromTrailing = true

    private var isLastCard: Bool { page == BasicsCard.allCases.count - 1 }

    var body: some View {
        OnboardingStepChrome(
            icon: "questionmark.circle",
            title: BasicsCard(rawValue: page)?.title ?? AppLanguage.text("Kurz erklärt", "Quick introduction"),
            subtitle: BasicsCard(rawValue: page)?.subtitle ?? "",
            onBack: onBack,
            onContinue: { if isLastCard { onContinue() } else { goTo(page + 1) } }
        ) {
            VStack(spacing: 12) {
                ZStack {
                    ForEach(BasicsCard.allCases, id: \.self) { card in
                        if card.rawValue == page {
                            basicsCardBody(card)
                                .transition(.asymmetric(
                                    insertion: .move(edge: enterFromTrailing ? .trailing : .leading).combined(with: .opacity),
                                    removal: .identity
                                ))
                        }
                    }
                }
                .frame(height: 250)

                HStack(spacing: 8) {
                    Button {
                        goTo(max(0, page - 1))
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(page == 0)

                    HStack(spacing: 6) {
                        ForEach(BasicsCard.allCases, id: \.self) { card in
                            Circle()
                                .fill(card.rawValue == page ? OnboardingPalette.accent : OnboardingPalette.progressTrack)
                                .frame(width: 6, height: 6)
                        }
                    }

                    Button {
                        goTo(min(BasicsCard.allCases.count - 1, page + 1))
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLastCard)
                }
                .foregroundStyle(OnboardingPalette.textSecondary)
            }
            .frame(maxWidth: 440)
        }
    }

    private func goTo(_ newPage: Int) {
        guard newPage != page else { return }
        enterFromTrailing = newPage > page
        withAnimation(.easeOut(duration: 0.32)) { page = newPage }
    }

    @ViewBuilder
    private func basicsCardBody(_ card: BasicsCard) -> some View {
        switch card {
        case .ledStatus: OnboardingLEDStatusDemo(profile: profile).cardBackground
        case .tapHold: OnboardingPadDemo(profile: profile, beats: [
            PadDemoBeat(highlighted: .key2, caption: AppLanguage.text("Kurz tippen → löst die Tap-Aktion aus", "Quick tap → triggers the tap action"), keyGesture: .tap),
            PadDemoBeat(highlighted: .key2, caption: AppLanguage.text("Gedrückt halten → löst eine zweite, eigene Aktion aus", "Hold → triggers a separate second action"), badge: AppLanguage.text("Halten erkannt", "Hold detected"), keyGesture: .hold)
        ]).cardBackground
        case .dial: OnboardingPadDemo(profile: profile, beats: [
            PadDemoBeat(highlighted: .encoderLeft, caption: AppLanguage.text("Drehen → Reasoning-Aufwand ändern", "Turn → change reasoning effort"), encoderGesture: .rotateLeft),
            PadDemoBeat(highlighted: .encoderPress, caption: AppLanguage.text("Kurz drücken → Modellwahl öffnen", "Press → open model picker"), encoderGesture: .press),
            PadDemoBeat(highlighted: .encoderPress, caption: AppLanguage.text("Halten (>350 ms) + drehen → Modell direkt wechseln", "Hold (>350 ms) + turn → switch model directly"), badge: AppLanguage.text("Modell gewechselt", "Model changed"), encoderGesture: .rotateRight)
        ]).cardBackground
        case .agentAssignment: OnboardingPadDemo(profile: profile, beats: [
            PadDemoBeat(highlighted: .key1, caption: AppLanguage.text("Taste halten, während ein Thread aktiv ist", "Hold a key while a thread is active"), keyGesture: .hold),
            PadDemoBeat(highlighted: .key1, caption: AppLanguage.text("Die LED zeigt danach den Live-Status", "The LED then shows its live status"), badge: AppLanguage.text("Thread zugewiesen", "Thread assigned")),
            PadDemoBeat(highlighted: .key1, caption: AppLanguage.text("Kurz tippen öffnet den Thread jederzeit wieder", "Tap to reopen the thread at any time"), keyGesture: .tap)
        ]).cardBackground
        }
    }
}

/// Live version of the LED legend: key 1 on the schematic pad cycles
/// through every status color/effect automatically every 5s, or jump to one
/// directly via its chip below — matching it against the real pad instead
/// of describing it as a static, disconnected list.
private struct OnboardingLEDStatusDemo: View {
    struct State_ {
        let label: String
        let color: Color
        let effect: OnboardingDemoPad.DotEffect
    }

    let profile: MacropadProfile

    // English on purpose: the German equivalents ("Braucht Eingabe",
    // "Fehlgeschlagen", "Unterbrochen", …) were long enough to truncate as
    // chip labels in this tight row; the short English words fit without it.
    private static let states: [State_] = [
        State_(label: "Running", color: Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255), effect: .pulse),
        State_(label: "Idle", color: .white, effect: .pulse),
        State_(label: "Needs Input", color: Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255), effect: .blink),
        State_(label: "Done", color: Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255), effect: .flash),
        State_(label: "Failed", color: Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255), effect: .blink),
        State_(label: "Interrupted", color: Color(red: 191 / 255, green: 90 / 255, blue: 242 / 255), effect: .steady)
    ]

    @State private var stateIndex = 0
    @State private var cycleToken = UUID()

    var body: some View {
        VStack(spacing: 12) {
            OnboardingDemoPad(
                dots: [.key1: .init(color: Self.states[stateIndex].color, effect: Self.states[stateIndex].effect, size: 16)],
                scale: 0.85,
                profile: profile
            )
            HStack(spacing: 5) {
                ForEach(Self.states.indices, id: \.self) { index in
                    chip(index)
                }
            }
            .frame(maxWidth: 380)
        }
        .task(id: cycleToken) { await autoCycle() }
    }

    private func chip(_ index: Int) -> some View {
        let active = index == stateIndex
        let color = Self.states[index].color
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { stateIndex = index }
            cycleToken = UUID()
        } label: {
            Text(Self.states[index].label)
                .font(.system(size: 10, weight: .semibold))
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(active ? color : Color.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(active ? color : Color.white.opacity(0.16), lineWidth: 1.5))
                // A light chip fill (e.g. the white "Idle" state) needs dark
                // text, not the usual white-on-dark — otherwise it's
                // invisible against its own background.
                .foregroundStyle(active ? (color.isLight ? .black : .white) : Color.white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: active)
    }

    @MainActor
    private func autoCycle() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                stateIndex = (stateIndex + 1) % Self.states.count
            }
        }
    }
}

private extension View {
    var cardBackground: some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OnboardingPalette.rowBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Microphone

struct OnboardingMicrophoneStep: View {
    @Binding var source: DictationSource
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepChrome(
            icon: "mic.fill",
            title: AppLanguage.text("Mikrofon-Zuordnung", "Microphone assignment"),
            subtitle: AppLanguage.text("Welches Diktat-Kürzel soll die Diktat-Taste am Pad auslösen?", "Which dictation shortcut should the pad's dictation key trigger?"),
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(spacing: 12) {
                ForEach(DictationSource.allCases) { candidate in
                    OnboardingChoiceCard(
                        icon: icon(for: candidate),
                        title: candidate.title,
                        subtitle: candidate.detail,
                        isSelected: source == candidate
                    ) { source = candidate }
                }
            }
            .frame(maxWidth: 420)
        }
    }

    private func icon(for source: DictationSource) -> String {
        switch source {
        case .codex: "terminal.fill"
        case .claude: "sparkles"
        case .followProfile: "arrow.triangle.2.circlepath"
        }
    }
}

// MARK: - Summary

struct OnboardingSummaryStep: View {
    let selectedAgents: Set<AutomationApp>
    let micSource: DictationSource
    let onBack: () -> Void
    let onFinish: () -> Void

    private var agentsSummary: String {
        selectedAgents.count == AutomationApp.allCases.count
            ? AppLanguage.text("Codex und Claude", "Codex and Claude")
            : selectedAgents.first?.displayName ?? "–"
    }

    var body: some View {
        OnboardingStepChrome(
            icon: "checkmark.seal.fill",
            title: AppLanguage.text("Fertig eingerichtet", "Setup complete"),
            subtitle: AppLanguage.text("Alles lässt sich später jederzeit in den Einstellungen ändern.", "You can change everything later in Settings."),
            continueTitle: AppLanguage.text("Los geht's", "Get started"),
            onBack: onBack,
            onContinue: onFinish
        ) {
            VStack(spacing: 10) {
                summaryRow(icon: "person.2.fill", title: "Agents", value: agentsSummary)
                summaryRow(icon: "mic.fill", title: AppLanguage.text("Mikrofon", "Microphone"), value: micSource.title)
            }
            .frame(maxWidth: 420)
        }
    }

    private func summaryRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OnboardingPalette.textPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(OnboardingPalette.textSecondary)
        }
        .padding(12)
        .background(OnboardingPalette.rowBackground, in: RoundedRectangle(cornerRadius: 9))
    }
}
