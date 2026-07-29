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

            EditorModeSwitch(
                selection: $section,
                options: [
                    .init(.base, title: "Grundlicht"),
                    .init(.reactions, title: "Reaktionen")
                ],
                density: .compact,
                accessibilityLabel: "Lichteditor"
            )

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

            HStack(spacing: 8) {
                EditorToggleRail(
                    isOn: idleBinding(\.enabled),
                    title: "Grundlicht",
                    systemImage: "lightbulb.led.fill"
                )
                .frame(width: 138)

                EditorModeSwitch(
                    selection: idleBinding(\.perKey),
                    options: [
                        .init(false, title: "Alle Tasten"),
                        .init(true, title: "Pro Taste")
                    ],
                    density: .compact,
                    accessibilityLabel: "Grundlichtmodus"
                )
                .disabled(!idle.enabled)
            }

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
    @State private var expandedLayerIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Automatische Lichtsignale bei Ereignissen. Änderungen werden im aktuellen Profil gespeichert.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Layer-Wechsel")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                        Text("Bestätigung direkt nach dem Wechsel. Jede Belegung hat ihr eigenes Signal.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                        ForEach(appState.profiles.selectedProfile.layers) { layer in
                            layerConfirmationRow(layer)
                        }
                    }

                    ForEach(LEDReactionGroup.allCases) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                            ForEach(group.events) { event in
                                reactionRow(event)
                            }
                        }
                    }
                }
            }
            .frame(height: 320)
        }
    }

    private func layerConfirmationRow(_ layer: ProfileLayer) -> some View {
        let isExpanded = expandedLayerIDs.contains(layer.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Circle()
                    .fill(layer.confirmation.color)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.name)
                        .font(.caption.weight(.medium))
                    Text(layer.id == appState.profiles.selectedProfile.activeLayerID ? "Aktiver Layer" : "Layer-Bestätigung")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    appState.previewLayerConfirmation(layer.id)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Bestätigung testen")

                ColorPicker("Farbe", selection: layerColorBinding(layer.id), supportsOpacity: false)
                    .labelsHidden()
                Picker("Effekt", selection: layerEffectBinding(layer.id)) {
                    ForEach(LEDReactionEffect.allCases) { effect in
                        Text(effect.title).tag(effect)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isExpanded {
                            expandedLayerIDs.remove(layer.id)
                        } else {
                            expandedLayerIDs.insert(layer.id)
                        }
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Optionen schließen" : "Helligkeit, Dauer und Wiederholungen")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    LabeledContent("Helligkeit") {
                        HStack(spacing: 8) {
                            Slider(value: layerBrightnessBinding(layer.id), in: 1...255)
                            Text("\(Int(layer.confirmationBrightness) * 100 / 255) %")
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    LabeledContent("Dauer") {
                        HStack(spacing: 8) {
                            Slider(value: layerDurationBinding(layer.id), in: 80...2_000, step: 20)
                            Text(periodLabel(layer.confirmationDurationMilliseconds))
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                    if layer.confirmationEffect != .steady && layer.confirmationEffect != .off {
                        Stepper(
                            "Wiederholungen: \(layer.confirmationRepeatCount)",
                            value: layerRepeatBinding(layer.id),
                            in: 1...8
                        )
                    }
                }
                .font(.caption)
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
    }

    private func currentLayer(_ id: UUID) -> ProfileLayer? {
        appState.profiles.selectedProfile.layers.first(where: { $0.id == id })
    }

    private func saveLayer(_ layer: ProfileLayer) {
        appState.profiles.updateLayerConfirmation(
            layer.id,
            effect: layer.confirmationEffect,
            red: layer.blinkRed,
            green: layer.blinkGreen,
            blue: layer.blinkBlue,
            brightness: layer.confirmationBrightness,
            durationMilliseconds: layer.confirmationDurationMilliseconds,
            repeats: layer.confirmationRepeatCount
        )
    }

    private func mutateLayer(_ id: UUID, _ mutation: (inout ProfileLayer) -> Void) {
        guard var layer = currentLayer(id) else { return }
        mutation(&layer)
        saveLayer(layer)
    }

    private func layerColorBinding(_ id: UUID) -> Binding<Color> {
        Binding(
            get: { currentLayer(id)?.confirmation.color ?? .white },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                mutateLayer(id) {
                    $0.blinkRed = UInt8(clamping: Int((rgb.redComponent * 255).rounded()))
                    $0.blinkGreen = UInt8(clamping: Int((rgb.greenComponent * 255).rounded()))
                    $0.blinkBlue = UInt8(clamping: Int((rgb.blueComponent * 255).rounded()))
                    if $0.confirmationEffect == .off { $0.confirmationEffect = .flash }
                }
            }
        )
    }

    private func layerEffectBinding(_ id: UUID) -> Binding<LEDReactionEffect> {
        Binding(
            get: { currentLayer(id)?.confirmationEffect ?? .flash },
            set: { effect in mutateLayer(id) { $0.confirmationEffect = effect } }
        )
    }

    private func layerBrightnessBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { Double(currentLayer(id)?.confirmationBrightness ?? 255) },
            set: { value in mutateLayer(id) { $0.confirmationBrightness = UInt8(clamping: Int(value.rounded())) } }
        )
    }

    private func layerDurationBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { Double(currentLayer(id)?.confirmationDurationMilliseconds ?? 180) },
            set: { value in mutateLayer(id) { $0.confirmationDurationMilliseconds = Int(value.rounded()) } }
        )
    }

    private func layerRepeatBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: { currentLayer(id)?.confirmationRepeatCount ?? 1 },
            set: { value in mutateLayer(id) { $0.confirmationRepeatCount = value } }
        )
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
                Button {
                    appState.previewReaction(event)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Reaktion testen")
                .accessibilityLabel("\(event.title) testen")
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
