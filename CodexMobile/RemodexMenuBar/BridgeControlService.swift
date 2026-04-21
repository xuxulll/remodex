// FILE: BridgeControlService.swift
// Purpose: Native macOS bridge runtime orchestration (no npm bridge dependency), plus compatibility wrappers used by menu bar UI.
// Layer: Companion app service
// Exports: BridgeControlService, ShellCommandRunner
// Depends on: Foundation, CryptoKit, Security, BridgeControlModels

import CryptoKit
import Foundation
import Security

enum BridgeControlError: LocalizedError {
    case commandFailed(command: String, message: String)
    case invalidSnapshot(String)
    case runtimeUnavailable(String)
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(_, let message):
            return message
        case .invalidSnapshot(let message):
            return message
        case .runtimeUnavailable(let message):
            return message
        case .unsupportedOperation(let message):
            return message
        }
    }
}

final class ShellCommandRunner {
    func run(command: String, environment: [String: String] = [:]) async throws -> ShellCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdoutReader = Task.detached(priority: .userInitiated) {
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrReader = Task.detached(priority: .userInitiated) {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }

            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
                override
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            let stdout = String(data: await stdoutReader.value, encoding: .utf8) ?? ""
            let stderr = String(data: await stderrReader.value, encoding: .utf8) ?? ""
            let result = ShellCommandResult(
                stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: process.terminationStatus
            )

            guard result.exitCode == 0 else {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                throw BridgeControlError.commandFailed(
                    command: command,
                    message: message.isEmpty ? "Command failed: \(command)" : message
                )
            }

            return result
        }.value
    }
}

struct ShellCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private final class NativeBridgeStateStore: BridgeStatePersisting {
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let stateDirectory: URL
    private let snapshotURL: URL
    private let trustedStateURL: URL
    private let securityService = "cn.stackapp.remodex.bridgecore"
    private let trustedKeychainAccount = "trusted-state"

    init() {
        self.stateDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".remodex-native", isDirectory: true)
        self.snapshotURL = stateDirectory.appendingPathComponent("bridge-snapshot.json")
        self.trustedStateURL = stateDirectory.appendingPathComponent("trusted-state.json")
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    }

    func readSnapshot() throws -> BridgeSnapshot {
        try ensureStateDirectory()
        guard let data = try? Data(contentsOf: snapshotURL) else {
            return defaultSnapshot()
        }

        do {
            return try decoder.decode(BridgeSnapshot.self, from: data)
        } catch {
            throw BridgeControlError.invalidSnapshot("Bridge snapshot is unreadable.")
        }
    }

    func writeSnapshot(_ snapshot: BridgeSnapshot) throws {
        try ensureStateDirectory()
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    func readTrustedState() throws -> BridgeTrustedState {
        try ensureStateDirectory()

        if let keychainData = readKeychainData(account: trustedKeychainAccount),
           let trusted = try? decoder.decode(BridgeTrustedState.self, from: keychainData) {
            return trusted
        }

        if let data = try? Data(contentsOf: trustedStateURL),
           let trusted = try? decoder.decode(BridgeTrustedState.self, from: data) {
            return trusted
        }

        let trusted = makeNewTrustedState()
        try writeTrustedState(trusted)
        return trusted
    }

    func writeTrustedState(_ trustedState: BridgeTrustedState) throws {
        try ensureStateDirectory()
        let data = try encoder.encode(trustedState)
        try data.write(to: trustedStateURL, options: .atomic)
        writeKeychainData(data, account: trustedKeychainAccount)
    }

    private func ensureStateDirectory() throws {
        if !fileManager.fileExists(atPath: stateDirectory.path) {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        }

        let logsDirectory = stateDirectory.appendingPathComponent("logs", isDirectory: true)
        if !fileManager.fileExists(atPath: logsDirectory.path) {
            try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        }
    }

    private func defaultSnapshot() -> BridgeSnapshot {
        let logsDirectory = stateDirectory.appendingPathComponent("logs", isDirectory: true)
        return BridgeSnapshot(
            currentVersion: "bridgecore-dev",
            label: "com.remodex.bridgecore",
            platform: "darwin",
            installed: true,
            launchdLoaded: false,
            launchdPid: nil,
            daemonConfig: BridgeDaemonConfig(
                relayUrl: "ws://localhost:9000/relay",
                pushServiceUrl: nil,
                codexEndpoint: nil,
                refreshEnabled: true
            ),
            bridgeStatus: BridgeRuntimeStatus(
                state: "stopped",
                connectionStatus: "idle",
                pid: nil,
                lastError: nil,
                updatedAt: Self.isoTimestamp()
            ),
            pairingSession: nil,
            stdoutLogPath: logsDirectory.appendingPathComponent("bridge.stdout.log").path,
            stderrLogPath: logsDirectory.appendingPathComponent("bridge.stderr.log").path
        )
    }

    private func makeNewTrustedState() -> BridgeTrustedState {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        return BridgeTrustedState(
            macDeviceId: UUID().uuidString,
            macIdentityPublicKey: publicKey,
            relaySessionId: UUID().uuidString,
            keyEpoch: 1,
            trustedPhoneDeviceID: nil,
            lastUpdatedAtISO8601: Self.isoTimestamp()
        )
    }

    private static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func readKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: securityService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private func writeKeychainData(_ data: Data, account: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: securityService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var add = baseQuery
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

private final class NativePairingService {
    func makePairingPayload(
        relayURL: String,
        trustedState: BridgeTrustedState,
        ttlSeconds: Int64 = 5 * 60
    ) -> BridgePairingPayload {
        let expiresAt = Int64(Date().timeIntervalSince1970 * 1000) + (ttlSeconds * 1000)
        return BridgePairingPayload(
            v: 2,
            relay: relayURL,
            sessionId: trustedState.relaySessionId,
            macDeviceId: trustedState.macDeviceId,
            macIdentityPublicKey: trustedState.macIdentityPublicKey,
            expiresAt: expiresAt
        )
    }
}

private final class NativeSecureChannelService: SecureTransporting {
    private var keyEpoch = 1
    private var sessionID = UUID().uuidString
    private var symmetricKey = SymmetricKey(size: .bits256)
    private var lastAppliedOutboundSequence = 0

    func beginHandshake() async throws -> BridgeHandshakeState {
        keyEpoch += 1
        sessionID = UUID().uuidString
        symmetricKey = SymmetricKey(size: .bits256)
        return BridgeHandshakeState(
            keyEpoch: keyEpoch,
            sessionId: sessionID,
            startedAt: Date()
        )
    }

    func encryptEnvelope(_ payload: String) throws -> BridgeSecureEnvelope {
        let payloadData = Data(payload.utf8)
        let sealed = try AES.GCM.seal(payloadData, using: symmetricKey)
        return BridgeSecureEnvelope(
            nonce: sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
    }

    func decryptEnvelope(_ envelope: BridgeSecureEnvelope) throws -> String {
        guard let nonceData = Data(base64Encoded: envelope.nonce),
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag) else {
            throw BridgeControlError.runtimeUnavailable("Encrypted payload is malformed.")
        }

        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let opened = try AES.GCM.open(box, using: symmetricKey)
        return String(data: opened, encoding: .utf8) ?? ""
    }

    func applyResumeState(_ state: BridgeResumeState) {
        lastAppliedOutboundSequence = max(lastAppliedOutboundSequence, state.lastAppliedOutboundSequence)
    }
}

private final class NativeCodexRuntimeHost: CodexHosting {
    private static let localAppServerListenURL = "ws://127.0.0.1:9101"
    private let runner: ShellCommandRunner
    private let stateStore: NativeBridgeStateStore
    private let callbackQueue = DispatchQueue(label: "bridgecore.codex.stream", qos: .utility)
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    init(runner: ShellCommandRunner, stateStore: NativeBridgeStateStore) {
        self.runner = runner
        self.stateStore = stateStore
    }

    func launch() async throws -> BridgeRuntimeProcessState {
        if let process, process.isRunning {
            return BridgeRuntimeProcessState(processIdentifier: Int(process.processIdentifier), startedAt: Date())
        }

        let codexPath = try await resolveCodexPath()
        let snapshot = try stateStore.readSnapshot()
        let stdoutURL = URL(fileURLWithPath: snapshot.stdoutLogPath)
        let stderrURL = URL(fileURLWithPath: snapshot.stderrLogPath)

        let stdout = try FileHandle(forWritingTo: ensureLogFile(stdoutURL))
        let stderr = try FileHandle(forWritingTo: ensureLogFile(stderrURL))
        let nextProcess = Process()
        nextProcess.executableURL = URL(fileURLWithPath: codexPath)
        nextProcess.arguments = ["app-server", "--listen", Self.localAppServerListenURL]
        nextProcess.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        nextProcess.standardOutput = stdout
        nextProcess.standardError = stderr
        nextProcess.terminationHandler = { [weak self] _ in
            self?.process = nil
        }

        try nextProcess.run()
        process = nextProcess
        stdoutHandle = stdout
        stderrHandle = stderr

        return BridgeRuntimeProcessState(processIdentifier: Int(nextProcess.processIdentifier), startedAt: Date())
    }

    func shutdown() async {
        guard let process else {
            return
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutHandle = nil
        stderrHandle = nil
        self.process = nil
    }

    func sendRPC(_ payload: String) async throws -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BridgeControlError.unsupportedOperation("RPC payload cannot be empty.")
        }

        throw BridgeControlError.unsupportedOperation(
            "Direct Codex app-server RPC passthrough is not exposed yet in this build."
        )
    }

    func streamEvents(_ onEvent: @escaping @Sendable (String) -> Void) async {
        guard let process, process.isRunning else {
            return
        }

        callbackQueue.async {
            onEvent("codex-runtime-online")
        }
    }

    func runtimeAvailability() async -> BridgeCLIAvailability {
        do {
            let codexPath = try await resolveCodexPath()
            let result = try await runner.run(command: "\(shellQuoted(codexPath)) --version")
            let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return .available(version: version.isEmpty ? "unknown" : version)
        } catch {
            let message = error.localizedDescription
            let normalized = message.lowercased()
            if normalized.contains("command not found") || normalized.contains("not found") {
                return .missing
            }
            return .broken(message: message)
        }
    }

    private func resolveCodexPath() async throws -> String {
        if let discovered = try? await runner.run(command: "command -v codex") {
            let path = discovered.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return path
            }
        }

        let fallbackPaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
        ]
        if let fallback = fallbackPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return fallback
        }

        throw BridgeControlError.runtimeUnavailable(
            "Codex CLI is not installed or not visible. Install Codex CLI and retry."
        )
    }

    private func ensureLogFile(_ fileURL: URL) -> URL {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: Data())
        }
        return fileURL
    }
}

private final class NativeBridgeRuntimeController: BridgeRuntimeControlling {
    private let stateStore: NativeBridgeStateStore
    private let codexHost: NativeCodexRuntimeHost
    private let secureChannel: NativeSecureChannelService
    private let pairingService: NativePairingService

    init(
        stateStore: NativeBridgeStateStore,
        codexHost: NativeCodexRuntimeHost,
        secureChannel: NativeSecureChannelService,
        pairingService: NativePairingService
    ) {
        self.stateStore = stateStore
        self.codexHost = codexHost
        self.secureChannel = secureChannel
        self.pairingService = pairingService
    }

    func start() async throws {
        let processState = try await codexHost.launch()
        _ = try await secureChannel.beginHandshake()
        let trusted = try stateStore.readTrustedState()
        let current = try stateStore.readSnapshot()
        let relayURL = current.daemonConfig?.relayUrl ?? "ws://localhost:9000/relay"
        let pairingPayload = pairingService.makePairingPayload(relayURL: relayURL, trustedState: trusted)

        let next = BridgeSnapshot(
            currentVersion: current.currentVersion,
            label: current.label,
            platform: current.platform,
            installed: true,
            launchdLoaded: true,
            launchdPid: processState.processIdentifier,
            daemonConfig: current.daemonConfig,
            bridgeStatus: BridgeRuntimeStatus(
                state: "running",
                connectionStatus: "connected",
                pid: processState.processIdentifier,
                lastError: nil,
                updatedAt: Self.isoTimestamp()
            ),
            pairingSession: BridgePairingSession(
                createdAt: Self.isoTimestamp(),
                pairingPayload: pairingPayload
            ),
            stdoutLogPath: current.stdoutLogPath,
            stderrLogPath: current.stderrLogPath
        )

        try stateStore.writeSnapshot(next)
    }

    func stop() async throws {
        await codexHost.shutdown()
        let current = try stateStore.readSnapshot()
        let next = BridgeSnapshot(
            currentVersion: current.currentVersion,
            label: current.label,
            platform: current.platform,
            installed: current.installed,
            launchdLoaded: false,
            launchdPid: nil,
            daemonConfig: current.daemonConfig,
            bridgeStatus: BridgeRuntimeStatus(
                state: "stopped",
                connectionStatus: "idle",
                pid: nil,
                lastError: nil,
                updatedAt: Self.isoTimestamp()
            ),
            pairingSession: current.pairingSession,
            stdoutLogPath: current.stdoutLogPath,
            stderrLogPath: current.stderrLogPath
        )
        try stateStore.writeSnapshot(next)
    }

    func status() async throws -> BridgeSnapshot {
        try stateStore.readSnapshot()
    }

    func resetPairing() async throws {
        let currentTrusted = try stateStore.readTrustedState()
        let rotated = BridgeTrustedState(
            macDeviceId: currentTrusted.macDeviceId,
            macIdentityPublicKey: currentTrusted.macIdentityPublicKey,
            relaySessionId: UUID().uuidString,
            keyEpoch: currentTrusted.keyEpoch + 1,
            trustedPhoneDeviceID: nil,
            lastUpdatedAtISO8601: Self.isoTimestamp()
        )
        try stateStore.writeTrustedState(rotated)

        let current = try stateStore.readSnapshot()
        let next = BridgeSnapshot(
            currentVersion: current.currentVersion,
            label: current.label,
            platform: current.platform,
            installed: current.installed,
            launchdLoaded: current.launchdLoaded,
            launchdPid: current.launchdPid,
            daemonConfig: current.daemonConfig,
            bridgeStatus: BridgeRuntimeStatus(
                state: current.bridgeStatus?.state,
                connectionStatus: current.bridgeStatus?.connectionStatus,
                pid: current.bridgeStatus?.pid,
                lastError: nil,
                updatedAt: Self.isoTimestamp()
            ),
            pairingSession: nil,
            stdoutLogPath: current.stdoutLogPath,
            stderrLogPath: current.stderrLogPath
        )
        try stateStore.writeSnapshot(next)
    }

    func resumeThread() async throws {
        _ = try await codexHost.sendRPC("{\"method\":\"thread/resume\",\"params\":{}}")
    }

    private static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

final class BridgeControlService {
    private let runner: ShellCommandRunner
    private let runtimeHost: NativeCodexRuntimeHost
    private let runtimeController: NativeBridgeRuntimeController

    init(runner: ShellCommandRunner = ShellCommandRunner()) {
        let stateStore = NativeBridgeStateStore()
        let secureChannel = NativeSecureChannelService()
        let pairingService = NativePairingService()
        let runtimeHost = NativeCodexRuntimeHost(runner: runner, stateStore: stateStore)

        self.runner = runner
        self.runtimeHost = runtimeHost
        self.runtimeController = NativeBridgeRuntimeController(
            stateStore: stateStore,
            codexHost: runtimeHost,
            secureChannel: secureChannel,
            pairingService: pairingService
        )
    }

    func detectCLIAvailability() async -> BridgeCLIAvailability {
        await runtimeHost.runtimeAvailability()
    }

    func loadSnapshot(relayOverride: String?) async throws -> BridgeSnapshot {
        let snapshot = try await runtimeController.status()
        guard let relayOverride,
              !relayOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return snapshot
        }

        let daemonConfig = BridgeDaemonConfig(
            relayUrl: relayOverride.trimmingCharacters(in: .whitespacesAndNewlines),
            pushServiceUrl: snapshot.daemonConfig?.pushServiceUrl,
            codexEndpoint: snapshot.daemonConfig?.codexEndpoint,
            refreshEnabled: snapshot.daemonConfig?.refreshEnabled
        )

        return BridgeSnapshot(
            currentVersion: snapshot.currentVersion,
            label: snapshot.label,
            platform: snapshot.platform,
            installed: snapshot.installed,
            launchdLoaded: snapshot.launchdLoaded,
            launchdPid: snapshot.launchdPid,
            daemonConfig: daemonConfig,
            bridgeStatus: snapshot.bridgeStatus,
            pairingSession: snapshot.pairingSession,
            stdoutLogPath: snapshot.stdoutLogPath,
            stderrLogPath: snapshot.stderrLogPath
        )
    }

    func startBridge(relayOverride _: String?) async throws {
        try await runtimeController.start()
    }

    func stopBridge(relayOverride _: String?) async throws {
        try await runtimeController.stop()
    }

    func resumeLastThread(relayOverride _: String?) async throws {
        try await runtimeController.resumeThread()
    }

    func resetPairing(relayOverride _: String?) async throws {
        try await runtimeController.resetPairing()
    }

    func updateBridgePackage() async throws {
        throw BridgeControlError.unsupportedOperation(
            "Bridge runtime is bundled in the app. Install a newer app build to update."
        )
    }

    func fetchLatestPackageVersion() async -> Result<String, Error> {
        .failure(
            BridgeControlError.unsupportedOperation(
                "npm package update checks are disabled for app-bundled bridge runtime."
            )
        )
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
