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
    private let persistenceURL: URL
    private let catalog: CodexActionCatalog

    private(set) var profiles: [MacropadProfile]
    var keyboardLayout: KeyboardLayout {
        didSet {
            guard keyboardLayout != oldValue else { return }
            UserDefaults.standard.set(keyboardLayout.rawValue, forKey: Self.keyboardLayoutDefaultsKey)
            hasUnsyncedChanges = true
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

    init(catalog: CodexActionCatalog, persistenceURL: URL? = nil) {
        self.catalog = catalog
        self.keyboardLayout = UserDefaults.standard.string(forKey: Self.keyboardLayoutDefaultsKey)
            .flatMap(KeyboardLayout.init(rawValue:)) ?? .automatic
        let baseDirectory = persistenceURL?.deletingLastPathComponent() ?? Self.applicationSupportDirectory()
        self.persistenceURL = persistenceURL ?? baseDirectory.appendingPathComponent("Profiles.json")
        let loaded = Self.load(from: self.persistenceURL)
        let seed = loaded ?? [ProfileFactory.codex(catalog: catalog), ProfileFactory.macOS(), ProfileFactory.safe()]
        let builtIns = Self.ensureBuiltInProfiles(in: seed, catalog: catalog)
        let encoderMigrated = Self.migrateLegacyCodexReasoningBindings(in: builtIns)
        let initial = Self.migrateLegacyDictationBindings(in: encoderMigrated, catalog: catalog)
        self.profiles = initial
        let codexID = initial.first(where: { $0.name == "Codex" })?.id
        self.selectedProfileID = codexID ?? initial.first?.id ?? UUID()
        if loaded == nil || initial != seed { persist() }
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
        var profile = selectedProfile
        profile.led.setSetting(setting)
        profile.updatedAt = .now
        replace(profile)
    }

    func assignCodexAction(id: String, to control: HardwareControl) {
        guard let action = catalog.keyboardAction(id: id) else { return }
        updateAction(action, for: control)
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

    private static func ensureBuiltInProfiles(in profiles: [MacropadProfile], catalog: CodexActionCatalog) -> [MacropadProfile] {
        guard !profiles.contains(where: { $0.name == "Codex · Reasoning triggers" }) else { return profiles }
        return profiles + [ProfileFactory.codexReasoningTriggers(catalog: catalog)]
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
                && press.deviceMacro == "ctrl-shift-m"
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
}
