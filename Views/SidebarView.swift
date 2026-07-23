import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case pad, diagnostics

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pad: "Codex-Drehrad"
        case .diagnostics: "Diagnose"
        }
    }
    var icon: String {
        switch self {
        case .pad: "dial.medium"
        case .diagnostics: "stethoscope"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarSection

    var body: some View {
        List(selection: $selection) {
            Section("Agent Micro") {
                ForEach(SidebarSection.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    }
}
