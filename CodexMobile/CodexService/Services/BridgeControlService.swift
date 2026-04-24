// FILE: BridgeControlService.swift
// Purpose: Native macOS bridge runtime orchestration (no npm bridge dependency), plus compatibility wrappers used by menu bar UI.
// Layer: Companion app service
// Exports: BridgeControlService, ShellCommandRunner
// Depends on: Foundation, CryptoKit, Security, BridgeControlModels

#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Security

private let nativeBridgePort = 9010

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
                relayUrl: "ws://localhost:\(nativeBridgePort)/relay",
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
            expiresAt: expiresAt,
            transport: "direct_app_server"
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
    private static let localAppServerListenURL = "ws://127.0.0.1:\(nativeBridgePort)"
    private static let localAppServerReadyURL = URL(string: "http://127.0.0.1:\(nativeBridgePort)/readyz")
    private static let startupTimeoutNanoseconds: UInt64 = 8_000_000_000
    private static let startupPollIntervalNanoseconds: UInt64 = 200_000_000
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
            if await isReadyEndpointReachable() {
                return BridgeRuntimeProcessState(processIdentifier: Int(process.processIdentifier), startedAt: Date())
            }

            terminateProcessTreeIfNeeded(pid: process.processIdentifier)
            self.process = nil
        }

        if let persistedPID = persistedRuntimePID(), isProcessAlive(pid: persistedPID) {
            terminateProcessTreeIfNeeded(pid: persistedPID)
        }

        await terminatePortListeners(excluding: [])

        let codexPath = try await resolveCodexPath()
        let snapshot = try stateStore.readSnapshot()
        let stdoutURL = URL(fileURLWithPath: snapshot.stdoutLogPath)
        let stderrURL = URL(fileURLWithPath: snapshot.stderrLogPath)

        let stdout = try FileHandle(forWritingTo: ensureLogFile(stdoutURL))
        let stderr = try FileHandle(forWritingTo: ensureLogFile(stderrURL))
        let nextProcess = Process()
        let launchEnvironment = buildLaunchEnvironment(codexPath: codexPath)
        nextProcess.executableURL = URL(fileURLWithPath: codexPath)
        nextProcess.arguments = ["app-server", "--listen", Self.localAppServerListenURL]
        nextProcess.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        nextProcess.environment = launchEnvironment
        nextProcess.standardOutput = stdout
        nextProcess.standardError = stderr

        try nextProcess.run()
        process = nextProcess
        stdoutHandle = stdout
        stderrHandle = stderr

        do {
            try await waitUntilRuntimeReady(process: nextProcess, stderrURL: stderrURL)
        } catch {
            terminateProcessTreeIfNeeded(pid: nextProcess.processIdentifier)
            try? stdout.close()
            try? stderr.close()
            stdoutHandle = nil
            stderrHandle = nil
            process = nil
            throw error
        }

        return BridgeRuntimeProcessState(processIdentifier: Int(nextProcess.processIdentifier), startedAt: Date())
    }

    func shutdown() async {
        shutdownSynchronously()
    }

    func shutdownSynchronously() {
        let activeProcess = process
        if let activeProcess, activeProcess.isRunning {
            activeProcess.terminate()
            activeProcess.waitUntilExit()
        } else if let persistedPID = persistedRuntimePID() {
            terminateProcessTreeIfNeeded(pid: persistedPID)
        }
        terminatePortListenersSynchronously(excluding: [])

        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutHandle = nil
        stderrHandle = nil
        process = nil
        persistStoppedSnapshot()
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

    private func persistedRuntimePID() -> Int32? {
        guard let snapshot = try? stateStore.readSnapshot(),
              snapshot.launchdLoaded,
              let persistedPID = snapshot.launchdPid,
              persistedPID > 0 else {
            return nil
        }
        return Int32(persistedPID)
    }

    private func terminateProcessTreeIfNeeded(pid: Int32) {
        guard isProcessAlive(pid: pid) else {
            return
        }

        _ = kill(pid, SIGTERM)
        for _ in 0..<10 where isProcessAlive(pid: pid) {
            usleep(100_000)
        }

        if isProcessAlive(pid: pid) {
            _ = kill(pid, SIGKILL)
        }
    }

    private func isProcessAlive(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func waitUntilRuntimeReady(process: Process, stderrURL: URL) async throws {
        let maxAttempts = Int(Self.startupTimeoutNanoseconds / Self.startupPollIntervalNanoseconds)
        for _ in 0..<maxAttempts {
            if !process.isRunning {
                throw startupFailureError(
                    reason: "Codex app-server exited before it became ready.",
                    stderrURL: stderrURL
                )
            }

            let readyEndpointReachable = await isReadyEndpointReachable()
            let listenerReady = await isRuntimeListenerReady(processID: process.processIdentifier)
            if readyEndpointReachable || listenerReady {
                return
            }

            try? await Task.sleep(nanoseconds: Self.startupPollIntervalNanoseconds)
        }

        throw startupFailureError(
            reason: "Timed out waiting for Codex app-server readiness on port \(nativeBridgePort).",
            stderrURL: stderrURL
        )
    }

    // Accepts listener readiness so start/restart stay compatible when app-server doesn't expose /readyz.
    private func isRuntimeListenerReady(processID: Int32) async -> Bool {
        let listeners = await listeningRuntimePIDs()
        return listeners.contains(processID)
    }

    private func isReadyEndpointReachable() async -> Bool {
        guard let readyURL = Self.localAppServerReadyURL else {
            return false
        }

        var request = URLRequest(url: readyURL)
        request.timeoutInterval = 1.0

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func startupFailureError(reason: String, stderrURL: URL) -> BridgeControlError {
        let stderrTail = readLogTail(stderrURL)
        if stderrTail.isEmpty {
            return .runtimeUnavailable(reason)
        }
        return .runtimeUnavailable("\(reason) \(stderrTail)")
    }

    private func terminatePortListeners(excluding excludedPIDs: Set<Int32>) async {
        let listeners = await listeningRuntimePIDs()
        guard !listeners.isEmpty else {
            return
        }

        for pid in listeners where !excludedPIDs.contains(pid) {
            terminateProcessTreeIfNeeded(pid: pid)
        }
    }

    private func terminatePortListenersSynchronously(excluding excludedPIDs: Set<Int32>) {
        let listeners = listeningRuntimePIDSSynchronously()
        guard !listeners.isEmpty else {
            return
        }

        for pid in listeners where !excludedPIDs.contains(pid) {
            terminateProcessTreeIfNeeded(pid: pid)
        }
    }

    private func listeningRuntimePIDs() async -> [Int32] {
        let command = "lsof -nP -t -iTCP:\(nativeBridgePort) -sTCP:LISTEN || true"
        guard let result = try? await runner.run(command: command) else {
            return []
        }
        return parsePIDs(from: result.stdout)
    }

    private func listeningRuntimePIDSSynchronously() -> [Int32] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "lsof -nP -t -iTCP:\(nativeBridgePort) -sTCP:LISTEN || true"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return parsePIDs(from: output)
        } catch {
            return []
        }
    }

    private func parsePIDs(from output: String) -> [Int32] {
        let values = output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
        return Array(Set(values))
    }

    private func readLogTail(_ fileURL: URL, maxCharacters: Int = 1_000) -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        if trimmed.count <= maxCharacters {
            return "Last runtime log: \(trimmed)"
        }

        let suffix = String(trimmed.suffix(maxCharacters))
        return "Last runtime log: \(suffix)"
    }

    private func persistStoppedSnapshot() {
        guard let snapshot = try? stateStore.readSnapshot() else {
            return
        }

        let next = BridgeSnapshot(
            currentVersion: snapshot.currentVersion,
            label: snapshot.label,
            platform: snapshot.platform,
            installed: snapshot.installed,
            launchdLoaded: false,
            launchdPid: nil,
            daemonConfig: snapshot.daemonConfig,
            bridgeStatus: BridgeRuntimeStatus(
                state: "stopped",
                connectionStatus: "idle",
                pid: nil,
                lastError: nil,
                updatedAt: Self.isoTimestamp()
            ),
            pairingSession: snapshot.pairingSession,
            stdoutLogPath: snapshot.stdoutLogPath,
            stderrLogPath: snapshot.stderrLogPath
        )
        try? stateStore.writeSnapshot(next)
    }

    private static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

    private func buildLaunchEnvironment(codexPath: String) -> [String: String] {
        let defaultPathEntries = [
            URL(fileURLWithPath: codexPath).deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let currentEnvironment = ProcessInfo.processInfo.environment
        let existingPathEntries = currentEnvironment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let pathEntries = Array(NSOrderedSet(array: defaultPathEntries + existingPathEntries)) as? [String] ?? defaultPathEntries

        return currentEnvironment.merging(["PATH": pathEntries.joined(separator: ":")]) { _, override in
            override
        }
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
        let configuredRelayURL = current.daemonConfig?.relayUrl ?? "ws://localhost:\(nativeBridgePort)/relay"
        let relayURL = directAppServerPairingURL(from: configuredRelayURL)
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
                pairingPayload: pairingPayload,
                pairingCode: shortPairingCode(from: trusted.relaySessionId)
            ),
            stdoutLogPath: current.stdoutLogPath,
            stderrLogPath: current.stderrLogPath
        )

        try stateStore.writeSnapshot(next)
    }

    // Rewrites loopback relay hosts to a LAN-reachable IP so phone/iPad QR pairing works off-device.
    private func directAppServerPairingURL(from rawRelayURL: String) -> String {
        guard var components = URLComponents(string: rawRelayURL),
              let host = components.host?.lowercased() else {
            return rawRelayURL
        }

        if isLoopbackHost(host), let lanIPAddress = preferredLANIPv4Address() {
            components.host = lanIPAddress
        }

        components.path = ""
        components.port = nativeBridgePort
        components.query = nil
        components.fragment = nil
        return components.string ?? rawRelayURL
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func preferredLANIPv4Address() -> String? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let firstAddress = addressList else {
            return nil
        }
        defer { freeifaddrs(addressList) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback else {
                continue
            }

            guard let rawAddress = interface.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let interfaceName = String(cString: interface.pointee.ifa_name)
            guard interfaceName.hasPrefix("en") else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                rawAddress,
                socklen_t(rawAddress.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                continue
            }

            let candidate = String(cString: hostBuffer)
            if !candidate.isEmpty {
                return candidate
            }
        }

        return nil
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

    func trustedState() async throws -> BridgeTrustedState {
        try stateStore.readTrustedState()
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

    // Generates a stable human-friendly code from the current relay session id.
    private func shortPairingCode(from sessionID: String) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let digest = SHA256.hash(data: Data(sessionID.utf8))
        let bytes = Array(digest)
        let code = String((0..<8).map { index in
            let byte = bytes[index % bytes.count]
            return alphabet[Int(byte) % alphabet.count]
        })
        let first = code.prefix(4)
        let second = code.suffix(4)
        return "\(first)-\(second)"
    }
}

final class BridgeControlService {
    private let facade: BridgeRuntimeFacade

    init(runner _: ShellCommandRunner = ShellCommandRunner()) {
        facade = .shared
    }

    func detectCLIAvailability() async -> BridgeCLIAvailability {
        await facade.detectCLIAvailability()
    }

    func loadSnapshot(relayOverride: String?) async throws -> BridgeSnapshot {
        let snapshot = await facade.loadSnapshot()
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

    func loadTrustedState() async throws -> BridgeTrustedState {
        let snapshot = await facade.loadSnapshot()
        if let payload = snapshot.pairingSession?.pairingPayload {
            return BridgeTrustedState(
                macDeviceId: payload.macDeviceId,
                macIdentityPublicKey: payload.macIdentityPublicKey,
                relaySessionId: payload.sessionId,
                keyEpoch: 1,
                trustedPhoneDeviceID: nil,
                lastUpdatedAtISO8601: BridgeSnapshot.isoTimestamp()
            )
        }

        return BridgeTrustedState(
            macDeviceId: UUID().uuidString,
            macIdentityPublicKey: UUID().uuidString,
            relaySessionId: UUID().uuidString,
            keyEpoch: 1,
            trustedPhoneDeviceID: nil,
            lastUpdatedAtISO8601: BridgeSnapshot.isoTimestamp()
        )
    }

    func startBridge(relayOverride _: String?) async throws {
        try await facade.startBridge()
    }

    func stopBridge(relayOverride _: String?) async throws {
        await facade.stopBridge()
    }

    func resumeLastThread(relayOverride _: String?) async throws {
        throw BridgeControlError.unsupportedOperation(
            "Resume last thread is not available in bridge v2 command mode."
        )
    }

    func resetPairing(relayOverride _: String?) async throws {
        await facade.resetPairing()
    }

    func restartCodex() async throws {
        try await facade.restartCodex()
    }

    func startCodex() async throws {
        try await facade.startCodex()
    }

    func stopCodex() async {
        await facade.stopCodex()
    }

    func listActiveSessions() async -> [BridgeSessionSummary] {
        await facade.listSessions()
    }

    func closeActiveSession(_ sessionID: String) async {
        await facade.closeSession(sessionID)
    }

    func loadRuntimeSettings() async -> BridgeRuntimeSettings {
        await facade.loadSettings()
    }

    func saveRuntimeSettings(_ settings: BridgeRuntimeSettings) async {
        await facade.saveSettings(settings)
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

    func forceStopBridgeForTermination() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [facade] in
            await facade.shutdownForTermination()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
    }
}

private extension BridgeSnapshot {
    static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
#endif
