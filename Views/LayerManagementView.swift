import AppKit
import SwiftUI

/// Manages the layers ("Belegungen") of the currently selected profile: add,
/// rename, duplicate, delete, and configure each layer's switch-confirmation
/// blink (color + how many times it flashes). Lighting stays shared across a
/// profile's layers — only the key/encoder assignments differ per layer.
struct LayerManagementView: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var renamingLayerID: UUID?
    @State private var renameText = ""

    private var profile: MacropadProfile { appState.profiles.selectedProfile }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Layer · \(profile.name)")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Jeder Layer trägt eine eigene Tasten-/Encoder-Belegung für dieses Profil. Licht und Grundbeleuchtung bleiben für alle Layer gleich, nur die Zuweisungen unterscheiden sich. Weise die Aktion „Layer wechseln“ einer Taste zu, um zwischen ihnen zu wechseln.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(profile.layers) { layer in
                        layerRow(layer)
                    }
                }
            }
            .frame(maxHeight: 340)

            Button("Neuen Layer hinzufügen", systemImage: "plus") {
                appState.profiles.addLayer()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private func layerRow(_ layer: ProfileLayer) -> some View {
        let isActive = layer.id == profile.activeLayerID
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    appState.profiles.selectLayer(layer.id)
                } label: {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Als aktiven Layer auswählen")

                if renamingLayerID == layer.id {
                    TextField("Name", text: $renameText, onCommit: {
                        appState.profiles.renameLayer(layer.id, to: renameText)
                        renamingLayerID = nil
                    })
                    .textFieldStyle(.roundedBorder)
                } else {
                    Text(layer.name)
                        .font(.body.weight(.medium))
                    Button {
                        renameText = layer.name
                        renamingLayerID = layer.id
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Umbenennen")
                }

                Spacer(minLength: 4)

                Button {
                    appState.profiles.duplicateLayer(layer.id)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .help("Layer duplizieren")

                Button(role: .destructive) {
                    appState.profiles.deleteLayer(layer.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(profile.layers.count <= 1)
                .help("Layer löschen")
            }

            HStack(spacing: 10) {
                Text("Blink-Bestätigung")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ColorPicker("Farbe", selection: blinkColorBinding(layer), supportsOpacity: false)
                    .labelsHidden()
                Stepper(
                    "\(layer.blinkCount)× blinken",
                    value: blinkCountBinding(layer),
                    in: 1...6
                )
                .font(.caption)
                .fixedSize()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(isActive ? 0.45 : 0.28), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func blinkColorBinding(_ layer: ProfileLayer) -> Binding<Color> {
        Binding(
            get: {
                Color(
                    red: Double(layer.blinkRed) / 255,
                    green: Double(layer.blinkGreen) / 255,
                    blue: Double(layer.blinkBlue) / 255
                )
            },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
                appState.profiles.updateLayerBlink(
                    layer.id,
                    red: UInt8(clamping: Int((rgb.redComponent * 255).rounded())),
                    green: UInt8(clamping: Int((rgb.greenComponent * 255).rounded())),
                    blue: UInt8(clamping: Int((rgb.blueComponent * 255).rounded())),
                    count: layer.blinkCount
                )
            }
        )
    }

    private func blinkCountBinding(_ layer: ProfileLayer) -> Binding<Int> {
        Binding(
            get: { layer.blinkCount },
            set: { newValue in
                appState.profiles.updateLayerBlink(
                    layer.id, red: layer.blinkRed, green: layer.blinkGreen, blue: layer.blinkBlue, count: newValue
                )
            }
        )
    }
}
