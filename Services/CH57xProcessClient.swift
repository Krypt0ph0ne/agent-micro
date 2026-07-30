import Foundation

struct CH57xDeviceTarget: Hashable, Sendable {
    var vendorID: Int
    var productID: Int

    static let ch57x8890 = CH57xDeviceTarget(vendorID: 0x1189, productID: 0x8890)

    var arguments: [String] {
        ["--vendor-id", String(format: "0x%04X", vendorID), "--product-id", String(format: "0x%04X", productID)]
    }

    func matches(_ device: ConnectedDevice?) -> Bool {
        device?.vendorID == vendorID && device?.productID == productID
    }
}

struct CH57xProcessClient {
    private let runner: any ProcessRunning
    private let helperURL: URL

    init(runner: any ProcessRunning = FoundationProcessRunner(), helperURL: URL? = nil) {
        self.runner = runner
        self.helperURL = helperURL ?? Self.locateHelper()
    }

    func validate(configuration: String) -> ProcessResult {
        run(command: "validate", configuration: configuration)
    }

    func upload(configuration: String, target: CH57xDeviceTarget) -> ProcessResult {
        run(command: "upload", configuration: configuration, timeout: 20, argumentsPrefix: target.arguments)
    }

    func setConfirmedLEDMode(_ mode: Int, target: CH57xDeviceTarget) -> ProcessResult {
        runner.run(ProcessInvocation(executablePath: helperURL.path, arguments: target.arguments + ["led", "\(mode)"], timeout: 12))
    }

    private func run(command: String, configuration: String, timeout: TimeInterval = 10, argumentsPrefix: [String] = []) -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return ProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: "",
                timedOut: false,
                launchError: "CH57x-Helper nicht gefunden: \(helperURL.path). Führe script/build_and_run.sh aus."
            )
        }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("codexpad-\(UUID().uuidString).yaml")
        do {
            try configuration.write(to: fileURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            return runner.run(ProcessInvocation(executablePath: helperURL.path, arguments: argumentsPrefix + [command, fileURL.path], timeout: timeout))
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: false, launchError: error.localizedDescription)
        }
    }

    private static func locateHelper() -> URL {
        if let resource = Bundle.main.url(forResource: "ch57x-keyboard-tool", withExtension: nil) {
            return resource
        }
        if let override = ProcessInfo.processInfo.environment["AGENT_MICRO_HELPER"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let workspaceHelper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/ch57x-keyboard-tool")
        return workspaceHelper
    }
}
