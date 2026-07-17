import Foundation

struct ProcessInvocation: Sendable, Hashable {
    var executablePath: String
    var arguments: [String]
    var timeout: TimeInterval
    var environment: [String: String]?

    init(executablePath: String, arguments: [String], timeout: TimeInterval = 10, environment: [String: String]? = nil) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.timeout = timeout
        self.environment = environment
    }
}

struct ProcessResult: Sendable, Hashable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var launchError: String?

    /// A transport command is considered successful only when it was clean.  The
    /// Rust helper uses stderr for failures, so accepting an exit code alone can
    /// produce a misleading "upload successful" state.
    var succeeded: Bool {
        exitCode == 0 && !timedOut && launchError == nil && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var failureDescription: String {
        if let launchError { return launchError }
        if timedOut { return "Zeitüberschreitung" }
        if exitCode != 0 { return "Exit-Code \(exitCode)" }
        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return stderr }
        return "Unbekannter Prozessfehler"
    }
}

protocol ProcessRunning {
    func run(_ invocation: ProcessInvocation) -> ProcessResult
}

/// A deliberately small process boundary: hardware transport can later be replaced
/// without changing SwiftUI or profile code.
struct FoundationProcessRunner: ProcessRunning {
    func run(_ invocation: ProcessInvocation) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        if let environment = invocation.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Do not wait until process termination to read either pipe. IORegistry
        // output can exceed a pipe buffer; waiting would deadlock ioreg and make
        // a connected pad look absent after the timeout.
        let stdoutReader = PipeDataReader()
        let stderrReader = PipeDataReader()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutReader.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrReader.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            readers.wait()
            return ProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(invocation.timeout)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
        }
        process.waitUntilExit()

        readers.wait()
        let stdout = String(data: stdoutReader.data, encoding: .utf8) ?? ""
        let stderr = String(data: stderrReader.data, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut, launchError: nil)
    }
}

private final class PipeDataReader: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    func set(_ data: Data) {
        lock.lock()
        storedData = data
        lock.unlock()
    }
}
