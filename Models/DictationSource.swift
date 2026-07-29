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
        case .claude: AppLanguage.text("Claude (nur bei Chat-Fokus)", "Claude (chat focus only)")
        case .followProfile: AppLanguage.text("Mit Profil wechseln", "Follow active profile")
        }
    }

    var detail: String {
        switch self {
        case .codex: AppLanguage.text("Hält immer Codex' systemweiten Diktier-Shortcut, auch während Claude im Vordergrund ist.", "Always holds Codex's global dictation shortcut, even while Claude is in the foreground.")
        case .claude: AppLanguage.text("Hält immer Claude Codes Push-to-Talk – wirkt nur, solange dessen Chat-Eingabefeld fokussiert ist.", "Always holds Claude Code's push-to-talk shortcut; it works only while Claude's chat input is focused.")
        case .followProfile: AppLanguage.text("Codex-Profil nutzt Codex' Diktat, Claude-Profil nutzt Claudes Push-to-Talk.", "The Codex profile uses Codex dictation; the Claude profile uses Claude push-to-talk.")
        }
    }
}
