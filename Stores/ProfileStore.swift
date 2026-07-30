import AppKit
import Foundation
import Observation
import OSLog
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

    /// Falls back from `decode` when the whole-document decode throws (e.g. a
    /// model change broke one profile's shape). Re-decodes each profile in the
    /// `profiles` array individually so a single corrupt entry doesn't erase
    /// every other saved profile — only skips the ones that fail.
    static func decodeLeniently(_ data: Data) -> (profiles: [MacropadProfile], droppedCount: Int)? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawProfiles = root["profiles"] as? [[String: Any]]
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var recovered: [MacropadProfile] = []
        var dropped = 0
        for rawProfile in rawProfiles {
            guard
                let profileData = try? JSONSerialization.data(withJSONObject: rawProfile),
                let profile = try? decoder.decode(MacropadProfile.self, from: profileData)
            else {
                dropped += 1
                continue
            }
            recovered.append(profile)
        }
        guard !recovered.isEmpty else { return nil }
        return (recovered, dropped)
    }
}

@MainActor
@Observable
final class ProfileStore {
    private static let selectedProfileDefaultsKey = "AgentMicro.selectedProfileID"
    private static let keyboardLayoutDefaultsKey = "AgentMicro.keyboardLayout"
    private static let dictationSourceDefaultsKey = "AgentMicro.dictationSource"
    private static let enabledAutomationAppsDefaultsKey = "AgentMicro.enabledAutomationApps"
    private let persistenceURL: URL
    private let catalog: CodexActionCatalog
    private let claudeCatalog: CodexActionCatalog

    private(set) var profiles: [MacropadProfile]
    var keyboardLayout: KeyboardLayout {
        didSet {
            guard keyboardLayout != oldValue else { return }
            UserDefaults.standard.set(keyboardLayout.rawValue, forKey: Self.keyboardLayoutDefaultsKey)
            hasUnsyncedChanges = true
            onChange?()
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
            guard selectedProfileID != oldValue else { return }
            UserDefaults.standard.set(selectedProfileID.uuidString, forKey: Self.selectedProfileDefaultsKey)
            onSelectedProfileChange?()
        }
    }
    /// Which built-in profiles (Codex/Claude) are currently offered for
    /// selection — set during onboarding's agent-choice step. A profile
    /// outside this set keeps its saved bindings untouched, it's just hidden
    /// from every picker/switcher until re-enabled. Defaults to both, so an
    /// install that never runs the guided onboarding behaves exactly as
    /// before this existed.
    var enabledAutomationApps: Set<AutomationApp> {
        didSet {
            guard enabledAutomationApps != oldValue else { return }
            UserDefaults.standard.set(
                enabledAutomationApps.map(\.rawValue).sorted().joined(separator: ","),
                forKey: Self.enabledAutomationAppsDefaultsKey
            )
            if !visibleProfiles.contains(where: { $0.id == selectedProfileID }), let firstVisible = visibleProfiles.first {
                selectedProfileID = firstVisible.id
            }
            onChange?()
        }
    }
    /// Every built-in profile whose app is currently enabled, plus any
    /// app-agnostic profile — what pickers and the hold-to-switch gesture
    /// should offer. Use instead of `profiles` for anything user-facing.
    var visibleProfiles: [MacropadProfile] {
        profiles.filter { $0.automationApp.map(enabledAutomationApps.contains) ?? true }
    }
    /// Changes are persisted locally immediately; this means not yet synchronized to hardware.
    private(set) var hasUnsyncedChanges = false
    private(set) var lastPersistenceError: String?
    /// Set when `Profiles.json` couldn't be decoded as-is and had to be
    /// recovered profile-by-profile (or, in the worst case, discarded). Nil
    /// on a clean load.
    private(set) var lastLoadWarning: String?
    private static let logger = Logger(subsystem: "io.github.krypt0ph0ne.agentmicro", category: "profile-store")
    /// Fired whenever a change is committed (including the `keyboardLayout`
    /// `didSet` below), so `AppState` can debounce an automatic hardware
    /// sync without `ProfileStore` needing to know `DeviceService` exists.
    var onChange: (() -> Void)?
    var onSelectedProfileChange: (() -> Void)?

    init(catalog: CodexActionCatalog, claudeCatalog: CodexActionCatalog, persistenceURL: URL? = nil) {
        self.catalog = catalog
        self.claudeCatalog = claudeCatalog
        self.keyboardLayout = UserDefaults.standard.string(forKey: Self.keyboardLayoutDefaultsKey)
            .flatMap(KeyboardLayout.init(rawValue:)) ?? .automatic
        let dictationSource = UserDefaults.standard.string(forKey: Self.dictationSourceDefaultsKey)
            .flatMap(DictationSource.init(rawValue:)) ?? .codex
        self.dictationSource = dictationSource
        if let storedApps = UserDefaults.standard.string(forKey: Self.enabledAutomationAppsDefaultsKey) {
            let parsed = Set(storedApps.split(separator: ",").compactMap { AutomationApp(rawValue: String($0)) })
            self.enabledAutomationApps = parsed.isEmpty ? Set(AutomationApp.allCases) : parsed
        } else {
            self.enabledAutomationApps = Set(AutomationApp.allCases)
        }
        let baseDirectory = persistenceURL?.deletingLastPathComponent() ?? Self.applicationSupportDirectory()
        self.persistenceURL = persistenceURL ?? baseDirectory.appendingPathComponent("Profiles.json")
        var loadWarning: String?
        let loadedRaw = Self.load(from: self.persistenceURL, warning: &loadWarning)
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
        let petMigrated = Self.migrateLegacyPetActions(in: dictationTagged)
        let idleColorMigrated = Self.migrateLegacyGreenIdleReaction(in: petMigrated)
        let initial = Self.applyDictationSource(dictationSource, to: idleColorMigrated, catalog: catalog, claudeCatalog: claudeCatalog)
        self.profiles = initial
        // Backfill the action-to-trigger directory from every saved layer so
        // existing Codex setup survives moving an action to another control.
        CodexTriggerRegistry.importExistingAssignments(from: initial)
        let codexID = initial.first(where: { $0.name == "Codex" })?.id
        let persistedID = UserDefaults.standard.string(forKey: Self.selectedProfileDefaultsKey).flatMap(UUID.init(uuidString:))
        if let persistedID, initial.contains(where: { $0.id == persistedID }) {
            self.selectedProfileID = persistedID
        } else {
            self.selectedProfileID = codexID ?? initial.first?.id ?? UUID()
        }
        self.lastLoadWarning = loadWarning
        if loadedRaw == nil || initial != seed || didPrune { persist() }
    }

    var selectedProfile: MacropadProfile {
        get { profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0] }
        set { replace(newValue) }
    }

    /// Flips between the Codex and Claude built-in profiles — the only two
    /// that exist by design (see `keptBuiltInNames`) — for a `.profileSwitch`
    /// action. A no-op if either is missing (shouldn't happen).
    func switchToOtherBuiltInProfile() {
        let targetApp: AutomationApp = selectedProfile.automationApp == .claude ? .codex : .claude
        guard let target = visibleProfiles.first(where: { $0.automationApp == targetApp }) else { return }
        selectedProfileID = target.id
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
        let app: AutomationApp = kind == .claudeShortcut ? .claude : .codex
        // Keep both the reservation and the action's established trigger,
        // including when the action moves to another control or layer.
        CodexTriggerRegistry.remember(trigger, for: definition.id, app: app)
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

    /// Adds a new layer to the selected profile, starting as a copy of the
    /// currently active layer's bindings so the user edits from a working
    /// baseline instead of a blank one, and selects it.
    func addLayer() {
        var profile = selectedProfile
        let newLayer = ProfileLayer(
            name: uniqueLayerName("Layer \(profile.layers.count + 1)", in: profile),
            controls: profile.controls
        )
        profile.layers.append(newLayer)
        profile.activeLayerID = newLayer.id
        profile.updatedAt = .now
        replace(profile)
    }

    func duplicateLayer(_ layerID: UUID) {
        var profile = selectedProfile
        guard let source = profile.layers.first(where: { $0.id == layerID }) else { return }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueLayerName("\(source.name) Kopie", in: profile)
        profile.layers.append(copy)
        profile.activeLayerID = copy.id
        profile.updatedAt = .now
        replace(profile)
    }

    func renameLayer(_ layerID: UUID, to name: String) {
        var profile = selectedProfile
        guard let index = profile.layers.firstIndex(where: { $0.id == layerID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profile.layers[index].name = trimmed
        profile.updatedAt = .now
        replace(profile)
    }

    /// Removes a layer, keeping at least one. If the removed layer was
    /// active, falls back to the first remaining one.
    func deleteLayer(_ layerID: UUID) {
        var profile = selectedProfile
        guard profile.layers.count > 1, let index = profile.layers.firstIndex(where: { $0.id == layerID }) else { return }
        profile.layers.remove(at: index)
        if profile.activeLayerID == layerID {
            profile.activeLayerID = profile.layers[0].id
        }
        profile.updatedAt = .now
        replace(profile)
    }

    func selectLayer(_ layerID: UUID) {
        var profile = selectedProfile
        guard profile.layers.contains(where: { $0.id == layerID }) else { return }
        profile.activeLayerID = layerID
        replace(profile)
    }

    /// Advances the selected profile's active layer to the next one,
    /// wrapping back to the first. A no-op with a single layer.
    func advanceToNextLayer() {
        var profile = selectedProfile
        guard profile.layers.count > 1, let index = profile.layers.firstIndex(where: { $0.id == profile.activeLayerID }) else { return }
        let nextIndex = (index + 1) % profile.layers.count
        profile.activeLayerID = profile.layers[nextIndex].id
        replace(profile)
    }

    /// Selects the layer at 1-indexed `position` (one tap = layer 1, two taps
    /// = layer 2, ...), clamped to the profile's actual layer count.
    func selectLayer(atPosition position: Int) {
        var profile = selectedProfile
        guard !profile.layers.isEmpty else { return }
        let index = min(max(position - 1, 0), profile.layers.count - 1)
        profile.activeLayerID = profile.layers[index].id
        replace(profile)
    }

    func updateLayerBlink(_ layerID: UUID, red: UInt8, green: UInt8, blue: UInt8, count: Int) {
        var profile = selectedProfile
        guard let index = profile.layers.firstIndex(where: { $0.id == layerID }) else { return }
        profile.layers[index].blinkRed = red
        profile.layers[index].blinkGreen = green
        profile.layers[index].blinkBlue = blue
        profile.layers[index].blinkCount = max(1, count)
        profile.layers[index].confirmationRepeatCount = max(1, count)
        profile.updatedAt = .now
        replace(profile)
    }

    func updateLayerConfirmation(
        _ layerID: UUID,
        effect: LEDReactionEffect,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        durationMilliseconds: Int,
        repeats: Int
    ) {
        var profile = selectedProfile
        guard let index = profile.layers.firstIndex(where: { $0.id == layerID }) else { return }
        profile.layers[index].confirmationEffect = effect
        profile.layers[index].blinkRed = red
        profile.layers[index].blinkGreen = green
        profile.layers[index].blinkBlue = blue
        profile.layers[index].confirmationBrightness = brightness
        profile.layers[index].confirmationDurationMilliseconds = max(80, durationMilliseconds)
        profile.layers[index].confirmationRepeatCount = max(1, repeats)
        // Keep old readers and exported profiles coherent too.
        profile.layers[index].blinkCount = max(1, repeats)
        profile.updatedAt = .now
        replace(profile)
    }

    private func uniqueLayerName(_ requested: String, in profile: MacropadProfile) -> String {
        guard profile.layers.contains(where: { $0.name == requested }) else { return requested }
        var number = 2
        while profile.layers.contains(where: { $0.name == "\(requested) \(number)" }) { number += 1 }
        return "\(requested) \(number)"
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

    func markSynchronized(profileID: UUID? = nil, layerID: UUID? = nil) {
        if let profileID, profileID != selectedProfileID { return }
        if let layerID, selectedProfile.activeLayerID != layerID { return }
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
        onChange?()
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
        return root.appendingPathComponent("Agent Micro", isDirectory: true)
    }

    /// Loads `Profiles.json`. A clean decode is the fast path; if the whole
    /// document fails (any single profile's shape no longer matches, e.g.
    /// after a model change), falls back to recovering profiles one at a time
    /// instead of discarding the user's entire saved configuration. The raw
    /// file is always backed up first so a bad recovery is never one-way.
    private static func load(from url: URL, warning: inout String?) -> [MacropadProfile]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let profiles = try? ProfileFileCodec.decode(data) { return profiles }

        backupRawFile(data, persistenceURL: url, reason: "corrupt")
        guard let recovered = ProfileFileCodec.decodeLeniently(data) else {
            warning = "Profiles.json war beschädigt und konnte nicht gelesen werden. Eine Sicherung liegt neben der Datei, die Belegung wurde auf Werkseinstellungen zurückgesetzt."
            logger.error("Profiles.json fully unreadable, resetting to defaults")
            return nil
        }
        if recovered.droppedCount > 0 {
            warning = "\(recovered.droppedCount) Profil(e) in Profiles.json waren beschädigt und wurden übersprungen. Die übrigen \(recovered.profiles.count) wurden wiederhergestellt; eine Sicherung liegt neben der Datei."
            logger.error("Recovered \(recovered.profiles.count) profile(s), dropped \(recovered.droppedCount)")
        }
        return recovered.profiles
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

    /// Writes the exact bytes of a `Profiles.json` that failed to decode
    /// cleanly to a timestamped sibling file, before any lenient recovery (or
    /// factory-default fallback) touches it — so the raw data is never lost.
    private static func backupRawFile(_ data: Data, persistenceURL: URL, reason: String) {
        let backupURL = persistenceURL.deletingLastPathComponent()
            .appendingPathComponent("Profiles.\(reason)-\(Int(Date().timeIntervalSince1970)).json")
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

    /// Codex exposes one `openPetOverlay` command. Early Agent Micro builds
    /// incorrectly modeled it as separate wake/tuck actions. Preserve every
    /// user's chosen trigger while collapsing either historic id onto the
    /// real toggle action.
    private static func migrateLegacyPetActions(in profiles: [MacropadProfile]) -> [MacropadProfile] {
        let retiredIDs: Set<String> = ["wake-pet", "tuck-away-pet"]
        func migratedAction(_ action: KeyboardAction?) -> KeyboardAction? {
            guard let action, let id = action.codexActionID, retiredIDs.contains(id) else { return action }
            return KeyboardAction(
                kind: action.kind,
                label: "Pet anzeigen",
                icon: "pawprint",
                deviceMacro: action.deviceMacro,
                codexActionID: "toggle-pet"
            )
        }

        return profiles.map { profile in
            var migrated = profile
            var changed = false
            for layerIndex in migrated.layers.indices {
                for bindingIndex in migrated.layers[layerIndex].controls.indices {
                    let binding = migrated.layers[layerIndex].controls[bindingIndex]
                    let tap = migratedAction(binding.action)
                    let hold = migratedAction(binding.holdAction)
                    if tap != binding.action || hold != binding.holdAction {
                        migrated.layers[layerIndex].controls[bindingIndex].action = tap ?? .disabled
                        migrated.layers[layerIndex].controls[bindingIndex].holdAction = hold
                        changed = true
                    }
                }
            }
            if changed { migrated.updatedAt = .now }
            return changed ? migrated : profile
        }
    }

    /// The "Agent frei" reaction shipped green before Felix decided idle
    /// should read as a calmer white pulse instead. Only rewrites a profile
    /// still carrying that exact original green (a custom recolor is left
    /// alone), matching the pattern of the other stale-default migrations
    /// above.
    private static func migrateLegacyGreenIdleReaction(in profiles: [MacropadProfile]) -> [MacropadProfile] {
        profiles.map { profile in
            let idle = profile.reaction(for: .agentIdle)
            guard idle.red == 48, idle.green == 209, idle.blue == 88 else { return profile }
            var migrated = profile
            migrated.setReaction(LEDReactionConfiguration.defaults.first(where: { $0.event == .agentIdle })!)
            return migrated
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
