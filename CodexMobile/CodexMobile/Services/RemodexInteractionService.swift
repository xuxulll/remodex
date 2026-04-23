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
            do {
                try await self.codexService.startLocalMacBridge()
            } catch {
                return
            }
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
    private let bridgeControlService = BridgeControlService()

    // Boots the native macOS bridge host so the app can connect directly as a local client.
    func startIfNeeded() async {
        do {
            try await bridgeControlService.startBridge(relayOverride: nil)
        } catch {
            return
        }
    }

    func stopIfNeeded() async {
        try? await bridgeControlService.stopBridge(relayOverride: nil)
    }

    func stopForTermination() {
        bridgeControlService.forceStopBridgeForTermination()
    }
}
#endif
