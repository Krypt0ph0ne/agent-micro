import SwiftUI

/// Manages the layers ("Belegungen") of the currently selected profile: add,
/// rename, duplicate and delete. Lighting belongs in the dedicated light
/// editor, including each layer's switch confirmation.
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
            Text("Jeder Layer trägt eine eigene Tasten-/Encoder-Belegung. Die Bestätigung beim Wechsel stellst du gesammelt unter „Licht → Reaktionen“ ein.")
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
        .padding(10)
        .background(.quaternary.opacity(isActive ? 0.45 : 0.28), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
