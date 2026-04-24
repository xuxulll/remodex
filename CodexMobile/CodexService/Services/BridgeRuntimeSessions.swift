// FILE: BridgeRuntimeSessions.swift
// Purpose: Session ownership tracking and request routing between bridge clients and Codex channels.
// Layer: Companion app service
// Exports: CodexSessionManager
// Depends on: Foundation

#if os(macOS)
import Foundation
private struct BridgeSessionState {
    let sessionID: String
    let ownerKey: String
    let clientID: String?
    let createdAt: Date
    var lastActivityAt: Date
    var connectionID: String
    var codexChannel: CodexSessionChannel

    var summary: BridgeSessionSummary {
        BridgeSessionSummary(
            sessionId: sessionID,
            clientId: clientID,
            connectionStatus: "connected",
            createdAt: createdAt,
            lastActivityAt: lastActivityAt
        )
    }
}

actor CodexSessionManager {
    private var sessions: [String: BridgeSessionState] = [:]

    func sessionCount() -> Int {
        sessions.count
    }

    func handleDisconnect(connectionID: String) {
        for key in sessions.keys {
            guard var session = sessions[key], session.connectionID == connectionID else {
                continue
            }
            session.connectionID = ""
            sessions[key] = session
        }
    }

    func listSessions() -> [BridgeSessionSummary] {
        sessions.values
            .map(\.summary)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }
        await session.codexChannel.close()
    }

    func closeAllSessions() async {
        let existing = sessions.values
        sessions.removeAll()
        for session in existing {
            await session.codexChannel.close()
        }
    }

    func handleRequest(
        connectionID: String,
        request: BridgeClientRequest,
        codexURL: URL,
        logger: @escaping @Sendable (String) -> Void,
        onSessionCreated: @escaping @Sendable (String, String, String) async -> Void,
        onDelta: @escaping @Sendable (String, String, String, String) async -> Void,
        onCompleted: @escaping @Sendable (String, String, String) async -> Void,
        onError: @escaping @Sendable (String, String?, String, String?) async -> Void
    ) async {
        do {
            var session = try resolveSession(connectionID: connectionID, request: request, codexURL: codexURL, logger: logger)
            let isNewSession = request.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            if isNewSession {
                await onSessionCreated(connectionID, session.sessionID, request.messageId)
            }

            session.lastActivityAt = Date()
            sessions[session.sessionID] = session

            try await session.codexChannel.sendUserText(
                request.text,
                messageID: request.messageId,
                onDelta: { delta in
                    await onDelta(session.connectionID, session.sessionID, request.messageId, delta)
                }
            )

            await onCompleted(session.connectionID, session.sessionID, request.messageId)
        } catch {
            await onError(connectionID, request.messageId, error.localizedDescription, request.sessionId)
        }
    }

    func handleRPCRequest(
        connectionID: String,
        request: BridgeClientRequest,
        codexURL: URL,
        logger: @escaping @Sendable (String) -> Void,
        onSessionCreated: @escaping @Sendable (String, String, String) async -> Void,
        onRPCResult: @escaping @Sendable (String, String, String, String, BridgeRPCEnvelope) async -> Void,
        onError: @escaping @Sendable (String, String?, String, String?) async -> Void
    ) async {
        guard let rpcMethod = request.rpcMethod?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rpcMethod.isEmpty else {
            await onError(connectionID, request.messageId, "Missing rpc_method.", request.sessionId)
            return
        }
        guard let rpcRequestId = request.rpcRequestId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rpcRequestId.isEmpty else {
            await onError(connectionID, request.messageId, "Missing rpc_request_id.", request.sessionId)
            return
        }

        do {
            var session = try resolveSession(
                connectionID: connectionID,
                request: request,
                codexURL: codexURL,
                logger: logger
            )
            let isNewSession = request.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            if isNewSession {
                await onSessionCreated(connectionID, session.sessionID, request.messageId)
            }

            session.lastActivityAt = Date()
            sessions[session.sessionID] = session

            let response = try await session.codexChannel.sendRPCRequest(
                method: rpcMethod,
                params: request.rpcParams
            )
            await onRPCResult(
                session.connectionID,
                session.sessionID,
                request.messageId,
                rpcRequestId,
                response
            )
        } catch {
            await onError(connectionID, request.messageId, error.localizedDescription, request.sessionId)
        }
    }

    private func resolveSession(
        connectionID: String,
        request: BridgeClientRequest,
        codexURL: URL,
        logger: @escaping @Sendable (String) -> Void
    ) throws -> BridgeSessionState {
        let requestedSessionID = request.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerKey = makeOwnerKey(connectionID: connectionID, clientID: request.clientId)

        if let requestedSessionID, !requestedSessionID.isEmpty {
            guard var existing = sessions[requestedSessionID] else {
                throw BridgeRuntimeError.invalidSession("Unknown session_id: \(requestedSessionID)")
            }

            guard existing.ownerKey == ownerKey else {
                throw BridgeRuntimeError.invalidSession("session_id does not belong to this client.")
            }

            existing.connectionID = connectionID
            existing.lastActivityAt = Date()
            sessions[requestedSessionID] = existing
            return existing
        }

        let sessionID = UUID().uuidString
        let channel = CodexSessionChannel(codexURL: codexURL, logger: logger)
        let now = Date()
        let newSession = BridgeSessionState(
            sessionID: sessionID,
            ownerKey: ownerKey,
            clientID: normalizedClientID(request.clientId),
            createdAt: now,
            lastActivityAt: now,
            connectionID: connectionID,
            codexChannel: channel
        )
        sessions[sessionID] = newSession
        return newSession
    }

    private func makeOwnerKey(connectionID: String, clientID: String?) -> String {
        if let normalized = normalizedClientID(clientID) {
            return "client:\(normalized)"
        }
        return "connection:\(connectionID)"
    }

    private func normalizedClientID(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif
