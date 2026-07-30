import Foundation
import Observation
import OSLog

/// `claude agents --json` prints every active interactive/background session
/// as a flat array — the closest Claude Code equivalent to Codex's
/// `thread/list`. There is no push/event stream like Codex's app-server, so
/// this polls on the same 2s cadence `CodexEventBridge` uses for turn
/// synchronization; live per-session status (running/idle/needs attention)
/// is layered on top separately once the opt-in hooks bridge is enabled.
private struct ClaudeAgentSession: Decodable {
    let pid: Int?
    let cwd: String?
    let kind: String?
    let startedAt: Double?
    let sessionId: String
    let name: String?
    let firstPrompt: String?

    private enum CodingKeys: String, CodingKey {
        case pid, cwd, kind, startedAt, sessionId, name, firstPrompt, prompt, initialPrompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        startedAt = try container.decodeIfPresent(Double.self, forKey: .startedAt)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        firstPrompt = try container.decodeIfPresent(String.self, forKey: .firstPrompt)
            ?? container.decodeIfPresent(String.self, forKey: .prompt)
            ?? container.decodeIfPresent(String.self, forKey: .initialPrompt)
    }

    var threadDescriptor: CodexThreadDescriptor {
        CodexThreadDescriptor(
            id: sessionId,
            title: name?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "",
            preview: "",
            cwd: cwd ?? "",
            parentThreadID: nil,
            agentNickname: nil,
            agentRole: kind,
            updatedAt: startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now,
            status: .idle
        )
    }
}

/// Claude Desktop keeps one compact metadata file per Code-tab session. This
/// is the same index the Desktop sidebar uses and, unlike `claude agents`,
/// includes inactive sessions as well. The fields below are intentionally
/// limited to identity, title, project and timestamps; transcript contents are
/// never read.
struct ClaudeDesktopSession: Decodable, Sendable {
    let sessionId: String
    let cliSessionId: String?
    let title: String?
    let cwd: String?
    let originCwd: String?
    let createdAt: Double?
    let lastActivityAt: Double?
    let isArchived: Bool?
    /// The only identity Claude's own deep-link route accepts. Claude resolves
    /// `claude://code/<id>` through `findSessionIdByBridgeSessionId`, which
    /// matches exactly these values — not the `local_…` metadata ID and not
    /// the CLI UUID. Sessions created before Claude started recording the
    /// field have none, and therefore cannot be navigated to directly.
    let bridgeSessionIds: [String]?

    var projectPath: String { originCwd ?? cwd ?? "" }

    /// The newest bridge ID, which is the one Claude's session manager
    /// resolves for a resumed session.
    var bridgeSessionID: String? {
        bridgeSessionIds?.last(where: { ClaudeAgentBridge.isRoutableBridgeSessionID($0) })
    }

    var threadDescriptor: CodexThreadDescriptor {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shortID = String(sessionId.replacingOccurrences(of: "local_", with: "").prefix(8))
        let project = projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath).lastPathComponent
        return CodexThreadDescriptor(
            id: sessionId,
            // Claude Desktop keeps the session even before it has generated a
            // sidebar title. Make that explicit instead of exposing a UUID as
            // if it were the title; it is unrelated to whether a PR merged.
            title: cleanTitle.isEmpty ? "Claude-Sitzung ohne Titel · \(shortID)" : cleanTitle,
            preview: [project, shortID].compactMap { $0 }.joined(separator: " · "),
            cwd: projectPath,
            parentThreadID: nil,
            agentNickname: nil,
            agentRole: "Claude Desktop",
            updatedAt: Self.date(milliseconds: lastActivityAt ?? createdAt) ?? .distantPast,
            status: .idle,
            alternateID: cliSessionId,
            navigationID: bridgeSessionID
        )
    }

    private static func date(milliseconds: Double?) -> Date? {
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

private struct ClaudeSessionSnapshot: Sendable {
    var threads: [CodexThreadDescriptor]
    var cliToDesktopID: [String: String]
}

private struct ClaudeBridgeError: Error {
    let message: String
}

@MainActor
@Observable
final class ClaudeAgentBridge: AgentBridge {
    private let logger = Logger(subsystem: "com.codexpad.app", category: "claude-bridge")
    private static let pollIntervalSeconds: TimeInterval = 2
    private static let hooksEnabledDefaultsKey = "CodexPad.claudeHooksStatusEnabled"
    private static let hookEventNames = ["Notification", "Stop", "SubagentStop", "UserPromptSubmit", "PreToolUse"]
    /// Once the tailed status file grows past this, it's truncated — every
    /// line up to that point has already been folded into `sessionLastEvent`,
    /// so nothing is lost by clearing it.
    private static let statusFileTruncateThreshold = 256 * 1024

    private var pollTask: Task<Void, Never>?
    /// Set while the Claude profile is not selected. Sticky on purpose: a
    /// stray `refreshThreads()` from a picker or a view must not silently
    /// resurrect the 2s CLI polling behind the user's back.
    private var isSuspended = false
    /// Sessions currently bound to a pad control; kept for the opt-in hooks
    /// status bridge, which only needs to tail status for these, not every
    /// Claude Code session running on the machine.
    private(set) var trackedThreadIDs: Set<String> = []
    /// How far into the status file `tailStatusFile` has already read.
    private var statusFileReadOffset: UInt64 = 0
    /// The last hook event seen per session, the running state status is
    /// derived from; survives file truncation since it lives in memory.
    private var sessionLastEvent: [String: String] = [:]
    /// Hook payloads use the CLI UUID while Desktop navigation uses its
    /// `local_…` session ID. Keep the bridge between both identities so live
    /// status and direct opening refer to the same visible row.
    private var cliToDesktopID: [String: String] = [:]

    private(set) var connectionState: CodexBridgeConnectionState = .disconnected
    private(set) var lastError: String?
    /// Off by default: only true once the user has explicitly enabled the
    /// hooks bridge in Settings, which is when CodexPad first writes to
    /// `~/.claude/settings.json`.
    private(set) var isHooksStatusEnabled: Bool
    private(set) var hooksStatusError: String?

    var onThreads: (([CodexThreadDescriptor]) -> Void)?
    var onStatus: ((String, CodexAgentStatus, AgentStatusSource) -> Void)?

    /// Without the hooks bridge the poll still yields a real running/idle
    /// distinction — it is coarse, not absent. Reporting `.notActivated` here
    /// used to contradict the LED, which showed that same poll result.
    var liveStatusAvailability: AgentLiveStatusAvailability {
        isHooksStatusEnabled ? .available : .sessionListOnly
    }

    /// `claude agents --json` is a poll, not a stream: when a session drops off
    /// the list, that *is* the end-of-run signal and nothing else will ever
    /// deliver it. See `AgentSnapshotAuthority`.
    let snapshotAuthority: AgentSnapshotAuthority = .authoritativeForRunning

    /// Claude validates the deep-link identifier with `/^(cse|session)_/`
    /// before it will resolve a session; anything else makes the handler bail
    /// out without even focusing the window.
    nonisolated static func isRoutableBridgeSessionID(_ value: String) -> Bool {
        value.hasPrefix("session_") || value.hasPrefix("cse_")
    }

    init() {
        isHooksStatusEnabled = UserDefaults.standard.bool(forKey: Self.hooksEnabledDefaultsKey)
    }

    func start() {
        isSuspended = false
        guard pollTask == nil else { return }
        connectionState = .connecting
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollOnce()
                if self?.isHooksStatusEnabled == true { self?.tailStatusFile() }
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        connectionState = .disconnected
    }

    /// Every tick spawns a fresh `claude` process (a ~250 MB binary), so this
    /// runs only while the Claude profile is selected. Assignments, tracked
    /// IDs and the derived hook states all live on and are reused on resume.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        stop()
    }

    func track(threadIDs: Set<String>) {
        trackedThreadIDs = threadIDs
    }

    /// Installs or removes the opt-in hook entries in the user's global
    /// `~/.claude/settings.json`. Only ever called from an explicit Settings
    /// toggle — never automatically. Existing hooks the user already has for
    /// these events are preserved; only entries whose command exactly matches
    /// CodexPad's own hook script are added or removed.
    func setHooksStatusEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try Self.writeHookScript()
                try Self.installHooks()
            } else {
                try Self.uninstallHooks()
            }
            isHooksStatusEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: Self.hooksEnabledDefaultsKey)
            hooksStatusError = nil
            if !enabled {
                sessionLastEvent.removeAll()
                statusFileReadOffset = 0
            }
        } catch {
            hooksStatusError = error.localizedDescription
        }
    }

    func refreshThreads() {
        guard !isSuspended else { return }
        guard pollTask != nil else {
            start()
            return
        }
        pollOnce()
    }

    func refreshRecentThreads() {
        refreshThreads()
    }

    func reconnectNow() {
        stop()
        start()
    }

    private func pollOnce() {
        Task.detached(priority: .utility) { [weak self] in
            let result = await Self.loadSessionSnapshot()
            await self?.handlePollResult(result)
        }
    }

    private func handlePollResult(_ result: Result<ClaudeSessionSnapshot, ClaudeBridgeError>) {
        switch result {
        case .success(let snapshot):
            connectionState = .connected(serverVersion: "Claude Desktop · \(snapshot.threads.count) Sitzungen")
            lastError = nil
            cliToDesktopID = snapshot.cliToDesktopID
            onThreads?(snapshot.threads)
        case .failure(let error):
            connectionState = .failed(error.message)
            lastError = error.message
            logger.error("\(error.message, privacy: .public)")
        }
    }

    private nonisolated static func loadSessionSnapshot() async -> Result<ClaudeSessionSnapshot, ClaudeBridgeError> {
        let desktopSessions = loadDesktopSessions()
        let activeResult = await runAgentsJSON()
        let activeSessions: [ClaudeAgentSession]
        switch activeResult {
        case .success(let sessions):
            activeSessions = sessions
        case .failure where !desktopSessions.isEmpty:
            activeSessions = []
        case .failure(let error):
            return .failure(error)
        }

        var cliToDesktopID: [String: String] = [:]
        var threadsByID: [String: CodexThreadDescriptor] = [:]
        for session in desktopSessions where session.isArchived != true {
            threadsByID[session.sessionId] = session.threadDescriptor
            if let cliID = session.cliSessionId, !cliID.isEmpty {
                cliToDesktopID[cliID] = session.sessionId
            }
        }

        for active in activeSessions {
            if let desktopID = cliToDesktopID[active.sessionId], var descriptor = threadsByID[desktopID] {
                descriptor.status = .running
                descriptor.updatedAt = .now
                threadsByID[desktopID] = descriptor
            } else {
                var descriptor = active.threadDescriptor
                descriptor.status = .running
                descriptor.preview = [
                    descriptor.projectName,
                    String(active.sessionId.prefix(8))
                ].compactMap { $0 }.joined(separator: " · ")
                threadsByID[descriptor.id] = descriptor
            }
        }

        return .success(ClaudeSessionSnapshot(
            threads: threadsByID.values.sorted { $0.updatedAt > $1.updatedAt },
            cliToDesktopID: cliToDesktopID
        ))
    }

    private nonisolated static func loadDesktopSessions() -> [ClaudeDesktopSession] {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Claude/claude-code-sessions", isDirectory: true),
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var sessions: [ClaudeDesktopSession] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  url.lastPathComponent.hasPrefix("local_"),
                  let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder().decode(ClaudeDesktopSession.self, from: data)
            else { continue }
            sessions.append(session)
        }
        return sessions
    }

    private nonisolated static func runAgentsJSON() async -> Result<[ClaudeAgentSession], ClaudeBridgeError> {
        guard let executable = claudeExecutable() else {
            return .failure(ClaudeBridgeError(message: "Claude CLI wurde nicht gefunden. Installiere oder starte die Claude-App."))
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["agents", "--json"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .failure(ClaudeBridgeError(message: "Claude CLI konnte nicht gestartet werden: \(error.localizedDescription)"))
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failure(ClaudeBridgeError(message: "`claude agents --json` endete mit Code \(process.terminationStatus)."))
        }
        guard let sessions = try? JSONDecoder().decode([ClaudeAgentSession].self, from: data) else {
            return .failure(ClaudeBridgeError(message: "`claude agents --json` lieferte keine gültige Antwort."))
        }
        return .success(sessions)
    }

    /// Checks common install locations first, then falls back to the copy
    /// bundled inside the Claude desktop app, picking the newest version
    /// directory under `claude-code/` — mirrors `CodexEventBridge.codexExecutable()`.
    private nonisolated static func claudeExecutable() -> URL? {
        let fixedCandidates = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        if let found = fixedCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        guard let claudeCodeRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Claude/claude-code", isDirectory: true),
            let versions = try? FileManager.default.contentsOfDirectory(at: claudeCodeRoot, includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }
        let newestFirst = versions
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for version in newestFirst {
            let binary = version.appendingPathComponent("claude.app/Contents/MacOS/claude")
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return binary
            }
        }
        return nil
    }

    // MARK: - Opt-in hooks status bridge

    private static func codexPadSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexPad", isDirectory: true)
    }

    private static func hookScriptURL() -> URL {
        codexPadSupportDirectory().appendingPathComponent("claude-hook-status.sh")
    }

    private static func statusFileURL() -> URL {
        codexPadSupportDirectory().appendingPathComponent("ClaudeSessionStatus.jsonl")
    }

    private static func settingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The exact command string every installed hook entry uses — also the
    /// marker `uninstallHooks` searches for, so only entries this app added
    /// are ever touched.
    private static func hookCommand() -> String {
        "\"\(hookScriptURL().path)\" >/dev/null 2>&1"
    }

    /// Always exits 0 and writes nothing to stdout, so it is inert for every
    /// hook event Claude Code supports — it can never block a tool call,
    /// block prompt submission, or otherwise influence a real session; it
    /// only ever appends one status line per fired hook.
    private static func writeHookScript() throws {
        let scriptURL = hookScriptURL()
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let statusPath = statusFileURL().path
        let script = """
        #!/bin/bash
        /usr/bin/python3 -c "
        import json, sys, time
        try:
            data = json.load(sys.stdin)
            session_id = data.get('session_id', '')
            if session_id:
                line = json.dumps({'sessionId': session_id, 'event': data.get('hook_event_name', ''), 'timestamp': time.time()})
                with open('\(statusPath)', 'a') as f:
                    f.write(line + chr(10))
        except Exception:
            pass
        " 2>/dev/null
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private static func installHooks() throws {
        var root = try readSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = hookCommand()
        for event in hookEventNames {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let alreadyPresent = entries.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String) == command } == true
            }
            guard !alreadyPresent else { continue }
            entries.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

    /// Removes only the hook entries whose command exactly matches
    /// `hookCommand()` — anything else the user has configured for these
    /// events, or any other top-level setting, is left untouched.
    private static func uninstallHooks() throws {
        var root = try readSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        let command = hookCommand()
        for event in hookEventNames {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.count == 1 && (inner[0]["command"] as? String) == command
            }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeSettings(root)
    }

    private static func readSettings() throws -> [String: Any] {
        let url = settingsURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeBridgeError(message: "~/.claude/settings.json enthält kein gültiges JSON-Objekt.")
        }
        return object
    }

    /// Writes to a temp file and renames over the original, so a crash or a
    /// concurrent Claude Code write mid-write can't leave a half-written file.
    private static func writeSettings(_ object: [String: Any]) throws {
        let url = settingsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let tempURL = url.appendingPathExtension("codexpad-tmp")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    /// Incrementally reads whatever the hook script has appended since the
    /// last poll, folds it into the in-memory per-session running state, and
    /// reports the derived status for every currently tracked session.
    /// Truncates the file once it grows past `statusFileTruncateThreshold`;
    /// safe because everything up to that point is already in memory.
    private func tailStatusFile() {
        let url = Self.statusFileURL()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= statusFileReadOffset else {
            statusFileReadOffset = 0
            return
        }
        guard size > statusFileReadOffset else { return }
        try? handle.seek(toOffset: statusFileReadOffset)
        let newData = handle.readDataToEndOfFile()
        statusFileReadOffset = size
        guard let text = String(data: newData, encoding: .utf8) else { return }

        var changedSessions: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let sessionId = entry["sessionId"] as? String,
                  let event = entry["event"] as? String
            else { continue }
            sessionLastEvent[sessionId] = event
            changedSessions.insert(sessionId)
        }

        for sessionId in changedSessions {
            let visibleID = cliToDesktopID[sessionId] ?? sessionId
            guard trackedThreadIDs.contains(visibleID) else { continue }
            onStatus?(visibleID, Self.status(forHookEvent: sessionLastEvent[sessionId]), .hook)
        }

        if size > UInt64(Self.statusFileTruncateThreshold) {
            try? Data().write(to: url)
            statusFileReadOffset = 0
        }
    }

    private static func status(forHookEvent event: String?) -> CodexAgentStatus {
        switch event {
        case "UserPromptSubmit", "PreToolUse": .running
        case "Notification": .needsAttention
        case "Stop", "SubagentStop": .completed
        default: .idle
        }
    }
}
