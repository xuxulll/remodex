// FILE: BridgeControlModels.swift
// Purpose: Shared bridge-core contracts and snapshot models used by the macOS bridge runtime + menu bar UI.
// Layer: Companion app model
// Exports: bridge core protocols, runtime snapshots, pairing models, and menu-bar UI state helpers
// Depends on: Foundation

import Foundation

protocol BridgeRuntimeControlling {
    func start() async throws
    func stop() async throws
    func status() async throws -> BridgeSnapshot
    func resetPairing() async throws
    func resumeThread() async throws
}

protocol SecureTransporting {
    func beginHandshake() async throws -> BridgeHandshakeState
    func encryptEnvelope(_ payload: String) throws -> BridgeSecureEnvelope
    func decryptEnvelope(_ envelope: BridgeSecureEnvelope) throws -> String
    func applyResumeState(_ state: BridgeResumeState)
}

protocol CodexHosting {
    func launch() async throws -> BridgeRuntimeProcessState
    func shutdown() async
    func sendRPC(_ payload: String) async throws -> String
    func streamEvents(_ onEvent: @escaping @Sendable (String) -> Void) async
}

protocol BridgeStatePersisting {
    func readSnapshot() throws -> BridgeSnapshot
    func writeSnapshot(_ snapshot: BridgeSnapshot) throws
    func readTrustedState() throws -> BridgeTrustedState
    func writeTrustedState(_ trustedState: BridgeTrustedState) throws
}

struct BridgeSnapshot: Codable, Equatable {
    let currentVersion: String
    let label: String
    let platform: String
    let installed: Bool
    let launchdLoaded: Bool
    let launchdPid: Int?
    let daemonConfig: BridgeDaemonConfig?
    let bridgeStatus: BridgeRuntimeStatus?
    let pairingSession: BridgePairingSession?
    let stdoutLogPath: String
    let stderrLogPath: String
}

struct BridgeDaemonConfig: Codable, Equatable {
    let relayUrl: String?
    let pushServiceUrl: String?
    let codexEndpoint: String?
    let refreshEnabled: Bool?
}

struct BridgeRuntimeStatus: Codable, Equatable {
    let state: String?
    let connectionStatus: String?
    let pid: Int?
    let lastError: String?
    let updatedAt: String?
}

struct BridgePairingSession: Codable, Equatable {
    let createdAt: String?
    let pairingPayload: BridgePairingPayload?
    let pairingCode: String?
}

struct BridgePairingPayload: Codable, Equatable {
    let v: Int
    let relay: String
    let sessionId: String
    let macDeviceId: String
    let macIdentityPublicKey: String
    let expiresAt: Int64
    let transport: String?
}

struct BridgeTrustedState: Codable, Equatable {
    let macDeviceId: String
    let macIdentityPublicKey: String
    let relaySessionId: String
    let keyEpoch: Int
    let trustedPhoneDeviceID: String?
    let lastUpdatedAtISO8601: String
}

struct BridgeHandshakeState: Codable, Equatable {
    let keyEpoch: Int
    let sessionId: String
    let startedAt: Date
}

struct BridgeSecureEnvelope: Codable, Equatable {
    let nonce: String
    let ciphertext: String
    let tag: String
}

struct BridgeResumeState: Codable, Equatable {
    let lastAppliedOutboundSequence: Int
}

struct BridgeRuntimeProcessState: Codable, Equatable {
    let processIdentifier: Int
    let startedAt: Date
}

struct BridgePackageUpdateState: Equatable {
    let installedVersion: String?
    let latestVersion: String?
    let errorMessage: String?

    static let empty = BridgePackageUpdateState(
        installedVersion: nil,
        latestVersion: nil,
        errorMessage: nil
    )

    var isUpdateAvailable: Bool {
        guard let installedVersion,
              let latestVersion else {
            return false
        }

        return installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending
    }
}

enum BridgeCLIAvailability: Equatable {
    case checking
    case available(version: String)
    case missing
    case broken(message: String)

    static let installCommand = "Install/enable Codex CLI in Settings"

    var isAvailable: Bool {
        if case .available = self {
            return true
        }

        return false
    }

    var statusLabel: String {
        switch self {
        case .checking:
            return "Checking"
        case .available:
            return "Runtime Ready"
        case .missing:
            return "Runtime Missing"
        case .broken:
            return "Runtime Error"
        }
    }

    var versionLabel: String? {
        guard case .available(let version) = self else {
            return nil
        }

        return version
    }

    var setupTitle: String {
        switch self {
        case .checking:
            return "Checking Codex Runtime"
        case .available:
            return "Runtime Ready"
        case .missing:
            return "Codex Runtime Required"
        case .broken:
            return "Runtime Needs Attention"
        }
    }

    var setupMessage: String {
        switch self {
        case .checking:
            return "Looking for a usable Codex CLI/runtime before enabling the native bridge runtime."
        case .available(let version):
            return "Detected Codex runtime (\(version))."
        case .missing:
            return "Install Codex CLI on this Mac. The native bridge needs it to host app-server requests."
        case .broken(let message):
            return "Found Codex CLI, but runtime validation failed. \(message)"
        }
    }
}

extension BridgeSnapshot {
    var effectiveRelayURL: String {
        pairingSession?.pairingPayload?.relay.nonEmptyTrimmed
        ?? daemonConfig?.relayUrl?.nonEmptyTrimmed
        ?? ""
    }

    var statusHeadline: String {
        if let connectionStatus = bridgeStatus?.connectionStatus?.nonEmptyTrimmed {
            return connectionStatus.capitalized
        }

        if launchdLoaded {
            return "Running"
        }

        return "Stopped"
    }

    var statusFootnote: String {
        if let updatedAt = bridgeStatus?.updatedDate {
            return Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date())
        }

        return launchdLoaded ? "Bridge active" : "Bridge inactive"
    }

    var lastErrorMessage: String {
        bridgeStatus?.lastError?.nonEmptyTrimmed ?? ""
    }

    var stateDirectoryPath: String {
        let stderrURL = URL(fileURLWithPath: stderrLogPath)
        return stderrURL.deletingLastPathComponent().deletingLastPathComponent().path
    }

    var relayKindLabel: String {
        classifyRelay(effectiveRelayURL)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

extension BridgeRuntimeStatus {
    var updatedDate: Date? {
        updatedAt.flatMap(bridgeISO8601Formatter.date)
    }
}

extension BridgePairingSession {
    var createdDate: Date? {
        createdAt.flatMap(bridgeISO8601Formatter.date)
    }
}

extension BridgePairingPayload {
    var expiryDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000)
    }

    var isExpired: Bool {
        expiryDate <= Date()
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func classifyRelay(_ relayURL: String) -> String {
    guard let components = URLComponents(string: relayURL),
          let host = components.host?.lowercased(),
          !host.isEmpty else {
        return "Unconfigured"
    }

    if host == "localhost"
        || host == "127.0.0.1"
        || host == "::1"
        || host.hasSuffix(".local")
        || host.hasPrefix("10.")
        || host.hasPrefix("192.168.")
        || isPrivate172Address(host) {
        return "Local"
    }

    return "Remote"
}

private let bridgeISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private func isPrivate172Address(_ host: String) -> Bool {
    let parts = host.split(separator: ".")
    guard parts.count == 4,
          parts[0] == "172",
          let secondOctet = Int(parts[1]) else {
        return false
    }

    return (16...31).contains(secondOctet)
}
