import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ThreadPickerPanelModel {
    var presentation: ThreadPickerPresentation?
}

private final class ThreadPickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The only AppKit boundary for the hardware picker. SwiftUI owns all visible
/// state; this controller owns the transient non-activating panel lifecycle.
@MainActor
final class ThreadPickerPanelController {
    private let model = ThreadPickerPanelModel()
    private var panel: ThreadPickerPanel?

    func update(_ presentation: ThreadPickerPresentation?) {
        model.presentation = presentation
        guard let presentation else {
            hide()
            return
        }
        let panel = panel ?? makePanel()
        let rowCount = max(1, presentation.threads.count)
        let height = min(620, 104 + rowCount * 49)
        panel.setContentSize(NSSize(width: 430, height: height))
        center(panel, on: targetScreen())
        panel.level = .screenSaver
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.level = .normal
    }

    private func makePanel() -> ThreadPickerPanel {
        let panel = ThreadPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 350),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppLanguage.text("Thread auswählen", "Choose thread")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ThreadPickerPanelView(model: model))
        self.panel = panel
        return panel
    }

    private func center(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func targetScreen() -> NSScreen {
        if let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen { return screen }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

private struct ThreadPickerPanelView: View {
    let model: ThreadPickerPanelModel

    var body: some View {
        if let picker = model.presentation {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLanguage.text("Thread auswählen", "Choose thread"))
                            .font(.headline)
                        Text(picker.appName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        AppLanguage.text("Drehen · Loslassen zum Zuweisen", "Turn · release to assign"),
                        systemImage: "dial.medium"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if picker.threads.isEmpty {
                    ContentUnavailableView(
                        AppLanguage.text("Noch keine Threads", "No threads yet"),
                        systemImage: "rectangle.stack.badge.clock",
                        description: Text(AppLanguage.text(
                            "Die aktuelle Liste wird gerade aktualisiert.",
                            "The recent list is being refreshed."
                        ))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(picker.threads.enumerated()), id: \.element.id) { index, thread in
                            row(thread, selected: picker.selectedIndex == index, assigned: picker.assignedThreadID == thread.id)
                        }
                    }
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.18))
            }
            .padding(8)
        }
    }

    private func row(_ thread: CodexThreadDescriptor, selected: Bool, assigned: Bool) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color(for: thread.status))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(thread.displayTitle)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                    if thread.isSubagent {
                        Text("SUB")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text([thread.projectName, thread.status.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if assigned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .help(AppLanguage.text("Aktuell zugewiesen", "Currently assigned"))
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1)
            }
        }
    }

    private func color(for status: CodexAgentStatus) -> Color {
        switch status {
        case .unassigned: .secondary
        case .idle: .white
        case .running: .blue
        case .needsAttention: .orange
        case .completed: .green
        case .failed: .red
        case .interrupted: .purple
        }
    }
}
