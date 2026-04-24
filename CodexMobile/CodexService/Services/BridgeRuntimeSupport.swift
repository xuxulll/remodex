// FILE: BridgeRuntimeSupport.swift
// Purpose: Shared runtime support for bridge settings persistence and Codex process lifecycle.
// Layer: Companion app service
// Exports: BridgeRuntimeError, BridgeRuntimeSettingsStore, BridgeRuntimeLogStore, CodexProcessManager
// Depends on: Foundation, Network, BridgeRuntimeModels, BridgeControlModels

#if os(macOS)
import Darwin
import Foundation
import Network
enum BridgeRuntimeError: LocalizedError {
    case invalidToken
    case invalidMessage(String)
    case invalidSession(String)
    case codexUnavailable(String)
    case codexAlreadyRunning
    case codexNotRunning
    case bridgeAlreadyRunning
    case bridgeNotRunning
    case unsupportedCodexHost(String)
    case codexLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Authentication failed: missing or invalid bridge token."
        case .invalidMessage(let message):
            return message
        case .invalidSession(let message):
            return message
        case .codexUnavailable(let message):
            return message
        case .codexAlreadyRunning:
            return "Codex process is already running."
        case .codexNotRunning:
            return "Codex process is not running."
        case .bridgeAlreadyRunning:
            return "Bridge server is already running."
        case .bridgeNotRunning:
            return "Bridge server is not running."
        case .unsupportedCodexHost(let host):
            return "Codex host must be loopback only. Received: \(host)."
        case .codexLaunchFailed(let message):
            return message
        }
    }
}

actor BridgeRuntimeSettingsStore {
    private enum Keys {
        static let runtimeSettings = "remodex.bridge.runtime.settings.v1"
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() -> BridgeRuntimeSettings {
        guard let data = UserDefaults.standard.data(forKey: Keys.runtimeSettings),
              let decoded = try? decoder.decode(BridgeRuntimeSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    func save(_ settings: BridgeRuntimeSettings) {
        guard let data = try? encoder.encode(settings) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Keys.runtimeSettings)
    }
}

actor BridgeRuntimeLogStore {
    private let maxErrors = 20
    private(set) var errors: [String] = []

    func recordError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errors.append(trimmed)
        if errors.count > maxErrors {
            errors.removeFirst(errors.count - maxErrors)
        }
    }

    func clear() {
        errors.removeAll()
    }
}

private struct CodexLaunchConfigurationResolver {
    func resolveArguments(settings: BridgeRuntimeSettings, helpOutput: String?) throws -> [String] {
        let codexHost = settings.codexListenHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoopbackHost(codexHost) else {
            throw BridgeRuntimeError.unsupportedCodexHost(codexHost)
        }

        if !settings.codexLaunchArguments.isEmpty {
            return settings.codexLaunchArguments
        }

        let listenURL = "ws://\(codexHost):\(settings.codexPort)"
        if helpOutput?.contains("--listen") == true {
            return ["app-server", "--listen", listenURL]
        }

        return ["app-server", "--listen", listenURL]
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }
}

actor CodexProcessManager {
    private let launchResolver = CodexLaunchConfigurationResolver()
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stderrBuffer = ""
    private var helpOutputCache: String?

    func detectCLIAvailability(settings: BridgeRuntimeSettings) async -> BridgeCLIAvailability {
        do {
            let executable = try resolveExecutablePath(settings.codexExecutablePath)
            let result = try await runProbe(executable: executable, arguments: ["--version"])
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return .available(version: trimmed.isEmpty ? "unknown" : trimmed)
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("not found") || message.contains("no such file") {
                return .missing
            }
            return .broken(message: error.localizedDescription)
        }
    }

    func start(settings: BridgeRuntimeSettings, log: @escaping @Sendable (String) -> Void) async throws -> Int {
        if let process, process.isRunning {
            throw BridgeRuntimeError.codexAlreadyRunning
        }

        let executable = try resolveExecutablePath(settings.codexExecutablePath)
        let helpOutput = try await appServerHelpOutput(executable: executable)
        let arguments = try launchResolver.resolveArguments(settings: settings, helpOutput: helpOutput)

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = buildEnvironment(executablePath: executable)

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            log("Codex stdout: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            Task {
                await self.appendStderr(line)
                if process?.isRunning == true {
                    log("Codex stderr: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw BridgeRuntimeError.codexLaunchFailed(
                "Failed to launch Codex CLI. Check executable path and args. `codex app-server --help` may help. \(error.localizedDescription)"
            )
        }

        self.process = process
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        do {
            try await waitUntilReady(host: settings.codexListenHost, port: settings.codexPort, process: process)
            return Int(process.processIdentifier)
        } catch {
            stopSynchronously()
            let stderrTail = await stderrTail(maxLength: 900)
            let suffix = stderrTail.isEmpty ? "" : " Last stderr: \(stderrTail)"
            throw BridgeRuntimeError.codexLaunchFailed(
                "Codex failed to become ready on ws://\(settings.codexListenHost):\(settings.codexPort).\(suffix)"
            )
        }
    }

    func stop() {
        stopSynchronously()
    }

    func restart(settings: BridgeRuntimeSettings, log: @escaping @Sendable (String) -> Void) async throws -> Int {
        stopSynchronously()
        return try await start(settings: settings, log: log)
    }

    func processID() -> Int? {
        guard let process, process.isRunning else {
            return nil
        }
        return Int(process.processIdentifier)
    }

    func isRunning() -> Bool {
        process?.isRunning == true
    }

    private func stopSynchronously() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func buildEnvironment(executablePath: String) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        let candidateEntries = [
            URL(fileURLWithPath: executablePath).deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existing = current["PATH"]?.split(separator: ":").map(String.init) ?? []
        let path = Array(NSOrderedSet(array: candidateEntries + existing)).compactMap { $0 as? String }.joined(separator: ":")
        return current.merging(["PATH": path]) { _, override in override }
    }

    private func resolveExecutablePath(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BridgeRuntimeError.codexUnavailable("Codex executable path is empty.")
        }

        if trimmed.contains("/") {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
            throw BridgeRuntimeError.codexUnavailable("Codex executable is not runnable at \(expanded).")
        }

        let result = Process()
        let pipe = Pipe()
        result.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        result.arguments = ["which", trimmed]
        result.standardOutput = pipe
        result.standardError = Pipe()
        try result.run()
        result.waitUntilExit()
        guard result.terminationStatus == 0 else {
            throw BridgeRuntimeError.codexUnavailable("Codex CLI was not found in PATH. Configure the executable path in settings.")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            throw BridgeRuntimeError.codexUnavailable("Codex CLI was not found in PATH. Configure the executable path in settings.")
        }
        return path
    }

    private func runProbe(executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw BridgeRuntimeError.codexUnavailable("Failed to run Codex probe command.")
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    private func appServerHelpOutput(executable: String) async throws -> String {
        if let helpOutputCache {
            return helpOutputCache
        }
        let output = try await runProbe(executable: executable, arguments: ["app-server", "--help"])
        helpOutputCache = output
        return output
    }

    private func waitUntilReady(host: String, port: Int, process: Process) async throws {
        for _ in 0..<60 {
            guard process.isRunning else {
                throw BridgeRuntimeError.codexLaunchFailed("Codex exited before it became ready.")
            }

            if await canConnect(host: host, port: port) {
                return
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        throw BridgeRuntimeError.codexLaunchFailed("Timed out waiting for Codex listener.")
    }

    private func canConnect(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let endpointHost = NWEndpoint.Host(host)
            guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
            let queue = DispatchQueue(label: "bridge.codex.readiness")
            var resumed = false

            func finish(_ value: Bool) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 0.8) {
                finish(false)
            }
        }
    }

    private func appendStderr(_ text: String) {
        stderrBuffer += text
        if stderrBuffer.count > 6_000 {
            stderrBuffer = String(stderrBuffer.suffix(6_000))
        }
    }

    private func stderrTail(maxLength: Int) -> String {
        String(stderrBuffer.suffix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
