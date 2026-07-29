import Foundation
import Observation
import OSLog

/// Splits a byte stream into complete newline-terminated JSON messages and
/// deserializes them. Not thread-safe on its own; the bridge only ever uses it
/// from a single serial queue, keeping this work off the main thread.
final class NDJSONLineReader: @unchecked Sendable {
    private var buffer = [UInt8]()
    /// How far into `buffer` we have already looked for a newline. Without this,
    /// a long message split across many chunks makes every chunk re-scan the
    /// whole growing buffer — O(n²) — which pegged the CPU even though the
    /// app-server itself was idle.
    private var scanOffset = 0

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        scanOffset = 0
    }

    /// Appends new bytes and returns every newly completed message, parsed. Only
    /// the freshly appended bytes are scanned, so total work is O(bytes).
    func appendAndParse(_ data: Data) -> [[String: Any]] {
        buffer.append(contentsOf: data)
        var lineStart = 0
        var objects: [[String: Any]] = []
        var index = scanOffset
        while index < buffer.count {
            if buffer[index] == 0x0A {
                if index > lineStart,
                   let object = try? JSONSerialization.jsonObject(with: Data(buffer[lineStart..<index])) as? [String: Any] {
                    objects.append(object)
                }
                lineStart = index + 1
            }
            index += 1
        }
        if lineStart > 0 { buffer.removeFirst(lineStart) }
        // Everything currently buffered has now been scanned for a newline.
        scanOffset = buffer.count
        return objects
    }
}

/// Read-only observer for Codex lifecycle and elicitation events. In particular,
/// server-initiated approval and user-input requests are intentionally never answered.
@MainActor
@Observable
final class CodexEventBridge: @unchecked Sendable, AgentBridge {
    private enum ThreadListMode {
        case full
        case recent
    }

    private enum RequestPurpose {
        case initialize
        case listThreads(ThreadListMode)
        case readThread(String)
    }

    private let logger = Logger(subsystem: "com.codexpad.app", category: "codex-bridge")
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    /// The app-server stream is split into NDJSON lines and deserialized off the
    /// main thread; only the finished objects are handed back to the main actor.
    /// An active Codex session streams a lot, and doing this parse on the main
    /// thread froze the UI. The reader is only ever touched on `parseQueue`.
    @ObservationIgnored nonisolated private let parseQueue = DispatchQueue(label: "com.codexpad.bridge.parse")
    @ObservationIgnored nonisolated private let lineReader = NDJSONLineReader()
    @ObservationIgnored private var nextRequestID = 1
    @ObservationIgnored private var pendingRequests: [Int: RequestPurpose] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var statusSyncTask: Task<Void, Never>?
    private var rolloutSyncTask: Task<Void, Never>?
    private var recentThreadSyncTask: Task<Void, Never>?
    @ObservationIgnored private let rolloutObserver = CodexRolloutStatusObserver()
    private var reconnectAttempt = 0
    private var isStopping = false
    private var trackedThreadIDs: Set<String> = []
    private var statusReadsInFlight: Set<String> = []
    private var pendingElicitations: [String: Set<String>] = [:]
    private var threadListAccumulator: [CodexThreadDescriptor] = []
    private var fullThreadListInFlight = false
    private var recentThreadListInFlight = false

    private(set) var connectionState: CodexBridgeConnectionState = .disconnected
    private(set) var lastError: String?
    let liveStatusAvailability: AgentLiveStatusAvailability = .available

    var onThreads: (([CodexThreadDescriptor]) -> Void)?
    var onStatus: ((String, CodexAgentStatus, AgentStatusSource) -> Void)?
    /// Fired for the two binary-decision approval kinds only (command
    /// execution, file change) — see `handleEvent`. The other elicitation
    /// kinds (permissions grant, free-form user input, MCP elicitation)
    /// stay on the read-only path below; they don't fit a yes/no answer.
    var onApprovalRequested: ((PendingApproval) -> Void)?
    /// Fired when a tracked approval resolves some other way (e.g. answered
    /// directly in the Codex CLI), by `PendingApproval.id`.
    var onApprovalResolved: ((String) -> Void)?

    func start() {
        guard process == nil else { return }
        isStopping = false
        reconnectTask?.cancel()
        connect()
    }

    func stop() {
        isStopping = true
        reconnectTask?.cancel()
        reconnectTask = nil
        statusSyncTask?.cancel()
        statusSyncTask = nil
        rolloutSyncTask?.cancel()
        rolloutSyncTask = nil
        recentThreadSyncTask?.cancel()
        recentThreadSyncTask = nil
        statusReadsInFlight.removeAll()
        fullThreadListInFlight = false
        recentThreadListInFlight = false
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        input = nil
        connectionState = .disconnected
    }

    func reconnectNow() {
        stop()
        isStopping = false
        reconnectAttempt = 0
        connect()
    }

    func track(threadIDs: Set<String>) {
        trackedThreadIDs = threadIDs
        rolloutObserver.retain(threadIDs: threadIDs)
        statusReadsInFlight.formIntersection(threadIDs)
        guard connectionState.isConnected else { return }
        synchronizeTrackedThreads()
    }

    func refreshThreads() {
        guard connectionState.isConnected else {
            start()
            return
        }
        requestFullThreadList()
        synchronizeTrackedThreads()
    }

    func refreshRecentThreads() {
        guard connectionState.isConnected else {
            start()
            return
        }
        requestRecentThreadList()
    }

    private func connect() {
        connectionState = reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt)
        lastError = nil

        guard let executable = Self.codexExecutable() else {
            fail("Codex CLI wurde nicht gefunden. Installiere oder starte die Codex-App.")
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            // Parse off the main thread; hand only finished objects back.
            self.parseQueue.async { [weak self] in
                guard let self else { return }
                let objects = self.lineReader.appendAndParse(data)
                guard !objects.isEmpty else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for object in objects { self.handle(object) }
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let message = String(data: data, encoding: .utf8), !message.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.logger.debug("app-server: \(message, privacy: .public)")
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in self?.processDidTerminate(code: process.terminationStatus) }
        }

        do {
            try process.run()
            self.process = process
            input = stdinPipe.fileHandleForWriting
            parseQueue.async { [lineReader] in lineReader.reset() }
            pendingRequests.removeAll()
            statusReadsInFlight.removeAll()
            sendInitialize()
        } catch {
            fail("Codex App Server konnte nicht gestartet werden: \(error.localizedDescription)")
        }
    }

    private func sendInitialize() {
        sendRequest(method: "initialize", params: [
            "clientInfo": ["name": "codexpad", "title": "CodexPad", "version": "1.0"],
            "capabilities": [
                "experimentalApi": true,
                "requestAttestation": false,
                "mcpServerOpenaiFormElicitation": false
            ]
        ], purpose: .initialize)
    }

    private func requestFullThreadList(cursor: String? = nil) {
        if cursor == nil {
            guard !fullThreadListInFlight else { return }
            fullThreadListInFlight = true
            threadListAccumulator.removeAll(keepingCapacity: true)
        }
        requestThreadList(cursor: cursor, mode: .full)
    }

    private func requestRecentThreadList() {
        guard !recentThreadListInFlight else { return }
        recentThreadListInFlight = true
        requestThreadList(cursor: nil, mode: .recent)
    }

    private func requestThreadList(cursor: String?, mode: ThreadListMode) {
        var params: [String: Any] = [
            "limit": 100,
            "sortKey": "recency_at",
            "sortDirection": "desc",
            "sourceKinds": [
                "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
                "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"
            ]
        ]
        if let cursor { params["cursor"] = cursor }
        sendRequest(method: "thread/list", params: params, purpose: .listThreads(mode))
    }

    private func synchronizeTrackedThreads() {
        for threadID in trackedThreadIDs where !statusReadsInFlight.contains(threadID) {
            statusReadsInFlight.insert(threadID)
            sendRequest(
                method: "thread/read",
                params: ["threadId": threadID, "includeTurns": true],
                purpose: .readThread(threadID)
            )
        }
    }

    private func startStatusSynchronization() {
        statusSyncTask?.cancel()
        statusSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.synchronizeTrackedThreads()
            }
        }
        rolloutSyncTask?.cancel()
        rolloutSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.synchronizeTrackedRollouts()
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        recentThreadSyncTask?.cancel()
        recentThreadSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.requestRecentThreadList()
            }
        }
    }

    private func synchronizeTrackedRollouts() {
        for update in rolloutObserver.poll(threadIDs: trackedThreadIDs) {
            onStatus?(update.threadID, update.status, update.source)
        }
    }

    private func sendRequest(method: String, params: [String: Any], purpose: RequestPurpose) {
        let id = nextRequestID
        nextRequestID += 1
        pendingRequests[id] = purpose
        writeJSON(["id": id, "method": method, "params": params])
    }

    private func writeJSON(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do {
            try input?.write(contentsOf: data)
        } catch {
            fail("Schreiben zum Codex App Server fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = Self.integerID(message["id"]), let purpose = pendingRequests.removeValue(forKey: id) {
            handleResponse(message, purpose: purpose)
            return
        }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        handleEvent(method: method, params: params, requestID: message["id"])
    }

    private func handleResponse(_ message: [String: Any], purpose: RequestPurpose) {
        if case .readThread(let threadID) = purpose {
            statusReadsInFlight.remove(threadID)
        }
        if let error = message["error"] as? [String: Any] {
            if case .listThreads(let mode) = purpose {
                switch mode {
                case .full: fullThreadListInFlight = false
                case .recent: recentThreadListInFlight = false
                }
            }
            let detail = error["message"] as? String ?? "Unbekannter App-Server-Fehler"
            lastError = detail
            logger.error("App-server request failed: \(detail, privacy: .public)")
            return
        }
        let result = message["result"] as? [String: Any] ?? [:]
        switch purpose {
        case .initialize:
            let version = result["userAgent"] as? String ?? "Codex App Server"
            reconnectAttempt = 0
            connectionState = .connected(serverVersion: version)
            logger.info("Connected to \(version, privacy: .public)")
            writeJSON(["method": "initialized"])
            requestFullThreadList()
            synchronizeTrackedThreads()
            startStatusSynchronization()
        case .listThreads(let mode):
            let data = result["data"] as? [[String: Any]] ?? []
            let descriptors = data.compactMap(parseThread)
            if !descriptors.isEmpty { onThreads?(descriptors) }
            switch mode {
            case .recent:
                recentThreadListInFlight = false
            case .full:
                threadListAccumulator.append(contentsOf: descriptors)
                if let cursor = result["nextCursor"] as? String, !cursor.isEmpty {
                    requestFullThreadList(cursor: cursor)
                } else {
                    fullThreadListInFlight = false
                    logger.info("Loaded \(self.threadListAccumulator.count, privacy: .public) Codex threads and subagents")
                }
            }
        case .readThread(let threadID):
            guard let thread = result["thread"] as? [String: Any] else { return }
            if let descriptor = parseThread(thread) { onThreads?([descriptor]) }
            if let status = synchronizedStatus(from: thread) {
                rememberAttentionSnapshot(status, threadID: threadID)
                onStatus?(threadID, status, .snapshot)
            }
        }
    }

    private func handleEvent(method: String, params: [String: Any], requestID: Any?) {
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any], let descriptor = parseThread(thread) {
                onThreads?([descriptor])
                onStatus?(descriptor.id, descriptor.status, .event)
            }
        case "thread/status/changed":
            guard let threadID = params["threadId"] as? String,
                  let status = params["status"] as? [String: Any] else { return }
            let mapped = StatusMapper.threadStatus(
                type: status["type"] as? String,
                activeFlags: status["activeFlags"] as? [String] ?? []
            )
            rememberAttentionSnapshot(mapped, threadID: threadID)
            onStatus?(threadID, mapped, .event)
        case "turn/started":
            if let threadID = params["threadId"] as? String {
                pendingElicitations[threadID] = nil
                onStatus?(threadID, .running, .event)
            }
        case "turn/completed":
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let status = StatusMapper.turnStatus(turn["status"] as? String) else { return }
            pendingElicitations[threadID] = nil
            onStatus?(threadID, status, .event)
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "applyPatchApproval", "execCommandApproval":
            guard let threadID = params["threadId"] as? String else { return }
            let opaqueID = requestID.map(String.init(describing:)) ?? UUID().uuidString
            pendingElicitations[threadID, default: []].insert(opaqueID)
            onStatus?(threadID, .needsAttention, .event)
            guard let rpcID = JSONRPCID(requestID) else {
                logger.error("Approval request for thread \(threadID, privacy: .public) has no usable id; cannot answer it")
                return
            }
            let kind: ApprovalKind = (method == "item/fileChange/requestApproval" || method == "applyPatchApproval") ? .fileChange : .command
            onApprovalRequested?(PendingApproval(
                id: opaqueID,
                source: .codex(threadID: threadID, requestID: rpcID, method: method),
                kind: kind,
                summary: Self.summary(for: kind, params: params),
                receivedAt: .now
            ))
        case "item/permissions/requestApproval", "item/tool/requestUserInput", "mcpServer/elicitation/request":
            guard let threadID = params["threadId"] as? String else { return }
            let opaqueID = requestID.map(String.init(describing:)) ?? UUID().uuidString
            pendingElicitations[threadID, default: []].insert(opaqueID)
            onStatus?(threadID, .needsAttention, .event)
            logger.notice("Observed read-only elicitation for thread \(threadID, privacy: .public); no response will be sent")
        case "serverRequest/resolved":
            guard let threadID = params["threadId"] as? String else { return }
            let opaqueID = params["requestId"].map(String.init(describing:))
            if let opaqueID {
                pendingElicitations[threadID]?.remove(opaqueID)
                onApprovalResolved?(opaqueID)
            }
            if pendingElicitations[threadID]?.isEmpty != false { onStatus?(threadID, .running, .event) }
        case "error":
            lastError = params["message"] as? String ?? "Codex App Server meldet einen Fehler."
        default:
            break
        }
    }

    /// Answers a Codex-origin approval for real: writes a JSON-RPC response
    /// back over the same stdio pipe, matching the exact shape each approval
    /// method expects (confirmed against the live `codex app-server`
    /// protocol schema — the legacy `execCommandApproval`/`applyPatchApproval`
    /// pair uses the shared `ReviewDecision` enum's plain-string cases, the
    /// v2 `item/.../requestApproval` pair uses its own smaller decision enum).
    func respond(to approval: PendingApproval, decision: ApprovalDecision) {
        guard case .codex(let threadID, let requestID, let method) = approval.source else { return }
        guard let result = Self.responseResult(method: method, decision: decision) else {
            logger.error("No known response shape for Codex approval method \(method, privacy: .public)")
            return
        }
        writeJSON(["id": requestID.jsonValue, "result": result])
        pendingElicitations[threadID]?.remove(approval.id)
        if pendingElicitations[threadID]?.isEmpty != false { onStatus?(threadID, .running, .event) }
        logger.notice("Answered Codex approval (\(method, privacy: .public)) for thread \(threadID, privacy: .public): \(decision == .accept ? "accept" : "decline", privacy: .public)")
    }

    private static func responseResult(method: String, decision: ApprovalDecision) -> [String: Any]? {
        switch method {
        case "execCommandApproval", "applyPatchApproval":
            return ["decision": decision == .accept ? "approved" : "denied"]
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return ["decision": decision == .accept ? "accept" : "decline"]
        default:
            return nil
        }
    }

    private static func summary(for kind: ApprovalKind, params: [String: Any]) -> String {
        switch kind {
        case .command:
            if let command = params["command"] as? String, !command.isEmpty { return command }
            if let commandArray = params["command"] as? [String], !commandArray.isEmpty { return commandArray.joined(separator: " ") }
            return "Befehl ausführen"
        case .fileChange:
            if let fileChanges = params["fileChanges"] as? [String: Any], !fileChanges.isEmpty {
                return fileChanges.keys.sorted().joined(separator: ", ")
            }
            return "Dateien ändern"
        }
    }

    private func parseThread(_ object: [String: Any]) -> CodexThreadDescriptor? {
        guard let id = object["id"] as? String else { return nil }
        let statusObject = object["status"] as? [String: Any] ?? [:]
        return CodexThreadDescriptor(
            id: id,
            title: object["name"] as? String ?? "",
            preview: object["preview"] as? String ?? "",
            cwd: object["cwd"] as? String ?? "",
            parentThreadID: object["parentThreadId"] as? String,
            agentNickname: object["agentNickname"] as? String,
            agentRole: object["agentRole"] as? String,
            updatedAt: Date(timeIntervalSince1970: (object["updatedAt"] as? NSNumber)?.doubleValue ?? 0),
            status: StatusMapper.threadStatus(
                type: statusObject["type"] as? String,
                activeFlags: statusObject["activeFlags"] as? [String] ?? []
            )
        )
    }

    private func synchronizedStatus(from thread: [String: Any]) -> CodexAgentStatus? {
        let status = thread["status"] as? [String: Any] ?? [:]
        let turns = thread["turns"] as? [[String: Any]] ?? []
        let latestTurn = turns.last
        return StatusMapper.synchronizedStatus(
            threadType: status["type"] as? String,
            activeFlags: status["activeFlags"] as? [String] ?? [],
            latestTurnStatus: latestTurn?["status"] as? String,
            latestTurnHasCompletionTimestamp: latestTurn?["completedAt"] is NSNumber
        )
    }

    private func rememberAttentionSnapshot(_ status: CodexAgentStatus, threadID: String) {
        let marker = "thread-status-active-flag"
        if status == .needsAttention {
            pendingElicitations[threadID, default: []].insert(marker)
        } else {
            pendingElicitations[threadID]?.remove(marker)
        }
    }

    private func processDidTerminate(code: Int32) {
        statusSyncTask?.cancel()
        statusSyncTask = nil
        rolloutSyncTask?.cancel()
        rolloutSyncTask = nil
        recentThreadSyncTask?.cancel()
        recentThreadSyncTask = nil
        statusReadsInFlight.removeAll()
        fullThreadListInFlight = false
        recentThreadListInFlight = false
        process = nil
        input = nil
        guard !isStopping else { return }
        scheduleReconnect(reason: "Codex App Server wurde beendet (Code \(code)).")
    }

    private func fail(_ message: String) {
        lastError = message
        connectionState = .failed(message)
        logger.error("\(message, privacy: .public)")
        if process != nil { process?.terminate() } else { scheduleReconnect(reason: message) }
    }

    private func scheduleReconnect(reason: String) {
        guard reconnectTask == nil, !isStopping else { return }
        reconnectAttempt += 1
        connectionState = .reconnecting(attempt: reconnectAttempt)
        lastError = reason
        let seconds = min(30, 1 << min(reconnectAttempt - 1, 5))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            self?.connect()
        }
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func codexExecutable() -> URL? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}
