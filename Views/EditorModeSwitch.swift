import SwiftUI

/// A compact, console-like mode picker for the editor surfaces.
///
/// It intentionally uses regular buttons instead of `Picker(.segmented)` so
/// the selected state can match the pad while retaining native keyboard and
/// accessibility behaviour.
struct EditorModeSwitch<Selection: Hashable>: View {
    struct Option: Identifiable {
        let selection: Selection
        let title: LocalizedStringKey
        let systemImage: String?

        var id: Selection { selection }

        init(_ selection: Selection, title: LocalizedStringKey, systemImage: String? = nil) {
            self.selection = selection
            self.title = title
            self.systemImage = systemImage
        }
    }

    enum Density {
        case primary
        case compact

        var height: CGFloat {
            switch self {
            case .primary: 34
            case .compact: 28
            }
        }

        var font: Font {
            switch self {
            case .primary: .subheadline.weight(.semibold)
            case .compact: .caption.weight(.semibold)
            }
        }

        var symbolFont: Font {
            switch self {
            case .primary: .caption.weight(.semibold)
            case .compact: .caption2.weight(.semibold)
            }
        }
    }

    @Binding var selection: Selection
    let options: [Option]
    let density: Density
    let accessibilityLabel: LocalizedStringKey

    init(
        selection: Binding<Selection>,
        options: [Option],
        density: Density = .primary,
        accessibilityLabel: LocalizedStringKey
    ) {
        _selection = selection
        self.options = options
        self.density = density
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                modeButton(option)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.075), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func modeButton(_ option: Option) -> some View {
        let isSelected = selection == option.selection

        return Button {
            guard selection != option.selection else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                selection = option.selection
            }
        } label: {
            HStack(spacing: 6) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage)
                        .font(density.symbolFont)
                        .symbolRenderingMode(.hierarchical)
                }
                Text(option.title)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .font(density.font)
            .frame(maxWidth: .infinity, minHeight: density.height)
            .contentShape(Capsule())
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .shadow(color: Color.accentColor.opacity(0.16), radius: 5, y: 1)
                }
            }
            .overlay {
                if isSelected {
                    Capsule()
                        .strokeBorder(Color.accentColor.opacity(0.52), lineWidth: 0.8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityValue(isSelected
            ? AppLanguage.text("Ausgewählt", "Selected")
            : AppLanguage.text("Nicht ausgewählt", "Not selected"))
        .accessibilityHint("Wechselt zum ausgewählten Bereich")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A matching compact on/off control for a mode rail.
struct EditorToggleRail: View {
    @Binding var isOn: Bool
    let title: LocalizedStringKey
    let systemImage: String

    init(
        isOn: Binding<Bool>,
        title: LocalizedStringKey,
        systemImage: String
    ) {
        _isOn = isOn
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                toggleIndicator
            }
            .foregroundStyle(isOn ? .primary : .secondary)
            .padding(.horizontal, 9)
            .frame(minHeight: 34)
            .contentShape(Capsule())
            .background(Color.primary.opacity(0.075), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.52) : Color.primary.opacity(0.12), lineWidth: isOn ? 0.8 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn
            ? AppLanguage.text("Aktiviert", "On")
            : AppLanguage.text("Deaktiviert", "Off"))
        .accessibilityHint("Schaltet Grundlicht ein oder aus")
    }

    private var toggleIndicator: some View {
        Capsule()
            .fill(isOn ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.15))
            .frame(width: 27, height: 16)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.primary.opacity(isOn ? 0.9 : 0.42))
                    .frame(width: 12, height: 12)
                    .padding(2)
            }
    }
}
