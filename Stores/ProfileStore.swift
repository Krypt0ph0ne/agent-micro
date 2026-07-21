import AppKit
import Foundation
import Observation
import SwiftUI

struct ProfileFileDocument: Codable, Hashable {
    static let schemaVersion = 1
    var schemaVersion: Int
    var exportedAt: Date
    var profiles: [MacropadProfile]
}

enum ProfileFileCodec {
    static func encode(_ profiles: [MacropadProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ProfileFileDocument(schemaVersion: ProfileFileDocument.schemaVersion, exportedAt: .now, profiles: profiles))
    }

    static func decode(_ data: Data) throws -> [MacropadProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ProfileFileDocument.self, from: data)
        guard document.schemaVersion == ProfileFileDocument.schemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document.profiles
    }
}

@MainActor
@Observable
final class ProfileStore {
    private static let selectedProfileDefaultsKey = "CodexPad.selectedProfileID"
    private static let keyboardLayoutDefaultsKey = "CodexPad.keyboardLayout"
    private static let dictationSourceDefaultsKey = "CodexPad.dictationSource"
    private let persistenceURL: URL
    private let catalog: CodexActionCatalog
    private let claudeCatalog: CodexActionCatalog

    private(set) var profiles: [MacropadProfile]
    var keyboardLayout: KeyboardLayout {
        didSet {
            guard keyboardLayout != oldValue else { return }
            UserDefaults.standard.set(keyboardLayout.rawValue, forKey: Self.keyboardLayoutDefaultsKey)
            hasUnsyncedChanges = true
        }
    }
    /// Which app's dictation chord the "Diktieren"-tagged control resolves
    /// to across every built-in profile, independent of which one is active.
    var dictationSource: DictationSource {
        didSet {
            guard dictationSource != oldValue else { return }
            UserDefaults.standard.set(dictationSource.rawValue, forKey: Self.dictationSourceDefaultsKey)
            applyDictationSource(dictationSource)
        }
    }
    var selectedProfileID: UUID {
        didSet {
            UserDefaults.standard.set(selectedProfileID.uuidString, forKey: Self.selectedProfileDefaultsKey)
        }
    }
    /// Changes are persisted locally immediately; this means not yet synchronized to hardware.
    private(set) var hasUnsyncedChanges = false
    private(set) var lastPersistenceError: String?

    init(catalog: CodexActionCatalog, claudeCatalog: CodexActionCatalog, persistenceURL: URL? = nil) {
        self.catalog = catalog
        self.claudeCatalog = claudeCatalog
        self.keyboardLayout = UserDefaults.standard.string(forKey: Self.keyboardLayoutDefaultsKey)
            .flatMap(KeyboardLayout.init(rawValue:)) ?? .automatic
        let dictationSource = UserDefaults.standard.string(forKey: Self.dictationSourceDefaultsKey)
            .flatMap(DictationSource.init(rawValue:)) ?? .codex
        self.dictationSource = dictationSource
        let baseDirectory = persistenceURL?.deletingLastPathComponent() ?? Self.applicationSupportDirectory()
        self.persistenceURL = persistenceURL ?? baseDirectory.appendingPathComponent("Profiles.json")
        let loadedRaw = Self.load(from: self.persistenceURL)
        let loaded = loadedRaw.map { Self.pruneToKeepOnly(Self.keptBuiltInNames, in: $0) }
        let didPrune = loadedRaw.map { $0 != loaded } ?? false
        if didPrune, let loadedRaw {
            Self.backupBeforePruning(loadedRaw, persistenceURL: self.persistenceURL)
        }
        let seed = loaded ?? [ProfileFactory.codex(catalog: catalog), ProfileFactory.claude(catalog: claudeCatalog)]
        let builtIns = Self.ensureBuiltInProfiles(in: seed, catalog: catalog, claudeCatalog: claudeCatalog)
        let taggedApps = Self.migrateAutomationAppTags(in: builtIns)
        let refreshedClaude = Self.migrateStaleClaudeCatalogBindings(in: taggedApps, claudeCatalog: claudeCatalog)
        let encoderMigrated = Self.migrateLegacyCodexReasoningBindings(in: refreshedClaude)
        let dictationTagged = Self.migrateLegacyDictationBindings(in: encoderMigrated, catalog: catalog)
        let initial = Self.applyDictationSource(dictationSource, to: dictationTagged, catalog: catalog, claudeCatalog: claudeCatalog)
        self.profiles = initial
        let codexID = initial.first(where: { $0.name == "Codex" })?.id
        let persistedID = UserDefaults.standard.string(forKey: Self.selectedProfileDefaultsKey).flatMap(UUID.init(uuidString:))
        if let persistedID, initial.contains(where: { $0.id == persistedID }) {
            self.selectedProfileID = persistedID
        } else {
            self.selectedProfileID = codexID ?? initial.first?.id ?? UUID()
        }
        if loadedRaw == nil || initial != seed || didPrune { persist() }
    }

    var selectedProfile: MacropadProfile {
        get { profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0] }
        set { replace(newValue) }
    }

    func actionBinding(for control: HardwareControl) -> Binding<KeyboardAction> {
        Binding(
            get: { self.selectedProfile.action(for: control) },
            set: { self.updateAction($0, for: control) }
        )
    }

    func updateAction(_ action: KeyboardAction, for control: HardwareControl) {
        var profile = selectedProfile
        profile.setAction(action, for: control)
        replace(profile)
    }

    func ledBinding(for control: HardwareControl) -> Binding<KeyLEDConfiguration> {
        Binding(
            get: { self.selectedProfile.led.setting(for: control) },
            set: { self.updateLED($0) }
        )
    }

    func updateLED(_ setting: KeyLEDConfiguration) {
        updateLEDs([setting])
    }

    func updateLEDs(_ settings: [KeyLEDConfiguration]) {
        var profile = selectedProfile
        for setting in settings {
            profile.led.setSetting(setting)
        }
        profile.updatedAt = .now
        replace(profile)
    }

    func updateReaction(_ reaction: LEDReactionConfiguration) {
        var profile = selectedProfile
        profile.setReaction(reaction)
        replace(profile)
    }

    func updateIdleLighting(_ idleLighting: IdleLEDConfiguration) {
        var profile = selectedProfile
        profile.idleLighting = idleLighting
        profile.updatedAt = .now
        replace(profile)
    }

    /// Resolves `id` against an arbitrary catalog (Codex's or Claude's) and
    /// writes the resulting shortcut to `control`.
    func assignAction(id: String, from catalog: CodexActionCatalog, to control: HardwareControl) {
        guard let action = catalog.keyboardAction(id: id) else { return }
        updateAction(action, for: control)
    }

    func assignCodexAction(id: String, to control: HardwareControl) {
        assignAction(id: id, from: catalog, to: control)
    }

    /// Binds a configurable action that has no default keybinding by giving
    /// it a dedicated trigger chord the pad sends straight to the target app.
    /// `slot` chooses whether the trigger becomes the tap or the hold action,
    /// so the wizard offers the same configurable actions in both places.
    func assignConfigurableCodexAction(_ definition: CodexActionDefinition, trigger: String, to control: HardwareControl, slot: ActionSlot = .tap, kind: ActionKind = .codexShortcut) {
        let action = KeyboardAction(
            kind: kind,
            label: definition.title,
            icon: definition.icon,
            deviceMacro: trigger,
            codexActionID: definition.id
        )
        switch slot {
        case .tap: updateAction(action, for: control)
        case .hold: setHoldAction(action, thresholdMilliseconds: selectedProfile.binding(for: control).resolvedHoldThresholdMilliseconds, for: control)
        }
    }

    func setHoldAction(_ action: KeyboardAction?, thresholdMilliseconds: Int? = nil, for control: HardwareControl) {
        var profile = selectedProfile
        profile.setHoldAction(action, thresholdMilliseconds: thresholdMilliseconds, for: control)
        replace(profile)
    }

    func newProfile() {
        let profile = ProfileFactory.safe()
        var renamed = profile
        renamed.name = uniqueName("Neues Profil")
        profiles.append(renamed)
        selectedProfileID = renamed.id
        commitChange()
    }

    func duplicateSelected() {
        var duplicate = selectedProfile
        duplicate.id = UUID()
        duplicate.name = uniqueName("\(selectedProfile.name) Kopie")
        duplicate.createdAt = .now
        duplicate.updatedAt = .now
        duplicate.isBuiltIn = false
        profiles.append(duplicate)
        selectedProfileID = duplicate.id
        commitChange()
    }

    func renameSelected(to name: String) {
        var profile = selectedProfile
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unbenanntes Profil" : name
        replace(profile)
    }

    func deleteSelected() {
        guard profiles.count > 1 else { return }
        profiles.removeAll(where: { $0.id == selectedProfileID })
        selectedProfileID = profiles[0].id
        commitChange()
    }

    func restoreSafeDefaults() {
        var safe = ProfileFactory.safe()
        safe.name = uniqueName(safe.name)
        profiles.append(safe)
        selectedProfileID = safe.id
        commitChange()
    }

    func addFactoryLikeCProfile() {
        var profile = ProfileFactory.factoryLikeC()
        profile.name = uniqueName(profile.name)
        profiles.append(profile)
        selectedProfileID = profile.id
        commitChange()
    }

    func markSynchronized() {
        hasUnsyncedChanges = false
    }

    func exportSelectedProfile() throws -> URL {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(selectedProfile.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        try ProfileFileCodec.encode([selectedProfile]).write(to: url, options: .atomic)
        return url
    }

    func importProfile() throws {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        let decoded = try ProfileFileCodec.decode(Data(contentsOf: url))
        guard let first = decoded.first else { throw CocoaError(.fileReadCorruptFile) }
        var imported = first
        imported.id = UUID()
        imported.name = uniqueName("\(first.name) Import")
        imported.isBuiltIn = false
        imported.updatedAt = .now
        profiles.append(imported)
        selectedProfileID = imported.id
        commitChange()
    }

    private func replace(_ profile: MacropadProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        commitChange()
    }

    private func commitChange() {
        hasUnsyncedChanges = true
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProfileFileCodec.encode(profiles).write(to: persistenceURL, options: .atomic)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    private func uniqueName(_ requested: String) -> String {
        guard profiles.contains(where: { $0.name == requested }) else { return requested }
        var number = 2
        while profiles.contains(where: { $0.name == "\(requested) \(number)" }) { number += 1 }
        return "\(requested) \(number)"
    }

    private static func applicationSupportDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexPad", isDirectory: true)
    }

    private static func load(from url: URL) -> [MacropadProfile]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ProfileFileCodec.decode(data)
    }

    /// Felix wants the profile list trimmed to exactly these two — everything
    /// else (macOS, Sichere F13–21, Codex · Reasoning triggers, any custom
    /// profile) is dropped on load.
    static let keptBuiltInNames: Set<String> = ["Codex", "Claude"]

    /// Drops every profile whose name isn't in `names`. Backed up by the
    /// caller first since this is a real, one-way deletion of whatever the
    /// user had — including custom profiles. Falls back to the untouched
    /// list if filtering would leave nothing at all.
    private static func pruneToKeepOnly(_ names: Set<String>, in profiles: [MacropadProfile]) -> [MacropadProfile] {
        let kept = profiles.filter { names.contains($0.name) }
        return kept.isEmpty ? profiles : kept
    }

    /// Writes the untouched, pre-prune profile list to a timestamped sibling
    /// file so trimming down to Codex/Claude is recoverable if unwanted.
    private static func backupBeforePruning(_ profiles: [MacropadProfile], persistenceURL: URL) {
        guard let data = try? ProfileFileCodec.encode(profiles) else { return }
        let backupURL = persistenceURL.deletingLastPathComponent()
            .appendingPathComponent("Profiles.before-prune-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: backupURL, options: .atomic)
    }

    private static func ensureBuiltInProfiles(in profiles: [MacropadProfile], catalog: CodexActionCatalog, claudeCatalog: CodexActionCatalog) -> [MacropadProfile] {
        var result = profiles
        if !result.contains(where: { $0.name == "Codex" }) {
            result.append(ProfileFactory.codex(catalog: catalog))
        }
        if !result.contains(where: { $0.name == "Claude" }) {
            result.append(ProfileFactory.claude(catalog: claudeCatalog))
        }
        return result
    }

    /// The Claude action catalog's ids changed after the initial ship (the
    /// CLI-keybinding guesses like "interrupt"/"toggle-todos"/"model-picker-
    /// toggle" were replaced by Felix's confirmed Claude Desktop shortcuts).
    /// Detects a built-in "Claude" profile still carrying any of those
    /// retired ids and resets its bindings to the current defaults; a
    /// profile the user has since rebound entirely away from every retired id
    /// is left alone.
    private static func migrateStaleClaudeCatalogBindings(in profiles: [MacropadProfile], claudeCatalog: CodexActionCatalog) -> [MacropadProfile] {
        let retiredIDs: Set<String> = [
            "interrupt", "toggle-todos", "toggle-transcript", "kill-agents", "background-task",
            "history-search", "open-artifact", "model-picker-toggle", "thinking-toggle",
            "fast-mode-toggle", "effort-decrease", "effort-increase", "model-cycle"
        ]
        return profiles.map { profile in
            guard profile.isBuiltIn, profile.name == "Claude" else { return profile }
            let hasRetiredBinding = profile.controls.contains { binding in
                guard let id = binding.action.codexActionID else { return false }
                return retiredIDs.contains(id)
            }
            guard hasRetiredBinding else { return profile }
            var refreshed = ProfileFactory.claude(catalog: claudeCatalog)
            refreshed.id = profile.id
            refreshed.createdAt = profile.createdAt
            return refreshed
        }
    }

    /// Backfills `automationApp` for built-in Codex profiles saved before that
    /// field existed. Never touches a renamed or user-duplicated profile.
    private static func migrateAutomationAppTags(in profiles: [MacropadProfile]) -> [MacropadProfile] {
        profiles.map { profile in
            guard profile.isBuiltIn, profile.automationApp == nil,
                  profile.name == "Codex" || profile.name == "Codex · Reasoning triggers" || profile.name == "Claude" else {
                return profile
            }
            var migrated = profile
            migrated.automationApp = profile.name == "Claude" ? .claude : .codex
            return migrated
        }
    }

    /// Only migrates the exact historic built-in defaults, never a custom edit.
    private static func migrateLegacyCodexReasoningBindings(in profiles: [MacropadProfile]) -> [MacropadProfile] {
        profiles.map { profile in
            guard profile.isBuiltIn,
                  profile.name == "Codex" || profile.name == "Codex · Reasoning triggers" else {
                return profile
            }
            let left = profile.action(for: .encoderLeft)
            let press = profile.action(for: .encoderPress)
            let right = profile.action(for: .encoderRight)
            let isNavigationDefault = left.codexActionID == "navigate-back"
                && press.codexActionID == "command-menu"
                && right.codexActionID == "navigate-forward"
            let isLegacyReasoningDefault = left.codexActionID == "reasoning-decrease"
                && left.deviceMacro == "f19"
                && press.codexActionID == "open-model-picker"
                && press.deviceMacro == "f20"
                && right.codexActionID == "reasoning-increase"
                && right.deviceMacro == "f21"
            let isDirectReasoningDefault = left.codexActionID == "reasoning-decrease"
                && left.deviceMacro == "f19"
                && press.codexActionID == "open-model-picker"
                && press.deviceMacro == "ctrl-shift-m"
                && right.codexActionID == "reasoning-increase"
                && right.deviceMacro == "f20"
            let isPowerDialDefault = left.deviceMacro == "f22"
                && press.deviceMacro == "ctrl-shift-m"
                && right.deviceMacro == "f24"
            let isPrivateTriggerDefault = left.deviceMacro == "f22"
                && press.deviceMacro == "f23"
                && right.deviceMacro == "f24"
            let isCurrentDirectDefault = left.codexActionID == "encoder-effort-decrease"
                && left.deviceMacro == "f18"
                && press.codexActionID == "encoder-model-modifier"
                && press.deviceMacro == "f23"
                && right.codexActionID == "encoder-effort-increase"
                && right.deviceMacro == "f19"
            guard isNavigationDefault || isLegacyReasoningDefault || isDirectReasoningDefault || isPowerDialDefault || isPrivateTriggerDefault || isCurrentDirectDefault else { return profile }
            var migrated = profile
            migrated.setAction(ProfileFactory.reasoningTriggerAction(for: .encoderLeft), for: .encoderLeft)
            migrated.setAction(ProfileFactory.reasoningTriggerAction(for: .encoderPress), for: .encoderPress)
            migrated.setAction(ProfileFactory.reasoningTriggerAction(for: .encoderRight), for: .encoderRight)
            return migrated
        }
    }

    /// Moves only the former built-in composer shortcut to Codex's dedicated
    /// global dictation toggle. Custom actions are never rewritten.
    private static func migrateLegacyDictationBindings(in profiles: [MacropadProfile], catalog: CodexActionCatalog) -> [MacropadProfile] {
        guard let globalDictation = catalog.keyboardAction(id: "dictation") else { return profiles }
        return profiles.map { profile in
            guard profile.isBuiltIn else { return profile }
            var migrated = profile
            var changed = false
            for control in HardwareControl.buttons {
                let action = migrated.action(for: control)
                guard action.codexActionID == "dictation",
                      ["ctrl-shift-d", "f17", "cmd-f17"].contains(action.deviceMacro ?? "") else { continue }
                migrated.setAction(globalDictation, for: control)
                changed = true
            }
            return changed ? migrated : profile
        }
    }

    /// Rewrites the dictation binding on every built-in profile to whichever
    /// app's chord `source` resolves to. Detects the binding purely by its
    /// catalog id, so a control the user repurposed for something else is
    /// never touched — same rule as `migrateLegacyDictationBindings`.
    private static func applyDictationSource(
        _ source: DictationSource,
        to profiles: [MacropadProfile],
        catalog: CodexActionCatalog,
        claudeCatalog: CodexActionCatalog
    ) -> [MacropadProfile] {
        profiles.map { profile in
            guard profile.isBuiltIn else { return profile }
            var migrated = profile
            var changed = false
            for control in HardwareControl.buttons {
                guard migrated.action(for: control).codexActionID == "dictation" else { continue }
                let resolvedCatalog: CodexActionCatalog
                switch source {
                case .codex: resolvedCatalog = catalog
                case .claude: resolvedCatalog = claudeCatalog
                case .followProfile: resolvedCatalog = profile.automationApp == .claude ? claudeCatalog : catalog
                }
                guard let resolved = resolvedCatalog.keyboardAction(id: "dictation") else { continue }
                migrated.setAction(resolved, for: control)
                changed = true
            }
            return changed ? migrated : profile
        }
    }

    /// Applies `applyDictationSource` to the live profile list and persists
    /// the result, for when the user changes the setting after launch.
    private func applyDictationSource(_ source: DictationSource) {
        profiles = Self.applyDictationSource(source, to: profiles, catalog: catalog, claudeCatalog: claudeCatalog)
        commitChange()
    }
}
