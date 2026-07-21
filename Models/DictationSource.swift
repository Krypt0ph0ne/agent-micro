import Foundation

/// Which app's dictation chord the built-in profiles' "Diktieren"
/// control resolves to, independent of which profile is selected.
enum DictationSource: String, CaseIterable, Codable, Identifiable {
    case codex
    case claude
    case followProfile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex (global)"
        case .claude: "Claude (nur bei Chat-Fokus)"
        case .followProfile: "Mit Profil wechseln"
        }
    }

    var detail: String {
        switch self {
        case .codex: "Hält immer Codex' systemweiten Diktier-Shortcut, auch während Claude im Vordergrund ist."
        case .claude: "Hält immer Claude Codes Push-to-Talk – wirkt nur, solange dessen Chat-Eingabefeld fokussiert ist."
        case .followProfile: "Codex-Profil nutzt Codex' Diktat, Claude-Profil nutzt Claudes Push-to-Talk."
        }
    }
}
