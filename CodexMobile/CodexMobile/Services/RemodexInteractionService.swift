// FILE: RemodexInteractionService.swift
// Purpose: Single integration surface that owns Codex chat service + platform runtime hooks.
// Layer: Service
// Exports: RemodexInteractionService

import Foundation
import SwiftUI

@MainActor
final class RemodexInteractionService {
    let codexService: CodexService
    #if os(macOS)
    private let macBridgeRuntime = RemodexMacBridgeRuntime()
    #endif

    init(codexService: CodexService) {
        self.codexService = codexService
        self.codexService.configureNotifications()
        #if os(macOS)
        self.codexService.localBridgeServerURL = RemodexMacBridgeRuntime.localBridgeWebSocketURL
        Task { @MainActor in
            await self.macBridgeRuntime.startIfNeeded()
        }
        #endif
    }

    func handleMemoryWarning() {
        TurnCacheManager.resetAll()
    }

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        guard newPhase == .background else {
            return
        }
        TurnCacheManager.resetAll()
    }

    #if os(macOS)
    func handleApplicationWillTerminate() {
        macBridgeRuntime.stopForTermination()
    }
    #endif
}

#if os(macOS)
@MainActor
final class RemodexMacBridgeRuntime {
    static let localBridgeWebSocketURL = "ws://127.0.0.1:9010/"
    private static let watchdogIntervalNanoseconds: UInt64 = 5_000_000_000
    private let bridgeControlService = BridgeControlService()
    private var watchdogTask: Task<Void, Never>?
    private var isTerminating = false

    // Boots the native macOS bridge host so the app can connect directly as a local client.
    func startIfNeeded() async {
        guard !isTerminating else {
            return
        }

        let settings = await bridgeControlService.loadRuntimeSettings()
        guard settings.autoStartBridgeOnLaunch else {
            return
        }

        ensureWatchdogRunning()

        do {
            try await bridgeControlService.startBridge(relayOverride: nil)
        } catch {
            return
        }
    }

    func stopIfNeeded() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        try? await bridgeControlService.stopBridge(relayOverride: nil)
    }

    func stopForTermination() {
        isTerminating = true
        watchdogTask?.cancel()
        watchdogTask = nil
        bridgeControlService.forceStopBridgeForTermination()
    }

    private func ensureWatchdogRunning() {
        guard watchdogTask == nil else {
            return
        }

        watchdogTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.watchdogIntervalNanoseconds)
                } catch {
                    return
                }

                guard !Task.isCancelled, !self.isTerminating else {
                    return
                }

                try? await self.bridgeControlService.startBridge(relayOverride: nil)
            }
        }
    }
}
#endif
