// FILE: BridgeMenuBarStore.swift
// Purpose: Owns CLI gating, bridge polling, command execution, and local relay override persistence for the menu bar control center.
// Layer: Companion app state
// Exports: BridgeMenuBarStore
// Depends on: AppKit, Combine, Foundation, BridgeControlService, BridgeControlModels

import AppKit
import Combine
import Foundation

enum BridgeMenuBarActionError: LocalizedError {
    case missingCLI
    case brokenCLI(String)
    case pairingTimeout

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            return "Install the Codex runtime before using the macOS bridge."
        case .brokenCLI(let message):
            return message
        case .pairingTimeout:
            return "The bridge did not publish a fresh pairing session in time. Check the daemon logs and try again."
        }
    }
}

@MainActor
final class BridgeMenuBarStore: ObservableObject {
    @Published var snapshot: BridgeSnapshot?
    @Published var updateState = BridgePackageUpdateState.empty
    @Published var cliAvailability: BridgeCLIAvailability = .checking
    @Published var runtimeSettings: BridgeRuntimeSettings = .default
    @Published var sessions: [BridgeSessionSummary] = []
    @Published var relayOverride: String
    @Published var isRefreshing = false
    @Published var isPerformingAction = false
    @Published var transientMessage = ""
    @Published var errorMessage = ""

    private static let relayOverrideKey = "remodex.menuBar.relayOverride"
    private let service: BridgeControlService
    private var refreshLoopTask: Task<Void, Never>?

    init(service: BridgeControlService? = nil) {
        self.service = service ?? BridgeControlService()
        self.relayOverride = UserDefaults.standard.string(forKey: Self.relayOverrideKey) ?? ""
        startRefreshLoop()

        Task {
            await self.bootstrap()
        }
    }

    deinit {
        refreshLoopTask?.cancel()
    }

    // Refreshes the bridge snapshot plus npm update metadata so the menu bar is the new control surface.
    func refresh(showSpinner: Bool = false) async {
        do {
            _ = try await performRefresh(
                showSpinner: showSpinner,
                clearSnapshotOnFailure: false
            )
        } catch {
            // Passive refreshes keep the last known snapshot so brief shell hiccups do not blank the menu bar.
        }
    }

    func saveRelayOverride(_ value: String) {
        relayOverride = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(relayOverride, forKey: Self.relayOverrideKey)
        Task {
            await self.refresh(showSpinner: true)
        }
    }

    func clearRelayOverride() {
        relayOverride = ""
        UserDefaults.standard.removeObject(forKey: Self.relayOverrideKey)
        Task {
            await self.refresh(showSpinner: true)
        }
    }

    func startBridge() {
        let previousPairingDate = snapshot?.pairingSession?.createdDate
        runAction(successMessage: "Bridge started.") {
            try await self.requireCLIAvailability()
            try await self.service.startBridge(relayOverride: self.effectiveRelayOverride)
            try await self.waitForFreshPairing(after: previousPairingDate)
        }
    }

    func stopBridge() {
        runAction(successMessage: "Bridge stopped.") {
            try await self.requireCLIAvailability()
            try await self.service.stopBridge(relayOverride: self.effectiveRelayOverride)
            try await self.refreshAfterAction()
        }
    }

    func startCodex() {
        runAction(successMessage: "Codex started.") {
            try await self.requireCLIAvailability()
            try await self.service.startCodex()
            try await self.refreshAfterAction()
        }
    }

    func stopCodex() {
        runAction(successMessage: "Codex stopped.") {
            await self.service.stopCodex()
            try await self.refreshAfterAction()
        }
    }

    func restartCodex() {
        runAction(successMessage: "Codex restarted.") {
            try await self.requireCLIAvailability()
            try await self.service.restartCodex()
            try await self.refreshAfterAction()
        }
    }

    func resumeLastThread() {
        runAction(successMessage: "Ultimo thread riaperto in Codex.") {
            try await self.requireCLIAvailability()
            try await self.service.resumeLastThread(relayOverride: self.effectiveRelayOverride)
            try await self.refreshAfterAction()
        }
    }

    func resetPairing() {
        runAction(successMessage: "Pairing resettato.") {
            try await self.requireCLIAvailability()
            try await self.service.resetPairing(relayOverride: self.effectiveRelayOverride)
            try await self.refreshAfterAction()
        }
    }

    func updateBridgePackage() {
        runAction(successMessage: "Bridge aggiornato all’ultima release.") {
            try await self.requireCLIAvailability()
            try await self.service.updateBridgePackage()
            if self.snapshot?.launchdLoaded == true {
                try await self.service.startBridge(relayOverride: self.effectiveRelayOverride)
            }
            try await self.refreshAfterAction()
        }
    }

    func retryCLISetup() {
        Task {
            await self.refresh(showSpinner: true)
        }
    }

    func openLogsFolder() {
        let path = snapshot?.stateDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath = (path?.isEmpty == false) ? path! : "\(NSHomeDirectory())/.remodex"
        NSWorkspace.shared.open(URL(fileURLWithPath: targetPath))
    }

    func openStdoutLog() {
        guard let snapshot, !snapshot.stdoutLogPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: snapshot.stdoutLogPath))
    }

    func openStderrLog() {
        guard let snapshot, !snapshot.stderrLogPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: snapshot.stderrLogPath))
    }

    func saveRuntimeSettings() {
        let normalized = normalizedSettings(runtimeSettings)
        runtimeSettings = normalized
        Task {
            await service.saveRuntimeSettings(normalized)
            await refresh(showSpinner: true)
        }
    }

    func closeSession(_ sessionID: String) {
        Task {
            await service.closeActiveSession(sessionID)
            await refresh(showSpinner: true)
        }
    }

    private var effectiveRelayOverride: String? {
        relayOverride.isEmpty ? nil : relayOverride
    }

    var isCLIAvailable: Bool {
        cliAvailability.isAvailable
    }

    private func startRefreshLoop() {
        refreshLoopTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(480))
                guard !Task.isCancelled else { return }
                await self.refresh(showSpinner: false)
            }
        }
    }

    // Performs the first load in two stages so the UI can show a dedicated "install the CLI" blocker.
    private func bootstrap() async {
        runtimeSettings = await service.loadRuntimeSettings()
        let cliAvailability = await refreshCLIAvailability()
        guard cliAvailability.isAvailable else {
            snapshot = nil
            updateState = .empty
            return
        }

        await refresh(showSpinner: true)
    }

    @discardableResult
    private func refreshCLIAvailability() async -> BridgeCLIAvailability {
        let availability = await service.detectCLIAvailability()
        cliAvailability = availability
        return availability
    }

    private func requireCLIAvailability() async throws {
        switch await refreshCLIAvailability() {
        case .available:
            return
        case .missing:
            throw BridgeMenuBarActionError.missingCLI
        case .broken(let message):
            throw BridgeMenuBarActionError.brokenCLI(message)
        case .checking:
            throw BridgeMenuBarActionError.missingCLI
        }
    }

    private func resolveUpdateState(installedVersion: String) async -> BridgePackageUpdateState {
        let latestVersionResult = await service.fetchLatestPackageVersion()
        switch latestVersionResult {
        case .success(let latestVersion):
            return BridgePackageUpdateState(
                installedVersion: installedVersion,
                latestVersion: latestVersion,
                errorMessage: nil
            )
        case .failure(let error):
            return BridgePackageUpdateState(
                installedVersion: installedVersion,
                latestVersion: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    // Lets command handlers fail loudly when the follow-up snapshot cannot be trusted.
    private func refreshAfterAction() async throws {
        _ = try await performRefresh(
            showSpinner: false,
            clearSnapshotOnFailure: true
        )
    }

    @discardableResult
    private func performRefresh(
        showSpinner: Bool,
        clearSnapshotOnFailure: Bool
    ) async throws -> BridgeSnapshot? {
        if showSpinner {
            isRefreshing = true
        }

        defer {
            isRefreshing = false
        }

        let cliAvailability = await refreshCLIAvailability()
        guard cliAvailability.isAvailable else {
            snapshot = nil
            updateState = .empty
            transientMessage = ""
            errorMessage = ""
            return nil
        }

        do {
            let snapshot = try await service.loadSnapshot(relayOverride: effectiveRelayOverride)
            self.snapshot = snapshot
            self.sessions = await service.listActiveSessions()
            self.errorMessage = ""
            self.updateState = await resolveUpdateState(installedVersion: snapshot.currentVersion)
            return snapshot
        } catch {
            if clearSnapshotOnFailure {
                snapshot = nil
                updateState = .empty
            }
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func normalizedSettings(_ settings: BridgeRuntimeSettings) -> BridgeRuntimeSettings {
        var normalized = settings
        normalized.bridgeListenHost = normalized.bridgeListenHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.bridgeListenHost.isEmpty {
            normalized.bridgeListenHost = "0.0.0.0"
        }
        normalized.codexListenHost = normalized.codexListenHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.codexListenHost.isEmpty {
            normalized.codexListenHost = "127.0.0.1"
        }
        normalized.codexExecutablePath = normalized.codexExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.codexExecutablePath.isEmpty {
            normalized.codexExecutablePath = "codex"
        }
        normalized.authToken = normalized.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.authToken.isEmpty {
            normalized.authToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        if !(1...65_535).contains(normalized.bridgePort) {
            normalized.bridgePort = 9010
        }
        if !(1...65_535).contains(normalized.codexPort) {
            normalized.codexPort = 9009
        }
        return normalized
    }

    // Treats a missing fresh QR as a real start failure so the menu bar never reports a false success.
    private func waitForFreshPairing(after previousPairingDate: Date?) async throws {
        for _ in 0..<20 {
            do {
                let nextSnapshot = try await service.loadSnapshot(relayOverride: effectiveRelayOverride)
                let nextPairingDate = nextSnapshot.pairingSession?.createdDate
                self.snapshot = nextSnapshot
                self.updateState = await resolveUpdateState(installedVersion: nextSnapshot.currentVersion)
                if previousPairingDate == nil {
                    if nextSnapshot.pairingSession?.pairingPayload != nil {
                        return
                    }
                } else if let nextPairingDate,
                          let previousPairingDate,
                          nextPairingDate > previousPairingDate {
                    return
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        throw BridgeMenuBarActionError.pairingTimeout
    }

    private func runAction(
        successMessage: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isPerformingAction else {
            return
        }

        isPerformingAction = true
        transientMessage = ""
        errorMessage = ""

        Task {
            defer {
                self.isPerformingAction = false
            }

            do {
                try await operation()
                self.transientMessage = successMessage
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
