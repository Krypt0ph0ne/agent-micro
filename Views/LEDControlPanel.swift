import AppKit
import SwiftUI

private enum LEDEditorSection: String, CaseIterable, Identifiable {
    case base = "Grundlicht"
    case reactions = "Reaktionen"
    var id: String { rawValue }
}

private enum LEDScope: Hashable {
    case all
    case key(HardwareControl)

    static let allScopes: [LEDScope] = [.all] + HardwareControl.buttons.map(LEDScope.key)

    var title: String {
        switch self {
        case .all: "Alle"
        case .key(let control): control.shortTitle.replacingOccurrences(of: "Taste ", with: "")
        }
    }

    var detailTitle: String {
        switch self {
        case .all: "Alle Tasten"
        case .key(let control): control.shortTitle
        }
    }
}

struct LEDControlPanel: View {
    let appState: AppState
    @Binding var control: HardwareControl
    @State private var section: LEDEditorSection = .base
    @State private var scope: LEDScope = .all

    private var targetControls: [HardwareControl] {
        switch scope {
        case .all: HardwareControl.buttons
        case .key(let control): [control]
        }
    }

    private var setting: KeyLEDConfiguration {
        appState.profiles.selectedProfile.led.setting(for: targetControls[0])
    }

    private var idle: IdleLEDConfiguration {
        appState.profiles.selectedProfile.idleLighting
    }

    /// Colour swatch shown in the header, reflecting the current base layer.
    private var headerPreviewColor: Color {
        guard idle.enabled else { return Color.white.opacity(0.16) }
        return idle.perKey ? setting.previewColor : idle.keyConfiguration(for: targetControls[0]).previewColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "lightbulb.led.fill")
                    .foregroundStyle(headerPreviewColor)
                Text("Licht")
                    .font(.headline)
                ContextInfoButton(
                    title: "So funktioniert das Licht",
                    message: "Zwei Ebenen: Das Grundlicht zeigt, wie deine Tasten im Ruhezustand aussehen. Reaktionen legen sich bei Ereignissen (Diktat, Senden, Agent-Status) automatisch darüber und kehren danach zum Grundlicht zurück."
                )
                Spacer()
            }

            Picker("Lichteditor", selection: $section) {
                ForEach(LEDEditorSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if section == .base {
                baseEditor
            } else {
                LEDReactionEditor(appState: appState)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: scope) { _, newScope in
            if case .key(let selected) = newScope { control = selected }
        }
    }

    private var baseEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("So sehen deine Tasten aus, solange nichts passiert. Reaktionen legen sich bei Ereignissen kurz darüber und kehren danach hierher zurück.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Grundlicht an", isOn: idleBinding(\.enabled))

            Picker("Modus", selection: idleBinding(\.perKey)) {
                Text("Alle gleich").tag(false)
                Text("Pro Taste").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!idle.enabled)

            if idle.perKey {
                perKeyControls
                    .disabled(!idle.enabled)
            } else {
                allKeysControls
                    .disabled(!idle.enabled)
            }
        }
    }

    // MARK: Base · one colour for every key

    private var allKeysControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Effekt")
                Spacer()
                Picker("Effekt", selection: idleBinding(\.effect)) {
                    ForEach(LEDEffect.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 138)
            }

            HStack {
                ColorPicker("Farbe", selection: idleColorBinding, supportsOpacity: false)
                Spacer()
                idlePresetColors
            }

            brightnessControls(
                effect: idle.effect,
                maxLabel: "Helligkeit",
                max: idleByteBinding(\.brightness),
                maxPercent: Int(idle.brightness) * 100 / 255,
                min: idleByteBinding(\.minBrightness),
                minPercent: Int(idle.minBrightness) * 100 / 255
            )

            if idle.effect == .blink || idle.effect == .pulse {
                LabeledContent(idle.effect == .blink ? "Blinkdauer" : "Pulsdauer") {
                    HStack(spacing: 8) {
                        Slider(value: idlePeriodBinding, in: 100...5_000)
                        Text(idlePeriodLabel)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Base · individual colour per key

    private var perKeyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Taste", selection: $scope) {
                ForEach(LEDScope.allScopes, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text("Effekt")
                Spacer()
                Picker("Effekt", selection: valueBinding(\.effect)) {
                    ForEach(LEDEffect.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 138)
            }

            HStack {
                ColorPicker("Farbe", selection: colorBinding, supportsOpacity: false)
                Spacer()
                presetColors
            }

            brightnessControls(
                effect: setting.effect,
                maxLabel: "Helligkeit",
                max: byteBinding(\.brightness),
                maxPercent: Int(setting.brightness) * 100 / 255,
                min: byteBinding(\.minBrightness),
                minPercent: Int(setting.minBrightness) * 100 / 255
            )

            if setting.effect == .blink || setting.effect == .pulse {
                LabeledContent(setting.effect == .blink ? "Blinkdauer" : "Pulsdauer") {
                    HStack(spacing: 8) {
                        Slider(value: periodBinding, in: 100...5_000)
                        Text(periodLabel)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            HStack {
                Button("Alle Tasten aus") { turnAllOff() }
                Spacer()
            }
        }
    }

    private var presetColors: some View {
        HStack(spacing: 5) {
            ForEach(Self.presets, id: \.name) { preset in
                Button {
                    update { value in
                        value.red = preset.rgb.0
                        value.green = preset.rgb.1
                        value.blue = preset.rgb.2
                        if value.effect == .off { value.effect = .steady }
                    }
                } label: {
                    Circle()
                        .fill(preset.color)
                        .frame(width: 17, height: 17)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }

    private var idlePresetColors: some View {
        HStack(spacing: 5) {
            ForEach(Self.presets, id: \.name) { preset in
                Button {
                    updateIdle { idle in
                        idle.red = preset.rgb.0
                        idle.green = preset.rgb.1
                        idle.blue = preset.rgb.2
                        if idle.effect == .off { idle.effect = .steady }
                    }
                } label: {
                    Circle()
                        .fill(preset.color)
                        .frame(width: 17, height: 17)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(preset.name)
                .accessibilityLabel("Idle-Farbe \(preset.name)")
            }
        }
    }

    /// Brightness row(s) shared by the base editors: a single slider normally,
    /// or a "Von / Bis" pair once "Pulsieren" is selected, so the effect can
    /// breathe within a configured range instead of always dipping to zero.
    @ViewBuilder
    private func brightnessControls(
        effect: LEDEffect,
        maxLabel: String,
        max: Binding<Double>,
        maxPercent: Int,
        min: Binding<Double>,
        minPercent: Int
    ) -> some View {
        LabeledContent(effect == .pulse ? "Bis" : maxLabel) {
            HStack(spacing: 8) {
                Slider(value: max, in: 0...255)
                Text("\(maxPercent) %")
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
        }
        if effect == .pulse {
            LabeledContent("Von") {
                HStack(spacing: 8) {
                    Slider(value: min, in: 0...255)
                    Text("\(minPercent) %")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }
            Text("Pulsiert zwischen \(minPercent) % und \(maxPercent) %. Bei 0 % pulsiert es klassisch bis ganz aus.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { setting.color },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                update { value in
                    value.red = UInt8(clamping: Int((rgb.redComponent * 255).rounded()))
                    value.green = UInt8(clamping: Int((rgb.greenComponent * 255).rounded()))
                    value.blue = UInt8(clamping: Int((rgb.blueComponent * 255).rounded()))
                    if value.effect == .off { value.effect = .steady }
                }
            }
        )
    }

    private func valueBinding<Value>(_ keyPath: WritableKeyPath<KeyLEDConfiguration, Value>) -> Binding<Value> {
        Binding(get: { setting[keyPath: keyPath] }, set: { newValue in update { $0[keyPath: keyPath] = newValue } })
    }

    private func byteBinding(_ keyPath: WritableKeyPath<KeyLEDConfiguration, UInt8>) -> Binding<Double> {
        Binding(get: { Double(setting[keyPath: keyPath]) }, set: { newValue in update { $0[keyPath: keyPath] = UInt8(clamping: Int(newValue.rounded())) } })
    }

    private var periodBinding: Binding<Double> {
        Binding(get: { Double(setting.periodMilliseconds) }, set: { newValue in update { $0.periodMilliseconds = Int((newValue / 100).rounded()) * 100 } })
    }

    private var periodLabel: String {
        setting.periodMilliseconds >= 1_000
            ? String(format: "%.1f s", Double(setting.periodMilliseconds) / 1_000)
            : "\(setting.periodMilliseconds) ms"
    }

    private func idleBinding<Value>(_ keyPath: WritableKeyPath<IdleLEDConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { appState.profiles.selectedProfile.idleLighting[keyPath: keyPath] },
            set: { newValue in updateIdle { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func idleByteBinding(_ keyPath: WritableKeyPath<IdleLEDConfiguration, UInt8>) -> Binding<Double> {
        Binding(
            get: { Double(appState.profiles.selectedProfile.idleLighting[keyPath: keyPath]) },
            set: { newValue in updateIdle { $0[keyPath: keyPath] = UInt8(clamping: Int(newValue.rounded())) } }
        )
    }

    private var idleColorBinding: Binding<Color> {
        Binding(
            get: { appState.profiles.selectedProfile.idleLighting.color },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                updateIdle { idle in
                    idle.red = UInt8(clamping: Int((rgb.redComponent * 255).rounded()))
                    idle.green = UInt8(clamping: Int((rgb.greenComponent * 255).rounded()))
                    idle.blue = UInt8(clamping: Int((rgb.blueComponent * 255).rounded()))
                    if idle.effect == .off { idle.effect = .steady }
                }
            }
        )
    }

    private var idlePeriodBinding: Binding<Double> {
        Binding(
            get: { Double(appState.profiles.selectedProfile.idleLighting.periodMilliseconds) },
            set: { newValue in updateIdle { $0.periodMilliseconds = Int((newValue / 100).rounded()) * 100 } }
        )
    }

    private var idlePeriodLabel: String {
        let period = appState.profiles.selectedProfile.idleLighting.periodMilliseconds
        return period >= 1_000 ? String(format: "%.1f s", Double(period) / 1_000) : "\(period) ms"
    }

    private func update(_ mutation: (inout KeyLEDConfiguration) -> Void) {
        let settings = targetControls.map { control in
            var next = appState.profiles.selectedProfile.led.setting(for: control)
            mutation(&next)
            return next
        }
        appState.profiles.updateLEDs(settings)
        appState.refreshAgentLEDs()
    }

    private func updateIdle(_ mutation: (inout IdleLEDConfiguration) -> Void) {
        var idle = appState.profiles.selectedProfile.idleLighting
        mutation(&idle)
        appState.profiles.updateIdleLighting(idle)
        appState.refreshAgentLEDs()
    }

    private func turnAllOff() {
        let settings = HardwareControl.buttons.map { control in
            var next = appState.profiles.selectedProfile.led.setting(for: control)
            next.effect = .off
            return next
        }
        appState.profiles.updateLEDs(settings)
        appState.refreshAgentLEDs()
    }

    private static let presets: [(name: String, color: Color, rgb: (UInt8, UInt8, UInt8))] = [
        ("Rot", .red, (255, 0, 0)), ("Orange", .orange, (255, 96, 0)),
        ("Gelb", .yellow, (255, 255, 0)), ("Grün", .green, (0, 255, 0)),
        ("Cyan", .cyan, (0, 255, 255)), ("Blau", .blue, (0, 0, 255)),
        ("Pink", .pink, (255, 0, 255)), ("Weiß", .white, (255, 255, 255))
    ]
}

private struct LEDReactionEditor: View {
    let appState: AppState
    @State private var expandedEvents: Set<LEDReactionEvent> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Automatische Lichtsignale bei Ereignissen. Änderungen werden im aktuellen Profil gespeichert.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(LEDReactionEvent.allCases) { event in
                        reactionRow(event)
                    }
                }
            }
            .frame(height: 250)
        }
    }

    private func reactionRow(_ event: LEDReactionEvent) -> some View {
        let reaction = appState.profiles.selectedProfile.reaction(for: event)
        let isExpanded = expandedEvents.contains(event)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Circle()
                    .fill(reaction.color)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.caption.weight(.medium))
                    Text(event.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                ColorPicker("Farbe", selection: reactionColorBinding(event), supportsOpacity: false)
                    .labelsHidden()
                Picker("Effekt", selection: reactionEffectBinding(event)) {
                    ForEach(LEDReactionEffect.allCases) { effect in
                        Text(effect.title).tag(effect)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isExpanded {
                            expandedEvents.remove(event)
                        } else {
                            expandedEvents.insert(event)
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Optionen schließen" : "Helligkeit und Dauer einstellen")
                .accessibilityLabel("Optionen für \(event.title)")
            }

            if isExpanded {
                reactionOptions(event, reaction: reaction)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
    }

    private func reactionOptions(_ event: LEDReactionEvent, reaction: LEDReactionConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent(reaction.effect == .pulse ? "Bis" : "Helligkeit") {
                HStack(spacing: 8) {
                    Slider(value: reactionByteBinding(event, \.brightness), in: 0...255)
                    Text("\(Int(reaction.brightness) * 100 / 255) %")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }

            if reaction.effect == .pulse {
                LabeledContent("Von") {
                    HStack(spacing: 8) {
                        Slider(value: reactionByteBinding(event, \.minBrightness), in: 0...255)
                        Text("\(Int(reaction.minBrightness) * 100 / 255) %")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Text("Pulsiert zwischen \(Int(reaction.minBrightness) * 100 / 255) % und \(Int(reaction.brightness) * 100 / 255) %.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if reaction.effect == .blink || reaction.effect == .pulse || reaction.effect == .flash {
                LabeledContent(reaction.effect == .flash ? "Dauer" : "Effektdauer") {
                    HStack(spacing: 8) {
                        Slider(value: reactionPeriodBinding(event), in: 100...5_000)
                        Text(periodLabel(reaction.periodMilliseconds))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            if event.isAgentEvent {
                Toggle("Grundlicht bei diesem Status ausblenden", isOn: reactionIdleOverrideBinding(event))
                    .font(.caption)
            }
        }
        .font(.caption)
        .padding(.leading, 18)
    }

    private func reactionColorBinding(_ event: LEDReactionEvent) -> Binding<Color> {
        Binding(
            get: { appState.profiles.selectedProfile.reaction(for: event).color },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                var reaction = appState.profiles.selectedProfile.reaction(for: event)
                reaction.red = UInt8(clamping: Int((rgb.redComponent * 255).rounded()))
                reaction.green = UInt8(clamping: Int((rgb.greenComponent * 255).rounded()))
                reaction.blue = UInt8(clamping: Int((rgb.blueComponent * 255).rounded()))
                if reaction.effect == .off { reaction.effect = .steady }
                save(reaction)
            }
        )
    }

    private func reactionEffectBinding(_ event: LEDReactionEvent) -> Binding<LEDReactionEffect> {
        Binding(
            get: { appState.profiles.selectedProfile.reaction(for: event).effect },
            set: { effect in
                var reaction = appState.profiles.selectedProfile.reaction(for: event)
                reaction.effect = effect
                save(reaction)
            }
        )
    }

    private func reactionByteBinding(_ event: LEDReactionEvent, _ keyPath: WritableKeyPath<LEDReactionConfiguration, UInt8>) -> Binding<Double> {
        Binding(
            get: { Double(appState.profiles.selectedProfile.reaction(for: event)[keyPath: keyPath]) },
            set: { value in mutateReaction(event) { $0[keyPath: keyPath] = UInt8(clamping: Int(value.rounded())) } }
        )
    }

    private func reactionPeriodBinding(_ event: LEDReactionEvent) -> Binding<Double> {
        Binding(
            get: { Double(appState.profiles.selectedProfile.reaction(for: event).periodMilliseconds) },
            set: { value in mutateReaction(event) { $0.periodMilliseconds = Int((value / 100).rounded()) * 100 } }
        )
    }

    private func reactionIdleOverrideBinding(_ event: LEDReactionEvent) -> Binding<Bool> {
        Binding(
            get: { appState.profiles.selectedProfile.reaction(for: event).disablesIdle },
            set: { value in mutateReaction(event) { $0.disablesIdle = value } }
        )
    }

    private func mutateReaction(_ event: LEDReactionEvent, _ mutation: (inout LEDReactionConfiguration) -> Void) {
        var reaction = appState.profiles.selectedProfile.reaction(for: event)
        mutation(&reaction)
        save(reaction)
    }

    private func periodLabel(_ milliseconds: Int) -> String {
        milliseconds >= 1_000
            ? String(format: "%.1f s", Double(milliseconds) / 1_000)
            : "\(milliseconds) ms"
    }

    private func save(_ reaction: LEDReactionConfiguration) {
        appState.profiles.updateReaction(reaction)
        appState.refreshAgentLEDs()
    }
}

private extension KeyLEDConfiguration {
    var color: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

private extension LEDReactionConfiguration {
    var color: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

private extension IdleLEDConfiguration {
    var color: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}
