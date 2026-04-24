// FILE: BridgeRuntimeService.swift
// Purpose: Orchestrates bridge server lifecycle, command routing, and high-level status snapshots.
// Layer: Companion app service
// Exports: BridgeRuntimeFacade
// Depends on: Foundation, BridgeRuntimeModels, BridgeControlModels

#if os(macOS)
import Foundation
actor BridgeRuntimeService {
    let settingsStore = BridgeRuntimeSettingsStore()
    let logs = BridgeRuntimeLogStore()
    let processManager = CodexProcessManager()
    let server = BridgeServer()
    let sessionManager = CodexSessionManager()

    var runtimeState = BridgeRuntimeState()
    var staticTrustedState = BridgeTrustedState(
        macDeviceId: UUID().uuidString,
        macIdentityPublicKey: UUID().uuidString,
        relaySessionId: UUID().uuidString,
        keyEpoch: 1,
        trustedPhoneDeviceID: nil,
        lastUpdatedAtISO8601: BridgeRuntimeService.isoTimestamp()
    )

    func detectCLIAvailability() async -> BridgeCLIAvailability {
        let settings = await settingsStore.load()
        let availability = await processManager.detectCLIAvailability(settings: settings)
        runtimeState.codexCLIAvailability = availability
        return availability
    }

    func loadSettings() async -> BridgeRuntimeSettings {
        await settingsStore.load()
    }

    func saveSettings(_ settings: BridgeRuntimeSettings) async {
        await settingsStore.save(settings)
    }

    func startBridge() async throws {
        if runtimeState.bridgeRunning {
            return
        }

        let settings = await settingsStore.load()
        let availability = await processManager.detectCLIAvailability(settings: settings)
        runtimeState.codexCLIAvailability = availability

        if case .missing = availability {
            throw BridgeRuntimeError.codexUnavailable("Codex CLI is not installed. Configure the executable path in bridge settings.")
        }

        if settings.autoStartCodexOnBridgeStart {
            try await startCodexIfNeeded(settings: settings)
        }

        do {
            try await server.start(
                settings: settings,
                onRequest: { [weak self] connectionID, text in
                    await self?.handleInboundText(connectionID: connectionID, text: text)
                },
                onDisconnect: { [weak self] connectionID in
                    await self?.handleDisconnect(connectionID: connectionID)
                },
                log: { [weak self] line in
                    Task {
                        await self?.log(line)
                    }
                }
            )
        } catch {
            if case BridgeRuntimeError.bridgeAlreadyRunning = error {
                runtimeState.bridgeRunning = true
                return
            }
            await logs.recordError(error.localizedDescription)
            throw error
        }

        runtimeState.bridgeRunning = true
    }

    func stopBridge() async {
        guard runtimeState.bridgeRunning else {
            return
        }
        await server.stop()
        await sessionManager.closeAllSessions()
        runtimeState.bridgeRunning = false
        runtimeState.connectedClientCount = 0
        runtimeState.activeSessionCount = 0
    }

    func startCodex() async throws {
        let settings = await settingsStore.load()
        _ = try await startCodexIfNeeded(settings: settings)
    }

    func stopCodex() async {
        await processManager.stop()
        runtimeState.codexRunning = false
        runtimeState.codexProcessID = nil
        await sessionManager.closeAllSessions()
        runtimeState.activeSessionCount = 0
    }

    func restartCodex() async throws {
        let settings = await settingsStore.load()
        do {
            let pid = try await processManager.restart(settings: settings, log: { [weak self] line in
                Task {
                    await self?.log(line)
                }
            })
            runtimeState.codexRunning = true
            runtimeState.codexProcessID = pid
            await sessionManager.closeAllSessions()
            runtimeState.activeSessionCount = 0
        } catch {
            runtimeState.codexRunning = false
            runtimeState.codexProcessID = nil
            await logs.recordError(error.localizedDescription)
            throw error
        }
    }

    func listSessions() async -> [BridgeSessionSummary] {
        await sessionManager.listSessions()
    }

    func closeSession(_ sessionID: String) async {
        await sessionManager.closeSession(sessionID)
        runtimeState.activeSessionCount = await sessionManager.sessionCount()
    }

    func snapshot() async -> BridgeSnapshot {
        let settings = await settingsStore.load()
        runtimeState.connectedClientCount = await server.connectedClientCount()
        runtimeState.activeSessionCount = await sessionManager.sessionCount()
        runtimeState.codexRunning = await processManager.isRunning()
        runtimeState.codexProcessID = await processManager.processID()
        let recentErrors = await logs.errors

        let pairingPayload = BridgePairingPayload(
            v: 2,
            relay: effectiveBridgeReachableURL(settings: settings),
            sessionId: staticTrustedState.relaySessionId,
            macDeviceId: staticTrustedState.macDeviceId,
            macIdentityPublicKey: staticTrustedState.macIdentityPublicKey,
            expiresAt: Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000),
            transport: "bridge_v2"
        )

        return BridgeSnapshot(
            currentVersion: runtimeState.codexCLIAvailability.versionLabel ?? "unknown",
            label: "com.remodex.bridgecore",
            platform: "darwin",
            installed: runtimeState.codexCLIAvailability.isAvailable,
            launchdLoaded: runtimeState.bridgeRunning,
            launchdPid: runtimeState.codexProcessID,
            daemonConfig: BridgeDaemonConfig(
                relayUrl: settings.bridgeListenURL,
                pushServiceUrl: nil,
                codexEndpoint: settings.codexListenURL,
                refreshEnabled: true
            ),
            bridgeStatus: BridgeRuntimeStatus(
                state: runtimeState.bridgeRunning ? "running" : "stopped",
                connectionStatus: runtimeState.bridgeRunning ? "connected" : "idle",
                pid: runtimeState.codexProcessID,
                lastError: recentErrors.last,
                updatedAt: Self.isoTimestamp(),
                connectedClientCount: runtimeState.connectedClientCount,
                activeSessionCount: runtimeState.activeSessionCount,
                bridgeURL: effectiveBridgeReachableURL(settings: settings),
                codexURL: settings.codexListenURL,
                recentErrors: recentErrors
            ),
            pairingSession: BridgePairingSession(
                createdAt: Self.isoTimestamp(),
                pairingPayload: pairingPayload,
                pairingCode: shortPairingCode(from: staticTrustedState.relaySessionId)
            ),
            stdoutLogPath: "",
            stderrLogPath: ""
        )
    }

    func resetPairing() {
        staticTrustedState = BridgeTrustedState(
            macDeviceId: staticTrustedState.macDeviceId,
            macIdentityPublicKey: staticTrustedState.macIdentityPublicKey,
            relaySessionId: UUID().uuidString,
            keyEpoch: staticTrustedState.keyEpoch + 1,
            trustedPhoneDeviceID: nil,
            lastUpdatedAtISO8601: Self.isoTimestamp()
        )
    }

    func forceStopForTermination() async {
        await server.stop()
        await processManager.stop()
        await sessionManager.closeAllSessions()
        runtimeState.bridgeRunning = false
        runtimeState.codexRunning = false
        runtimeState.codexProcessID = nil
    }

    func startCodexIfNeeded(settings: BridgeRuntimeSettings) async throws -> Int {
        if await processManager.isRunning(), let pid = await processManager.processID() {
            runtimeState.codexRunning = true
            runtimeState.codexProcessID = pid
            return pid
        }

        do {
            let pid = try await processManager.start(settings: settings, log: { [weak self] line in
                Task {
                    await self?.log(line)
                }
            })
            runtimeState.codexRunning = true
            runtimeState.codexProcessID = pid
            return pid
        } catch {
            runtimeState.codexRunning = false
            runtimeState.codexProcessID = nil
            await logs.recordError(error.localizedDescription)
            throw error
        }
    }

}

final class BridgeRuntimeFacade {
    static let shared = BridgeRuntimeFacade()

    private let runtime = BridgeRuntimeService()

    func detectCLIAvailability() async -> BridgeCLIAvailability {
        await runtime.detectCLIAvailability()
    }

    func loadSnapshot() async -> BridgeSnapshot {
        await runtime.snapshot()
    }

    func startBridge() async throws {
        try await runtime.startBridge()
    }

    func stopBridge() async {
        await runtime.stopBridge()
    }

    func startCodex() async throws {
        try await runtime.startCodex()
    }

    func stopCodex() async {
        await runtime.stopCodex()
    }

    func restartCodex() async throws {
        try await runtime.restartCodex()
    }

    func resetPairing() async {
        await runtime.resetPairing()
    }

    func listSessions() async -> [BridgeSessionSummary] {
        await runtime.listSessions()
    }

    func closeSession(_ sessionID: String) async {
        await runtime.closeSession(sessionID)
    }

    func loadSettings() async -> BridgeRuntimeSettings {
        await runtime.loadSettings()
    }

    func saveSettings(_ settings: BridgeRuntimeSettings) async {
        await runtime.saveSettings(settings)
    }

    func shutdownForTermination() async {
        await runtime.forceStopForTermination()
    }
}

#endif
