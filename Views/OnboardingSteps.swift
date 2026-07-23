import SwiftUI

/// Whether onboarding reserves a hardware key for holding-to-switch between
/// the Codex and Claude profiles, or leaves switching to the app only.
/// Shared between `OnboardingView` (which applies the final choice to
/// `ProfileStore.layerSwitchControl` on finish) and the step views below.
enum LayerSwitchChoice: Equatable {
    case key(HardwareControl)
    case appOnly
}

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
            title: "Zwei Berechtigungen",
            subtitle: "Damit CodexPad Tasten und Drehrad empfangen und Shortcuts an Codex/Claude senden kann, braucht macOS diese Freigaben.",
            continueTitle: isQuickMode ? "Los geht's" : "Weiter",
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(spacing: 10) {
                permissionRow(
                    title: "Bedienungshilfen",
                    detail: "Damit CodexPad Tastenkombinationen an Codex/Claude senden kann.",
                    isGranted: monitor.hasAccessibilityPermission
                )
                permissionRow(
                    title: "Input Monitoring",
                    detail: "Damit CodexPad die Tasten und das Drehrad überhaupt empfängt.",
                    isGranted: monitor.hasInputMonitoringPermission
                )
                if !bothGranted {
                    Button("Berechtigungen anfordern") { monitor.requestPermissions() }
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
            title: "Welche Agents nutzt du?",
            subtitle: "Das steuert, welche Profile im Menü auftauchen und ob eine Umschalt-Taste zwischen ihnen sinnvoll ist.",
            continueDisabled: selected.isEmpty,
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(spacing: 12) {
                option(.codex, icon: "terminal.fill", title: "Nur Codex", subtitle: "Nur das Codex-Profil ist aktiv.")
                option(.claude, icon: "sparkles", title: "Nur Claude", subtitle: "Nur das Claude-Profil ist aktiv.")
                OnboardingChoiceCard(
                    icon: "arrow.left.arrow.right",
                    title: "Beide",
                    subtitle: "Codex- und Claude-Profil sind beide aktiv, mit einer Umschalt-Möglichkeit dazwischen.",
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

// MARK: - Switch button

/// Shown only when both agents are selected. Deliberately has no default —
/// `onContinue` stays disabled until the user picks one of the two options,
/// so nobody ends up with a silently-assigned reserved key.
struct OnboardingSwitchButtonStep: View {
    @Binding var choice: LayerSwitchChoice?
    let onBack: () -> Void
    let onContinue: () -> Void

    private var isKeyChoice: Bool {
        if case .key = choice { return true }
        return false
    }

    private var selectedKey: HardwareControl {
        if case .key(let control) = choice { return control }
        return ProfileStore.defaultLayerSwitchControl
    }

    private var highlightBinding: Binding<HardwareControl> {
        Binding(get: { selectedKey }, set: { choice = .key($0) })
    }

    var body: some View {
        OnboardingStepChrome(
            icon: "arrow.left.arrow.right.circle",
            title: "Zwischen Codex und Claude wechseln",
            subtitle: "Eine Taste kann fürs Umschalten reserviert werden, oder du wechselst nur über die App. Klicke eine Taste an, um sie zu wählen.",
            continueDisabled: choice == nil,
            onBack: onBack,
            onContinue: onContinue
        ) {
            VStack(spacing: 12) {
                OnboardingChoiceCard(
                    icon: "hand.tap.fill",
                    title: "Taste zum Halten wählen",
                    subtitle: "Halten (>400 ms) wechselt das Profil.",
                    isSelected: isKeyChoice
                ) { choice = .key(selectedKey) }

                if isKeyChoice {
                    OnboardingSwitchKeyPad(selected: highlightBinding)
                        .padding(.vertical, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                OnboardingChoiceCard(
                    icon: "square.grid.2x2",
                    title: "Nur über die App wechseln",
                    subtitle: "Keine Taste ist reserviert; das Umschalten läuft über Menüleiste bzw. Hauptfenster.",
                    isSelected: choice == .appOnly
                ) { choice = .appOnly }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isKeyChoice)
            .frame(maxWidth: 440)
        }
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
        case .tapHold: "Tippen vs. Halten"
        case .dial: "Das Drehrad"
        case .agentAssignment: "Agents zuweisen"
        }
    }

    var subtitle: String {
        switch self {
        case .ledStatus: "Jede Taste zeigt per Farbe und Effekt den Status ihres zugewiesenen Agents."
        case .tapHold: "Eine Taste kann zwei Funktionen tragen – kurz tippen ist etwas anderes als gedrückt halten."
        case .dial: "Direkt am Pad, ohne die Maus zu benutzen."
        case .agentAssignment: "Threads landen per Halten auf einer Taste, nicht per Konfigurationsmenü."
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
            title: BasicsCard(rawValue: page)?.title ?? "Kurz erklärt",
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
            PadDemoBeat(highlighted: .key2, caption: "Kurz tippen → löst die Tap-Aktion aus", keyGesture: .tap),
            PadDemoBeat(highlighted: .key2, caption: "Gedrückt halten → löst eine zweite, eigene Aktion aus", badge: "Halten erkannt", keyGesture: .hold)
        ]).cardBackground
        case .dial: OnboardingPadDemo(profile: profile, beats: [
            PadDemoBeat(highlighted: .encoderLeft, caption: "Drehen → Reasoning-Aufwand ändern", encoderGesture: .rotateLeft),
            PadDemoBeat(highlighted: .encoderPress, caption: "Kurz drücken → Modellwahl öffnen", encoderGesture: .press),
            PadDemoBeat(highlighted: .encoderPress, caption: "Halten (>350 ms) + drehen → Modell direkt wechseln", badge: "Modell gewechselt", encoderGesture: .rotateRight)
        ]).cardBackground
        case .agentAssignment: OnboardingPadDemo(profile: profile, beats: [
            PadDemoBeat(highlighted: .key1, caption: "Taste halten, während ein Thread aktiv ist", keyGesture: .hold),
            PadDemoBeat(highlighted: .key1, caption: "Die LED zeigt danach den Live-Status", badge: "Thread zugewiesen"),
            PadDemoBeat(highlighted: .key1, caption: "Kurz tippen öffnet den Thread jederzeit wieder", keyGesture: .tap)
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
            title: "Mikrofon-Zuordnung",
            subtitle: "Welches Diktat-Kürzel soll die Diktat-Taste am Pad auslösen?",
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
    let switchChoice: String?
    let micSource: DictationSource
    let onBack: () -> Void
    let onFinish: () -> Void

    private var agentsSummary: String {
        selectedAgents.count == AutomationApp.allCases.count
            ? "Codex und Claude"
            : selectedAgents.first?.displayName ?? "–"
    }

    var body: some View {
        OnboardingStepChrome(
            icon: "checkmark.seal.fill",
            title: "Fertig eingerichtet",
            subtitle: "Alles lässt sich später jederzeit in den Einstellungen ändern.",
            continueTitle: "Los geht's",
            onBack: onBack,
            onContinue: onFinish
        ) {
            VStack(spacing: 10) {
                summaryRow(icon: "person.2.fill", title: "Agents", value: agentsSummary)
                if let switchChoice {
                    summaryRow(icon: "arrow.left.arrow.right", title: "Umschalten", value: switchChoice)
                }
                summaryRow(icon: "mic.fill", title: "Mikrofon", value: micSource.title)
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
